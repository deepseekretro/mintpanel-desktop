#!/usr/bin/env python3
"""功能回归：binary / base64 子协议、静态文件、并发、stats、畸形帧、SIGTERM 优雅退出。

用法: python3 test.py <binary> [--port 6099] [--vnc 5999]
"""
import base64
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

BIN = sys.argv[1] if len(sys.argv) > 1 else "./dist/websockify-go"
PORT = int(os.environ.get("TPORT", "6099"))
VNCPORT = int(os.environ.get("TVNC", "5999"))

fails = []


def check(name, cond, extra=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"   {extra}" if extra else ""))
    if not cond:
        fails.append(name)


# ---------- fake VNC server ----------
def fake_vnc():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", VNCPORT))
    srv.listen(64)

    def h(c):
        try:
            c.sendall(b"RFB 003.008\n")
            while True:
                d = c.recv(65536)
                if not d:
                    break
                c.sendall(b"ECHO:" + d)
        except OSError:
            pass
        finally:
            c.close()

    while True:
        c, _ = srv.accept()
        threading.Thread(target=h, args=(c,), daemon=True).start()


# ---------- minimal websocket client ----------
def ws_connect(proto="binary", path="/websockify"):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
    )
    if proto:
        req += f"Sec-WebSocket-Protocol: {proto}\r\n"
    s.sendall((req + "\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise RuntimeError("handshake closed")
        buf += chunk
    head, rest = buf.split(b"\r\n\r\n", 1)
    lines = head.decode(errors="replace").splitlines()
    return s, lines, rest


def frame(opcode, payload, mask=True):
    b = bytearray([0x80 | opcode])
    n = len(payload)
    mbit = 0x80 if mask else 0
    if n < 126:
        b.append(mbit | n)
    elif n < 65536:
        b.append(mbit | 126)
        b += struct.pack(">H", n)
    else:
        b.append(mbit | 127)
        b += struct.pack(">Q", n)
    if mask:
        k = os.urandom(4)
        b += k
        b += bytes(c ^ k[i % 4] for i, c in enumerate(payload))
    else:
        b += payload
    return bytes(b)


def read_frame(s, timeout=5):
    s.settimeout(timeout)

    def rd(n):
        out = b""
        while len(out) < n:
            c = s.recv(n - len(out))
            if not c:
                raise RuntimeError("eof")
            out += c
        return out

    h = rd(2)
    op = h[0] & 0x0F
    n = h[1] & 0x7F
    if n == 126:
        n = struct.unpack(">H", rd(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", rd(8))[0]
    return op, rd(n)


def http_get(path):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
    data = b""
    while True:
        c = s.recv(65536)
        if not c:
            break
        data += c
    s.close()
    head = data.split(b"\r\n\r\n", 1)[0].decode(errors="replace")
    status = int(head.splitlines()[0].split()[1])
    return status, head, data.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in data else b""


def proc_log(proc=None):
    return _PROC_LOG[0] if _PROC_LOG else ""


_PROC_LOG = [""]


def drain(proc):
    try:
        import select
        while True:
            r, _, _ = select.select([proc.stdout], [], [], 0)
            if not r:
                break
            line = proc.stdout.readline()
            if not line:
                break
            _PROC_LOG[0] += line
    except Exception:
        pass


def main():
    threading.Thread(target=fake_vnc, daemon=True).start()
    webdir = tempfile.mkdtemp(prefix="novnc-test-")
    open(os.path.join(webdir, "vnc.html"), "w").write("<!doctype html><title>noVNC</title>")
    open(os.path.join(webdir, "app.js"), "w").write("console.log(1)")
    open(os.path.join(webdir, "mod.wasm"), "wb").write(b"\x00asm")

    proc = subprocess.Popen(
        [BIN, "-listen", f"127.0.0.1:{PORT}", "-target", f"127.0.0.1:{VNCPORT}",
         "-web", webdir, "-stats", "/__stats", "-v"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    time.sleep(0.6)
    globals()["PROC"] = proc
    try:
        print("[1] binary subprotocol -> RFB + bidirectional")
        s, lines, rest = ws_connect("binary")
        check("101 upgrade", lines[0].endswith("101 Switching Protocols"), lines[0])
        check("negotiated binary", any("binary" in l for l in lines if "Protocol" in l),
              str([l for l in lines if "Protocol" in l]))
        op, payload = read_frame(s)
        check("first frame is RFB banner", payload.startswith(b"RFB 003.008"), repr(payload[:14]))
        s.sendall(frame(0x2, b"hello"))
        op, payload = read_frame(s)
        check("ws->tcp->ws echo", payload == b"ECHO:hello", repr(payload))
        s.sendall(frame(0x8, b""))
        s.close()

        print("[2] base64 subprotocol")
        s, lines, rest = ws_connect("base64")
        check("negotiated base64", any("base64" in l for l in lines if "Protocol" in l),
              str([l for l in lines if "Protocol" in l]))
        op, payload = read_frame(s)
        check("first frame is text base64", op == 0x1, f"opcode={op}")
        check("decodes to RFB banner",
              base64.b64decode(payload).startswith(b"RFB 003.008"), repr(payload))
        s.sendall(frame(0x1, base64.b64encode(b"hi")))
        op, payload = read_frame(s)
        check("base64 echo", base64.b64decode(payload) == b"ECHO:hi", repr(payload))
        s.close()

        print("[3] static files")
        st, head, body = http_get("/vnc.html")
        check("GET /vnc.html 200", st == 200, str(st))
        check("vnc.html body", b"noVNC" in body, repr(body[:30]))
        st, head, body = http_get("/")
        check("GET / serves vnc.html", st == 200 and b"noVNC" in body, str(st))
        st, head, body = http_get("/mod.wasm")
        check("wasm mime", st == 200 and "application/wasm" in head, str(st))
        st, head, body = http_get("/../etc/passwd")
        check("traversal blocked", st in (301, 403, 404), str(st))
        st, head, body = http_get("/nope.js")
        check("404 for missing", st == 404, str(st))

        print("[4] stats endpoint")
        st, head, body = http_get("/__stats")
        js = json.loads(body)
        check("stats json", st == 200 and "active" in js, json.dumps(js))

        print("[5] concurrency: 12 simultaneous sessions")
        socks = []
        for i in range(12):
            s, lines, _ = ws_connect("binary")
            try:
                op, payload = read_frame(s)
                assert payload.startswith(b"RFB"), payload[:16]
            except Exception as e:
                drain(proc)
                print(f"    conn {i} failed: {type(e).__name__} {e}")
                print("    server log tail:")
                for ln in (proc_log() or "").strip().splitlines()[-12:]:
                    print("      ", ln)
                raise
            socks.append(s)
        st, head, body = http_get("/__stats")
        js = json.loads(body)
        check("12 active sessions", js["active"] == 12, json.dumps(js))
        for s in socks:
            s.close()
        time.sleep(0.5)
        st, head, body = http_get("/__stats")
        js = json.loads(body)
        check("all released", js["active"] == 0, json.dumps(js))

        print("[6] malformed frame does not kill the server")
        s, lines, _ = ws_connect("binary")
        read_frame(s)
        s.sendall(bytes([0x82, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))  # bogus length
        s.close()
        time.sleep(0.3)
        s2, lines, _ = ws_connect("binary")
        op, payload = read_frame(s2)
        check("server alive after garbage", payload.startswith(b"RFB"), repr(payload[:14]))
        s2.close()

        print("[7] SIGTERM drains and exits 0")
        proc.send_signal(signal.SIGTERM)
        try:
            rc = proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
            rc = "timeout"
        check("exit code 0", rc == 0, str(rc))
        out = proc.stdout.read()
        check("logged drain", "draining" in out or "bye" in out, out.strip().splitlines()[-1][:80])
    finally:
        if proc.poll() is None:
            proc.kill()

    print()
    if fails:
        print(f"FAILED ({len(fails)}): {', '.join(fails)}")
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
