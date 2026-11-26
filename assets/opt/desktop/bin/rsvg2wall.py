#!/usr/bin/env python3
"""Render an SVG with librsvg/cairo and set it as the X root wallpaper. No browser needed.

usage: rsvg2wall.py <file.svg> [--ppm out.ppm] [--size WxH]
"""
import ctypes, os, sys

U, I, UI = ctypes.c_ulong, ctypes.c_int, ctypes.c_uint
c_void_p, c_char_p, c_double, c_ubyte = ctypes.c_void_p, ctypes.c_char_p, ctypes.c_double, ctypes.c_ubyte

class Dim(ctypes.Structure):
    _fields_ = [('width', I), ('height', I), ('em', c_double), ('ex', c_double)]

def render(svg, out_w=None, out_h=None):
    rsvg = ctypes.CDLL('librsvg-2.so.2')
    cairo = ctypes.CDLL('libcairo.so.2')
    rsvg.rsvg_handle_new_from_file.restype = c_void_p
    rsvg.rsvg_handle_new_from_file.argtypes = [c_char_p, ctypes.POINTER(c_void_p)]
    rsvg.rsvg_handle_get_dimensions.argtypes = [c_void_p, ctypes.POINTER(Dim)]
    rsvg.rsvg_handle_render_cairo.argtypes = [c_void_p, c_void_p]
    cairo.cairo_image_surface_create.restype = c_void_p
    cairo.cairo_image_surface_create.argtypes = [I, I, I]
    cairo.cairo_create.restype = c_void_p
    cairo.cairo_create.argtypes = [c_void_p]
    cairo.cairo_surface_flush.argtypes = [c_void_p]
    cairo.cairo_image_surface_get_data.restype = ctypes.POINTER(c_ubyte)
    cairo.cairo_image_surface_get_data.argtypes = [c_void_p]
    cairo.cairo_image_surface_get_stride.restype = I
    cairo.cairo_image_surface_get_stride.argtypes = [c_void_p]
    cairo.cairo_paint.argtypes = [c_void_p]
    cairo.cairo_set_source_rgba.argtypes = [c_void_p, c_double, c_double, c_double, c_double]
    cairo.cairo_scale.argtypes = [c_void_p, c_double, c_double]

    err = c_void_p()
    handle = rsvg.rsvg_handle_new_from_file(svg.encode(), ctypes.byref(err))
    if not handle:
        raise SystemExit('librsvg could not open %s' % svg)
    d = Dim()
    rsvg.rsvg_handle_get_dimensions(handle, ctypes.byref(d))
    W = out_w or d.width
    H = out_h or d.height
    surf = cairo.cairo_image_surface_create(0, W, H)       # CAIRO_FORMAT_ARGB32
    cr = cairo.cairo_create(surf)
    cairo.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 1.0)    # opaque base under any transparency
    cairo.cairo_paint(cr)
    if (W, H) != (d.width, d.height) and d.width and d.height:
        cairo.cairo_scale(cr, W / float(d.width), H / float(d.height))
    rsvg.rsvg_handle_render_cairo(handle, cr)
    cairo.cairo_surface_flush(surf)
    stride = cairo.cairo_image_surface_get_stride(surf)
    data = ctypes.string_at(cairo.cairo_image_surface_get_data(surf), stride * H)
    return W, H, stride, data  # BGRA (little endian ARGB32), premultiplied but opaque here

def write_ppm(path, W, H, stride, data):
    rgb = bytearray(W * H * 3)
    for y in range(H):
        row = data[y * stride:(y + 1) * stride]
        rgb[y * W * 3:(y + 1) * W * 3:3] = row[2::4]
        rgb[y * W * 3 + 1:(y + 1) * W * 3:3] = row[1::4]
        rgb[y * W * 3 + 2:(y + 1) * W * 3:3] = row[0::4]
    with open(path, 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (W, H))
        f.write(bytes(rgb))

def set_root(W, H, stride, data):
    X = ctypes.CDLL('/usr/lib/x86_64-linux-gnu/libX11.so.6')
    X.XOpenDisplay.restype = c_void_p;   X.XOpenDisplay.argtypes = [c_char_p]
    X.XDefaultRootWindow.restype = U;     X.XDefaultRootWindow.argtypes = [c_void_p]
    X.XDefaultVisual.restype = c_void_p;  X.XDefaultVisual.argtypes = [c_void_p, I]
    X.XDefaultDepth.restype = I;          X.XDefaultDepth.argtypes = [c_void_p, I]
    X.XCreatePixmap.restype = U
    X.XCreatePixmap.argtypes = [c_void_p, U, UI, UI, UI]
    X.XCreateGC.restype = c_void_p
    X.XCreateGC.argtypes = [c_void_p, U, U, c_void_p]
    X.XCreateImage.restype = c_void_p
    X.XCreateImage.argtypes = [c_void_p, c_void_p, UI, I, I, c_char_p, UI, UI, I, I]
    X.XPutImage.argtypes = [c_void_p, U, c_void_p, c_void_p, I, I, I, I, UI, UI]
    X.XSetWindowBackgroundPixmap.argtypes = [c_void_p, U, U]
    X.XClearWindow.argtypes = [c_void_p, U]
    X.XSync.argtypes = [c_void_p, I]

    buf = bytearray()
    for y in range(H):                     # cairo stride may be padded, XImage wants exact rows
        buf += data[y * stride:y * stride + W * 4]
    cbuf = (ctypes.c_char * len(buf)).from_buffer(buf)
    dpy = X.XOpenDisplay(os.environ.get('DISPLAY', ':99').encode())
    if not dpy:
        raise SystemExit('cannot open display')
    root = X.XDefaultRootWindow(dpy)
    vis = X.XDefaultVisual(dpy, 0)
    depth = X.XDefaultDepth(dpy, 0)
    pm = X.XCreatePixmap(dpy, root, W, H, depth)
    gc = X.XCreateGC(dpy, pm, 0, None)
    img = X.XCreateImage(dpy, vis, depth, 2, 0, ctypes.cast(cbuf, c_char_p), W, H, 32, 0)
    X.XPutImage(dpy, pm, gc, ctypes.c_void_p(img), 0, 0, 0, 0, W, H)
    X.XSetWindowBackgroundPixmap(dpy, root, pm)
    X.XClearWindow(dpy, root)
    X.XSync(dpy, 0)

def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    svg = args[0]
    ppm = None
    size = None
    i = 1
    while i < len(args):
        if args[i] == '--ppm':
            ppm = args[i + 1]; i += 2
        elif args[i] == '--size':
            size = args[i + 1]; i += 2
        else:
            i += 1
    ow = oh = None
    if size:
        ow, oh = (int(v) for v in size.lower().split('x'))
    W, H, stride, data = render(svg, ow, oh)
    if ppm:
        write_ppm(ppm, W, H, stride, data)
        print('ppm %dx%d -> %s' % (W, H, ppm))
    set_root(W, H, stride, data)
    print('wallpaper set %dx%d from %s (librsvg)' % (W, H, svg))

main()
