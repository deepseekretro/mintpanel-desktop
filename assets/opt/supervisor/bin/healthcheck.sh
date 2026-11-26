#!/bin/bash
# Service-level healthcheck: supervisord只判断进程存活，这里补上「端口/协议真的能干活」的判定。
SV=__TARGET__/opt/supervisor
D=__TARGET__/opt/desktop
PY=/usr/local/bin/python3
H=__TARGET__
ctl() { PYTHONPATH="$SV/lib" "$PY" -m supervisor.supervisorctl -c "$SV/etc/supervisord.conf" "$@" >>"$SV/log/healthcheck.log" 2>&1; }
log() { echo "[$(date '+%F %T')] $*"; }

while :; do
  # x11vnc: wedged processes still hold 5900 but never answer RFB -> restart
  if ! "$PY" "$SV/bin/probe.py" rfb 5900; then
    log "x11vnc not answering RFB -> restart"
    ctl restart x11vnc
  fi
  # websockify
  if ! "$PY" "$SV/bin/probe.py" port 6080; then
    log "websockify not listening -> restart"
    ctl restart websockify
  fi
  # panel + named tunnel (keep it short so a stuck tunnel can't block us)
  [ -x "$H/opt/mintpanel/ensure.sh" ] && timeout 25 bash "$H/opt/mintpanel/ensure.sh" >/dev/null 2>&1
  # browser automation
  if [ -x "$H/camoufox/open-two.sh" ] && ! pgrep -f 'camoufox/cf-ui\.mjs' >/dev/null 2>&1; then
    log "camoufox cf-ui.mjs gone -> open-two.sh"
    setsid nohup bash "$H/camoufox/open-two.sh" >>"$SV/log/healthcheck.log" 2>&1 </dev/null &
  fi
  sleep 30
done
