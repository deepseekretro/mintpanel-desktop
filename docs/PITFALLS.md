# 踩过的坑

每一条都是真机上的故障，不是推测。

---

## 1. flock 的 fd 会泄漏给子进程，锁永远不释放

**症状**：点桌面图标，`deskicon.log` / `open-two.log` 明确记录「another open-two.sh is running」，
但屏幕上没有浏览器窗口，也就是既不重启也不报错。

**原因**：`open-two.sh` 用 `exec 9>/tmp/open-two.lock; flock -n 9` 做单实例，随后
`bash start-ui.sh` 启动浏览器。**子进程继承了 fd 9**，于是 `open-two.sh` 早已退出，
浏览器进程却仍持有那把锁。

**修法**：启动子进程时显式关掉：

```bash
bash "$H/camoufox/start-ui.sh" >>"$LOG" 2>&1 9>&-   # 9>&- 不把锁 fd 传下去
```

**排查手法**（不用猜）：

```bash
for p in /proc/[0-9]*; do
  ls -l "$p/fd" 2>/dev/null | grep -q open-two.lock && echo "holder=$p $(tr '\0' ' ' < $p/cmdline)"
done
```

**泛化**：任何 `exec N>lockfile` + `flock` + 再 `nohup`/`setsid` 起长命子进程，
都必须 `N>&-`。这和 systemd `Type=forking` 的遗留锁是同一类问题。

---

## 2. openbox 的菜单不是 `~/.config/openbox/menu.xml`

**症状**：改了 `~/.config/openbox/menu.xml`，`openbox --reconfigure` 之后菜单毫无变化。

**原因**：openbox 是用 `--config-file` 启动的：

```
openbox --config-file ~/opt/desktop/etc/xdg/openbox/rc.xml
```

而 `rc.xml` 里 `<menu><file>` 指向 `~/opt/desktop/etc/xdg/openbox/menu.xml`。
`~/.config/openbox/` 那份从来没被读过。

**排查**：

```bash
pgrep -af openbox                          # 看 --config-file 指向哪里
grep '<file>' ~/opt/desktop/etc/xdg/openbox/rc.xml
```

---

## 3. `fly-supervise.py` 不是保活，是 subreaper

看名字以为是守护进程，读代码才发现它做的是 `prctl(PR_SET_CHILD_SUBREAPER)`：
把自己变成子收割者，让浏览器进程树的孤儿重挂到自己下面被 `waitpid` 回收。

它来自 playhosting 容器——那里 **PID 1 是 `java`**，从不 `wait()`，孤儿会变成永久僵尸
塞满 `pids.max=512`。

换到 Docker + **PID 1 = `tini`** 的机器上就没必要了：tini 天然收养并回收孤儿。
实测去掉后 `cf-ui.mjs` 直接挂在 PID1 下，`zombies=0`，`pids.current=265/512`。

**判断依据永远是 `/proc/1/comm`，不是「有没有这个文件」**：

```bash
case "$(cat /proc/1/comm)" in
  tini|dumb-init|systemd|s6-svscan|init|runit) : ;;   # 不需要 wrapper
  *) WRAP="$PY_BIN $H/camoufox/fly-supervise.py" ;;   # java 之类才需要
esac
```

---

## 4. Go 编译报 `no space left on device`，其实磁盘有 900 G

**症状**：

```
link: mapping output file failed: no space left on device
```

**原因**：不是磁盘满，是 `/tmp` —— 这类容器 `/tmp` 是 100 MB 的 tmpfs，`go build` 的
临时目标文件全写在那里。`df -h /` 显示 968 G 也没用。

**修法**：

```bash
GOTMPDIR=$HOME/opt/src/tmp GOCACHE=$HOME/.cache/go-build go build ...
```

同理：**任何可能超过 100 MB 的中间产物都不要落 `/tmp`**。

---

## 5. `pkill -f <pattern>` 会杀掉自己

在 `/api/exec` 里执行 `pkill -f 'camoufox/cf-ui.mjs'`，如果这条命令自身的命令行里
包含了同样的字符串，`pkill` 会匹配到自己然后自杀。

**修法**：方括号技巧，让 pattern 不匹配自身字面量：

```bash
pkill -f 'camoufox/cf-ui[.]mjs'      # 正则里 [.] 不等于字面量 "."
```

---

## 6. pip `--target` 不安装 console_scripts 的 import 路径

`pip install --target ~/opt/supervisor/lib supervisor` 会把入口脚本放到
`lib/bin/supervisord`，但它是个 `from supervisor.supervisord import main` 的脚本——
不在 `sys.path` 里就 `ModuleNotFoundError`。

**两种解法**（本仓库都用）：

1. 加一层 3 行 bash wrapper，`export PYTHONPATH=$SV/lib` 后 `exec` 真入口；
2. 直接给真入口打补丁，让它自己把自己所在包的目录插进 `sys.path`：

```python
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))
```

另外：`setuptools>=81` 移除了 `pkg_resources`，supervisor 4.2.5 依赖它 →
必须 `pip install "setuptools<81"`。

---

## 7. 容器里 `ssh` 客户端直接 fatal

```
$ ssh -V
No user exists for uid 1001
```

`/etc/passwd` 没有 uid 1001 的条目，OpenSSH 客户端在 `main()` 第一行
`getpwuid(getuid())` 失败就 `fatal()`。这意味着：

- `ssh-keygen -f ...` 也会失败（同样原因）
- 所有走 `git@github.com:` 的操作都不可用

**替代**：生成密钥用 Python `cryptography`（`PrivateFormat.OpenSSH`），
推仓库走 HTTPS + PAT。

---

## 8. 不要把重活挂进 `.bashrc`

