#!/bin/bash
# Xvfb + one-shot wallpaper.
# 壁纸不是独立守护进程：X 起来后设一次就结束；Xvfb 被 supervisord 重启时本脚本重新执行，壁纸自然跟着重设。
D=__TARGET__/opt/desktop
PY=__PYBIN__
XKB="$D/share/X11/xkb"
[ -d "$XKB" ] || XKB=/usr/share/X11/xkb
mkdir -p /tmp/.X11-unix 2>/dev/null
[ -x "$D/bin/xkbcomp" ] && cp -af "$D/bin/xkbcomp" /tmp/xkbcomp 2>/dev/null
BIN="$D/bin/Xvfb-patched"; [ -x "$BIN" ] || BIN="$D/bin/Xvfb"

"$BIN" __DISP__ -screen 0 1920x1080x24 -ac -nolisten tcp -xkbdir "$XKB" &
XPID=$!
# forward stop signals to Xvfb, otherwise supervisord can only kill this wrapper and leaves Xvfb orphaned
trap 'kill -TERM "$XPID" 2>/dev/null; wait "$XPID" 2>/dev/null; exit 0' TERM INT

# one-shot wallpaper: runs once per Xvfb lifetime, then the subshell exits
(
  for _ in $(seq 1 60); do
    DISPLAY=__DISP__ "$D/bin/xdpyinfo" >/dev/null 2>&1 && break
    sleep 0.5
  done
  SVG="$D/share/wallpaper/debian13-ceratopsian.svg"
  PPM="$D/share/wallpaper/trixie-official.ppm"
  [ -f "$SVG" ] && "$PY" "$D/bin/rsvg2wall.py" "$SVG" --ppm "$PPM" --size 1920x1080 >>"$D/logs/wallpaper.log" 2>&1
  [ -f "$PPM" ] || "$PY" "$D/bin/mkwall.py" "$PPM" >>"$D/logs/wallpaper.log" 2>&1
  [ -f "$PPM" ] && "$PY" "$D/bin/set-wallpaper.py" "$PPM" >>"$D/logs/wallpaper.log" 2>&1
) &

wait "$XPID"
