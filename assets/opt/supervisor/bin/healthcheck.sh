#!/bin/bash
# Service-level healthcheck: supervisord只判断进程存活，这里补上「端口/协议真的能干活」的判定。
SV=__TARGET__/opt/supervisor
D=__TARGET__/opt/desktop
PY=/usr/local/bin/python3
H=__TARGET__
ctl() { PYTHONPATH="$SV/lib" "$PY" -m supervisor.supervisorctl -c "$SV/etc/supervisord.conf" "$@" >>"$SV/log/healthcheck.log" 2>&1; }
log() { echo "[$(date '+%F %T')] $*"; }

# x11vnc: a wedged process still accepts connections but never answers RFB -> restart.
# Two deployment modes: TCP 5900 (default) or `-unixsock` (no TCP listener at all, used
# when the container's private address is reachable from neighbours). Read the mode from
# the program config instead of guessing from the socket file: a dead x11vnc removes its
# socket too, and we would then probe the wrong thing and never restart it.
VNC_UNIX=$(cat "$SV"/etc/conf.d/*.conf 2>/dev/null \
  | grep -v '^[[:space:]]*[;#]' \
  | sed -n 's/.*-unixsock[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' | head -n1)
if [ -n "$VNC_UNIX" ]; then
  VNC_PROBE=("rfbunix" "$VNC_UNIX")
else
  VNC_PROBE=("rfb" "5900")
fi

while :; do
  # Two attempts: at boot this loop starts before Xvfb/x11vnc are listening, and a
  # single probe would kill a perfectly healthy x11vnc that is 2 s old.
  if ! "$PY" "$SV/bin/probe.py" "${VNC_PROBE[@]}"; then
    sleep 4
    if ! "$PY" "$SV/bin/probe.py" "${VNC_PROBE[@]}"; then
      log "x11vnc not answering RFB (${VNC_PROBE[0]} ${VNC_PROBE[1]}) -> restart"
      ctl restart x11vnc
    fi
  fi
  # websockify
  if ! "$PY" "$SV/bin/probe.py" port 6080; then
    log "websockify not listening -> restart"
    ctl restart websockify
  fi
  # panel + named tunnel (keep it short so a stuck tunnel can't block us)
  [ -x "$H/opt/mintpanel/ensure.sh" ] && timeout 25 bash "$H/opt/mintpanel/ensure.sh" >/dev/null 2>&1
  # browser automation -- only when a browser is actually installed. With
  # INSTALL_BROWSER=0 the launcher still exists (it ships in desktop-assets), so
  # without this guard it retries "restart automation" every 30 s forever.
  BROWSER_OK=0
  [ -x "$H/cf-new/camoufox-bin" ] && BROWSER_OK=1
  [ -d "$H/.cache/camoufox" ] && BROWSER_OK=1
  if [ "$BROWSER_OK" = "1" ] && [ -x "$H/camoufox/open-two.sh" ] \
     && ! pgrep -f 'camoufox/cf-ui\.mjs' >/dev/null 2>&1; then
    log "camoufox cf-ui.mjs gone -> open-two.sh"
    setsid nohup bash "$H/camoufox/open-two.sh" >>"$SV/log/healthcheck.log" 2>&1 </dev/null &
  fi
  sleep 30
done
