#!/usr/bin/env bash
# 把 assets/ 打成 dist/desktop-assets.tar.gz —— 安装脚本只从 release 下载这一份，
# 所以 assets/ 改了必须重打，否则新装的机器拿到的是旧文件（甚至是缺文件的包）。
#
# 教训（2026-11-26）：手工 `tar czf ... opt/supervisor opt/desktop/bin` 只打了子目录，
# 丢掉 camoufox/、mintpanel-autostart.sh、mintpanel-ensure.sh，安装脚本的
# "missing desktop asset" 检查会在 step 5 直接 abort。永远从 assets/ 整体打包。
set -uo pipefail
cd "$(dirname "$0")"

OUT=dist/desktop-assets.tar.gz
mkdir -p dist

tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime='2026-01-01 00:00:00Z' \
    -czf "$OUT" -C assets .

echo "  -> $OUT ($(stat -c%s "$OUT") bytes, $(tar tzf "$OUT" | grep -cv '/$') files)"

# 安装脚本要求这 4 个文件必须在包里，缺一个就 abort，这里先自查一次
# 注意：不要用 `tar tzf | grep -q` —— grep 命中即退出会让 tar 收到 SIGPIPE，
# 在 pipefail 下整条管道返回 141，看起来像「文件缺失」。先落一份清单再判断。
LIST=$(tar tzf "$OUT")
MISSING=0
for f in mintpanel-autostart.sh mintpanel-ensure.sh \
         opt/supervisor/bin/healthcheck.sh opt/supervisor/bin/probe.py; do
  if ! grep -qxF "./$f" <<<"$LIST"; then
    echo "  !! $f missing from $OUT"
    MISSING=$((MISSING + 1))
  fi
done

if [ "$MISSING" -eq 0 ]; then
  echo "  -> required desktop assets present"
else
  echo "  !! $MISSING required asset(s) missing" >&2
  exit 1
fi
