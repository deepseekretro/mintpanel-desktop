#!/usr/bin/env python3
"""把一棵进程树挂到「子收割者」下，杜绝僵尸堆积。

背景：容器 PID1 是 `java`，从不 wait()，任何孤儿进程退出后都会变成永久
僵尸（Z），一个浏览器生命周期能留下 100+，直接吃光 pids.max=512。
本脚本用 prctl(PR_SET_CHILD_SUBREAPER) 把自己变成收割者：子树里所有孤儿
都会重挂到这里并被 waitpid 回收，不再落到 PID1。

用法：
    python3 fly-supervise.py env DISPLAY=:2 ... node cf-ui.mjs
    （第一个参数是程序，其余透传）

退出：主程序退出后本脚本退出；SIGTERM/SIGINT 转发给主程序。
"""
import ctypes
import os
import signal
import sys

PR_SET_CHILD_SUBREAPER = 36


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("fly-supervise: usage: fly-supervise.py CMD [ARGS...]\n")
        return 2

    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        sys.stderr.write("fly-supervise: prctl 失败 errno=%d\n" % ctypes.get_errno())

    pid = os.fork()
    if pid == 0:
        try:
            os.execvp(sys.argv[1], sys.argv[1:])
        except Exception as e:  # noqa: BLE001
            sys.stderr.write("fly-supervise: exec %s: %s\n" % (sys.argv[1], e))
        os._exit(127)

    def forward(signum, _frame):
        try:
            os.kill(pid, signum)
        except Exception:
            pass

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)

    reaped = 0
    while True:
        try:
            p, _ = os.waitpid(-1, 0)
        except ChildProcessError:
            break
        except InterruptedError:
            continue
        if p == 0:
            continue
        reaped += 1
        if p == pid:
            break
    if reaped:
        sys.stderr.write("fly-supervise: 回收 %d 个子进程\n" % reaped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
