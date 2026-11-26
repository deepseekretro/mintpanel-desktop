#!/usr/bin/env python3
"""probe.py port <n> | probe.py rfb <n> | probe.py rfbunix <path>

exit 0 on success, 1 on failure. `rfb` speaks a real RFB handshake on a TCP
port, `rfbunix` does the same over a unix socket (x11vnc -unixsock deployments
have no TCP listener at all, so probing 5900 there always fails).
"""
import socket
import sys


def probe_unix(path):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(4)
    try:
        s.connect(path)
        return 0 if s.recv(12).startswith(b"RFB ") else 1
    except Exception:
        return 1
    finally:
        s.close()


def main():
    if len(sys.argv) < 3:
        return 2
    mode = sys.argv[1]
    if mode == "rfbunix":
        return probe_unix(sys.argv[2])
    port = int(sys.argv[2])
    s = socket.socket()
    s.settimeout(4 if mode == "rfb" else 2)
    try:
        s.connect(("127.0.0.1", port))
        if mode == "rfb":
            return 0 if s.recv(12).startswith(b"RFB ") else 1
        return 0
    except Exception:
        return 1
    finally:
        s.close()


sys.exit(main())
