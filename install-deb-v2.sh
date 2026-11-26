#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/deepseekretro/mintpanel-desktop/main/dist}"
TOKEN="${TOKEN:-}"
# Release URL helper. The default BASE_URL is this repository's public dist/ and needs
# no credentials. Point BASE_URL at a private mirror and set TOKEN to use that instead.
rel_url() {
  if [ -n "$TOKEN" ]; then
    printf '%s/releases/%s?token=%s' "$BASE_URL" "$1" "$TOKEN"
  else
    printf '%s/%s' "$BASE_URL" "$1"
  fi
}
TARGET="${MINTPANEL_DIR:-$HOME}"
PANEL_PORT="${MINTPANEL_PORT:-8090}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"

OPT_DIR="$TARGET/opt"
OPT_NODE="$OPT_DIR/node"
OPT_PANEL="$OPT_DIR/mintpanel"
OPT_DSK="$OPT_DIR/desktop"
OPT_SV="$OPT_DIR/supervisor"
STAGE="$TARGET/.mintpanel-deb-stage-$"

cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

echo "=================================================="
echo " MintPanel + Online .deb /opt Flattened Deployer"
echo " Target : $OPT_DIR"
echo " Source : $BASE_URL"
echo "=================================================="

command -v curl >/dev/null || { echo "[ERR] curl is required"; exit 1; }

# 带退避的重试下载：隧道/边缘偶发 404・5xx，单次 curl --retry 不够用
dl() {
  local url="$1" out="$2" n=0 err
  while :; do
    if curl -fsSL --retry 2 --retry-all-errors --retry-delay 2 --max-time 1800 "$url" -o "$out" 2>/tmp/.dl.err; then
      return 0
    fi
    n=$((n+1))
    err=$(tail -1 /tmp/.dl.err 2>/dev/null | tr -d '\r')
    if [ "$n" -ge 12 ]; then
      echo "[ERR] download failed after $n tries: $url ($err)"
      return 1
    fi
    echo "  -> download retry $n/12 ($err)"
    sleep 4
  done
}
command -v apt-get >/dev/null || { echo "[ERR] apt-get is required"; exit 1; }
command -v dpkg-deb >/dev/null || { echo "[ERR] dpkg-deb is required"; exit 1; }

mkdir -p "$OPT_NODE" "$OPT_PANEL" "$OPT_DSK/bin" "$OPT_DSK/lib" "$OPT_DSK/share" "$OPT_DSK/etc" "$STAGE/debs" "$STAGE/root"

OPT_CF="$OPT_DIR/cloudflared"

INSTALL_BROWSER="${INSTALL_BROWSER:-}"
if [ -z "$INSTALL_BROWSER" ]; then
  if [ -r /dev/tty ]; then
    printf "是否安装 Camoufox 浏览器及默认扩展 (uBlock Origin + Cookie-Editor)? [Y/n]: " >/dev/tty
    read -r INSTALL_BROWSER </dev/tty || INSTALL_BROWSER="y"
  else
    INSTALL_BROWSER="y"
  fi
fi
case "$INSTALL_BROWSER" in
  [nN]|[nN][oO]|0) INSTALL_BROWSER="0" ;;
  *) INSTALL_BROWSER="1" ;;
esac

# ------------------------------------------------------------------
# Stop existing MintPanel / Desktop / cloudflared / Camoufox processes before overwrite
# ------------------------------------------------------------------
echo "[0/7] 停止已有相关进程准备覆盖安装..."
if [ -f "$OPT_PANEL/.panel.pid" ]; then
  OLD_PANEL_PID=$(cat "$OPT_PANEL/.panel.pid" 2>/dev/null || true)
  [ -n "$OLD_PANEL_PID" ] && kill "$OLD_PANEL_PID" 2>/dev/null || true
  rm -f "$OPT_PANEL/.panel.pid"
