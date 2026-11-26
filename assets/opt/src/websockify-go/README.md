# websockify-go

`websockify` 的 Go 替代品：**WebSocket ⇄ TCP 双向代理**，用来把 noVNC 浏览器页面接到 x11vnc（5900）。

写它的唯一原因：原版 websockify 是 `fork` 语义——`websockifyserver.py` 里每来一条连接就

```python
p = multiprocessing.Process(target=self.top_new_client, args=(startsock, address))
p.start()
```

于是一个 Python 解释器进程 = 一条 VNC 连接。在只有 6.76 GB cgroup 的容器里，
十几个人同时开着 noVNC 页面就是十几个 Python 进程。Go 版用 goroutine，实测数据见下。

## 实测（nodaroo-01，真实 x11vnc）

| 场景 | websockify (Python) | websockify-go |
|---|---|---|
| 0 连接 | 26.6 MB（父进程） | 5.6 MB |
| 10 连接 | 22 进程 / 452 MB 总 RSS | 1 进程 / 6.9 MB |
| 每连接增量 | 一个完整解释器（~20 MB） | ~128 KB |
| 并发模型 | 每连接 1 个 fork 进程 | 每连接 2 个 goroutine |
| 依赖 | Python 3.12 + dist-packages | 无（静态链接二进制） |

## 用法

```bash
websockify-go -listen 127.0.0.1:6080 -target 127.0.0.1:5900 \
              -web ~/opt/desktop/share/novnc -stats /__stats
```

| 参数 | 说明 |
|---|---|
| `-listen` | 监听地址，默认 `127.0.0.1:6080` |
| `-target` | VNC 目标，默认 `127.0.0.1:5900` |
| `-web` | 顺带 serve 静态目录（noVNC 的 `vnc.html`）；空 = 关闭 |
| `-ws-path` | 只在这个路径升级，默认 `/websockify`；`""` = 任意路径 |
| `-stats` | 可选 JSON 统计端点，如 `/__stats` |
| `-ping-interval` | 发 WS ping 的间隔，默认 0（关）。设了之后 `pong` 超时会断连 |
| `-idle-timeout` | 空闲多久断开，默认 0（关）。VNC 会长时间静置，别乱开 |
| `-max-conns` | 超过这个连接数直接拒绝（保护内存），默认 0 = 不限 |
| `-v` | 打印每条连接的开/关与字节数 |

子协议：同时协商 `binary`（现代 noVNC 默认）和 `base64`（老客户端/某些代理）；
客户端不带子协议时按 `binary` 处理（与 websockify 行为一致）。

## 构建

目标机上编译（推荐，避免交叉编译打错架构）：

```bash
export PATH=$HOME/opt/toolchain/go/bin:$PATH
export GOCACHE=$HOME/.cache/go-build
export GOTMPDIR=$HOME/opt/src/tmp      # ← 必须，/tmp 是 100 MB tmpfs，linker 会 no space
export GOFLAGS=-mod=vendor GOPROXY=off # vendor/ 已入库，不需要外网
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$(date +%Y%m%d)" -o ~/opt/desktop/bin/websockify-go .
```

本地交叉编译（本机架构与目标不同时）：

```bash
./build.sh          # 产出 dist/websockify-go (amd64) 与 dist/websockify-go-arm64
```

## 测试

```bash
python3 test.py ./dist/websockify-go      # 需要 python3，用内置 fake VNC 服务器
```

覆盖：binary/base64 子协议、首帧 RFB banner、双向 echo、静态文件（含 `.wasm` MIME、
路径穿越、404）、`/__stats`、12 并发、畸形帧后仍存活、SIGTERM 优雅退出（exit 0）。

## 与原 websockify 的差异（诚实清单）

- 不支持 TLS（`--cert`）：本机场景是 `cloudflared → 面板 → 127.0.0.1:6080`，不需要。
- 不支持 `--token-plugin` 之类的鉴权插件：面板已经做了鉴权，且 cookie 桥接在面板层。
- 不支持 `--record`（录屏）、`--unix-target`、`--ssl-only`。
- `--web` 的目录列表行为不同（Go 版只 serve 文件，不生成目录索引）。
- base64 子协议按标准 base64 编解码，不做 websockify 那种「每帧无 padding」的宽松处理。

## 部署 / 回滚（nodaroo-01）

当前 supervisord 配置（`~/opt/supervisor/etc/conf.d/desktop.conf`）：

```ini
[program:websockify]
command=/home/container/opt/desktop/bin/websockify-go -listen 127.0.0.1:6080 \
        -target 127.0.0.1:5900 -web /home/container/opt/desktop/share/novnc -stats /__stats
priority=40
autostart=true
autorestart=true
startsecs=1
stopsignal=TERM
stopwaitsecs=5
```

回滚到 Python 版：

```bash
cd ~/opt/supervisor/etc/conf.d
cp desktop.conf.bak-pywebsockify desktop.conf
~/opt/supervisor/bin/supervisorctl -c ~/opt/supervisor/etc/supervisord.conf reread
~/opt/supervisor/bin/supervisorctl -c ~/opt/supervisor/etc/supervisord.conf update
```
