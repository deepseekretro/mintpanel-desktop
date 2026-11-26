# 架构细节

## 为什么是 supervisord，不是自写守护脚本

最初是 `desktop-supervise.sh`：一个 `while :; do probe; sleep; done` 的循环。它只能判断
「进程在不在」，判断不了「服务能不能用」，也没有「按 program 重试」的能力。

换成 supervisord 后拿到的三样东西：

1. **`autorestart` + `startretries` 按 program 配置** —— x11vnc 卡死和 tint2 崩掉要的策略不一样。
2. **`priority` 决定启动顺序** —— X 必须早于窗口管理器。
3. **`stopsignal` 可逐 program 指定** —— x11vnc 在某些状态下不响应 TERM，用 KILL。

而「服务级探测」这件事 supervisord 天生不做，所以保留成 `[program:healthcheck]`：
一个每 30 秒跑一轮的**短命** program（不是常驻守护），做 RFB 握手 / 端口探测 / 兜底拉起。

## program 清单

| program | priority | 命令 | 关键配置 |
|---|---|---|---|
| `xvfb` | 10 | `xvfb-run.sh` | wrapper 里 `trap 'kill -TERM $XPID; wait'`，并把壁纸作为一次性副作用 |
| `openbox` | 20 | `openbox --config-file etc/xdg/openbox/rc.xml` | 菜单文件由 rc.xml 的 `<menu><file>` 指向 |
| `tint2` | 30 | `tint2 -c ~/.config/tint2/tint2rc` | `panel_items = TSC`（无 launcher） |
| `x11vnc` | 40 | `x11vnc -display :99 -rfbport 5900 ...` | **`stopsignal=KILL`**、`stopwaitsecs=5` |
| `websockify` | 40 | `websockify-go -listen 6080 -target 5900 -web share/novnc` | 默认 Python 版；有 Go toolchain 时脚本自动换成 Go 版 |
| `cloudflared` | 45 | `cloudflared tunnel --config ~/.cloudflared/config.yml run` | `startsecs=5`（握手要时间） |
| `healthcheck` | 50 | `healthcheck.sh` | 30 秒一轮，每轮都是新进程 |

## 壁纸为什么不是独立 program

壁纸是「X 起来之后设一次」的**副作用**，不是服务。做成常驻 program 只有两种结局：
要么是 `while true; sleep 10; set` 这种无意义轮询，要么程序退出后 supervisord 一直
`autorestart` 它。

所以折进 `xvfb-run.sh`：

```bash
Xvfb :99 ... &
XPID=$!
trap 'kill -TERM $XPID; wait' TERM INT
( set-wallpaper ... ) &          # 后台一次性
wait "$XPID"
```

`trap` 是**必须的**：否则 supervisord 停 program 时只杀掉 wrapper，Xvfb 变成孤儿继续
占着 `:99`，下次启动直接 `Server is already active for display 99`。

## healthcheck 做什么

```bash
probe.py rfb  5900   || supervisorctl restart x11vnc     # 真的做一次 RFB 握手
probe.py port 6080   || supervisorctl restart websockify # 只探端口
timeout 25 bash ensure.sh                                # 面板 + cloudflared 兜底
[ -e cf-ui.mjs进程 ] || open-two.sh                      # 浏览器没了就重起
```

注意顺序：先服务探测，后兜底。这样不会因为上一次兜底没跑完就误判。

## 数据流

```
浏览器页面
  ↓ https://<域名>/vnc.html
cloudflared (named tunnel)
  ↓ http 127.0.0.1:8090
MintPanel server.mjs  ── 反代 /websockify → 127.0.0.1:6080
  ↓ ws 127.0.0.1:6080
websockify-go  ──解 base64/binary 帧→ 裸 RFB
  ↓ tcp 127.0.0.1:5900
x11vnc
  ↓ X protocol
Xvfb :99  ── openbox 管窗口，tint2 画任务栏
```

## websockify 为什么重写成 Go

Python 版 `websockify` 每个连接 fork 一个进程（`multiprocessing.Process(target=self.top_new_client)`），
一个解释器约 20 MB。实测同一台机器：

| | 空闲 | 10 个连接 |
|---|---|---|
| Python websockify | 26.6 MB / 1 proc | 452.7 MB / 22 procs |
| **websockify-go** | 5.6 MB / 1 proc | 7.0 MB / 1 proc（≈128 KB/连接） |

Go 版单进程 goroutine 对，支持 `binary` + `base64` 子协议、静态文件（含 `.wasm` MIME）、
`/__stats`、SIGTERM 优雅退出。源码在 `assets/opt/src/websockify-go/`（vendor 已内置，离线可编）。
