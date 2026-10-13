#!/usr/bin/env python3
"""Convert a PNG into an image file for rom/imgload.asm.

    mkimage.py in.png out.fb [--preview out.png]

The picture is scaled to fit 640x480 (keeping its shape, centred on black),
reduced to 16 colours by median cut and Floyd-Steinberg dithered. Palette
entry 0 is always black, for the border; the other 15 are chosen from the
picture.

Output layout, exactly what the ROM expects to receive:

    64 bytes      palette, 16 x {red, green, blue, 0}
    153600 bytes  480 lines x 320 bytes, two pixels per byte, LOW nibble left

Standard library only. Reads 8-bit RGB, RGBA and greyscale PNGs that are not
interlaced.
"""
import argparse, struct, sys, zlib

W, H = 640, 480


def read_png(path):
    """Return (width, height, rows) with rows as lists of (r, g, b)."""
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        sys.exit(f"{path}: not a PNG")
    pos, idat, hdr = 8, b'', None
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b'IHDR':
            hdr = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
    w, h, depth, ctype, _, _, interlace = hdr
    bpp = {0: 1, 2: 3, 4: 2, 6: 4}.get(ctype)
    if depth != 8 or bpp is None or interlace:
        sys.exit(f"{path}: need a non-interlaced 8-bit RGB, RGBA or grey PNG")
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else b if pb <= pc else c
                line[i] = (line[i] + pr) & 255
        prev = line
        if bpp >= 3:
            rows.append([(line[x * bpp], line[x * bpp + 1], line[x * bpp + 2])
                         for x in range(w)])
        else:
            rows.append([(line[x * bpp],) * 3 for x in range(w)])
    return w, h, rows


def write_png(path, w, h, rows):
    raw = b''.join(b'\0' + bytes(c for px in row for c in px) for row in rows)

    def chunk(kind, body):
        return (struct.pack('>I', len(body)) + kind + body +
                struct.pack('>I', zlib.crc32(kind + body)))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' +
                           chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                           chunk(b'IDAT', zlib.compress(raw, 9)) +
                           chunk(b'IEND', b''))


def resize(w, h, rows, nw, nh):
    """Bilinear resample. Fine for the mild scaling this is used for."""
    out = []
    for y in range(nh):
        fy = (y + 0.5) * h / nh - 0.5
        y0 = min(max(int(fy), 0), h - 1)
        y1 = min(y0 + 1, h - 1)
        wy = min(max(fy - y0, 0.0), 1.0)
        r0, r1, line = rows[y0], rows[y1], []
        for x in range(nw):
            fx = (x + 0.5) * w / nw - 0.5
            x0 = min(max(int(fx), 0), w - 1)
            x1 = min(x0 + 1, w - 1)
            wx = min(max(fx - x0, 0.0), 1.0)
            line.append(tuple(
                (r0[x0][c] * (1 - wx) + r0[x1][c] * wx) * (1 - wy) +
                (r1[x0][c] * (1 - wx) + r1[x1][c] * wx) * wy
                for c in range(3)))
        out.append(line)
    return out


def median_cut(pixels, n):
    """Pick n representative colours from a list of (r, g, b)."""
    boxes = [pixels]
    while len(boxes) < n:
        # Split the box with the widest spread, along that channel.
        best, span, chan = None, -1, 0
        for i, box in enumerate(boxes):
            if len(box) < 2:
                continue
            for c in range(3):
                vals = [p[c] for p in box]
                s = max(vals) - min(vals)
                if s > span:
                    best, span, chan = i, s, c
        if best is None:
            break
        box = sorted(boxes.pop(best), key=lambda p: p[chan])
        mid = len(box) // 2
        boxes += [box[:mid], box[mid:]]
    return [tuple(round(sum(p[c] for p in box) / len(box)) for c in range(3))
            for box in boxes]


def dither(rows, palette):
    """Floyd-Steinberg onto `palette`; returns rows of palette indices."""
    h, w = len(rows), len(rows[0])
    buf = [[list(px) for px in row] for row in rows]
    out = []
    for y in range(h):
        line = []
        for x in range(w):
            r, g, b = buf[y][x]
            best, bd = 0, 1e30
            for i, (pr, pg, pb) in enumerate(palette):
                d = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
                if d < bd:
                    best, bd = i, d
            line.append(best)
            err = (r - palette[best][0], g - palette[best][1], b - palette[best][2])
            for dx, dy, k in ((1, 0, 7 / 16), (-1, 1, 3 / 16), (0, 1, 5 / 16), (1, 1, 1 / 16)):
                xx, yy = x + dx, y + dy
                if 0 <= xx < w and yy < h:
                    t = buf[yy][xx]
                    for c in range(3):
                        t[c] += err[c] * k
        out.append(line)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('src')
    ap.add_argument('out')
    ap.add_argument('--preview', help='also write the result as a PNG')
    a = ap.parse_args()

    w, h, rows = read_png(a.src)
    scale = min(W / w, H / h)
    nw, nh = min(W, round(w * scale) & ~1), min(H, round(h * scale))
    pic = resize(w, h, rows, nw, nh)

    palette = [(0, 0, 0)] + median_cut([px for row in pic for px in row], 15)
    palette += [(0, 0, 0)] * (16 - len(palette))
    idx = dither(pic, palette)

    # Centre on a black (index 0) screen. x0 is even, so a byte never straddles
    # the picture's edge.
    x0, y0 = ((W - nw) // 2) & ~1, (H - nh) // 2
    screen = [[0] * W for _ in range(H)]
    for y in range(nh):
        screen[y0 + y][x0:x0 + nw] = idx[y]

    fb = bytearray()
    for row in screen:
        for x in range(0, W, 2):
            fb.append(row[x] | (row[x + 1] << 4))      # low nibble = left pixel
    pal = b''.join(bytes([r, g, b, 0]) for r, g, b in palette)
    assert len(pal) == 64 and len(fb) == W * H // 2
    open(a.out, 'wb').write(pal + fb)
    print(f"{a.src}: {w}x{h} -> {nw}x{nh} at ({x0},{y0}), "
          f"{len(pal) + len(fb)} bytes -> {a.out}")

    if a.preview:
        write_png(a.preview, W, H, [[palette[i] for i in row] for row in screen])


if __name__ == '__main__':
    main()
