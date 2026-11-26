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
