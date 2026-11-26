#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://github.com/deepseekretro/mintpanel-desktop/releases/latest/download}"
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
# Panel entry point. On an unfamiliar machine cloudflared has no authority of its
# own over any domain -- the authorisation lives inside a tunnel token (or the
# credentials JSON). Create the tunnel in the Cloudflare dashboard, set its public
# hostname to http://127.0.0.1:$PANEL_PORT, then pass the token here.
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
# Optional: provision the tunnel automatically with a fine-grained API token.
# Scopes needed: Account > Cloudflare Tunnel > Edit, Zone > DNS > Edit,
# Zone > Zone > Read (skip the last one by passing CF_ZONE_ID).
# The API token is used once during install; only the per-tunnel token is kept.
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"

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

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'USAGE'
mintpanel-desktop installer

  curl -fsSL <release-url>/install-deb-v3.sh | bash
  curl -fsSL <release-url>/install-deb-v3.sh \
    | CF_TUNNEL_TOKEN=<token> PANEL_DOMAIN=panel.example.com bash

面板对外入口，三选一：
  0) CF_API_TOKEN=<token> PANEL_DOMAIN=<host>
     全自动：脚本用细粒度 API token 建/复用 tunnel、写 ingress、建 DNS CNAME，
     然后把「每隧道 token」写进 supervisord。API token 只在安装时用一次，不落盘。
     面板在 :8090、noVNC 在 :6080，是两个监听，所以会自动再建一条
     <host 前缀>-vnc.<域> 指向 :6080（CF_VNC_DOMAIN 可覆盖，CF_NO_VNC=1 可关闭）。
     需要的权限：Account > Cloudflare Tunnel > Edit、Zone > DNS > Edit、
                 Zone > Zone > Read（给了 CF_ZONE_ID 可省）
  1) CF_TUNNEL_TOKEN=<token>
     Cloudflare dashboard > Zero Trust > Networks > Tunnels 里创建 tunnel，
     Public hostname 指向 http://127.0.0.1:8090，然后把 token 交给本脚本。
     机器上不需要任何域名权限，授权全在那个 token 里。
  2) 机器上已有 ~/.cloudflared/config.yml + credentials.json —— 直接复用。
  3) 两者都没有 —— 走 quick tunnel，随机 *.trycloudflare.com 域名，重启就变。

其他变量：
  MINTPANEL_PORT=8090   MINTPANEL_DIR=$HOME   VNC_PORT=5900   NOVNC_PORT=6080
  DISPLAY_NUM=99        BASE_URL=<release>    TOKEN=<private mirror token>
  CF_ACCOUNT_ID / CF_ZONE_ID / CF_TUNNEL_NAME  可选，省掉两次查询 / 自定义隧道名
  MINTPANEL_TOKEN=<hex> 面板访问口令；不给则沿用上一次安装的，只有全新机器才随机生成
USAGE
  exit 0
fi

# 入口放在下载之前打印，避免装完才发现域名不对
DESK_URL=""
if [ -n "$CF_API_TOKEN" ] && [ -n "$PANEL_DOMAIN" ]; then
  ENTRY_MODE="named tunnel (CF_API_TOKEN, provisioned via API)"
  ENTRY_URL="https://$PANEL_DOMAIN"
  if [ -n "${CF_NO_VNC:-}" ]; then
    DESK_URL=""
  else
    DESK_URL="https://${CF_VNC_DOMAIN:-${PANEL_DOMAIN%%.*}-vnc.${PANEL_DOMAIN#*.}}/vnc.html"
  fi
elif [ -n "$CF_TUNNEL_TOKEN" ]; then
  ENTRY_MODE="named tunnel (CF_TUNNEL_TOKEN)"
  ENTRY_URL="https://${PANEL_DOMAIN:-<public hostname set in the Cloudflare dashboard>}"
elif [ -f "$TARGET/.cloudflared/config.yml" ]; then
  ENTRY_MODE="named tunnel (~/.cloudflared/config.yml)"
  ENTRY_URL="https://${PANEL_DOMAIN:-<public hostname in config.yml>}"
else
  ENTRY_MODE="quick tunnel (random *.trycloudflare.com host)"
  ENTRY_URL="(assigned at runtime, changes on every restart)"
fi

echo "=================================================="
echo " MintPanel + Online .deb /opt Flattened Deployer"
echo " Target     : $OPT_DIR"
echo " Source     : $BASE_URL"
echo " Panel port : $PANEL_PORT"
echo " Public URL : $ENTRY_URL"
echo " Entry mode : $ENTRY_MODE"
if [ -n "$DESK_URL" ]; then echo " Desktop    : $DESK_URL"; fi
true
echo "=================================================="

