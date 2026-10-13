#!/usr/bin/env python3
"""Lay the named sections of a 65Tools `as` ELF into a flat $readmemh image.

Unlike `asimg.py`, which reconstructs an image from the listing because the
assembler's section file-offsets could not be trusted, this reads the ELF
directly -- and then *checks* the result, because that offset bug is real:
`elf_file.c` advances its running offset by the bytes it writes but records
`sh_size`, so a section that writes more than it reports shifts everything
after it. `--expect ADDR=BYTE` asserts a known byte landed where it should.

usage: elf2hex.py prog.elf out.hex --base 0xC000 --size 0x4000 \
           --sections kernel,development --expect 0xFFFC=0x60
"""
import argparse, struct, sys


def sections(path):
    d = open(path, 'rb').read()
    if d[:4] != b'\x7fELF':
        sys.exit(f'{path}: not an ELF file')
    e_shoff, = struct.unpack_from('<I', d, 0x20)
    ent, num, sidx = struct.unpack_from('<HHH', d, 0x2E)

    def sh(i):
        return struct.unpack_from('<IIIIII', d, e_shoff + i * ent)

    _, _, _, _, so, ss = sh(sidx)
    strtab = d[so:so + ss]
    out = {}
    for i in range(num):
        nm, typ, fl, addr, off, size = sh(i)
        name = strtab[nm:strtab.index(b'\0', nm)].decode()
        if typ == 1 and size:
            out[name] = (addr, d[off:off + size])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('elf'); ap.add_argument('out')
    ap.add_argument('--base', required=True)
    ap.add_argument('--size', required=True)
    ap.add_argument('--sections', required=True)
    ap.add_argument('--fill', default='0xFF')
    ap.add_argument('--width', type=int, default=8, choices=(8, 16),
                    help='emit 8-bit bytes or 16-bit little-endian words. '
                         'A 16-bit ROM halves the number of accesses an '
                         'instruction fetch needs.')
    ap.add_argument('--expect', action='append', default=[], metavar='ADDR=BYTE',
                    help='assert a byte value in the finished image; repeatable')
    a = ap.parse_args()
    base, size, fill = int(a.base, 0), int(a.size, 0), int(a.fill, 0)

    found = sections(a.elf)
    img = bytearray([fill]) * size

    for want in [s.strip() for s in a.sections.split(',')]:
        if want not in found:
            sys.exit(f'{a.elf}: no section named {want!r} '
                     f'(have {sorted(found)})')
        addr, data = found[want]
        if addr < base or addr + len(data) > base + size:
            sys.exit(f'section {want} at {addr:#06x}..{addr+len(data)-1:#06x} '
                     f'does not fit in [{base:#06x},{base+size:#06x})')
        img[addr - base:addr - base + len(data)] = data
        print(f'  {want:14} {addr:#06x}..{addr+len(data)-1:#06x}  {len(data)} bytes')

    for spec in a.expect:
        where, _, val = spec.partition('=')
        where, val = int(where, 0), int(val, 0)
        got = img[where - base]
        if got != val:
            sys.exit(f'--expect {spec}: image holds {got:#04x} at {where:#06x}, '
                     f'not {val:#04x} -- section offsets are wrong')
        print(f'  checked {where:#06x} == {val:#04x}')

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
    print(f'{a.out}: {size} bytes @ {base:#06x}')


if __name__ == '__main__':
    main()