fi
for pidf in "$OPT_DSK"/logs/*.pid; do
  [ -f "$pidf" ] || continue
  OLD_DSK_PID=$(cat "$pidf" 2>/dev/null || true)
  [ -n "$OLD_DSK_PID" ] && kill "$OLD_DSK_PID" 2>/dev/null || true
  rm -f "$pidf"
done
pkill -f "$OPT_CF/bin/cloudflared" 2>/dev/null || true
pkill -f "cloudflared.*127\.0\.0\.1:$PANEL_PORT" 2>/dev/null || true
if [ "$INSTALL_BROWSER" = "1" ]; then
  pkill -9 -f "camoufox/cf-ui\.mjs" 2>/dev/null || true
  pkill -9 -f "camoufox-bin" 2>/dev/null || true
fi
sleep 1

# ------------------------------------------------------------------
# Step 1: Deploy Node.js & MintPanel into $TARGET/opt/{node,mintpanel}
# ------------------------------------------------------------------
echo "[1/7] Downloading & installing official Node.js v22 -> $OPT_NODE ..."
if [ ! -x "$OPT_NODE/bin/node" ]; then
  NODE_TAR=$(curl -fsSL "https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt" | awk '/linux-x64\.tar\.gz$/{print $2; exit}')
  [ -n "$NODE_TAR" ] || { echo "[ERR] Failed to resolve official Node.js v22 tarball"; exit 1; }
  echo "  -> Official: https://nodejs.org/dist/latest-v22.x/$NODE_TAR"
  dl "https://nodejs.org/dist/latest-v22.x/$NODE_TAR" "$STAGE/node.tar.gz"
  tar -xzf "$STAGE/node.tar.gz" -C "$OPT_NODE" --strip-components=1
  if [ ! -x "$OPT_NODE/bin/node" ] && [ -d "$OPT_NODE/node/bin" ]; then
    mv "$OPT_NODE/node"/* "$OPT_NODE/"
    rmdir "$OPT_NODE/node" 2>/dev/null || true
  fi
  rm -f "$STAGE/node.tar.gz"
fi
NODE_BIN="$OPT_NODE/bin/node"
echo "  -> Node: $($NODE_BIN -v)"

echo "[2/7] Downloading & installing MintPanel -> $OPT_PANEL ..."
  dl "$(rel_url mintpanel-bundle-x86_64.tar.gz)" "$STAGE/panel.tar.gz"
  tar -xzf "$STAGE/panel.tar.gz" -C "$OPT_PANEL"
  rm -f "$STAGE/panel.tar.gz"

cat > "$OPT_PANEL/start.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$OPT_PANEL"
if [ -f "$OPT_PANEL/.panel.pid" ]; then
  OLD_PID=\$(cat "$OPT_PANEL/.panel.pid" 2>/dev/null || true)
  if [ -n "\$OLD_PID" ] && kill -0 "\$OLD_PID" 2>/dev/null; then
    kill "\$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
fi
export PORT="\${PORT:-$PANEL_PORT}"
export HOST="\${HOST:-127.0.0.1}"
export WORKBENCH_DIR="\${WORKBENCH_DIR:-$OPT_PANEL}"
nohup "$OPT_NODE/bin/node" "$OPT_PANEL/server.mjs" >> "$OPT_PANEL/panel.log" 2>&1 &
echo \$! > "$OPT_PANEL/.panel.pid"
echo "[MintPanel] started PID \$(cat "$OPT_PANEL/.panel.pid") on \$HOST:\$PORT"
EOF
chmod +x "$OPT_PANEL/start.sh"

# Seed random Hysteria2 + Xray into encrypted SQLite vault (.panel_vault.db) if missing
echo "  -> Seeding random Hysteria2 & Xray into encrypted SQLite vault..."
(
  cd "$OPT_PANEL"
  if [ ! -s "$OPT_PANEL/.panel_token" ]; then
    "$NODE_BIN" -e 'console.log(require("node:crypto").randomBytes(16).toString("hex"))' > "$OPT_PANEL/.panel_token"
    chmod 600 "$OPT_PANEL/.panel_token"
  fi
  "$NODE_BIN" --experimental-sqlite --input-type=module <<'SEEDEOF'
import crypto from "node:crypto";
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { loadVaultConfig, saveVaultConfig, seedEncryptedAssetIfEmpty } from "./vault.mjs";

if (!loadVaultConfig("hy2")) {
  const tmp = "/tmp/.hy2-seed-" + process.pid;
  fs.mkdirSync(tmp, { recursive: true });
  execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-keyout", tmp + "/key.pem", "-out", tmp + "/cert.pem", "-days", "3650", "-nodes", "-subj", "/CN=bing.com"], { stdio: "ignore" });
  seedEncryptedAssetIfEmpty("hy2_cert.pem", tmp + "/cert.pem");
  seedEncryptedAssetIfEmpty("hy2_key.pem", tmp + "/key.pem");
  fs.rmSync(tmp, { recursive: true, force: true });
  const hyPort = 20000 + crypto.randomInt(25000);
  const hyPass = crypto.randomBytes(18).toString("base64url");
  const hyYaml = [
    "listen: :" + hyPort,
    "tls:",
    "  cert: /tmp/hy2/cert.pem",
    "  key: /tmp/hy2/key.pem",
    "auth:",
    "  type: password",
    "  password: " + hyPass,
    "masquerade:",
    "  type: proxy",
    "  proxy:",
    "    url: https://bing.com/",
    "    rewriteHost: true"
  ].join("\n") + "\n";
  saveVaultConfig("hy2", hyYaml, true);
  console.log("  -> Seeded random Hysteria2 on UDP :" + hyPort);
}

if (!loadVaultConfig("xray")) {
  const { privateKey } = crypto.generateKeyPairSync("x25519");
  const pkcs8 = privateKey.export({ format: "der", type: "pkcs8" });
  const privB64 = pkcs8.subarray(pkcs8.length - 32).toString("base64url");
  const xrPort = 20000 + crypto.randomInt(25000);
  const uuid = crypto.randomUUID();
  const shortId = crypto.randomBytes(4).toString("hex");
  const xrJson = {
    log: { loglevel: "warning" },
    inbounds: [{
      listen: "0.0.0.0",
      port: xrPort,
      protocol: "vless",
      settings: {
        clients: [{ id: uuid, flow: "xtls-rprx-vision" }],
        decryption: "none"
      },
      streamSettings: {
        network: "tcp",
        security: "reality",
        realitySettings: {
          show: false,
          dest: "www.microsoft.com:443",
          xver: 0,
          serverNames: ["www.microsoft.com"],
          privateKey: privB64,
          shortIds: [shortId]
        }
      }
    }],
    outbounds: [{ protocol: "freedom", tag: "direct" }]
  };
  saveVaultConfig("xray", JSON.stringify(xrJson, null, 2), true);
  console.log("  -> Seeded random Xray VLESS+REALITY on TCP :" + xrPort);
}
SEEDEOF
)

"$OPT_PANEL/start.sh"

# ------------------------------------------------------------------
# Step 3: Online fetch .deb packages via apt-get --print-uris
# ------------------------------------------------------------------
echo "[3/7] Resolving & downloading .deb packages online..."
APT_PKGS="xvfb x11-xkb-utils xkb-data x11vnc openbox tint2 patchelf xterm x11-utils novnc python3-websockify fonts-dejavu-core fonts-wqy-microhei wmctrl unzip librsvg2-2 librsvg2-common"
# libasound2 vs libasound2t64：Ubuntu 24.04 起改名 t64，Debian 12 仍叫 libasound2
APT_ASOUND="libasound2"
if apt-cache show libasound2t64 >/dev/null 2>&1; then APT_ASOUND="libasound2t64"; fi
APT_PKGS="$APT_PKGS $APT_ASOUND"
echo "  -> libasound package: $APT_ASOUND"
APT_OPTS=(-y --no-install-recommends)

# 镜像自带的 /var/lib/apt/lists 常常过期，解析出的 URL 全部 404。
# 先往独立 state 目录刷新索引，再用这套新鲜 lists 解析 URI。
mkdir -p "$STAGE/apt-state/lists/partial" "$STAGE/apt-state/cache/archives/partial"
APT_STATE_OPTS=(
  -o Dir::State::lists="$STAGE/apt-state/lists"
  -o Dir::Cache::archives="$STAGE/apt-state/cache/archives"
  -o Dir::State::status=/dev/null
  -o Acquire::AllowInsecureRepositories=true
)
echo "  -> refreshing apt index into $STAGE/apt-state ..."
if ! apt-get "${APT_STATE_OPTS[@]}" update 2>"$STAGE/apt-update.err"; then
  echo "  -> apt update failed, will fall back to system lists"
  tail -3 "$STAGE/apt-update.err" 2>/dev/null | sed 's/^/     /'
  APT_STATE_OPTS=()
fi

resolve_uris() {
  apt-get --print-uris "${APT_OPTS[@]}" "${APT_STATE_OPTS[@]}" install $APT_PKGS 2>/dev/null \
    | awk "/^'http/{gsub(/'/,\"\",\$1); print \$1}"
}
URIS=$(resolve_uris || true)
if [ -z "$URIS" ] && [ "${#APT_STATE_OPTS[@]}" -gt 0 ]; then
  echo "  -> fresh index gave nothing, retrying with system lists ..."
  APT_STATE_OPTS=()
  URIS=$(resolve_uris || true)
fi

if [ -z "$URIS" ]; then
  echo "[ERR] Failed to resolve .deb URIs via apt-get"
  echo "      package availability check:"
  for p in $APT_PKGS; do
    apt-cache show "$p" >/dev/null 2>&1 || echo "        MISSING $p"
  done
  echo "      free space check:"; df -h /tmp "$TARGET" 2>/dev/null | sed 's/^/     /'
  exit 1
fi

URI_COUNT=$(printf "%s\n" "$URIS" | wc -l)
echo "  -> Downloading $URI_COUNT .deb packages (8 parallel)..."
printf "%s\n" "$URIS" | xargs -P 8 -I{} sh -c '
  u="$1"
  f="$2/$(basename "$u")"
  curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 "$u" -o "$f" 2>/dev/null
' _ {} "$STAGE/debs"

HAVE=$(ls "$STAGE/debs"/*.deb 2>/dev/null | wc -l)
if [ "$HAVE" -lt "$URI_COUNT" ]; then
  echo "  -> $HAVE/$URI_COUNT downloaded, serializing the rest with dl() ..."
  printf "%s\n" "$URIS" | while IFS= read -r u; do
    [ -n "$u" ] || continue
    f="$STAGE/debs/$(basename "$u")"
    [ -s "$f" ] && continue
    dl "$u" "$f" || echo "     !! failed: $(basename "$u")"
  done
  HAVE=$(ls "$STAGE/debs"/*.deb 2>/dev/null | wc -l)
fi
echo "  -> $HAVE/$URI_COUNT .deb files ready"
if [ "$HAVE" -lt "$URI_COUNT" ]; then
  echo "[ERR] incomplete .deb set ($HAVE/$URI_COUNT)"
  exit 1
fi

echo "[4/7] Extracting & flattening into $OPT_DSK (zero usr/bin)..."
for pidf in "$OPT_DSK"/logs/*.pid; do
  [ -f "$pidf" ] || continue
  old=$(cat "$pidf" 2>/dev/null || true)
  [ -n "$old" ] && kill "$old" 2>/dev/null || true
done
sleep 0.5
for deb in "$STAGE/debs"/*.deb; do
  dpkg-deb -x "$deb" "$STAGE/root"
done

# Flatten binaries -> $OPT_DSK/bin
for d in "$STAGE/root/usr/bin" "$STAGE/root/bin" "$STAGE/root/usr/sbin" "$STAGE/root/sbin"; do
  [ -d "$d" ] && cp -a "$d"/. "$OPT_DSK/bin/"
done

# Flatten shared libraries & plugin subdirs -> $OPT_DSK/lib
for d in "$STAGE/root/usr/lib/x86_64-linux-gnu" "$STAGE/root/lib/x86_64-linux-gnu" "$STAGE/root/usr/lib" "$STAGE/root/lib"; do
  if [ -d "$d" ]; then
    for item in "$d"/*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      base=$(basename "$item")
      case "$base" in
        x86_64-linux-gnu|pkgconfig|systemd|udev|tmpfiles.d|sysusers.d|mime) continue ;;
        *) cp -a "$item" "$OPT_DSK/lib/" ;;
      esac
    done
  fi
done

# Flatten share & etc -> $OPT_DSK/{share,etc}
[ -d "$STAGE/root/usr/share" ] && cp -a "$STAGE/root/usr/share"/. "$OPT_DSK/share/"
[ -d "$STAGE/root/etc" ] && cp -a "$STAGE/root/etc"/. "$OPT_DSK/etc/"

# Patch RPATH on all binaries & libs using extracted patchelf so no LD_LIBRARY_PATH is needed
PATCHELF="$OPT_DSK/bin/patchelf"
if [ -x "$PATCHELF" ]; then
  echo "  -> Patching ELF RPATH -> $OPT_DSK/lib ..."
  for f in "$OPT_DSK/bin"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    LD_LIBRARY_PATH="$OPT_DSK/lib" "$PATCHELF" --set-rpath "$OPT_DSK/lib" --force-rpath "$f" >/dev/null 2>&1 || true
  done
  for f in "$OPT_DSK/lib"/*.so*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case "$(basename "$f")" in
      libc.so*|libpthread.so*|libdl.so*|libm.so*|librt.so*|ld-linux*) continue ;;
    esac
    LD_LIBRARY_PATH="$OPT_DSK/lib" "$PATCHELF" --set-rpath "$OPT_DSK/lib" --force-rpath "$f" >/dev/null 2>&1 || true
  done
  for sub in "$OPT_DSK/lib/xorg/modules" "$OPT_DSK/lib/dri"; do
    if [ -d "$sub" ]; then
      find "$sub" -type f -name "*.so*" -exec env LD_LIBRARY_PATH="$OPT_DSK/lib" "$PATCHELF" --set-rpath "$OPT_DSK/lib" --force-rpath {} \; >/dev/null 2>&1 || true
    fi
  done
fi

# Patch Xvfb hardcoded /usr/bin -> /tmp\0\0\0\0 using Node.js and place xkbcomp in /tmp/xkbcomp
if [ -x "$OPT_DSK/bin/Xvfb" ] && [ -x "$OPT_DSK/bin/xkbcomp" ]; then
  echo "  -> Patching Xvfb -> Xvfb-patched + /tmp/xkbcomp ..."
  "$NODE_BIN" -e '
    const fs = require("fs");
    let buf = fs.readFileSync(process.argv[1]);
    const needle = Buffer.from("/usr/bin");
    const repl = Buffer.from("/tmp\0\0\0\0");
    let idx = 0, count = 0;
    while ((idx = buf.indexOf(needle, idx)) !== -1) {
      repl.copy(buf, idx);
      idx += needle.length;
      count++;
    }
    fs.writeFileSync(process.argv[2], buf, { mode: 0o755 });
    console.log("  -> Patched", count, "occurrences in Xvfb-patched");
  ' "$OPT_DSK/bin/Xvfb" "$OPT_DSK/bin/Xvfb-patched"
  cp -a "$OPT_DSK/bin/xkbcomp" /tmp/xkbcomp
  chmod +x /tmp/xkbcomp
  if [ -x "$PATCHELF" ]; then
    LD_LIBRARY_PATH="$OPT_DSK/lib" "$PATCHELF" --set-rpath "$OPT_DSK/lib" --force-rpath /tmp/xkbcomp >/dev/null 2>&1 || true
  fi
fi

# ------------------------------------------------------------------
# Step 5: Write desktop launcher & start desktop stack
# ------------------------------------------------------------------
echo "[5/7] Writing $OPT_DSK/start-desktop.sh & starting desktop..."
PY_BIN=""
for cand in "$(command -v python3 2>/dev/null || true)" "$TARGET/python/bin/python3" "/usr/bin/python3"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then
    PY_BIN="$cand"
    break
  fi
done


mkdir -p "$OPT_DSK/etc/xdg/openbox"
mkdir -p "$TARGET/.config/openbox"
cat > "$OPT_DSK/etc/xdg/openbox/menu.xml" <<OBMENU
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
<menu id="root-menu" label="Camoufox">
  <item label="关闭当前窗口">
    <action name="Execute"><execute>$OPT_DSK/bin/wmctrl -c :ACTIVE:</execute></action>
  </item>
  <menu id="client-list-combined-menu" label="所有窗口"/>
  <menu id="client-list-menu" label="本桌面的窗口"/>
  <separator/>
  <item label="Camoufox 159">
    <action name="Execute"><execute>$TARGET/camoufox/open-two.sh</execute></action>
  </item>
  <item label="排列两窗口（左右并排）">
    <action name="Execute"><execute>$TARGET/camoufox/arrange-windows.sh</execute></action>
  </item>
  <item label="终端 (xterm)">
    <action name="Execute"><execute>$OPT_DSK/bin/xterm</execute></action>
  </item>
  <separator/>
  <item label="重载 openbox 配置">
    <action name="Reconfigure"/>
  </item>
</menu>
</openbox_menu>
OBMENU
cp -f "$OPT_DSK/etc/xdg/openbox/menu.xml" "$TARGET/.config/openbox/menu.xml"
cp -f "$OPT_DSK/etc/xdg/openbox/rc.xml" "$TARGET/.config/openbox/rc.xml"

cat > "$OPT_DSK/etc/xdg/openbox/rc.xml" <<OBRC
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance><strength>10</strength><screen_edge_strength>20</screen_edge_strength></resistance>
  <focus><focusNew>yes</focusNew><followMouse>no</followMouse><focusLast>yes</focusLast><underMouse>no</underMouse></focus>
  <placement><policy>Smart</policy><center>yes</center></placement>
  <theme><name>Clearlooks</name><titleLayout>NLIMC</titleLayout><keepBorder>yes</keepBorder><animateIconify>yes</animateIconify></theme>
  <menu><file>$OPT_DSK/etc/xdg/openbox/menu.xml</file><hideDelay>200</hideDelay><middle>no</middle><submenuShowDelay>100</submenuShowDelay></menu>
  <mouse>
    <dragThreshold>8</dragThreshold><doubleClickTime>200</doubleClickTime>
    <context name="Root">
      <mousebind button="Right" action="Press"><action name="ShowMenu"><menu>root-menu</menu></action></mousebind>
      <mousebind button="Middle" action="Press"><action name="ShowMenu"><menu>client-list-combined-menu</menu></action></mousebind>
    </context>
    <context name="Titlebar">
      <mousebind button="Left" action="Drag"><action name="Move"/></mousebind>
      <mousebind button="Left" action="DoubleClick"><action name="ToggleMaximize"/></mousebind>
      <mousebind button="Right" action="Press"><action name="ShowMenu"><menu>client-menu</menu></action></mousebind>
    </context>
    <context name="Close"><mousebind button="Left" action="Press"><action name="Close"/></mousebind></context>
    <context name="Iconify"><mousebind button="Left" action="Press"><action name="Iconify"/></mousebind></context>
    <context name="Maximize"><mousebind button="Left" action="Press"><action name="ToggleMaximize"/></mousebind></context>
  </mouse>
  <keyboard><chainQuitKey>C-g</chainQuitKey><keybind key="A-F4"><action name="Close"/></keybind><keybind key="F1"><action name="ShowMenu"><menu>root-menu</menu></action></keybind></keyboard>
  <applications/>
</openbox_config>
OBRC


mkdir -p "$OPT_DSK/etc/fonts"
cat > "$OPT_DSK/etc/fonts/fonts.conf" <<FCCONF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>$OPT_DSK/share/fonts</dir>
  <dir>$TARGET/.fonts</dir>
  <dir>/usr/share/fonts</dir>
  <cachedir>/tmp/fontconfig-cache</cachedir>
  <include ignore_missing="yes">$OPT_DSK/etc/fonts/conf.d</include>
  <alias><family>sans-serif</family><prefer><family>Noto Sans SC</family><family>Arimo</family><family>WenQuanYi Micro Hei</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>sans</family><prefer><family>Noto Sans SC</family><family>Arimo</family><family>WenQuanYi Micro Hei</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>system-ui</family><prefer><family>Noto Sans SC</family><family>Arimo</family><family>WenQuanYi Micro Hei</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>monospace</family><prefer><family>Cousine</family><family>WenQuanYi Micro Hei Mono</family><family>DejaVu Sans Mono</family></prefer></alias>
</fontconfig>
FCCONF
FONTCONFIG_FILE="$OPT_DSK/etc/fonts/fonts.conf" fc-cache -f "$OPT_DSK/share/fonts" >/dev/null 2>&1 || true

mkdir -p "$OPT_DSK/etc/xdg/tint2" "$TARGET/.local/share/applications" "$TARGET/.config/tint2"
cat > "$TARGET/.local/share/applications/camoufox.desktop" <<DESKEOF
[Desktop Entry]
Type=Application
Name=Camoufox
Comment=Launch Camoufox Browser
Exec=$TARGET/camoufox/start-ui.sh
Icon=firefox
Terminal=false
Categories=Network;WebBrowser;
DESKEOF

cat > "$OPT_DSK/etc/xdg/tint2/tint2rc" <<TINT2RC
#---- Background ----
rounded = 0
border_width = 0
background_color = #1b1d21 92
border_color = #000000 0
panel_monitor = all
panel_position = bottom center horizontal
panel_size = 100% 30
panel_margin = 0 0
panel_padding = 6 2 6
panel_items = TSC
panel_background_id = 1
wm_menu = 1

#---- Taskbar ----
taskbar_mode = single_desktop
taskbar_padding = 2 2 2
taskbar_background_id = 0
taskbar_name = 0
task_icon = 1
task_text = 1
task_width = 220
task_centered = 1

#---- Task ----
task_font = sans 9
task_font_color = #c8ccd2 100
task_active_font_color = #ffffff 100
task_background_id = 0

#---- Launcher ----
launcher_padding = 4 2 4
launcher_background_id = 0
launcher_icon_size = 18
# launcher_item_app removed: the desktop icon is the entry point
# launcher_item_app = $TARGET/.local/share/applications/camoufox.desktop

#---- Clock ----
time1_format = %H:%M
time1_font = sans 9
clock_font_color = #c8ccd2 100
clock_padding = 8 2
clock_background_id = 0

#---- Separator ----
separator_style = empty

# Task mouse bindings
mouse_left = toggle_iconify
mouse_middle = close
mouse_right = none
TINT2RC
cp -f "$OPT_DSK/etc/xdg/tint2/tint2rc" "$TARGET/.config/tint2/tint2rc"

# --- desktop assets: supervisord config, icon tile, librsvg wallpaper, click helper ---
echo "[5/7] Fetching desktop assets -> $TARGET ..."
dl "$(rel_url desktop-assets.tar.gz)" "$STAGE/desktop-assets.tar.gz"
tar xzf "$STAGE/desktop-assets.tar.gz" -C "$TARGET"

for f in "$OPT_DSK/start-desktop.sh" \
         "$OPT_DSK/bin/desktop-supervise.sh" \
         "$OPT_DSK/bin/deskicon.py" \
         "$OPT_DSK/bin/rsvg2wall.py" \
         "$OPT_DSK/bin/mkwall.py" \
         "$OPT_DSK/bin/set-wallpaper.py" \
         "$OPT_SV/etc/supervisord.conf" \
         "$OPT_SV/etc/conf.d/desktop.conf" \
         "$OPT_SV/etc/conf.d/cloudflared.conf" \
         "$OPT_SV/bin/xvfb-run.sh" \
         "$OPT_SV/bin/probe.py" \
         \
         "$OPT_SV/bin/healthcheck.sh" \
         "$TARGET/camoufox/open-two.sh" \
         "$TARGET/camoufox/arrange-windows.sh" \
         "$TARGET/mintpanel-autostart.sh" \
         "$TARGET/mintpanel-ensure.sh"; do
  [ -f "$f" ] || continue
  sed -i \
    -e "s|__TARGET__|$TARGET|g" \
    -e "s|__PYBIN__|$PY_BIN|g" \
    -e "s|__DISP__|:$DISPLAY_NUM|g" \
    -e "s|__VNCPORT__|$VNC_PORT|g" \
    -e "s|__NOVNCPORT__|$NOVNC_PORT|g" "$f"
done
chmod +x "$OPT_DSK/start-desktop.sh" "$OPT_DSK/bin/desktop-supervise.sh" \
         "$OPT_SV/bin/supervisord" "$OPT_SV/bin/supervisorctl" \
         "$OPT_SV/bin/xvfb-run.sh" "$OPT_SV/bin/healthcheck.sh" "$OPT_SV/bin/probe.py" \
         "$TARGET/camoufox/open-two.sh" "$TARGET/camoufox/arrange-windows.sh" \
         "$TARGET/mintpanel-autostart.sh" 2>/dev/null || true

# optional: build websockify-go (single process, goroutine per connection instead of a
# Python process per connection). Only when a Go toolchain is present at ~/opt/toolchain/go.
OPT_SRC="$OPT_DIR/src"
if [ -x "$TARGET/opt/toolchain/go/bin/go" ] && [ -f "$OPT_SRC/websockify-go/main.go" ]; then
  echo "  -> building websockify-go (Go toolchain found)"
  mkdir -p "$OPT_SRC/tmp"
  ( cd "$OPT_SRC/websockify-go" && \
    PATH="$TARGET/opt/toolchain/go/bin:$PATH" \
    GOCACHE="$TARGET/.cache/go-build" GOTMPDIR="$OPT_SRC/tmp" \
    GOFLAGS=-mod=vendor GOPROXY=off CGO_ENABLED=0 \
    go build -trimpath -ldflags "-s -w -X main.version=install-$(date +%H%M%S)" \
      -o "$OPT_DSK/bin/websockify-go" . ) 2>&1 | tail -3
  if [ -x "$OPT_DSK/bin/websockify-go" ]; then
    "$PY_BIN" - "$OPT_SV/etc/conf.d/desktop.conf" "$OPT_DSK" <<'PYWS'
import sys
conf, dsk = sys.argv[1], sys.argv[2]
lines = open(conf, encoding='utf-8').read().splitlines()
out = []
for line in lines:
    if line.startswith('command=') and 'websockify' in line:
        out.append(f"command={dsk}/bin/websockify-go -listen 127.0.0.1:6080 "
                   f"-target 127.0.0.1:5900 -web {dsk}/share/novnc -stats /__stats")
    elif line.startswith('environment=') and ('websockify' in line or 'PYTHONPATH' in line):
        continue  # the Go binary needs no PYTHONPATH
    else:
        out.append(line)
open(conf, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PYWS
    echo "     websockify program -> websockify-go ($(stat -c%s "$OPT_DSK/bin/websockify-go" 2>/dev/null) bytes)"
  else
    echo "     !! websockify-go build failed, keeping the python websockify"
  fi
fi

# supervisord: pip --target so it needs no root (fallback = legacy desktop-supervise.sh)
mkdir -p "$OPT_SV/lib"
if [ ! -d "$OPT_SV/lib/supervisor" ]; then
  echo "  -> installing supervisord 4.2.5 via pip --target $OPT_SV/lib ..."
  "$PY_BIN" -m pip install --quiet --target "$OPT_SV/lib" "supervisor==4.2.5" "setuptools<81" 2>&1 | tail -2 \
    || echo "     !! supervisord install failed; will fall back to desktop-supervise.sh"
fi

# make the pip console_scripts self-sufficient (so \`lib/bin/supervisord\` runs without PYTHONPATH)
for f in "$OPT_SV/lib/bin/supervisord" "$OPT_SV/lib/bin/supervisorctl"; do
  [ -f "$f" ] || continue
  grep -q 'sys.path.insert(0, _os.path.dirname(_os.path.dirname' "$f" && continue
  "$PY_BIN" - "$f" <<'PYPATCH'
import sys
p = sys.argv[1]
lines = open(p, encoding='utf-8').read().splitlines(True)
inj = ("import os as _os, sys as _sys\n"
       "_sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))\n")
out, done = [], False
for ln in lines:
    if not done and ln.startswith('from supervisor'):
        out.append(inj); done = True
    out.append(ln)
open(p, 'w', encoding='utf-8').write(''.join(out))
PYPATCH
done
chmod +x "$OPT_SV/lib/bin/"* "$OPT_SV/bin/"* 2>/dev/null || true

if [ -d "$OPT_SV/lib/supervisor" ]; then
  echo "  -> starting desktop stack under supervisord"
  PYTHONPATH="$OPT_SV/lib" setsid nohup "$PY_BIN" -m supervisor.supervisord -c "$OPT_SV/etc/supervisord.conf" </dev/null >/dev/null 2>&1 &
  sleep 8
  PYTHONPATH="$OPT_SV/lib" "$PY_BIN" -m supervisor.supervisorctl -c "$OPT_SV/etc/supervisord.conf" status 2>&1 | head -12
else
  echo "  -> supervisord unavailable, starting desktop directly"
  "$OPT_DSK/start-desktop.sh"
fi


# ------------------------------------------------------------------
# Step 6: Download cloudflared -> $OPT_DIR/cloudflared & start tunnel
# ------------------------------------------------------------------
OPT_CF="$OPT_DIR/cloudflared"
mkdir -p "$OPT_CF/bin"
echo "[6/7] Downloading cloudflared -> $OPT_CF/bin/cloudflared ..."
if [ ! -x "$OPT_CF/bin/cloudflared" ]; then
  dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" "$OPT_CF/bin/cloudflared"
  chmod +x "$OPT_CF/bin/cloudflared"
fi

pkill -f "cloudflared.*127\.0\.0\.1:$PANEL_PORT" 2>/dev/null || true
cat > "$OPT_PANEL/tunnel.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$OPT_PANEL"
for f in .cf.pid .cf-named.pid; do
  [ -f "\$f" ] || continue
  OLD=\$(cat "\$f" 2>/dev/null || true)
  [ -n "\$OLD" ] && kill "\$OLD" 2>/dev/null || true
  rm -f "\$f"
done

# fixed domain wins when a named tunnel config exists (survives restarts)
NAMED="$TARGET/.cloudflared/config.yml"
if [ -f "\$NAMED" ]; then
  : >"$OPT_PANEL/cf-named.log"
  nohup "$OPT_CF/bin/cloudflared" tunnel --no-autoupdate --config "\$NAMED" run </dev/null >>"$OPT_PANEL/cf-named.log" 2>&1 &
  echo \$! > "$OPT_PANEL/.cf-named.pid"
  for i in \$(seq 1 20); do
    grep -q "Registered tunnel connection" "$OPT_PANEL/cf-named.log" 2>/dev/null && break
    sleep 1
  done
  HOST=\$(grep -m1 'hostname:' "\$NAMED" 2>/dev/null | awk '{print \$NF}' || true)
  echo "PANEL_URL=https://\${HOST:-<named-tunnel>}"
  echo "PANEL_TOKEN=\$(cat "$OPT_PANEL/.panel_token" 2>/dev/null || true)"
  exit 0
fi

rm -f "$OPT_PANEL/cf-panel.log"
nohup "$OPT_CF/bin/cloudflared" tunnel --no-autoupdate --url "http://127.0.0.1:$PANEL_PORT" </dev/null >"$OPT_PANEL/cf-panel.log" 2>&1 &
echo \$! > "$OPT_PANEL/.cf.pid"

URL=""
for i in \$(seq 1 25); do
  URL=\$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$OPT_PANEL/cf-panel.log" 2>/dev/null | head -n 1 || true)
  [ -n "\$URL" ] && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$PANEL_PORT/" >/dev/null 2>&1 || true
echo "PANEL_URL=\$URL"
echo "PANEL_TOKEN=\$(cat "$OPT_PANEL/.panel_token" 2>/dev/null || true)"
EOF
chmod +x "$OPT_PANEL/tunnel.sh"
"$OPT_PANEL/tunnel.sh"


# ------------------------------------------------------------------
# Step 7: Preserve manually uploaded Java JAR + Optional Camoufox Browser (with 2 extensions)
# ------------------------------------------------------------------
echo "[7/7] 保留手动上传的 Java 插件（不覆盖 /home/container/plugins/*.jar）"

if [ "$INSTALL_BROWSER" = "1" ]; then
  echo "[browser] 正在从官方源安装 Camoufox + 默认双扩展 (AMO) + 自动化脚本..."
  mkdir -p "$TARGET/camoufox/profile-ui/extensions" "$TARGET/tmp" "$TARGET/.cache/camoufox"

  if [ ! -f "$TARGET/camoufox/package.json" ]; then
    cat > "$TARGET/camoufox/package.json" <<'PKGEOF'
{
  "name": "camoufox",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "camoufox-js": "^0.13.0"
  }
}
PKGEOF
  fi

  if [ ! -d "$TARGET/camoufox/node_modules/camoufox-js" ]; then
    echo "[browser] 安装 npm camoufox-js ..."
    (cd "$TARGET/camoufox" && PATH="$OPT_NODE/bin:$PATH" npm install --omit=dev --no-audit --no-fund)
  fi

  if [ ! -x "$TARGET/cf-new/camoufox-bin" ]; then
    echo "[browser] 从 GitHub 官方拉取 Camoufox v159.0-beta.42 -> $TARGET/cf-new ..."
    mkdir -p "$TARGET/cf-new"
    dl "https://github.com/daijro/camoufox/releases/download/v159.0-beta.42/camoufox-159.0-beta.42-lin.x86_64.zip" "$TARGET/tmp/camoufox-159.zip"
    if command -v unzip >/dev/null 2>&1; then
      unzip -oq "$TARGET/tmp/camoufox-159.zip" -d "$TARGET/cf-new"
    else
      "$OPT_DSK/bin/unzip" -oq "$TARGET/tmp/camoufox-159.zip" -d "$TARGET/cf-new"
    fi
    chmod +x "$TARGET/cf-new/"{camoufox-bin,gfxtest,glxtest,vaapitest,pingsender,plugin-container} 2>/dev/null || true
    rm -f "$TARGET/tmp/camoufox-159.zip"
  fi

  mkdir -p "$TARGET/.fonts"
  echo "[browser] 下载 Camoufox 白名单字体 (Arimo / Cousine / Tinos / NotoSansSC)..."
  [ -s "$TARGET/.fonts/Arimo-Regular.ttf" ] || curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/arimo/Arimo%5Bwght%5D.ttf" -o "$TARGET/.fonts/Arimo-Regular.ttf" || true
  [ -s "$TARGET/.fonts/Cousine-Regular.ttf" ] || curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/cousine/Cousine-Regular.ttf" -o "$TARGET/.fonts/Cousine-Regular.ttf" || true
  [ -s "$TARGET/.fonts/Tinos-Regular.ttf" ] || curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/tinos/Tinos-Regular.ttf" -o "$TARGET/.fonts/Tinos-Regular.ttf" || true
  [ -s "$TARGET/.fonts/NotoSansSC-VF.ttf" ] || curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf" -o "$TARGET/.fonts/NotoSansSC-VF.ttf" || true
  FONTCONFIG_FILE="$OPT_DSK/etc/fonts/fonts.conf" fc-cache -f >/dev/null 2>&1 || true

  EXT_DIR="$TARGET/camoufox/profile-ui/extensions"
  echo "[browser] 从 Mozilla AMO 官方下载默认双扩展..."
  [ -s "$EXT_DIR/uBlock0@raymondhill.net.xpi" ] ||     curl -fsSL -L "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi" -o "$EXT_DIR/uBlock0@raymondhill.net.xpi"
  [ -s "$EXT_DIR/{c3c10168-4186-445c-9c5b-63f12b8e2c87}.xpi" ] ||     curl -fsSL -L "https://addons.mozilla.org/firefox/downloads/latest/cookie-editor/latest.xpi" -o "$EXT_DIR/{c3c10168-4186-445c-9c5b-63f12b8e2c87}.xpi"

  dl "$(rel_url cf-ui.mjs)" "$TARGET/camoufox/cf-ui.mjs"
  dl "$(rel_url fly-supervise.py)" "$TARGET/camoufox/fly-supervise.py"
  chmod +x "$TARGET/camoufox/fly-supervise.py"

  cat > "$TARGET/camoufox/start-ui.sh" <<UIEOF
#!/usr/bin/env bash
unset LD_LIBRARY_PATH LD_PRELOAD
set -uo pipefail
H="$TARGET"
LOG="\$H/camoufox/ui.log"
mkdir -p "\$H/tmp" "\$H/camoufox" "\$H/.cache/camoufox/addons" "\$H/.cache/camoufox/fontconfig"
[ -s "\$H/.cache/camoufox/version.json" ] || printf %s '{"version":"152.0.4","build":"beta.30","prerelease":true,"sha256":null,"created_at":null}' > "\$H/.cache/camoufox/version.json"
for b in "\$H/.cache/camoufox/" "\$H/.cache/camoufox/browsers/*/*/" "\$H/cf-new/"; do
  [ -d "\$b" ] || continue
  for conf in "\${b}fontconfig/lin" "\${b}fontconfig/linux64"; do
    mkdir -p "\$conf" 2>/dev/null || continue
    cat > "\$conf/fonts.conf" <<FEOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>$OPT_DSK/share/fonts</dir>
  <dir>/usr/share/fonts</dir>
  <dir>\$H/.fonts</dir>
  <cachedir>\$H/.cache/fontconfig</cachedir>
  <include ignore_missing="yes">$OPT_DSK/etc/fonts/conf.d</include>
  <include ignore_missing="yes">/etc/fonts/conf.d</include>
  <alias><family>sans-serif</family><prefer><family>Noto Sans SC</family><family>Arimo</family><family>WenQuanYi Micro Hei</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>sans</family><prefer><family>Noto Sans SC</family><family>Arimo</family><family>WenQuanYi Micro Hei</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>system-ui</family><prefer><family>Noto Sans SC</family><family>Arimo</family><family>WenQuanYi Micro Hei</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>monospace</family><prefer><family>Cousine</family><family>WenQuanYi Micro Hei Mono</family><family>DejaVu Sans Mono</family></prefer></alias>