早期在 `.bashrc` 里挂了「重建桌面栈」。结果：桌面里开一个 `xterm` → 交互式 shell
读 `.bashrc` → 把正在跑的整套东西杀掉重建。

**结论**：`.bashrc` 只做纯粹的、幂等的、不影响既有进程的事。存活由 supervisord 负责。

---

## 9. quick tunnel 和 named tunnel 是两个东西

`cloudflared` 出现两份进程时不要急着认为「重复启动」：

| | 二进制 | 典型用途 |
|---|---|---|
| `[program:cloudflared]` | `opt/cloudflared/bin/cloudflared` | named tunnel → 面板端口，固定域名 |
| `cfd/run.sh` | `cfd/cloudflared` | quick tunnel → 某个本地端口，随机 `trycloudflare.com` 域名 |

同名不同命，先看 `--config` 还是 `--url` 再判断。
---

## 10. raw CDN 会把「文件不存在」的 404 缓存很久

**症状**：push 完一个新二进制，`raw.githubusercontent.com/<repo>/main/dist/<file>` 一直 404，
而同一个仓库的其他文件（包括 63 MB 的）都正常 200。GitHub API 查 `contents` 明明在，
blob 大小也对。

**原因**：push 之前用那个 URL 探测过（当时文件确实不存在），CDN 把 404 缓存了。
`?cache=1`、`?v=<timestamp>` 这些 query 都绕不过去。

**实测三条路径**：

```
raw.githubusercontent.com/<repo>/main/dist/<file>          404
github.com/<repo>/raw/main/dist/<file>                     404
github.com/<repo>/blob/main/dist/<file>?raw=true           200
raw.githubusercontent.com/<repo>/HEAD/dist/<file>          200   ← 用这个
```

**修法**：`BASE_URL` 用 `/HEAD/` 而不是 `/main/`；或者干脆改用 Release 附件
（`https://github.com/<repo>/releases/latest/download/<file>`，走发布 CDN，不会有这个问题）。

**教训**：探测「文件是否已经发布」时不要用最终要用的那个 URL——换一个，否则自己给自己
埋一个缓存。

---

## 11. deploy key 建不了 Release，但 GitHub Actions 可以

deploy key 的权限范围只有 git 传输（clone/fetch/push），够不着 REST API——
所以 `POST /repos/{owner}/{repo}/releases` 和上传附件都做不了。

绕过办法：在仓库里放一个 tag 触发的 workflow，用仓库自带的 `GITHUB_TOKEN` 建 release：

```yaml
on: push: tags: ["v*"]
permissions:
  contents: write
steps:
  - uses: softprops/action-gh-release@v2
    with:
      files: dist/*
```

deploy key 触发的 push 同样会触发 workflow。于是「没有 PAT」不再是障碍。
---

## 12. 无控制终端时 `[ -r /dev/tty ]` 是假的

setsid / nohup / CI 里跑安装脚本，`/dev/tty` 这个设备节点仍然存在且可读，`[ -r /dev/tty ]`
返回真；真正失败的是**打开**它的那一刻（ENXIO）。在 `set -e` 下，`printf ... >/dev/tty`
直接把整个安装干掉：

```
install-v3.sh: line 125: /dev/tty: No such device or address
```

正确探针是「能不能真的打开」：

```bash
if { exec 3<>/dev/tty; } 2>/dev/null; then
  printf "..." >&3; read -r ans <&3; exec 3>&-
else
  ans="默认值"
fi
```

## 13. assets 里带着未替换占位符的模板，supervisord 一声不响就死

`cloudflared.conf` 模板残留 `__TARGET__` 占位符，被解包进 `conf.d/`，而负责替换的 `sed`
循环只覆盖了白名单里的文件。supervisord 首次启动直接拒绝：

```
Error: The directory named as part of the path __TARGET__/opt/mintpanel/cf-named.log
does not exist in section 'program:cloudflared'
```

之后再怎么 `supervisorctl status` 都只是 `.../supervisor.sock no such file`，看不出根因。

**两条规矩**：
1. 每个 conf 文件只能有一个生成者（`cloudflared.conf` 只由 step 6 写，assets 里不许带）
2. 启动前 `rm -f` 掉可能继承的旧副本，别指望它一定是干净的

## 14. `stdout_logfile` 的目录没人创建

`desktop.conf` 里每个 program 都写 `stdout_logfile=opt/desktop/logs/*.log`，但安装脚本
从来没 `mkdir` 过 `opt/desktop/logs`。在老机器上能跑，因为手工安装时顺手建过；换新机器就是

```
Error: The directory named as part of the path .../opt/desktop/logs/xvfb.log does not exist
```

supervisord 对日志目录是**硬要求**，目录不存在就整个不启动（不是单个 program 失败）。

## 15. `releases/latest/download` 的缓存按边缘节点独立

发版后本机 `curl` 立刻拿到新附件，目标机却还是旧内容（`md5sum` 不变）。CDN 缓存 TTL
大约 30–60 秒，且各节点不同步。

- 安装/验证时用**固定 tag**：`releases/download/v1.3.3/...`，立刻一致
- 发版后自检要看**响应体 md5**，不是 HTTP 200
- `latest` 适合长期入口，不适合「刚发完版马上装」

## 16. 覆盖安装时 `cp: Text file busy`

在一台**已装好 v3** 的机器上重跑安装脚本，第 4 步（把 deb 摊平进 `opt/desktop`）失败：

```
cp: cannot create regular file '/home/container/opt/desktop/bin/./x11vnc': Text file busy
```

`ETXTBSY` 的成因是**有进程正在执行那个文件**，`cp` 不能用新内容覆盖正在跑的镜像。
v3 之后 `opt/desktop` 完全归 supervisord 管，而 Step 0 原来只杀：