if [ -z "$CF_TUNNEL_TOKEN" ] && [ -z "$CF_API_TOKEN" ] && [ ! -f "$TARGET/.cloudflared/config.yml" ]; then
  if [ -n "$PANEL_DOMAIN" ]; then
    echo "[WARN] PANEL_DOMAIN=$PANEL_DOMAIN is ignored: this machine has no cloudflared"
    echo "       credentials for it. A domain cannot be claimed from the machine side."
  fi
  echo " NOTE: quick tunnel gives a random *.trycloudflare.com host, not your domain."
  echo "       For a stable domain: Cloudflare dashboard > Zero Trust > Networks >"
  echo "       Tunnels > create > public hostname http://127.0.0.1:$PANEL_PORT, then"
  echo "       re-run with  CF_TUNNEL_TOKEN=<token> PANEL_DOMAIN=<your host> bash ..."
  echo "       (Ctrl-C now if that is what you want; continuing in 10 s.)"
  sleep 10
fi

command -v curl >/dev/null || { echo "[ERR] curl is required"; exit 1; }

# 带退避的重试下载：隧道/边缘偶发 404・5xx，单次 curl --retry 不够用
dl() {
  local url="$1" out="$2" n=0 err
  while :; do
    if curl -fsSL --retry 2 --retry-all-errors --retry-delay 2 --max-time 1800 "$url" -o "$out" 2>/tmp/.dl.err; then
      return 0
    fi
    n=$((n+1))
    err=$(tail -1 /tmp/.dl.err 2>/dev/null | tr -d '\r' || true)
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
  # `curl | bash` still owns a controlling terminal, setsid/nohup does not. Opening
  # /dev/tty is the only reliable probe: `[ -r /dev/tty ]` is true even without a
  # controlling terminal, and the printf then fails and kills the script under `set -e`.
  if { exec 3<>/dev/tty; } 2>/dev/null; then
    printf "是否安装 Camoufox 浏览器及默认扩展 (uBlock Origin + Cookie-Editor)? [Y/n]: " >&3
    read -r INSTALL_BROWSER <&3 || INSTALL_BROWSER="y"
    exec 3>&-
  else
    echo "[i] 没有可用的终端（setsid/nohup/CI），默认安装 Camoufox 及扩展"
    echo "    要跳过浏览器请设 INSTALL_BROWSER=n 后重新运行"
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

# v3 makes supervisord the only supervisor, so it must go first: otherwise its children stay
# alive holding mmap'd copies of $OPT_DSK/bin/* and step 4 dies with "Text file busy".
if [ -x "$OPT_SV/bin/supervisorctl" ]; then
  "$OPT_SV/bin/supervisorctl" -c "$OPT_SV/etc/supervisord.conf" shutdown >/dev/null 2>&1 || true
fi
pkill -f "$OPT_SV/lib/bin/supervisord" 2>/dev/null || true
pkill -f "$OPT_SV/bin/supervisord" 2>/dev/null || true
pkill -f "$OPT_DSK/xvfb-run\.sh" 2>/dev/null || true
pkill -f "$OPT_DSK/bin/websockify" 2>/dev/null || true
pkill -f "$OPT_DSK/bin/x11vnc" 2>/dev/null || true
pkill -f "$OPT_DSK/bin/tint2" 2>/dev/null || true
pkill -f "$OPT_DSK/bin/openbox" 2>/dev/null || true
pkill -f "$OPT_DSK/bin/Xvfb" 2>/dev/null || true
pkill -x Xvfb 2>/dev/null || true
pkill -x x11vnc 2>/dev/null || true
pkill -x tint2 2>/dev/null || true
pkill -x openbox 2>/dev/null || true
# wait for the images to be unmapped before step 4 starts overwriting them
for _i in $(seq 1 15); do
  # `|| true` is load-bearing: with `set -o pipefail` a no-match pgrep returns 1,
  # which would abort the whole installer through `set -e` the moment the last
  # process exits.
  _alive=$(pgrep -f "$OPT_DSK/(bin|lib)/" 2>/dev/null | wc -l || true)
  [ "$_alive" -eq 0 ] && break
  sleep 1
done
pkill -9 -f "$OPT_DSK/(bin|lib)/" 2>/dev/null || true
sleep 1
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
  NODE_TAR=$(curl -fsSL "https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt" | awk '/linux-x64\.tar\.gz$/{print $2; exit}' || true)
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

# Keep the existing panel token across reinstalls: it is the credential that external
# things (server-list, bookmarks, /go/<idx> cookie bridge) hold. Regenerating it silently
# breaks all of them with a 403.
PANEL_TOKEN_PREV=""
[ -s "$OPT_PANEL/.panel_token" ] && PANEL_TOKEN_PREV="$(cat "$OPT_PANEL/.panel_token" 2>/dev/null || true)"
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
  if [ -n "${MINTPANEL_TOKEN:-}" ]; then
    printf '%s' "$MINTPANEL_TOKEN" > "$OPT_PANEL/.panel_token"
    echo "     panel token -> MINTPANEL_TOKEN (pinned by caller)"
  elif [ -n "$PANEL_TOKEN_PREV" ] && [ ! -s "$OPT_PANEL/.panel_token" ]; then
    printf '%s' "$PANEL_TOKEN_PREV" > "$OPT_PANEL/.panel_token"
    echo "     panel token -> preserved from the previous install"
  elif [ ! -s "$OPT_PANEL/.panel_token" ]; then
    "$NODE_BIN" -e 'console.log(require("node:crypto").randomBytes(16).toString("hex"))' > "$OPT_PANEL/.panel_token"
    echo "     panel token -> newly generated"
  else
    echo "     panel token -> already present, kept"
  fi
  chmod 600 "$OPT_PANEL/.panel_token"
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
  tail -3 "$STAGE/apt-update.err" 2>/dev/null | sed 's/^/     /' || true
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
  echo "      free space check:"; df -h /tmp "$TARGET" 2>/dev/null | sed 's/^/     /' || true
  exit 1
fi

URI_COUNT=$(printf "%s\n" "$URIS" | wc -l)
echo "  -> Downloading $URI_COUNT .deb packages (8 parallel)..."
printf "%s\n" "$URIS" | xargs -P 8 -I{} sh -c '
  u="$1"
  f="$2/$(basename "$u")"
  curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 "$u" -o "$f" 2>/dev/null
' _ {} "$STAGE/debs"

HAVE=$(ls "$STAGE/debs"/*.deb 2>/dev/null | wc -l || true)
if [ "$HAVE" -lt "$URI_COUNT" ]; then
  echo "  -> $HAVE/$URI_COUNT downloaded, serializing the rest with dl() ..."
  printf "%s\n" "$URIS" | while IFS= read -r u; do
    [ -n "$u" ] || continue
    f="$STAGE/debs/$(basename "$u")"
    [ -s "$f" ] && continue
    dl "$u" "$f" || echo "     !! failed: $(basename "$u")"
  done
  HAVE=$(ls "$STAGE/debs"/*.deb 2>/dev/null | wc -l || true)
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
  if [ -d "$d" ]; then
    cp -a "$d"/. "$OPT_DSK/bin/" 2>/dev/null || {
      pkill -9 -f "$OPT_DSK/(bin|lib)/" 2>/dev/null || true
      sleep 2
      cp -a "$d"/. "$OPT_DSK/bin/"
    }
  fi
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
  PATCHFAIL=0
  for f in "$OPT_DSK/bin"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    # subshell so a patchelf crash does not print "Segmentation fault" from the parent shell
    if ! ( LD_LIBRARY_PATH="$OPT_DSK/lib" "$PATCHELF" --set-rpath "$OPT_DSK/lib" --force-rpath "$f" ) >/dev/null 2>&1; then
      PATCHFAIL=$((PATCHFAIL + 1))
      [ "$PATCHFAIL" -le 6 ] && echo "     !! patchelf failed on bin/$(basename "$f")"
    fi
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
# Step 5: Desktop configs + supervisord program set
# ------------------------------------------------------------------
echo "[5/7] Writing desktop configs & supervisord program set (supervisord is the only supervisor)..."
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

# --- desktop assets: supervisord program set, wallpaper helper, click helpers ---
echo "[5/7] (cont.) Fetching desktop assets -> $TARGET ..."
dl "$(rel_url desktop-assets.tar.gz)" "$STAGE/desktop-assets.tar.gz"
tar xzf "$STAGE/desktop-assets.tar.gz" -C "$TARGET"

mkdir -p "$OPT_SV/etc/conf.d" "$OPT_SV/bin" "$OPT_SV/run" "$OPT_SV/log" "$OPT_SV/lib" "$OPT_DSK/logs"
# cloudflared.conf is generated in step 6 only. An older/templated copy here would
# still contain __TARGET__ placeholders and makes supervisord refuse to start.
rm -f "$OPT_SV/etc/conf.d/cloudflared.conf"

MISSING=0
for f in "$OPT_DSK/bin/rsvg2wall.py" \
         "$OPT_DSK/bin/mkwall.py" \
         "$OPT_DSK/bin/set-wallpaper.py" \
         "$OPT_SV/etc/supervisord.conf" \
         "$OPT_SV/etc/conf.d/desktop.conf" \
         "$OPT_SV/bin/supervisord" \
         "$OPT_SV/bin/supervisorctl" \
         "$OPT_SV/bin/xvfb-run.sh" \
         "$OPT_SV/bin/probe.py" \
         "$OPT_SV/bin/healthcheck.sh" \
         "$TARGET/camoufox/open-two.sh" \
         "$TARGET/camoufox/arrange-windows.sh" \
         "$TARGET/mintpanel-autostart.sh" \
         "$TARGET/mintpanel-ensure.sh"; do
  if [ -f "$f" ]; then
    sed -i \
      -e "s|__TARGET__|$TARGET|g" \
      -e "s|__PYBIN__|$PY_BIN|g" \
      -e "s|__DISP__|:$DISPLAY_NUM|g" \
      -e "s|__VNCPORT__|$VNC_PORT|g" \
      -e "s|__NOVNCPORT__|$NOVNC_PORT|g" "$f"
  else
    echo "  !! missing desktop asset: $f"
    MISSING=$((MISSING + 1))
  fi
done
[ "$MISSING" -eq 0 ] || { echo "  !! $MISSING desktop asset(s) missing, aborting"; exit 1; }

chmod +x "$OPT_SV/bin/supervisord" "$OPT_SV/bin/supervisorctl" \
         "$OPT_SV/bin/xvfb-run.sh" "$OPT_SV/bin/healthcheck.sh" "$OPT_SV/bin/probe.py" \
         "$TARGET/camoufox/open-two.sh" "$TARGET/camoufox/arrange-windows.sh" \
         "$TARGET/mintpanel-autostart.sh" "$TARGET/mintpanel-ensure.sh" 2>/dev/null || true

# --- websockify: always the prebuilt Go binary from the release.
#     The binary is built by CI (.github/workflows/release.yml), so the target machine
#     never needs a Go toolchain and never compiles anything. Falls back to the Python
#     websockify program only when no prebuilt binary is available or it will not run.
OPT_SRC="$OPT_DIR/src"
WS_GO=0
case "$(uname -m)" in
  x86_64|amd64)  WS_FILE="websockify-go-linux-amd64" ;;
  aarch64|arm64) WS_FILE="websockify-go-linux-arm64" ;;
  *)             WS_FILE="" ;;
esac
mkdir -p "$OPT_DSK/bin"
if [ -n "$WS_FILE" ]; then
  echo "  -> downloading $WS_FILE from the release (no compilation on this host)"
  if dl "$(rel_url "$WS_FILE")" "$OPT_DSK/bin/websockify-go"; then
    chmod +x "$OPT_DSK/bin/websockify-go"
    # verify before wiring it into supervisord: a truncated/foreign-arch binary would
    # otherwise fail silently every restart
    if "$OPT_DSK/bin/websockify-go" -version >/dev/null 2>&1; then
      WS_GO=1
      echo "     websockify-go $("$OPT_DSK/bin/websockify-go" -version), $(stat -c%s "$OPT_DSK/bin/websockify-go") bytes"
    else
      echo "     !! downloaded websockify-go does not run on this host, discarding it"
      rm -f "$OPT_DSK/bin/websockify-go"
    fi
  fi
fi

if [ "$WS_GO" -eq 1 ]; then
  "$PY_BIN" - "$OPT_SV/etc/conf.d/desktop.conf" "$OPT_DSK" <<'PYWS'
import sys
conf, dsk = sys.argv[1], sys.argv[2]
out = []
for line in open(conf, encoding='utf-8').read().splitlines():
    if line.startswith('command=') and 'websockify' in line:
        out.append(f"command={dsk}/bin/websockify-go -listen 127.0.0.1:__NOVNCPORT__ "
                   f"-target 127.0.0.1:__VNCPORT__ -web {dsk}/share/novnc -stats /__stats")
    elif line.startswith('environment=') and ('websockify' in line or 'PYTHONPATH' in line):
        continue  # the Go binary needs no PYTHONPATH
    else:
        out.append(line)
open(conf, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PYWS
  sed -i -e "s|__NOVNCPORT__|$NOVNC_PORT|g" -e "s|__VNCPORT__|$VNC_PORT|g" "$OPT_SV/etc/conf.d/desktop.conf"
  echo "     websockify program -> websockify-go"
else
  echo "  !! no usable prebuilt websockify-go for $(uname -m); keeping the Python websockify program"
  echo "     (that costs ~20 MB per noVNC connection -- see docs/ARCHITECTURE.md)"
fi

# --- supervisord itself: pip --target, no root needed ---
if [ ! -d "$OPT_SV/lib/supervisor" ]; then
  echo "  -> installing supervisord 4.2.5 via pip --target $OPT_SV/lib ..."
  "$PY_BIN" -m pip install --quiet --target "$OPT_SV/lib" "supervisor==4.2.5" "setuptools<81" 2>&1 | tail -2
fi
if [ ! -d "$OPT_SV/lib/supervisor" ]; then
  echo "  !! supervisord install failed -- this installer requires supervisord, aborting"
  exit 1
fi

# pip console_scripts need the package dir on sys.path when run directly
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
chmod +x "$OPT_SV/lib/bin/"* 2>/dev/null || true

# --- program set sanity check (supervisord is the ONLY supervisor) ---
NPROG=$(grep -h '^\[program:' "$OPT_SV/etc/conf.d/"*.conf 2>/dev/null | wc -l || true)
NPROG=${NPROG:-0}
echo "  -> $NPROG supervisord programs declared:"
grep -h '^\[program:' "$OPT_SV/etc/conf.d/"*.conf 2>/dev/null | sed 's/^/       /' || true
[ "$NPROG" -ge 6 ] || { echo "  !! expected >=6 programs, aborting"; exit 1; }

# --- boot supervisord and wait for the whole set ---
echo "  -> booting supervisord"
pkill -f 'supervisor\.supervisord.*opt/supervisor/etc' 2>/dev/null || true
sleep 1
setsid nohup "$OPT_SV/bin/supervisord" -c "$OPT_SV/etc/supervisord.conf" </dev/null >/dev/null 2>&1 &
SV_BOOTED=0
for i in $(seq 1 30); do
  [ -S "$OPT_SV/run/supervisor.sock" ] && { SV_BOOTED=1; break; }
  sleep 1
done
if [ "$SV_BOOTED" -eq 0 ]; then
  # A config error makes supervisord exit before it ever writes the socket; run it in the
  # foreground once so its own message lands in the installer output instead of nowhere.
  echo "  !! supervisord did not create $OPT_SV/run/supervisor.sock"
  echo "     --- supervisord's own complaint ---"
  timeout 5 "$OPT_SV/bin/supervisord" -c "$OPT_SV/etc/supervisord.conf" -n 2>&1 \
    | grep -v 'pkg_resources\|UserWarning\|import pkg_resources' | head -6 | sed 's/^/     /'
  echo "     --- conf.d ---"
  ls -1 "$OPT_SV/etc/conf.d" 2>/dev/null | sed 's/^/     /' || true
  exit 1
fi
"$OPT_SV/bin/supervisorctl" -c "$OPT_SV/etc/supervisord.conf" start all 2>&1 | tail -8 || true

RUNNING=0
for i in $(seq 1 20); do
  RUNNING=$("$OPT_SV/bin/supervisorctl" -c "$OPT_SV/etc/supervisord.conf" status 2>/dev/null | grep -c RUNNING || true)
  [ "${RUNNING:-0}" -ge "${NPROG:-1}" ] && break
  sleep 2
done
"$OPT_SV/bin/supervisorctl" -c "$OPT_SV/etc/supervisord.conf" status 2>&1 | sed 's/^/       /' || true
echo "  -> $RUNNING/$NPROG programs RUNNING"


# ------------------------------------------------------------------
# Step 6: cloudflared binary + supervisord program (named tunnel if configured)
# ------------------------------------------------------------------
OPT_CF="$OPT_DIR/cloudflared"
mkdir -p "$OPT_CF/bin"
echo "[6/7] Downloading cloudflared -> $OPT_CF/bin/cloudflared ..."
if [ ! -x "$OPT_CF/bin/cloudflared" ]; then
  dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" "$OPT_CF/bin/cloudflared"
  chmod +x "$OPT_CF/bin/cloudflared"
fi

NAMED_CFG="$TARGET/.cloudflared/config.yml"
CF_PROG="$OPT_SV/etc/conf.d/cloudflared.conf"

# --- optional: provision the tunnel through the Cloudflare API -------------------------
#     This is the fine-grained alternative to `cloudflared tunnel login`: no cert.pem and
#     no account-wide credential ever lands on this host, only the per-tunnel token.
# noVNC/websockify is a separate listener, so it needs its own hostname: the panel does
# not proxy /vnc.html. Derive <sub>-vnc.<zone>, overridable by CF_VNC_DOMAIN, and
# skippable with CF_NO_VNC=1.
VNC_DOMAIN="${CF_VNC_DOMAIN:-}"
if [ -z "$VNC_DOMAIN" ] && [ -n "$PANEL_DOMAIN" ] && [ -z "${CF_NO_VNC:-}" ]; then
  VNC_DOMAIN="${PANEL_DOMAIN%%.*}-vnc.${PANEL_DOMAIN#*.}"
fi
if [ -n "$CF_API_TOKEN" ] && [ -n "$PANEL_DOMAIN" ]; then
  echo "  -> provisioning the tunnel through the Cloudflare API ($PANEL_DOMAIN)"
  CF_OUT=$("$PY_BIN" - "$CF_API_TOKEN" "$PANEL_DOMAIN" "$PANEL_PORT" "$VNC_DOMAIN" "$NOVNC_PORT" <<'PYCF'
import json, os, sys, urllib.request, urllib.error

token, domain, port = sys.argv[1], sys.argv[2], sys.argv[3]
vnc_host = sys.argv[4] if len(sys.argv) > 4 else ""
vnc_port = sys.argv[5] if len(sys.argv) > 5 else "6080"
API = "https://api.cloudflare.com/client/v4"
HDR = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, method=method, headers=HDR, data=data)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read() or b"{}"
        try:
            return json.loads(raw)
        except Exception:
            return {"errors": [{"message": raw[:120].decode("utf8", "replace")}]}
    except Exception as e:
        return {"errors": [{"message": str(e)[:120]}]}


def fail(msg, resp=None):
    errs = [e.get("message", "") for e in (resp or {}).get("errors", [])][:2]
    print("ERROR=" + msg + (": " + "; ".join(errs) if errs else ""))
    sys.exit(0)


parts = domain.split(".")
if len(parts) < 3:
    fail("PANEL_DOMAIN must look like sub.zone.tld")
sub, zone_name = parts[0], ".".join(parts[1:])
tname = os.environ.get("CF_TUNNEL_NAME", "").strip() or sub

acct = os.environ.get("CF_ACCOUNT_ID", "").strip()
if not acct:
    r = call("GET", "/accounts?per_page=1")
    if not r.get("success") or not r.get("result"):
        fail("cannot list accounts (need Account > Cloudflare Tunnel > Edit, or set CF_ACCOUNT_ID)", r)
    acct = r["result"][0]["id"]

zid = os.environ.get("CF_ZONE_ID", "").strip()
if not zid:
    r = call("GET", "/zones?name=" + zone_name)
    if not r.get("success") or not r.get("result"):
        fail(f"cannot resolve zone {zone_name} (need Zone > Zone > Read, or set CF_ZONE_ID)", r)
    zid = r["result"][0]["id"]

r = call("GET", f"/accounts/{acct}/cfd_tunnel?name={tname}&is_deleted=false")
if not r.get("success"):
    fail("cannot list tunnels", r)
if r.get("result"):
    tid = r["result"][0]["id"]
    print(f"NOTE=reusing existing tunnel '{tname}' ({tid})")
    # A CLI-created tunnel is "locally managed": Cloudflare never pushes ingress to it, so
    # writing /configurations succeeds but cloudflared keeps serving 503. Refuse early.
    d = call("GET", f"/accounts/{acct}/cfd_tunnel/{tid}")
    src = (d.get("result") or {}).get("config_src")
    if src != "cloudflare":
        fail(f"tunnel '{tname}' is {src}-managed (config_src={src}); the API cannot push "
             "ingress to it. Delete that tunnel in the dashboard and re-run, or keep it and "
             "manage ingress with ~/.cloudflared/config.yml on the host")
else:
    r = call("POST", f"/accounts/{acct}/cfd_tunnel", {"name": tname, "config_src": "cloudflare"})
    if not r.get("success"):
        fail("cannot create tunnel", r)
    tid = r["result"]["id"]
    print(f"NOTE=created tunnel '{tname}' ({tid})")

r = call("GET", f"/accounts/{acct}/cfd_tunnel/{tid}/token")
if not r.get("success"):
    fail("cannot fetch the tunnel token", r)
tok = r["result"] if isinstance(r.get("result"), str) else (r.get("result") or {}).get("token", "")
if not tok:
    fail("tunnel token came back empty")

# The panel lives on $port; noVNC/websockify lives on $vnc_port and needs its own hostname,
# otherwise https://<panel>/vnc.html just 404s (the panel does not proxy it).
ingress = [{"hostname": domain, "service": f"http://127.0.0.1:{port}"}]
if vnc_host:
    ingress.append({"hostname": vnc_host, "service": f"http://127.0.0.1:{vnc_port}"})
r = call("PUT", f"/accounts/{acct}/cfd_tunnel/{tid}/configurations",
         {"config": {"ingress": ingress + [{"service": "http_status:404"}]}})
if not r.get("success"):
    fail("cannot write the ingress config", r)
for rule in ingress:
    print(f"NOTE=ingress {rule['hostname']} -> {rule['service']}")

for host in [h["hostname"] for h in ingress]:
    r = call("GET", f"/zones/{zid}/dns_records?name={host}")
    if not r.get("success"):
        fail("cannot read DNS records (need Zone > DNS > Edit)", r)
    if r.get("result"):
        print(f"NOTE=DNS for {host} already present, left untouched")
        continue
    r = call("POST", f"/zones/{zid}/dns_records",
             {"type": "CNAME", "name": host.split(".")[0],
              "content": f"{tid}.cfargotunnel.com", "proxied": True, "ttl": 1})
    if not r.get("success"):
        fail(f"cannot create the DNS record for {host}", r)
    print(f"NOTE=DNS CNAME created (proxied) for {host}")

print(f"TUNNEL_ID={tid}")
print(f"TUNNEL_TOKEN={tok}")
if vnc_host:
    print(f"VNC_URL=https://{vnc_host}")
PYCF
)
  CF_ERR=$(printf '%s\n' "$CF_OUT" | sed -n 's/^ERROR=//p')
  if [ -n "$CF_ERR" ]; then
    echo "  !! Cloudflare API refused: $CF_ERR"
    echo "     required token scopes:"
    echo "       Account > Cloudflare Tunnel > Edit"
    echo "       Zone    > DNS > Edit"
    echo "       Zone    > Zone > Read   (or pass CF_ZONE_ID to skip)"
    exit 1
  fi
  printf '%s\n' "$CF_OUT" | sed -n 's/^NOTE=/     /p'
  CF_TUNNEL_TOKEN=$(printf '%s\n' "$CF_OUT" | sed -n 's/^TUNNEL_TOKEN=//p')
  CF_TUNNEL_ID=$(printf '%s\n' "$CF_OUT" | sed -n 's/^TUNNEL_ID=//p')
  if [ -z "$CF_TUNNEL_TOKEN" ]; then
    echo "  !! the API returned no tunnel token"
    exit 1
  fi
  CF_VNC_URL=$(printf '%s\n' "$CF_OUT" | sed -n 's/^VNC_URL=//p')
  echo "     tunnel ready (${CF_TUNNEL_ID}), token kept in the supervisord conf only"
  if [ -n "$CF_VNC_URL" ]; then echo "     desktop (noVNC): $CF_VNC_URL/vnc.html"; fi
fi

# 三个分支共用的尾部
cf_tail() {
  cat <<'CFTAIL'
priority=45
autostart=true
autorestart=true
startsecs=5
startretries=10
stopsignal=TERM
stopwaitsecs=10
redirect_stderr=true
CFTAIL
}

if [ -n "$CF_TUNNEL_TOKEN" ]; then
  # A tunnel token carries the tunnel UUID + secret, so this machine needs no
  # certificate, no `cloudflared login`, and no account authorisation of its own.
  echo "  -> named tunnel via CF_TUNNEL_TOKEN"
  mkdir -p "$OPT_PANEL"
  umask 077
  {
    echo '; Cloudflare named tunnel via token -> MintPanel. Managed by supervisord.'
    echo '; The token below is a credential: keep this file at mode 600.'
    echo '[program:cloudflared]'
    echo '; TUNNEL_TOKEN is passed as an environment variable, not on the command line,'
    echo '; so the credential does not show up in ps output.'
    echo "environment=TUNNEL_TOKEN=\"$CF_TUNNEL_TOKEN\""
    echo "command=$OPT_CF/bin/cloudflared --no-autoupdate tunnel run"
    echo "stdout_logfile=$OPT_PANEL/cf-named.log"
    cf_tail
  } > "$CF_PROG"
  chmod 600 "$CF_PROG"
  umask 022
  CF_WAIT_LOG="$OPT_PANEL/cf-named.log"
elif [ -f "$NAMED_CFG" ]; then
  echo "  -> named tunnel config found, panel gets a fixed domain"
  {
    echo '; Cloudflare named tunnel -> MintPanel. Managed by supervisord.'
    echo '[program:cloudflared]'
    echo "command=$OPT_CF/bin/cloudflared --no-autoupdate tunnel --config $NAMED_CFG run"
    echo "stdout_logfile=$OPT_PANEL/cf-named.log"
    cf_tail
  } > "$CF_PROG"
  CF_WAIT_LOG="$OPT_PANEL/cf-named.log"
else
  echo "  -> no tunnel credentials, using a quick tunnel (random trycloudflare.com host)"
  {
    echo '; Cloudflare quick tunnel -> MintPanel. Managed by supervisord.'
    echo '; For a stable domain: create a tunnel in the Cloudflare dashboard, point its'
    echo '; public hostname at http://127.0.0.1:'"$PANEL_PORT"' , then re-run this installer'
    echo '; with CF_TUNNEL_TOKEN=<token>.'
    echo '[program:cloudflared]'
    echo "command=$OPT_CF/bin/cloudflared --no-autoupdate tunnel --url http://127.0.0.1:$PANEL_PORT"
    echo "stdout_logfile=$OPT_PANEL/cf-panel.log"
    cf_tail
  } > "$CF_PROG"
  CF_WAIT_LOG="$OPT_PANEL/cf-panel.log"
fi

"$OPT_SV/bin/supervisorctl" -c "$OPT_SV/etc/supervisord.conf" reread 2>&1 | tail -2 || true
"$OPT_SV/bin/supervisorctl" -c "$OPT_SV/etc/supervisord.conf" update 2>&1 | tail -3 || true
for i in $(seq 1 25); do
  grep -q 'Registered tunnel connection' "$CF_WAIT_LOG" 2>/dev/null && break
  sleep 1
done

if [ -f "$NAMED_CFG" ]; then
  HOST=$(grep -m1 'hostname:' "$NAMED_CFG" 2>/dev/null | awk '{print $NF}' || true)
  echo "  PANEL_URL=https://${HOST:-<named-tunnel>}"
else
  URL=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$CF_WAIT_LOG" 2>/dev/null | head -n 1 || true)
  echo "  PANEL_URL=${URL:-<quick tunnel not registered yet, see $CF_WAIT_LOG>}"
fi
echo "  PANEL_TOKEN=$(cat "$OPT_PANEL/.panel_token" 2>/dev/null || true)"


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
# Autostart: supervisord only.
# NEVER hook heavy work into .bashrc: an interactive shell (xterm in the desktop)
# re-ran the desktop launcher and killed the whole running stack. Supervisord below
# is the single owner of liveness (autorestart per program + port/RFB probes).
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

if [ ! -S "$OPT_SV/run/supervisor.sock" ]; then
  echo "  -> supervisord socket missing, booting it"
  setsid nohup "$OPT_SV/bin/supervisord" -c "$OPT_SV/etc/supervisord.conf" </dev/null >/dev/null 2>&1 &
  sleep 5
fi
"$OPT_SV/bin/supervisorctl" -c "$OPT_SV/etc/supervisord.conf" start all 2>&1 | tail -8 || true

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
echo "   Supervisor : $OPT_SV/bin/supervisord -c $OPT_SV/etc/supervisord.conf"
"$OPT_SV/bin/supervisorctl" -c "$OPT_SV/etc/supervisord.conf" status 2>/dev/null | sed 's/^/                /' || true
echo "   Desktop    : programs = xvfb / openbox / tint2 / x11vnc / websockify / healthcheck"
echo "   Wallpaper  : $OPT_DSK/share/wallpaper/debian13-ceratopsian.svg (set once by xvfb-run.sh)"
echo "   Entry point: openbox right-click menu / F1 -> camoufox/open-two.sh (no desktop icon)"
echo "   .bashrc    : no autostart hook (supervisord owns liveness)"
echo "=================================================="