</fontconfig>
FEOF
  done
done
if pgrep -f "camoufox/cf-ui.mjs" >/dev/null 2>&1; then
  exit 0
fi
PY_BIN="\$(command -v python3 || echo "\$H/python/bin/python3")"
WRAP=""
# subreaper wrapper only when PID 1 does not reap zombies (e.g. java)
P1NAME="\$(cat /proc/1/comm 2>/dev/null || echo unknown)"
case "\$P1NAME" in
  tini|dumb-init|systemd|s6-svscan|init|runit) : ;;
  *) [ -x "\$PY_BIN" ] && [ -f "\$H/camoufox/fly-supervise.py" ] && WRAP="\$PY_BIN \$H/camoufox/fly-supervise.py" ;;
esac
CF_BIN=""
[ -x "\$H/cf-new/camoufox-bin" ] && CF_BIN="\$H/cf-new/camoufox-bin"
setsid env DISPLAY=":\${DISPLAY_NUM:-$DISPLAY_NUM}" TMPDIR="\$H/tmp" TZ=Asia/Kolkata \
  LD_LIBRARY_PATH="$OPT_DSK/lib:\$H/gui/lib2" PATH="$OPT_NODE/bin:$OPT_DSK/bin:\$PATH" \
  AUTO="\${AUTO:-1}" \${CF_BIN:+CF_EXE="\$CF_BIN"} \
  CF_SECOND="\${CF_SECOND:-https://dash.pingless.org/afk}" \
  \$WRAP node --experimental-sqlite "\$H/camoufox/cf-ui.mjs" >>"\$LOG" 2>&1 </dev/null &