- `opt/mintpanel/.panel.pid`
- `opt/desktop/logs/*.pid`
- `cloudflared`
- Camoufox（仅 `INSTALL_BROWSER=1` 时）

supervisord 自己没被杀，于是它托管的 Xvfb / openbox / tint2 / x11vnc / websockify
继续持有 `bin/*` 的映射 → 第 4 步必炸。

正确顺序：

```bash
"$OPT_SV/bin/supervisorctl" -c "$OPT_SV/etc/supervisord.conf" shutdown
pkill -f "$OPT_SV/lib/bin/supervisord"          # 只杀本前缀的
pkill -f "$OPT_DSK/xvfb-run\.sh"
pkill -f "$OPT_DSK/bin/websockify" / x11vnc / tint2 / openbox / Xvfb
for _i in $(seq 1 15); do                        # 等镜像彻底 unmapped
  [ "$(pgrep -f "$OPT_DSK/(bin|lib)/" | wc -l)" -eq 0 ] && break
  sleep 1
done
pkill -9 -f "$OPT_DSK/(bin|lib)/"                # 兜底
```

两点提醒：

- **必须等**，不能只发 SIGTERM 就往下走：`stat()` 到 `cp` 之间进程可能还没退干净
- `pkill -f "$OPT_DSK/(bin|lib)/"` 不会打死脚本自己（脚本 cmdline 里没有这个路径），
  但**别写成 `pkill -f opt/desktop`**，那样会把安装进程自己也算进去

另外第 4 步的 bin 合并现在带一次重试：万一有迟到的进程重新抓住文件，杀掉后重拷一次。

## 17. `set -o pipefail` + 命令替换 = 静默自杀

现象：覆盖安装跑到 Step 0 最后一步直接没了，日志停在 `[0/7] 停止已有相关进程准备覆盖安装...`，
`bash -x` 的 trace 结尾是：

```
+ _alive=0
+ cleanup
+ rm -rf '/home/container/.mintpanel-deb-stage-$'
```

注意 `_alive=0` 和 `cleanup` 之间**没有** `+ '[' 0 -eq 0 ']'`，说明脚本在赋值那一行就退出了，
`cleanup` 只是 `trap ... EXIT` 的收尾，**没人杀它**。

原因：

```bash
set -euo pipefail
_alive=$(pgrep -f "$OPT_DSK/(bin|lib)/" 2>/dev/null | wc -l)
```

- 进程清空后 `pgrep` 无匹配 → 退出码 **1**
- `pipefail` 让整条管道的退出码取最右非零 → **1**（不是 `wc` 的 0）
- 赋值语句因此失败 → `set -e` 直接终止脚本

`pgrep | wc -l` 是最容易中招的组合：`wc` 永远成功，看起来"不会失败"。同类的还有
`ls dir/*.deb | wc -l`（目录空时 `ls` 返回 2）、`grep -c`、`ss | grep`。

两个修法，任选：

```bash
n=$(pgrep -f pattern | wc -l || true)      # || 作用在整条管道上
n=$( { pgrep -f pattern || true; } | wc -l)
```

排查命令：

```bash
grep -nE '=\$\([^)]*\| *(wc|head|tail|awk)' install-deb-v3.sh
```

**隔离实验也要带 `set -e` 才有意义**：我第一版复现脚本写成 `set -uo pipefail`，
少了 `-e`，同样代码跑得好好的，白绕一圈。

### 17.1 同一个坑的完整清单（v1.4.3–v1.4.5 一共修了 10 处）

| 位置 | 写法 | 为什么会返回非零 |
|---|---|---|
| step 0 退出等待 | `pgrep -f pattern \| wc -l` | 进程清空后 `pgrep` 无匹配 = 1 |
| `.deb` 计数 | `ls dir/*.deb \| wc -l` | 目录空时 `ls` = 2 |
| program 计数 | `grep -h '^\[program:' ... \| wc -l` | 无匹配 = 1 |
| supervisor 启动 | `supervisorctl start all \| tail -8` | program 全是 `autostart=true`，早已 RUNNING → `already started` = 非 0 |
| RUNNING 计数 | `... status \| grep -c RUNNING` | 一个都没匹配上 = 1 |
| 状态展示 | `supervisorctl status \| sed ...` | 套接字还不可用时非 0 |
| 配置回显 | `grep -h '^\[program:' ... \| sed ...` | 无匹配 = 1 |
| 错误提示 | `tail -3 apt-update.err \| sed ...` | 上一步没留文件 = 1 |
| 磁盘提示 | `df -h /tmp "$TARGET" \| sed ...` | 路径不存在 = 1 |
| Node 版本解析 | `curl -fsSL ... \| awk ...` | 网络失败 = 非 0（现在会走到显式空值检查并给出可读报错） |

判定规则：**行尾是 `| grep/head/tail/sed/wc/awk` 且不在 `if`/`while` 条件里，就必须有 `|| true`**。

```bash
# 一次性审计
grep -nE '\| *(tail|head|grep|sed|awk|wc|tr)[^|]*$' install-deb-v3.sh \
  | grep -v '|| true' | grep -vE ':\s*(if|elif|while|\[)'
```

这类 bug 的迷惑性在于：**每次报错位置都不一样**（上一个坑挡住了下一个），看似"修不完"。
实际上全部来自同一条 `set -euo pipefail`。

## 18. 不要为 noVNC 单独开一个公网 hostname —— 它没有鉴权

现象：装完 `https://<panel>/vnc.html` 是 404，于是"顺手"给 websockify 的 6080 加了一条
ingress（`<sub>-vnc.<zone> -> 127.0.0.1:6080`）。桌面能用了，但**任何人拿到这个 hostname
都能直接接管桌面**——`x11vnc` 默认是 `-nopw`，websockify 也不校验任何东西。
桌面里通常开着浏览器，浏览器里通常是已登录的会话。

