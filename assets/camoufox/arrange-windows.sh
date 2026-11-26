#!/usr/bin/env bash
set -uo pipefail
H="${MINTPANEL_DIR:-$HOME}"
D="$H/opt/desktop"
unset LD_LIBRARY_PATH LD_PRELOAD
WM="$D/bin/wmctrl"
X="env DISPLAY=${DISPLAY:-__DISP__} LD_LIBRARY_PATH=$D/lib:$H/gui/lib2"
[ -x "$WM" ] || exit 1
for i in $(seq 1 20); do
  n=$($X "$WM" -l 2>/dev/null | grep -c "Camoufox" || true)
  [ "$n" -ge 2 ] && break
  sleep 1
done
mapfile -t ids < <($X "$WM" -l 2>/dev/null | grep -i "camoufox" | awk '{print tolower($1)}' | sort)
main="${ids[0]:-}"
second="${ids[1]:-}"
[ -n "$second" ] && $X "$WM" -i -r "$second" -e 0,0,0,940,1020
[ -n "$main" ] && $X "$WM" -i -r "$main" -e 0,950,0,950,1020