sleep 1
( sleep 10; DISPLAY=":\${DISPLAY_NUM:-$DISPLAY_NUM}" bash "\$H/camoufox/arrange-windows.sh" >>"\$LOG" 2>&1
  sleep 6; DISPLAY=":\${DISPLAY_NUM:-$DISPLAY_NUM}" bash "\$H/camoufox/arrange-windows.sh" >>"\$LOG" 2>&1 ) </dev/null &
echo "\$(date +%H:%M:%S) 菜单: 已提交启动" >>"\$LOG"
UIEOF
  # arrange-windows.sh is shipped inside desktop-assets.tar.gz

  chmod +x "$TARGET/camoufox/start-ui.sh"

  if [ -s "$EXT_DIR/uBlock0@raymondhill.net.xpi" ] && [ -s "$EXT_DIR/{c3c10168-4186-445c-9c5b-63f12b8e2c87}.xpi" ]; then
    echo "  -> 默认双扩展已从官方就位: uBlock0@raymondhill.net.xpi + {c3c10168-4186-445c-9c5b-63f12b8e2c87}.xpi"
  else
    echo "  -> [WARN] 扩展目录缺少 .xpi 文件: $EXT_DIR"
  fi
  echo "[browser] 启动 Camoufox 自动化..."
  HOME="$TARGET" DISPLAY_NUM="$DISPLAY_NUM" bash "$TARGET/camoufox/start-ui.sh" || true