**正确入口是面板自带的 `/novnc` 反代**，`server.mjs` 里两处都校验 `mintpanel_session`：

```js
function proxyNovncHttp(req, res) {
  if (!isAuthedReq(req)) { res.writeHead(401, ...); return; }   // 未登录 401
  ...proxy to NOVNC_HOST:NOVNC_PORT
}

server.on("upgrade", (req, socket, head) => {
  if (!url.includes("websockify")) return socket.destroy();
  if (!isAuthedReq(req)) { socket.end("HTTP/1.1 401 Unauthorized\r\n\r\n"); return; }
  ...proxy to 127.0.0.1:6080/websockify
});
```

所以：

| 入口 | 鉴权 |
|---|---|
| `https://<panel>/novnc/vnc.html` | 面板登录态（HTTP 与 WS 都校验）✓ |
| `https://<sub>-vnc.<zone>/vnc.html` | **无** ✗ |

验证方法（`--http1.1` 是必须的，HTTP/2 下 Cloudflare 对 Upgrade 直接 400）：

```bash
curl -s -i --http1.1 -H "Cookie: mintpanel_session=$SESS" \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  https://<panel>/novnc/websockify        # 有 cookie -> 101，没有 -> 401
```

纵深防御：即使走面板代理，`x11vnc` 也应带 `-rfbauth`（`-storepasswd` 生成 8 字符，
`chmod 600`），这样单独拿到 5900/6080 也进不去。

脚本策略（v1.4.7 起）：默认**不建**公开 VNC hostname；只有 `CF_VNC_DOMAIN=...` 显式给出才建，
并在安装时打印警告。真需要直连就配 Cloudflare Access（本账号 Zero Trust 已启用，
`/accounts/{a}/access/apps` 可用）。

## 19. noVNC 中文剪贴板乱码（发给远端被截断 / 收进来是拉丁乱码）

| 项 | 内容 |
|---|---|
| 症状 | 远端复制中文出来是 `è¿ç¨ä¸æ`；往远端粘贴中文没反应 |
| 根因 A | x11vnc 的 `ServerCutText` 装的是 X selection 的**原始 UTF-8 字节**，noVNC 标准路径按 ISO-8859-1 逐字节拼串 |
| 根因 B | `clipboardPasteFrom()` 用 `charCodeAt(i)` 截成单字节，非 Latin-1 字符全丢 |
| 根因 C | libvncserver 0.9.14 的 ExtendedClipboard 只半实现：回 `Notify` 时重发自己的 CutText、从不 `Request` → 粘贴静默失效 |
| 修法 | 对 `share/novnc/core/rfb.js` 打 3 处补丁（收 UTF-8 解码 / 发 UTF-8 编码 / 不宣告 ExtendedClipboard），全部带 `[local patch]` 标记 |
| 安装脚本 | `install-deb-v3.sh` 步骤 5 自动打，幂等（已含 `local patch` 就跳过），输出 `noVNC clipboard patch: 3 edits applied` |
| 检查 | `grep -c 'local patch' share/novnc/core/rfb.js` 应为 3 |
| 会被覆盖吗 | 会。重装 `novnc` deb 会覆盖；重跑安装脚本会重新打 |

详细配方与真浏览器验证方法见 `/root/NOVNC-CLIPBOARD.md`。

## 20. x11vnc 泄漏 SysV 共享内存 → 桌面黑屏（x11vnc FATAL）

| 项 | 内容 |
|---|---|
| 症状 | 重装几次后 `x11vnc` 变 `FATAL`（supervisord 显示），`/novnc` 连不上；日志 `shmget(scanline) failed: No space left on device` |
| 根因 | x11vnc 每次启动申请两个 SysV shm 段（7680 B + ≈8 MB），被 supervisord 重启时不释放。`kernel.shmmni` 默认 4096，累积到上限后无法再申请 |
| 判断 | `ipcs -m \| grep -c '^0x'` 接近 4096；`diff` 里全是 `nattch=0` 的孤儿段 |
| 修法 1 | `ipcs -m \| awk -v me=$(id -u) '$1 ~ /^0x/ && $3 == me && $6 == 0 {print $2}' \| while read id; do ipcrm -m $id; done`（`ipcrm -m` 一次只能删一个，`xargs -n 200 ipcrm -m` 是错的） |
| 修法 2（根治） | x11vnc 加 **`-noshm`**，不再用 SysV 共享内存；安装脚本也会在启动前清理孤儿段 |
| 注意 | `/dev/shm` 用量为 0 与 SysV shm 无关，别被 `df /dev/shm` 误导 |

## 21. hy2 / xray 节点链接不能用手访问面板的域名（隧道域名）

| 项 | 内容 |
|---|---|
| 症状 | 通过 `nodaroo-02.10w123.com` 打开面板，复制出来的 hy2/xray 节点串连不上 |
| 根因 | cloudflared 只代理 HTTP/WebSocket。hy2 是 UDP、xray REALITY 是裸 TCP，**都不过隧道**。而 UI 的 `q()` 默认取 `location.hostname`，于是把隧道域名写进了节点地址 |
| 修法 | 面板探测「直连域名」并以 cookie `panel_direct_host` 下发给浏览器；UI 的 `q()` 优先读这个 cookie，再回落到 `location.hostname` |
| 配置 | `PANEL_DIRECT_HOST=de2.nodaroo.fun`（安装脚本写入 `<panel>/.direct_host`，一行一个候选；多个候选时按 A 记录与出口 IP 匹配取正确的那个） |
| 服务端细节 | cookie 必须在 `res.writeHead(status, headers)` 的 headers 里合并，不能用 `res.setHeader` —— Astro 传自己的 headers 对象会把先前设置整个覆盖 |
| 检查 | `curl -D- -X POST .../api/auth/login` 应同时出现 `mintpanel_session` 和 `panel_direct_host=...` |

