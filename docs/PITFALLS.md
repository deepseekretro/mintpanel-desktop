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