else
  echo "[browser] 已跳过 Camoufox 浏览器安装 (INSTALL_BROWSER=0)"
fi

# ------------------------------------------------------------------
# Auto-start hook (.bashrc + ensure.sh) matching local container setup
# ------------------------------------------------------------------
if [ -f "$TARGET/mintpanel-ensure.sh" ]; then
  cp -f "$TARGET/mintpanel-ensure.sh" "$OPT_PANEL/ensure.sh"
  chmod +x "$OPT_PANEL/ensure.sh"
fi
chmod +x "$OPT_PANEL/ensure.sh"

# ------------------------------------------------------------------
# Autostart: supervisor only.
# NEVER hook heavy work into .bashrc: an interactive shell (xterm in the desktop)
# re-ran start-desktop.sh and killed the whole running stack. The supervisor below
# is the single owner of liveness (port-aware, never tears down a live display).
# ------------------------------------------------------------------
BASHRC_FILE="$TARGET/.bashrc"
touch "$BASHRC_FILE"
if grep -q 'mintpanel-autostart' "$BASHRC_FILE" 2>/dev/null; then
  echo "  -> stripping legacy mintpanel-autostart hook from .bashrc"
  "$PY_BIN" - "$BASHRC_FILE" <<'STRIPEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r'\n?# >>> mintpanel-autostart >>>.*?# <<< mintpanel-autostart <<<\n?', '\n', s, flags=re.S)