### 补充：域名模式下前端也不能把域名当 SNI

后端把 `sni` 固定成服务端 `serverNames`（`www.microsoft.com` / hy2 的 `www.bing.com`）后，
前端还有两处会把它改回去：

| 位置 | 原行为 | 改成 |
|---|---|---|
| `K(host)` 自动模式 | host 是域名 → 返回 host 当 SNI | 返回 `""`，不覆盖后端给的 sni |
| `ae(link, host, sni)` | `!sni && host` 时用 host 补 sni | 去掉这个回退 |
| 状态文案 | `SNI 已自动跟随=<域名>` | `连接地址=<域名>，SNI 跟随服务端伪装` |
| SNI 输入框 | 自动模式把域名填进去 | 保持空 |

实测：`vless://...@de2.nodaroo.fun:25675?...&sni=www.microsoft.com`（自动模式），手动填 SNI 仍生效。

#### 第二层：卡片徽标 + 输入框 + 初始状态行

上一条只修了 `K()`，页面仍有三处把域名当成 SNI：

| 位置 | 原代码 | 现象 |
|---|---|---|
| `je()` / `Me()` 卡片徽标 | `r=a||(H(n)?o.sni:n)` | 卡片显示 `SNI: de2.nodaroo.fun`（复制出来的链接却是 `www.bing.com`） |
| `je()` / `Me()` 预填 | `t("node-custom-sni").value=H(n)?"":n` | SNI 输入框被填成域名 |
| 初始化 | 只有事件处理器里调 `oe()` | `node-host-status` 一直停在 SSR 占位文案 `当前模式: IP 原生` |

改法：徽标用 `r=a||o.sni`；输入框恒置空；初始化链末尾补一次 `oe()`（`De(),oe(),setInterval(...)`）。
SSR chunk `dist/server/pages/index.astro.mjs` 里的规则文案也随之改掉——原来写的是「域名模式下 SNI 自动跟随域名」，与现在的行为相反。

验证（camoufox headless 实跑 `/services`）：
`当前模式: 域名模式 (连接地址=de2.nodaroo.fun，SNI 跟随服务端伪装)` /
`SNI: www.bing.com` / `SNI: www.microsoft.com` / SNI 输入框为空。

## 23. xray 要出两条链路，hy2 只能一条

UDP 走不了 cloudflared 隧道，所以两条协议的可达性完全不同：

| 协议 | 直连 | 经 cloudflared |
|---|---|---|
| hysteria2 | ✅ `direct_host:SERVER_PORT` (UDP) | ❌ 隧道只转发 TCP/HTTP |
| xray REALITY | ✅ `direct_host:SERVER_PORT` (TCP) | ❌ REALITY 是裸 TCP，隧道不透传 |
| xray over WS | — | ✅ `面板域名:443` + `path=/rayws` |

**不需要改云端隧道配置**：面板自己就在隧道后面，给它加一条 WebSocket upgrade 转发即可。

1. xray vault 配置加一个 inbound（注意 ws 不能用 `flow: xtls-rprx-vision`）：

```json
{ "tag": "ws-in", "listen": "127.0.0.1", "port": 28443, "protocol": "vless",
  "settings": { "clients": [{ "id": "<同 reality 的 uuid>", "email": "cdn@mint" }], "decryption": "none" },
  "streamSettings": { "network": "ws", "wsSettings": { "path": "/rayws" } } }
```

2. 面板 `server.mjs` 的 `upgrade` 事件里加一条分支：`/rayws` → `127.0.0.1:28443`，**不校验 panel session**
   （VLESS uuid 本身就是鉴权，客户端带不了浏览器 cookie）。

3. `xraylib` 追加第二条 link，前端 `Me()` 按 `tag === "cdn"` 渲染成「Cloudflare 隧道」徽标。

**前端必须放行 ws 链接**：`ae(link, host, sni)` 会把链接里的 `@host:` 和 `sni=` 改写成直连域名，
隧道链接一改就废。加一条短路：

```js
if (/[?&]type=ws(&|#|$)/.test(a)) return a;
```

**验收**（客户端配置，不填 flow）：

```
vless://<uuid>@<panel-domain>:443?security=tls&type=ws&path=%2Frayws&host=<panel-domain>&sni=<panel-domain>&fp=chrome
```

实测两条链路出口 IP 都是 `94.130.237.57`（Hetzner DE）。

## 24. 手工打补丁后浏览器还在跑旧 JS

**症状**：改完 `dist/client/_astro/index.*.js`、接口返回值也确认了新值，但浏览器页面照旧（比如输入框还是隧道域名）。

**根因**两层：

1. `server.mjs` 的 `serveStatic` 只设 `Content-Type`，**没有 `Cache-Control` / `ETag` / `Last-Modified`**。
   浏览器对这类响应走启发式缓存（按已有 age 的百分比续期），可能挂很久。
2. Astro 的 `_astro/index.<hash>.js` 文件名是**构建期**内容 hash。手工改内容不改名字，缓存键完全不变。

**修法**：

```bash
# 改名 = 换 cache key，浏览器必然重新下载
new=$(md5sum dist/client/_astro/index.astro_astro_type_script_index_0_lang.OLD.js | cut -c1-8)
mv ...OLD.js ...$new.js
sed -i "s/OLD/$new/g" dist/server/manifest_*.mjs     # Astro manifest 里有两处引用
```

并在 `serveStatic` 里补缓存头（以后改什么都不用改名）：

```js
res.writeHead(200, {
  "Content-Type": MIME[ext] || "application/octet-stream",
  "Cache-Control": "no-store, must-revalidate"
});
```

