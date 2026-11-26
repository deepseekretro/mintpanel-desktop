#!/usr/bin/env bash
# MintPanel 保活：面板进程 + cloudflared（命名隧道优先，quick tunnel 兜底）
# [adapt-nodaroo02] 原版 ensure.sh 只起一次 cloudflared，撞上 429（同一出口短时间建太多
# quick tunnel）就再也不重试，面板外部地址就永久没了。
# 现在：① 有 __TARGET__/.cloudflared/config.yml 时优先跑命名隧道（固定域名
# nodaroo-02.10w123.com，重启不断线）；② 命名隧道起不来才退回 quick tunnel（退避重试）。
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${PORT:-8090}"
CF_BIN="__TARGET__/opt/cloudflared/bin/cloudflared"
NAMED_CFG="${NAMED_CFG:-__TARGET__/.cloudflared/config.yml}"

panel_alive() { [ -f "$DIR/.panel.pid" ] && kill -0 "$(cat "$DIR/.panel.pid" 2>/dev/null)" 2>/dev/null; }

if ! panel_alive; then
  if [ -x "$DIR/start.sh" ]; then
    "$DIR/start.sh" || true
  fi
fi

# supervisord 在管 cloudflared 时不要再自己起一个（双实例会抢同一个 tunnel）
SV="__TARGET__/opt/supervisor"
if [ -f "$SV/etc/supervisord.conf" ] && [ -x "$SV/bin/supervisorctl" ]; then
  if "$SV/bin/supervisorctl" -c "$SV/etc/supervisord.conf" status cloudflared 2>/dev/null | grep -q RUNNING; then
    exit 0
  fi
fi

# 1) 命名隧道（固定域名，重启后域名不变）
if [ -f "$NAMED_CFG" ]; then
  if ! pgrep -f "cloudflared.*--config $NAMED_CFG" >/dev/null 2>&1; then
    echo "[ensure] starting named tunnel ($NAMED_CFG)"
    : >"$DIR/cf-named.log"
    nohup "$CF_BIN" tunnel --no-autoupdate --config "$NAMED_CFG" run </dev/null >>"$DIR/cf-named.log" 2>&1 &
    echo $! >"$DIR/.cf-named.pid"
    for j in $(seq 1 20); do
      grep -q "Registered tunnel connection" "$DIR/cf-named.log" 2>/dev/null && break
      sleep 1
    done
  fi
  if pgrep -f "cloudflared.*--config $NAMED_CFG" >/dev/null 2>&1; then
    exit 0
  fi
  echo "[ensure] named tunnel 未起来，退回 quick tunnel"
fi

# 2) quick tunnel 兜底（域名每次变，见 cf-panel.log）
if pgrep -f "cloudflared.*127\.0\.0\.1:$PORT" >/dev/null 2>&1; then
  exit 0
fi

for i in $(seq 1 30); do
  : >"$DIR/cf-panel.log"
  nohup "$CF_BIN" tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" </dev/null >>"$DIR/cf-panel.log" 2>&1 &
  echo $! >"$DIR/.cf.pid"
  for j in $(seq 1 20); do
    URL=$(grep -oE "https://[a-z0-9.-]+\.trycloudflare\.com" "$DIR/cf-panel.log" 2>/dev/null | head -n1 || true)
    if [ -n "$URL" ]; then
      echo "[ensure] tunnel up: $URL"
      exit 0
    fi
    kill -0 "$(cat "$DIR/.cf.pid" 2>/dev/null)" 2>/dev/null || break
    sleep 1
  done
  kill "$(cat "$DIR/.cf.pid" 2>/dev/null)" 2>/dev/null || true
  sleep 10
done

echo "[ensure] cloudflared 启动失败（反复 429），稍后由上层钩子重试"
exit 1
