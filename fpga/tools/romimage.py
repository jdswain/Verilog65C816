#!/usr/bin/env python3
"""romimage.py -- size the boot ROM to its image.

    romimage.py image.mem out.mem

The image is a byte-wide memory file from `as -o X.mem`: the bytes from its
origin up to $FFFF, the reset vector at the end. The ROM is the smallest of
8, 16 or 32 KB that holds it, at the top of bank 0 ($E000, $C000 or $8000).
An image shorter than that is put at the top, where the vectors are, with
$FF below it. out.mem is the image as the ROM holds it, rewritten only if it
changes; the ROM's address bits and base are printed, e.g. "14 C000".
"""
import re
import sys

src, out = sys.argv[1], sys.argv[2]
data = [int(w, 16) for line in open(src)
        for w in line.split('//')[0].split()
        if re.fullmatch(r'[0-9a-fA-F]{1,2}', w)]
n = len(data)
bits = 13
while (1 << bits) < n and bits < 15:
    bits += 1
size = 1 << bits
if n == 0 or n > size:
    sys.exit(f"romimage: {src} is {n} bytes; the ROM takes 1 to 32768")
base = 0x10000 - size
data = [0xFF] * (size - n) + data

text = f"// ${base:04X}-$FFFF, from {src.split('/')[-1]} ({n} bytes)\n" + \
    ''.join(' '.join(f"{b:02X}" for b in data[i:i + 16]) + '\n'
            for i in range(0, size, 16))
try:
    same = open(out).read() == text
except OSError:
    same = False
if not same:
    with open(out, 'w') as f:
        f.write(text)
print(bits, f"{base:04X}")