**另外**：`localStorage.node_custom_host` 优先级最高。旧版面板会把当前访问域名自动写进这个框，
若被 `onCustomHostChange` 落盘，之后永远返回那个值。`q()` 里加清洗：

```js
if (e && e === location.hostname) { localStorage.removeItem("node_custom_host"); e = ""; }
```

**验证**（camoufox 三个上下文）：

| 场景 | 期望 |
|---|---|
| 干净浏览器 | 显示探测到的直连域名 |
| `localStorage = 隧道域名` | 值被删除，仍显示直连域名 |
| `localStorage = 自定义域名` | 尊重用户输入 |

## 25. 隧道链路用 XHTTP (packet-up)，不要 ws

`ws` 在 xray 25+ 已被标记 deprecated（`This feature WebSocket transport is deprecated`），
CDN 后面更合适的是 **XHTTP**，`mode: packet-up` 对 cloudflared 这种 HTTP/1.1 反代最省事。

服务端：

```json
{ "tag": "xhttp-in", "listen": "127.0.0.1", "port": 28444, "protocol": "vless",
  "settings": { "clients": [{ "id": "<uuid>", "email": "cdn@mint" }], "decryption": "none" },
  "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/rayws", "mode": "auto" } } }
```

**服务端必须 `mode: "auto"`，客户端才指定 `packet-up`。** 服务端写死 `packet-up` 时，
部分客户端的内置协商（先试 stream-up）会直接失败，表现就是「配置看着没错但连不上」。

`stream-up` 在 Cloudflare 后面**不可用**（实测 10 MB 下行 = 0 B / 90 s 超时）：
它依赖单向长 POST 上行流，cloudflared 与 CF 边缘都会缓冲/切断。`auto` 只是兼容期开关，
实际生效的只能是 `packet-up`。

面板 `server.mjs` 要同时支持两种形态：

- 普通 HTTP（XHTTP 用）：任何 `/rayws*` 请求 → `http.request` 转发到上游，`req.pipe` / `res.pipe` 双向流式
- upgrade（兼容旧 ws）：`/rayws` 的 upgrade → `net.connect` 裸转发

客户端链接：

```
vless://<uuid>@<panel-domain>:443?security=tls&encryption=none&type=xhttp&mode=packet-up&path=%2Frayws&host=<panel-domain>&sni=<panel-domain>&fp=chrome
```

### 端口别用 28443

面板用 `/proc/net/tcp` 里出现 `:6F1B`（=28443）判断「Java 插件在跑」，命中就**跳过 Node 端启动** xray。
一旦把 CDN 入口放在 28443，面板就会一直认为 Java 插件活着，xray 永远起不来。用 28444。

### 而且这个判断本身有坑

`/proc/net/tcp` 里 `state=06`（TIME_WAIT）的残留连接也算「端口被绑」，所以要按状态过滤：

```js
// 只看 LISTEN(0A)
if (cols.length >= 4 && cols[1].endsWith(":" + hexPort) && cols[3] === "0A") return true;
```

`xraylib` 里的 `checkJavaXrayRunning()`、`server.mjs` 里的 `isTcpPortBound()` 两处都要改。

**验收**（真客户端，xhttp 配置不填 flow）：经隧道出口 IP 与直连一致。

## 26. `action=restart` 只写文件，不重载内嵌 xray

**症状**：改完 xray config（例如 `xhttpSettings.mode` 从 `packet-up` 改成 `auto`），调
`POST /api/xraylib {"action":"restart"}` 返回 `{"ok":true}`，监听也还在，但客户端行为完全没变。

**根因**：面板的内嵌 xray 是**同一个 Node 进程里的 native 库实例**（`yabs_xray.node` + `libxray.so`）。
`save_config` 把配置写进 vault 和 `/tmp/xray/config.json`，`restart` 只做了「文件层面的重启」，
没有 `os.Exit`/重新 `Start()` 那个 native 实例 —— 内存里跑的还是旧配置。

**判断方法**：

```bash
ps -o pid,lstart,etime -p $(pgrep -f 'mintpanel/server.mjs')
```

面板进程启动时间没变 = native 实例大概率没重载。

**正确做法**：改完配置后到面板 UI 点「重启 Xray」按钮（它会走真正的 native 重载），
或者重启整个面板进程。CLI 的 `action=restart` 不足以让新配置生效。

**验证**：改完立刻用真客户端连一次；同时看 `panel.log` 里 `[xhttp-in >> direct]` 计数是否增长。

## 27. 入口分流交给 nginx，不要用 Node 的 http 代理转发 XHTTP

**实测差距**（同一条隧道、同一个 xray inbound、同一天）：

| 分流实现 | 10 MB 下行 |
|---|---|
| Node `server.mjs` 里 `http.request` + `pipe` 转发 | 6.2 MB/s |
| nginx `proxy_pass` | **15.3 MB/s** |

Node 的 `http.request` 转发要走用户态拷贝、分块边界和它自己的 agent 连接池，长连接下行
在高延迟链路上劣化明显；nginx 是零拷贝直通，并且 `proxy_buffering off` /
`proxy_request_buffering off` 能把双向流式行为控制得很干净。

**架构**：

```
cloudflared（云端 ingress = http://127.0.0.1:8090）
  -> nginx 127.0.0.1:8090
       location /rayws  -> 127.0.0.1:28444   (xray XHTTP inbound)
       location /       -> 127.0.0.1:8091    (面板)
```

**为什么面板要退到 8091**：8090 必须让给 nginx，而 cloudflared 的 ingress 写在
Cloudflare 后台（`config_src: cloudflare`），改本地参数无效。把面板挪走比改云端配置安全得多。

**nginx 怎么装**（容器里 apt 只读、也没有 root）：

