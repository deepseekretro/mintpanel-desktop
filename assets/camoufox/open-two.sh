#!/usr/bin/env bash
# Desktop-icon click target: guarantee a visible Camoufox UI with two windows.
# - windows exist      -> activate + tile them
# - zero windows       -> restart the automation (it can be alive with a dead context)
set -uo pipefail
H=__TARGET__
export DISPLAY="${DISPLAY:-__DISP__}"
D="$H/opt/desktop"
LOG="$H/camoufox/open-two.log"
WM="$D/bin/wmctrl"
log() { echo "$(date '+%F %T') $*" >>"$LOG"; }
count_wins() { "$WM" -l 2>/dev/null | grep -ci 'camoufox' || true; }

# one instance at a time: repeated clicks used to start several copies that killed each other
exec 9>/tmp/open-two.lock
if ! flock -n 9; then
  log "another open-two.sh is running -> just activating existing windows"
  for id in $("$WM" -l 2>/dev/null | grep -i camoufox | awk '{print $1}'); do
    "$WM" -i -a "$id" >/dev/null 2>&1
  done
  exit 0
fi

log "click (windows=$(count_wins))"
if [ "$(count_wins)" -eq 0 ]; then
  log "no browser windows -> restart automation"
  pkill -f 'camoufox/cf-ui.mjs' 2>/dev/null
  sleep 2
  pkill -9 -f 'camoufox/cf-ui.mjs' 2>/dev/null
  sleep 1
  log "remaining procs: $(pgrep -fc 'camoufox/cf-ui[.]mjs' 2>/dev/null || echo 0)"
  bash "$H/camoufox/start-ui.sh" >>"$LOG" 2>&1 9>&-   # 9>&- : do NOT pass the lock fd to the browser
  for _ in $(seq 1 15); do
    [ "$(count_wins)" -ge 1 ] && break
    sleep 2
  done
  log "after start: windows=$(count_wins)"
fi
mapfile -t ids < <("$WM" -l 2>/dev/null | grep -i camoufox | awk '{print $1}')
log "windows: ${ids[*]:-none}"
for id in "${ids[@]:-}"; do
  [ -n "$id" ] && "$WM" -i -a "$id" >/dev/null 2>&1
done
sleep 1
bash "$H/camoufox/arrange-windows.sh" >>"$LOG" 2>&1
log "done (windows=$(count_wins))"
