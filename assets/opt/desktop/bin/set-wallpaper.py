#!/usr/bin/env python3
"""Set the X root window background from a binary PPM (P6) file.

Xvfb has no feh/hsetroot/convert on this box, so we do it with plain Xlib:
PPM -> BGRX buffer -> XImage -> Pixmap -> root window background.
"""
import ctypes, os, sys, time

X = ctypes.CDLL('/usr/lib/x86_64-linux-gnu/libX11.so.6')
U, I, UI = ctypes.c_ulong, ctypes.c_int, ctypes.c_uint

X.XOpenDisplay.restype = ctypes.c_void_p;   X.XOpenDisplay.argtypes = [ctypes.c_char_p]
X.XDefaultRootWindow.restype = U;           X.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
X.XDefaultVisual.restype = ctypes.c_void_p; X.XDefaultVisual.argtypes = [ctypes.c_void_p, I]
X.XDefaultDepth.restype = I;                X.XDefaultDepth.argtypes = [ctypes.c_void_p, I]
X.XCreatePixmap.restype = U
X.XCreatePixmap.argtypes = [ctypes.c_void_p, U, UI, UI, UI]
X.XCreateGC.restype = ctypes.c_void_p
X.XCreateGC.argtypes = [ctypes.c_void_p, U, U, ctypes.c_void_p]
X.XCreateImage.restype = ctypes.c_void_p
X.XCreateImage.argtypes = [ctypes.c_void_p, ctypes.c_void_p, UI, I, I, ctypes.c_char_p, UI, UI, I, I]
X.XPutImage.argtypes = [ctypes.c_void_p, U, ctypes.c_void_p, ctypes.c_void_p, I, I, I, I, UI, UI]
X.XSetWindowBackgroundPixmap.argtypes = [ctypes.c_void_p, U, U]
X.XClearWindow.argtypes = [ctypes.c_void_p, U]
X.XSync.argtypes = [ctypes.c_void_p, I]
X.XDestroyImage.argtypes = [ctypes.c_void_p]

def load_ppm(path):
    with open(path, 'rb') as f:
        data = f.read()
    pos, fields = 0, []
    while len(fields) < 4:
        while pos < len(data) and data[pos:pos+1].isspace():
            pos += 1
        if data[pos:pos+1] == b'#':
            while data[pos:pos+1] not in (b'\n', b''):
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos+1].isspace():
            pos += 1
        fields.append(data[start:pos])
    if fields[0] != b'P6':
        raise SystemExit('not a P6 PPM: %r' % fields[0])
    pos += 1
    w, h = int(fields[1]), int(fields[2])
    need = w * h * 3
    px = data[pos:pos + need]
    if len(px) != need:
        raise SystemExit('truncated PPM: %d != %d' % (len(px), need))
    return w, h, px

def main():
    src = sys.argv[1] if len(sys.argv) > 1 else '__TARGET__/opt/desktop/share/wallpaper/trixie.ppm'
    w, h, rgb = load_ppm(src)
    t0 = time.time()
    buf = bytearray(w * h * 4)
    buf[0::4] = rgb[2::3]      # B
    buf[1::4] = rgb[1::3]      # G
    buf[2::4] = rgb[0::3]      # R
    buf[3::4] = b'\xff' * (w * h)
    cbuf = (ctypes.c_char * len(buf)).from_buffer(buf)
    dpy = X.XOpenDisplay(os.environ.get('DISPLAY', ':99').encode())
    if not dpy:
        raise SystemExit('cannot open display')
    scr = 0
    root = X.XDefaultRootWindow(dpy)
    vis = X.XDefaultVisual(dpy, scr)
    depth = X.XDefaultDepth(dpy, scr)
    pm = X.XCreatePixmap(dpy, root, w, h, depth)
    gc = X.XCreateGC(dpy, pm, 0, None)
    ximg = X.XCreateImage(dpy, vis, depth, 2, 0, ctypes.cast(cbuf, ctypes.c_char_p), w, h, 32, 0)
    if not ximg:
        raise SystemExit('XCreateImage failed')
    X.XPutImage(dpy, pm, gc, ctypes.c_void_p(ximg), 0, 0, 0, 0, w, h)
    X.XSetWindowBackgroundPixmap(dpy, root, pm)
    X.XClearWindow(dpy, root)
    X.XSync(dpy, 0)
    print('wallpaper set %dx%d depth=%d in %.2fs' % (w, h, depth, time.time() - t0))

main()