```bash
curl -s -o nginx.deb http://deb.debian.org/debian/pool/main/n/nginx/nginx_1.22.1-9+deb12u9_amd64.deb
dpkg-deb -x nginx.deb "$HOME/opt/nginx"
$HOME/opt/nginx/usr/sbin/nginx -p "$HOME/opt/nginx" -c "$HOME/opt/nginx/nginx.conf"
```

Debian 12 的 nginx 只依赖 `libpcre2-8-0` / `libssl3` / `zlib1g`，这些基础镜像里都有，
不需要 `patchelf`，也不用编译。

**launch 方式**：交给 supervisord（`priority=42`，早于 healthcheck），
`-g "daemon off;"` 前台跑否则 supervisord 认为它退出了。它挂了＝整站不可达，必须 `autorestart=true`。

**`set -e` 陷阱**：`[ "$ENTRY_PORT" = "$PANEL_PORT" ] && ENTRY_PORT=$((PANEL_PORT+1))`
条件为假时整行返回 1，脚本直接静默退出。必须写成 `if ... then ... fi`。

**验收顺序**（改完必须全走一遍）：

```
GET  /              -> 200   (面板)
POST /rayws/probe   -> 400   (xray 应答)
GET  /api/xraylib   -> 401   (需要登录)
GET  /novnc/vnc.html-> 401   (需要登录)
真客户端经 CF 拉大文件 -> 出口 IP 与直连一致
```

## 28. PaaS 只给一个端口（`SERVER_PORT`），端口对不上就没有直连

**症状**：面板生成的直连链接（REALITY / hysteria2）连不通，隧道那条却正常。

**真正的根因几乎总是端口**，而不是协议、证书或防火墙。PaaS 容器只暴露一个公网端口，
写在环境变量 `SERVER_PORT` 里；而面板的 xray/hy2 配置是**磁盘上的旧文件**，里面记的
还是上一次生成时的端口（或别的机器上的端口），新代码的默认值只对「配置不存在」生效。

实测两台机器的遗留值：

| 机器 | `SERVER_PORT` | 旧 config 实际监听 | 结果 |
|---|---|---|---|
| nodaroo-01 | `25917` | xray `30649`、hy2 `:38573` | 两条直连都不通 |
| nodaroo-02 | `26064` | xray `26064` | 正常 |

**必须先改配置再测端口，否则会得到假阴性。** 我第一次判断 nodaroo-01「没有入站通道」
就是错的：平台把 `25917` DNAT 进容器，但 xray 监听 `30649`，SYN 无人接管被丢弃，
从外面看和「没有映射」完全一样。把 inbound 改到 `25917` 后立刻通了 ——
**验证映射是否存在的唯一可靠方法是让服务监听那个端口，不能靠扫端口猜。**

**域名不在环境变量里。** PaaS 只注入端口，域名得自己维护：

```
PUBLIC_NODE_HOST   → 生成链接里的 host（hy2lib/xraylib 都读它）
PANEL_DIRECT_HOST  → server.mjs 的 detectDirectHost() 候选，校验 A 记录 == 容器出口 IP
./.direct_host     → 同上，文件形式，一行一个候选
```

三个都不配时，前端 `q()` 会退回到 `location.hostname`，也就是**隧道域名**
（`xxx.10w123.com`，解析到 Cloudflare 边缘）—— 拿它做 REALITY 握手必然失败。
判断方法：`curl -sD - -o /dev/null https://<面板域>/ | grep panel_direct_host`，
没有这个 cookie 就说明三个都没配。

```bash
# 正确配置（start.sh 里）
export PANEL_DIRECT_HOST="${PANEL_DIRECT_HOST:-se2.nodaroo.fun}"
export PUBLIC_NODE_HOST="${PUBLIC_NODE_HOST:-se2.nodaroo.fun}"
echo 'se2.nodaroo.fun' > .direct_host
```

**hysteria2 与 xray 共用同一个端口号**（UDP / TCP，互不冲突）。nodaroo-01 现在：
hy2 `UDP 25917`、xray `TCP 25917`、隧道 `/rayws` → `127.0.0.1:28444`。

**硬编码兜底端口是定时炸弹。** 现在代码写的是：

```js
const NODE_PORT = Number(process.env.SERVER_PORT || 25675);
```

`25675` 在没有 `SERVER_PORT` 的平台上会安静地生成 `host:25675` 的链接 ——
在共享 PaaS 上那可能是**邻居容器**。看起来正常、实际连到别人机器，比报错危险得多。
注释里其实已经写了这一点，但代码没落实。

**待发版（v1.9.0）**：端口三级兜底 + host 三级兜底 + 无值就不出直连链接

```js
// 端口：PaaS 各家注入的变量不同
const PUBLIC_PORT =
  Number(process.env.SERVER_PORT)   ||   // nodaroo / 多数 PaaS
  Number(process.env.WEBSITES_PORT) ||   // Azure App Service
  Number(process.env.PORT)          ||   // Railway / Render / Fly / Heroku
  0;

// host：域名 > 探测到的出口 IP > 不给
const HOST = process.env.PUBLIC_NODE_HOST || await detectEgressIp() || null;

const HAS_DIRECT = PUBLIC_PORT > 0 && !!HOST;
// HAS_DIRECT 为 false 时不生成 direct 链接，node_info.port = null
```

**出口 IP 为什么能当兜底**：`detectDirectHost()` 本来就在做「候选域名的 A 记录
== 容器出口 IP」的比对，出口 IP 这份数据已经拿到了，只是没拿它当 host。
实测 nodaroo-01：`REALITY` 与 `hysteria2` 用 `16.16.127.139:25917` 直连，
出口均正确 —— **REALITY 的 `sni` 与连接目标是两回事**，`sni` 只是伪装字段，
`address` 填 IP 完全可用；hy2 用 `insecure: 1` 也不受影响。

