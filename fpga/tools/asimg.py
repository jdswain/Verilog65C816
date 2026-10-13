#!/usr/bin/env python3
"""Build a ROM image from a 65Tools `as` build (ELF + listing).

Neither output file is trustworthy on its own:

  * The ELF's section file-offsets are wrong. `elf_file.c` advances its running
    offset by `file_size(section)` but records `sh_size`, and the `dp` section
    writes its allocation bytes while reporting `sh_size == 0`. Every section
    after `dp` therefore sits that many bytes later in the file than its
    `sh_offset` claims, and `text`'s `sh_size` is inflated by the same amount.
  * The listing is exact on addresses but truncates each line's byte column to
    six bytes, so any longer datum (`text.0` strings) is incomplete.

So we take the address range from the listing and the bytes from the ELF,
locating `text` from the end of the file: section headers are written last, so
the final section's data ends where the header table begins.

usage: asimg.py prog.elf prog.lst out.hex --base 0xE000 --size 0x2000
"""
import argparse, re, struct, sys

LINE    = re.compile(r'^([0-9a-fA-F]{4,6}):((?:\s+[0-9a-fA-F]{2})+)')
SECTION = re.compile(r'^\s*section\s+(\w+)', re.I)
SRC_COL = 24


def listing_range(path, keep):
    """(lo, hi) address span of the kept sections, from the listing."""
    lo = hi = None
    section = 'text'
    for raw in open(path):
        m = SECTION.match(raw[SRC_COL:])
        if m:
            section = m.group(1).lower()
            continue
        m = LINE.match(raw)
        if not m or section not in keep:
            continue
        addr = int(m.group(1), 16)
        end = addr + len(m.group(2).split()) - 1
        lo = addr if lo is None else min(lo, addr)
        hi = end if hi is None else max(hi, end)
    if lo is None:
        sys.exit(f'{path}: no code bytes in sections {sorted(keep)}')
    return lo, hi


def elf_tail(path, length):
    """The last `length` bytes of section data, i.e. what precedes the
    section-header table at the end of the file."""
    d = open(path, 'rb').read()
    if d[:4] != b'\x7fELF':
        sys.exit(f'{path}: not an ELF file')
    e_shoff, = struct.unpack_from('<I', d, 32)
    e_shentsize, = struct.unpack_from('<H', d, 46)
    e_shnum, = struct.unpack_from('<H', d, 48)
    hdr_table = e_shnum * e_shentsize
    end = len(d) - hdr_table
    if end != e_shoff:
        print(f'note: e_shoff={e_shoff} but header table starts at {end}',
              file=sys.stderr)
    start = end - length
    if start < 0:
        sys.exit(f'{path}: file too short for {length} bytes of code')
    return d[start:end]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('elf'); ap.add_argument('lst'); ap.add_argument('out')
    ap.add_argument('--base', required=True)
    ap.add_argument('--size', required=True)
    ap.add_argument('--fill', default='0xFF')
    ap.add_argument('--width', type=int, default=8, choices=(8, 16),
                    help='emit 8-bit bytes or 16-bit little-endian words. '
                         'A 16-bit ROM halves the number of accesses an '
                         'instruction fetch needs.')
    ap.add_argument('--sections', default='text,rodata,data')
    ap.add_argument('--word', action='append', default=[], metavar='ADDR=VAL',
                    help='place a little-endian 16-bit word (e.g. a reset '
                         'vector: --word 0xFFFC=0xE000); repeatable')
    a = ap.parse_args()
    base, size, fill = int(a.base, 0), int(a.size, 0), int(a.fill, 0)
    keep = {s.strip().lower() for s in a.sections.split(',')}

    lo, hi = listing_range(a.lst, keep)
    length = hi - lo + 1
    code = elf_tail(a.elf, length)

    if not (base <= lo and hi < base + size):
        sys.exit(f'code {lo:#06x}..{hi:#06x} does not fit in '
                 f'[{base:#06x},{base + size:#06x})')

    img = bytearray([fill]) * size
    img[lo - base:lo - base + length] = code

    for spec in a.word:
        where, _, val = spec.partition('=')
        where, val = int(where, 0), int(val, 0)
        if not (base <= where < base + size - 1):
            sys.exit(f'--word {spec}: {where:#06x} outside the image')
        img[where - base]     = val & 0xFF
        img[where - base + 1] = (val >> 8) & 0xFF

    with open(a.out, 'w') as f:
        if a.width == 8:
            for i in range(0, size, 16):
                f.write(' '.join(f'{b:02x}' for b in img[i:i + 16]) + '\n')
        else:
            if size % 2:
                sys.exit('--width 16 needs an even size')
            words = [img[i] | (img[i + 1] << 8) for i in range(0, size, 2)]
            for i in range(0, len(words), 8):
                f.write(' '.join(f'{w:04x}' for w in words[i:i + 8]) + '\n')

    words = ' '.join(a.word)
    print(f'{a.elf}: {length} bytes {lo:#06x}..{hi:#06x} -> {a.out} '
          f'({size} bytes @ {base:#06x})' + (f'  [{words}]' if words else ''))


if __name__ == '__main__':
    main()
