#!/usr/bin/env python3
"""Build the text-mode font ROM from a GEM font in EmuTOS C source form.

    mkfont.py font/fnt_st_8x16.c rom/font_st8x16.hex [--show TEXT]

A GEM font stores all 256 glyphs side by side in one bitmap, 2048 pixels wide
and 16 high, as big-endian 16-bit words: row r of character c is byte c of
bitmap row r. video.v wants it the other way round -- one glyph after another,
16 bytes each -- so that the ROM address is simply {character, row}:

    hex line (c * 16 + r)  =  row r of character c, bit 7 = leftmost pixel
"""
import argparse, re, sys

CHARS, ROWS = 256, 16


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('src')
    ap.add_argument('out')
    ap.add_argument('--show', help='print these characters as ASCII art')
    a = ap.parse_args()

    text = open(a.src).read()
    m = re.search(r'dat_table\[\]\s*=\s*\{(.*?)\};', text, re.S)
    if not m:
        sys.exit(f"{a.src}: no dat_table[]")
    words = [int(w, 16) for w in re.findall(r'0x([0-9a-fA-F]{4})', m.group(1))]
    if len(words) != CHARS * ROWS // 2:
        sys.exit(f"{a.src}: {len(words)} words, expected {CHARS * ROWS // 2}")

    form = bytearray()
    for w in words:
        form += bytes([w >> 8, w & 255])               # big-endian
    glyph = [[form[r * CHARS + c] for r in range(ROWS)] for c in range(CHARS)]

    with open(a.out, 'w') as f:
        for c in range(CHARS):
            for r in range(ROWS):
                f.write(f"{glyph[c][r]:02x}\n")
    print(f"{a.src}: {CHARS} glyphs x {ROWS} rows -> {a.out}")

    for ch in a.show or '':
        for r in range(ROWS):
            print(''.join('#' if glyph[ord(ch)][r] & (0x80 >> x) else '.'
                          for x in range(8)))
        print()


if __name__ == '__main__':
    main()