open(p, 'w').write(s2)
print('  -> .bashrc cleaned' if s2 != s else '  -> nothing to clean')
STRIPEOF
fi

if [ -f "$OPT_DSK/bin/desktop-supervise.sh" ]; then
  pkill -f 'desktop-supervise\.sh' 2>/dev/null || true
  rm -f "$OPT_DSK/logs/supervise.pid"
  setsid nohup bash "$OPT_DSK/bin/desktop-supervise.sh" </dev/null >/dev/null 2>&1 &
  sleep 1
  echo "  -> desktop supervisor: pid $(cat "$OPT_DSK/logs/supervise.pid" 2>/dev/null || echo '?')"
fi

# app.py calls this on every container boot (spawn_autostart); it is idempotent
if [ -x "$TARGET/mintpanel-autostart.sh" ]; then
  setsid nohup bash "$TARGET/mintpanel-autostart.sh" </dev/null >/dev/null 2>&1 &
fi

echo "=================================================="
echo " Deploy complete!"
echo "   $OPT_NODE"
echo "   $OPT_PANEL (port $PANEL_PORT)"
echo "   $OPT_DSK (bin / lib / share / etc)"
echo "   $OPT_CF/bin/cloudflared"
echo "   Java plugin: preserved (manual upload)"
echo "   Browser    : $( [ "$INSTALL_BROWSER" = "1" ] && echo "installed ($TARGET/cf-new + 2 extensions)" || echo "skipped" )"
echo "   Desktop    : supervisor=$OPT_DSK/bin/desktop-supervise.sh (port/RFB aware)"
echo "   Wallpaper  : $OPT_DSK/share/wallpaper/debian13-ceratopsian.svg (librsvg -> root pixmap)"
echo "   Entry point: openbox right-click menu / F1 -> camoufox/open-two.sh (no desktop icon)"
echo "   .bashrc    : no autostart hook (liveness is owned by the supervisor)"
echo "=================================================="
