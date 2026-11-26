#!/usr/bin/env python3
"""probe.py port <n> | probe.py rfb <n> -- exit 0 on success, 1 on failure."""
import socket, sys
def main():
    if len(sys.argv) < 3:
        return 2
    mode, port = sys.argv[1], int(sys.argv[2])
    s = socket.socket(); s.settimeout(4 if mode == "rfb" else 2)
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
