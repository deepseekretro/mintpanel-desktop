#!/usr/bin/env bash
# MintPanel / 桌面栈 / Camoufox 启动钩子（supervisord 版）
# 由 __TARGET__/app.py 在 exec remote-bash-agent 之前以独立会话调用。幂等。
set -u

H="${MINTPANEL_DIR:-__TARGET__}"
D="$H/opt/desktop"
P="$H/opt/mintpanel"
SV="$H/opt/supervisor"
PY=/usr/local/bin/python3
CONF="$SV/etc/supervisord.conf"
export MINTPANEL_DIR="$H"

log() { echo "[mintpanel-autostart] $(date '+%F %T') $*"; }

if [ -f "$H/.mintpanel-autostart.log" ] && [ "$(stat -c %s "$H/.mintpanel-autostart.log" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv -f "$H/.mintpanel-autostart.log" "$H/.mintpanel-autostart.log.old"
fi
exec >>"$H/.mintpanel-autostart.log" 2>&1

log "hook start (HOME=$HOME, DISPLAY_NUM=${DISPLAY_NUM:-99})"

ctl() { "$SV/bin/supervisorctl" -c "$CONF" "$@" 2>/dev/null; }

if [ -f "$CONF" ] && [ -d "$SV/lib/supervisor" ]; then
  if pgrep -f 'supervisor\.supervisord.*opt/supervisor/etc' >/dev/null 2>&1; then
    log "supervisord already running"
  else
    log "starting supervisord"
    setsid nohup "$SV/bin/supervisord" -c "$CONF" </dev/null >/dev/null 2>&1 &
    sleep 6
  fi
  log "supervisorctl start all"
  ctl start all
  ctl status | head -12
else
  log "!! supervisord is missing ($SV) -- desktop cannot start; re-run the installer"
fi

# 2) 面板 + cloudflared 隧道
if [ -x "$P/ensure.sh" ]; then
  log "ensuring MintPanel + cloudflared"
  setsid nohup bash "$P/ensure.sh" </dev/null >/dev/null 2>&1 &
fi

# 3) Camoufox 自动化（装了才起）
if [ -x "$H/camoufox/start-ui.sh" ]; then
  if pgrep -f "camoufox/cf-ui\.mjs" >/dev/null 2>&1; then
    log "camoufox already running"
  else
    log "starting camoufox ui"
    setsid nohup env HOME="$H" DISPLAY=":${DISPLAY_NUM:-99}" DISPLAY_NUM="${DISPLAY_NUM:-99}" \
      bash "$H/camoufox/start-ui.sh" </dev/null >/dev/null 2>&1 &
  fi
fi

log "hook done"