但 IP 当 **首选** 有三个真风险，所以只能当兜底：

| 风险 | 说明 |
|---|---|
| 出口 ≠ 入站 | NAT 池场景下出站走 A、入站映射到 B，拿到一个连不进的 IP（本机是 1:1 NAT，恰好一致） |
| IP 会变 | 重新调度 / 迁移 / 重建容器后失效 |
| 无法自证 | 面板在容器内，验证不了「外面能否从这个 IP:PORT 进来」；出口 IP 是「我出去的地址」，不等于「别人能进来的地址」 |

因此优先级固定为：**人工域名 > 探测出口 IP > null（不出直连）**，
永远不要回落到硬编码值。

改动点：`astro-panel/src/pages/api/hy2lib.astro.ts`、`xraylib.astro.ts`、
`server.mjs` 的 cookie 段。同步四处：本仓库 `dist/`、nodaroo-02、nodaroo-01、pingless-in-shell。

**自检命令**（查完再改）：

```bash
# 1. 平台给的端口
env | grep -E '^SERVER_PORT='
# 2. 实际监听
ss -ltn | grep -E ':(25917|30649)'; ss -lunp | grep node
# 3. 配置里的 listen / inbound port
head -1 /tmp/hy2/config.yaml
python3 -c "import json;c=json.load(open('/tmp/xray/config.json'));print([(i.get('port'),i.get('streamSettings',{}).get('network')) for i in c['inbounds']])"
# 4. 链接里的端口是否与 SERVER_PORT 一致
curl -s -b <cookie> https://<面板域>/api/xraylib | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['node_info'])"
```

**警告**：`/tmp` 在部分平台是持久化的（容器重启不重建时）。所以「重启就好」并不成立，
旧 config 会一直生效，必须人工核对或代码里加校验。

## 29. 健康检查探错端口 = 每 30 s 杀掉一次健康的 x11vnc

**现象**：noVNC 画面每隔半分钟黑一下再恢复；`supervisord.log` 里 x11vnc
`spawned -> success -> SIGKILL -> spawned` 无限循环，间隔恰好 32 s。

**原因**：`healthcheck.sh` 原本写死 `probe.py rfb 5900`（TCP）。而为了不在容器的
私有网段上暴露 VNC（无密码），x11vnc 改成了 `-rfbport 0 -rfbportv6 -1 -unixsock ~/.vnc/vnc.sock`，
**根本没有 TCP 5900**。于是探测永远失败，健康检查每次都「治」一次 —— 把好进程杀了。

**修法**：从 program 配置里读出模式，再选探测方式，别用「socket 文件在不在」猜
（x11vnc 死了 socket 也没了，猜错就永远不重启）。

```bash
VNC_UNIX=$(cat "$SV"/etc/conf.d/*.conf 2>/dev/null \
  | grep -v '^[[:space:]]*[;#]' \
  | sed -n 's/.*-unixsock[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' | head -n1)
if [ -n "$VNC_UNIX" ]; then VNC_PROBE=("rfbunix" "$VNC_UNIX"); else VNC_PROBE=("rfb" "5900"); fi
```

`probe.py` 同时加了 `rfbunix <path>`（AF_UNIX + 真的收 12 字节 `RFB 003.008`）。
另外探测失败要**重试一次再重启**：开机时 healthcheck 可能比 Xvfb/x11vnc 先起来，
单次探测会把 2 秒大的进程误杀一次。

## 30. 容器重启后整套服务没起来：`app.py` 缺自启钩子

**现象**：PaaS 重启容器后 `supervisord` / 面板 / cloudflared / xray 全都不在，
但 remote-bash agent 在线（所以「机器还活着」，很容易误判成服务挂了）。

**原因**：这个镜像族（Pterodactyl 式 python 容器）的 STARTUP 只有
`python /home/container/app.py`，而 `app.py` 是**平台给的最小引导**：下载
`remote-bash-agent.py` 然后 `os.execv` 成 agent。它不会跑 `mintpanel-autostart.sh`，
所以桌面栈、面板、隧道都等着没人叫。

判据（一条就够）：

```bash
ps -o etime= -p 1        # PID1 只有几分钟 = 刚重启过
grep -c spawn_autostart ~/app.py   # 0 = 没有钩子
pgrep -fc supervisord              # 0 = 服务栈没起
```

**修法**：给 `app.py` 加 `spawn_autostart()`（在 `download_script()` 之后、`execv` 之前
用独立会话提交），安装脚本 v1.8.1 起会**自动打这个补丁**（幂等、`py_compile` 校验、
失败自动回滚备份）。别把钩子塞进 `.bashrc`：xterm 里的交互式 shell 会重跑桌面启动，
历史上就是这么把 Xvfb 打死的（见 §22 一带的记录）。

## 31. `pack-assets.sh`：desktop-assets.tar.gz 不能只打子目录

`dist/desktop-assets.tar.gz` 是安装脚本 step 5 唯一的桌面资产来源，它**必须**包含
`camoufox/`、`mintpanel-autostart.sh`、`mintpanel-ensure.sh`、`opt/supervisor/*`、
`opt/desktop/{bin,share}`。手工 `tar czf ... opt/supervisor opt/desktop/bin` 打出来的包
少了三样，安装脚本的 `missing desktop asset` 检查会直接 abort。

**永远从 `assets/` 整体打包**：

```bash
./pack-assets.sh    # tar -C assets .  + 必需文件自查
```

顺带一个 bash 坑：自查时不要写 `tar tzf "$OUT" | grep -qx ./file`。
`grep -q` 命中即退出 → tar 收到 SIGPIPE → 在 `set -o pipefail` 下整条管道返回 141，
结果永远是「文件缺失」。先 `LIST=$(tar tzf ...)` 再 `grep -qxF <<<"$LIST"`。
