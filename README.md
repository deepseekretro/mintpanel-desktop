# mintpanel-desktop

无 root 容器里的**浏览器桌面**：Xvfb + openbox + tint2 + x11vnc + noVNC，外加 MintPanel 控制面板，
全部由 **supervisord** 托管（没有 systemd、没有 root、没有 sudo）。

> 目标环境：Pterodactyl / playhosting 这类容器 —— uid 1001、`/home/container`、
> 无 systemd、无 root、`apt` 只读。这套脚本只用 `curl` + `dpkg-deb -x` + `patchelf` + `pip --target`。

## 快速开始

```bash
# 全新容器，一条命令
curl -fsSL https://github.com/deepseekretro/mintpanel-desktop/releases/latest/download/install-deb-v3.sh | bash
```

装完会打印 supervisord 的 program 状态和面板地址。可选环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PANEL_PORT` | 8090 | MintPanel 监听端口 |
| `VNC_PORT` | 5900 | x11vnc 端口 |
| `NOVNC_PORT` | 6080 | websockify 端口 |
| `DISPLAY_NUM` | 99 | X display 编号 |
| `INSTALL_BROWSER` | 1 | 是否装 Camoufox（0 = 跳过） |
| `BASE_URL` | 本仓库 Release 附件 | 私有镜像时指向自己的 release 目录 |
| `TOKEN` | 空 | 仅当 `BASE_URL` 需要鉴权时才设置 |

`websockify-go` 提供 `linux/amd64` 和 `linux/arm64` 预编译二进制（`dist/websockify-go-linux-*`），
安装时按 `uname -m` 自动选择；拉不到时才退回源码编译，最后才是 Python websockify。

从私有镜像安装：

```bash
BASE_URL=https://mirror.example/releases TOKEN=xxxx \
  bash install-deb-v3.sh
```

## 三十秒结论

| 问题 | 答案 |
|---|---|
| 怎么装 | `bash install-deb-v3.sh`（一条命令，幂等，可重复跑） |
| 谁管进程 | `supervisord 4.2.5`（pip `--target` 装的，无 root），7 个 program |
| 怎么进桌面 | 面板 `https://<域名>/` → noVNC → 端口 6080（**websockify-go**） |
| 怎么开浏览器 | 桌面右键 →「Camoufox 159」，或按 **F1**（无桌面图标，刻意的） |
| 挂了怎么办 | `supervisorctl status` 看状态；`healthcheck.sh` 每 30s 做服务级探测 |
| 回滚 | `install-deb-v2.sh`（上一版）+ 安装时的 `.preinstall-backup-*` |

## 架构

```
tini (PID 1, 回收孤儿)
└── supervisord  4.2.5                      <- 唯一的 supervisor
    ├── xvfb        (10)  Xvfb :99 + 一次性壁纸（librsvg -> root pixmap）
    ├── openbox     (20)  窗口管理器（右键菜单 / F1 -> Camoufox）
    ├── tint2       (30)  任务栏（panel_items = TSC，无 launcher）
    ├── x11vnc      (40)  :99 -> 5900，stopsignal=KILL（防卡死时 TERM 无效）
    ├── websockify  (40)  6080 -> 5900 + 静态 noVNC（Go 版，goroutine/连接）
    ├── cloudflared (45)  named tunnel -> 127.0.0.1:8090（面板）/ quick 兜底
    └── healthcheck (50)  每 30s：RFB 探针 + 6080 端口探针 + ensure.sh

外部入口
  https://<域名>/          -> cloudflared -> MintPanel (8090)
  https://<域名>/vnc.html  -> MintPanel 反代 -> websockify-go (6080) -> x11vnc (5900)
  Camoufox 浏览器           -> 由 camoufox/open-two.sh 拉起（不在 supervisord 里）
```

## 端口

| 端口 | 用途 | 归属 |
|---|---|---|
| 8090 | MintPanel 面板 | `opt/mintpanel/server.mjs` |
| 6080 | noVNC / websockify | `[program:websockify]` |
| 5900 | x11vnc | `[program:x11vnc]` |
| `:99` | X display | `[program:xvfb]` |

## 目录布局（安装后）

```
$HOME/
├── opt/
│   ├── node/          官方 Node.js 22
│   ├── mintpanel/     面板（server.mjs + ensure.sh + .panel_token）
│   ├── desktop/       Xvfb / openbox / tint2 / x11vnc / xterm / noVNC / 壁纸
│   │   ├── bin/       websockify-go, xterm, Xvfb, rsvg2wall.py …
│   │   ├── lib/       解包出来的库（patchelf 修过 RPATH）
│   │   └── share/     novnc/, wallpaper/, fonts/
│   ├── supervisor/    ← 唯一 supervisor
│   │   ├── lib/       pip --target (supervisor 4.2.5 + setuptools<81)
│   │   ├── bin/       {supervisord,supervisorctl} wrapper, xvfb-run.sh, healthcheck.sh, probe.py
│   │   ├── etc/       supervisord.conf + conf.d/{desktop,cloudflared}.conf
│   │   ├── run/       supervisor.sock, supervisord.pid
│   │   └── log/       supervisord.log
│   ├── cloudflared/
│   └── toolchain/go/  可选：有它就会把 websockify 编成 Go 版
├── .cloudflared/      named tunnel credentials + config.yml
├── camoufox/          cf-ui.mjs, start-ui.sh, open-two.sh, arrange-windows.sh
└── .ssh/              可选：GitHub deploy key
```

## 三个启动脚本的关系

| 脚本 | 职责 | 幂等依据 |
|---|---|---|
| `camoufox/open-two.sh` | 人工入口。保证「屏幕上有两个 Camoufox 窗口」 | 窗口数（`wmctrl -l`），0 就杀掉陈旧进程重起 |
| `camoufox/start-ui.sh` | 环境准备（fontconfig 中文字体、version.json、env）+ `setsid` 拉起 | 进程（`pgrep cf-ui.mjs`） |
| `node cf-ui.mjs` | 本体：起 Camoufox、开窗、跑自动化 | 无（调试用） |

`open-two.sh` 里的 `exec 9>/tmp/open-two.lock; flock -n 9` 是单实例锁——
**启动子进程时必须 `9>&-`**，否则浏览器会继承 fd 把锁永久占住（详见 `docs/PITFALLS.md`）。

## 常用命令

```bash
SV=$HOME/opt/supervisor
$SV/bin/supervisorctl -c $SV/etc/supervisord.conf status
$SV/bin/supervisorctl -c $SV/etc/supervisord.conf restart websockify
$SV/bin/supervisorctl -c $SV/etc/supervisord.conf tail -f healthcheck

tail -f $HOME/opt/desktop/logs/wallpaper.log      # 壁纸
tail -f $HOME/camoufox/open-two.log               # 点图标/右键菜单
tail -f $HOME/camoufox/ui.log                     # 浏览器本体
```

## 文档

| 文件 | 内容 |
|---|---|
| `docs/ARCHITECTURE.md` | 每个 program 的职责、依赖顺序、信号选择 |
| `docs/PITFALLS.md` | 踩过的坑：flock fd 泄漏、openbox 菜单路径、subreaper、GOTMPDIR…… |

## 许可

内部工具，未附许可证。
