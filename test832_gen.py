#!/usr/bin/env python3
"""Generate test832.hex: self-checks of the 65C832 (docs/65C832.md), its
modes and the WDM-prefixed extension, hand-assembled. make test832 runs it
in tb_cpu.v.

The assembler below keeps the mode (E16, E8, M, X) as it goes, so that an
immediate is as wide as its register. Each check is a branch over a stub,
taken when the check passes; the stub pushes the check's number and jumps
to `fail`, which writes it to $00F006/7 and $FF to $00F000 (FAIL, detail).

Part 1 (bank 0) is directed: the extension's no-ops and MUL in emulation
mode, every addressing mode of MUL and DIV's rounding in 65C816 native
mode, then 65C832 native mode (a 32-bit accumulator and index registers:
loads, arithmetic, decimal, RMW, the stack, transfers, XBA/TDC, XCE between
16 and 32 bits, block moves past 64 KB, BRK/IRQ/NMI/ABORT through the
65C832 vectors, IRQs around prefixed instructions), and XFE back.
Part 2 (bank 1) is random: MUL/UML/DIV/UDV, the shifts and BSW at every
width (emulation, 65C816 native, 65C832 native), each result, X and NVZC
against Python's arithmetic.

With --c816 it writes test816x.hex instead, for the core built as the Tang
Nano builds it (C832=0, XOPS=1): the same checks without the 65C832 modes,
and XFE checked to do nothing. make test816x runs it.
"""
import random
import sys

random.seed(832)

C816 = '--c816' in sys.argv[1:]
OUT = 'test816x' if C816 else 'test832'

MEM_SIZE = 0x20000          # banks $00 and $01
SRC = 0x1F000               # block move source, past part 2's code
mem = bytearray(MEM_SIZE)
labels = {}
fixups = []                 # (kind, pos, name)
pc = 0
tid = 0
descs = {}

# the mode, as the code being assembled will have it
e16, e8, mf, xf = 1, 1, 1, 1


def emu():
    return e8 and e16

def aw():
    if emu() or mf:
        return 8
    return 32 if (not e16 and e8) else 16

def xw():
    if emu() or xf:
        return 8
    return 32 if not e16 else 16

def mask(w):
    return (1 << w) - 1

def sgn(v, w):
    return v - (1 << w) if (v >> (w - 1)) & 1 else v


def org(a):
    global pc
    pc = a

def db(*bs):
    global pc
    for b in bs:
        assert pc < MEM_SIZE, 'out of memory'
        mem[pc] = b & 0xFF
        pc += 1

def label(name):
    labels[name] = pc

def w16(name):
    fixups.append(('w16', pc, name))
    db(0, 0)

def w24(name):
    fixups.append(('w24', pc, name))
    db(0, 0, 0)

def imm(v, w):
    v &= mask(w)
    return [(v >> (8 * i)) & 0xFF for i in range(w // 8)]


# ---- checks ---------------------------------------------------------------
def chk(br, desc):
    """B?? over the stub: PEA #id / JML fail."""
    global tid
    tid += 1
    descs[tid] = desc
    db(br, 7)
    db(0xF4, tid & 0xFF, tid >> 8)
    db(0x5C); w24('fail')

def eq(d): chk(0xF0, d)
def ne(d): chk(0xD0, d)
def cs(d): chk(0xB0, d)
def cc(d): chk(0x90, d)
def mi(d): chk(0x30, d)
def pl(d): chk(0x10, d)
def vs(d): chk(0x70, d)
def vc(d): chk(0x50, d)


# ---- instructions -----------------------------------------------------------
def LDA(v): db(0xA9, *imm(v, aw()))
def LDX(v): db(0xA2, *imm(v, xw()))
def LDY(v): db(0xA0, *imm(v, xw()))
def CMP(v): db(0xC9, *imm(v, aw()))
def CPX(v): db(0xE0, *imm(v, xw()))
def CPY(v): db(0xC0, *imm(v, xw()))
def ADC(v): db(0x69, *imm(v, aw()))
def SBC(v): db(0xE9, *imm(v, aw()))
def AND(v): db(0x29, *imm(v, aw()))
def ORA(v): db(0x09, *imm(v, aw()))
def EOR(v): db(0x49, *imm(v, aw()))
def BITi(v): db(0x89, *imm(v, aw()))
def STAa(a): db(0x8D, a & 0xFF, a >> 8)
def LDAa(a): db(0xAD, a & 0xFF, a >> 8)
def STAd(d): db(0x85, d)
def LDAd(d): db(0xA5, d)
def STAl(a): db(0x8F, a & 0xFF, (a >> 8) & 0xFF, a >> 16)
def LDAl(a): db(0xAF, a & 0xFF, (a >> 8) & 0xFF, a >> 16)
def STXa(a): db(0x8E, a & 0xFF, a >> 8)
def STZa(a): db(0x9C, a & 0xFF, a >> 8)
def CLC(): db(0x18)
def SEC(): db(0x38)
def CLV(): db(0xB8)
def CLI(): db(0x58)
def SEI(): db(0x78)
def NOP(): db(0xEA)
def PHP(): db(0x08)
def PLP(): db(0x28)
def PHA(): db(0x48)
def PLA(): db(0x68)
def TSC(): db(0x3B)
def TAX(): db(0xAA)
def TXA(): db(0x8A)
def TAY(): db(0xA8)
def TYA(): db(0x98)

def EXT(op, *operand): db(0x42, op, *operand)
MD = {'MUL': 0x69, 'UML': 0x29, 'DIV': 0xC9, 'UDV': 0x49}
SH = {'ASL': 0x0A, 'ROL': 0x2A, 'LSR': 0x4A, 'ROR': 0x6A, 'ASR': 0x8A}
def MDi(name, v): EXT(MD[name], *imm(v, aw()))       # MUL # ... UDV #
def SHF(name, n): EXT(SH[name], n)
def BSW(): EXT(0xEB)

def REP(b):
    global mf, xf
    db(0xC2, b)
    if not emu():
        if b & 0x20: mf = 0
        if b & 0x10: xf = 0

def SEP(b):
    global mf, xf
    db(0xE2, b)
    if not emu():
        if b & 0x20: mf = 1
        if b & 0x10: xf = 1

def setc(c): (SEC if c else CLC)()
def setv(v): SEP(0x40) if v else CLV()

def XCE(c):
    """C := E8, E8 := c."""
    global e8, mf, xf
    setc(c)
    db(0xFB)
    e8 = c
    if emu(): mf = xf = 1

def XFE(c, v):
    """C := E8, V := E16; E8 := c, E16 := v."""
    global e8, e16, mf, xf
    setc(c); setv(v)
    EXT(0xFB)
    e8, e16 = c, v
    if emu(): mf = xf = 1


# ---- the model --------------------------------------------------------------
def m_md(name, a, b, w):
    """(A, X, V) after MUL/UML/DIV/UDV of a by b at width w; None: by 0."""
    if name in ('MUL', 'UML'):
        if name == 'MUL':
            p = sgn(a, w) * sgn(b, w)
            ov = not (-(1 << (w - 1)) <= p < (1 << (w - 1)))
        else:
            p = a * b
            ov = (p >> w) != 0
        p &= mask(2 * w)
        return p & mask(w), (p >> w) & mask(w), ov
    if b == 0:
        return None
    if name == 'DIV':
        sa, sb = sgn(a, w), sgn(b, w)
        q = sa // sb                       # rounded down
        r = sa - q * sb                    # the divisor's sign
        ov = sa == -(1 << (w - 1)) and sb == -1
    else:
        q, r, ov = a // b, a % b, False
    return q & mask(w), r & mask(w), ov

def m_shf(name, a, n, w, c):
    """(result, C) of ASL/ROL/LSR/ROR/ASR #n."""
    k = n % w
    if k == 0:
        return a, c
    if name == 'ASL':
        return (a << k) & mask(w), (a >> (w - k)) & 1
    if name == 'LSR':
        return a >> k, (a >> (k - 1)) & 1
    if name == 'ASR':
        return (sgn(a, w) >> k) & mask(w), (a >> (k - 1)) & 1
    if name == 'ROL':
        r = ((a << k) | (a >> (w - k))) & mask(w)
        return r, r & 1
    r = ((a >> k) | (a << (w - k))) & mask(w)       # ROR
    return r, (r >> (w - 1)) & 1

def m_bsw(a, w):
    return int.from_bytes(a.to_bytes(w // 8, 'little'), 'big')

def nz(v, w):
    return (((v >> (w - 1)) & 1) << 7) | ((v & mask(w)) == 0) << 1


def flags_check(expect, desc):
    """P, pushed by PHP after the operation: its N, V, Z and C."""
    wide = not mf
    if wide: SEP(0x20)
    PLA()
    db(0x29, 0xC3)               # AND #$C3
    db(0xC9, expect)             # CMP #expect
    eq(desc + ' NVZC')
    if wide: REP(0x20)


# ===========================================================================
# Part 1: directed, bank 0
# ===========================================================================
org(0x8000)
label('start')
db(0xA2, 0xFF)                  # LDX #$FF
db(0x9A)                        # TXS            S=$01FF

# ---- emulation mode: the extension's no-ops and MUL ----
LDA(0x5A)
EXT(0x00); EXT(0x01); EXT(0x02); EXT(0xFF); EXT(0x24)   # 2-byte no-ops
CMP(0x5A)
eq('WDM no-ops ($00 $01 $02 $FF $24): 2 bytes, A kept')
LDA(12); MDi('MUL', 13)
CMP(156)
eq('emulation: MUL #13 of 12')
LDA(200); MDi('UDV', 7)
CMP(28)
eq('emulation: UDV #7 of 200 (quotient)')
db(0xE0, 4)                     # CPX #4
eq('emulation: UDV #7 of 200 (remainder in X)')

# ---- 65C816 native, 16-bit ----
XCE(0)
REP(0x30)
LDA(1234); MDi('MUL', 5678)     # 7006652 = $006AE9BC
CMP(0xE9BC)
eq('816: MUL 16-bit low half')
CPX(0x006A)
eq('816: MUL 16-bit high half in X')
LDA(-7); MDi('DIV', 2)
CMP(-4)
eq('816: -7 DIV 2 = -4')
CPX(1)
eq('816: -7 MOD 2 = 1')
LDA(7); MDi('DIV', -2)
CMP(-4)
eq('816: 7 DIV -2 = -4')
CPX(-1)
eq('816: 7 MOD -2 = -1')
LDA(-7); MDi('DIV', -2)
CMP(3)
eq('816: -7 DIV -2 = 3')
CPX(-1)
eq('816: -7 MOD -2 = -1')
LDA(-6); MDi('DIV', 3)
CMP(-2)
eq('816: -6 DIV 3 = -2')
CPX(0)
eq('816: -6 MOD 3 = 0')
LDX(0x1111); LDA(0x4321); CLV(); MDi('DIV', 0)
vs('816: DIV by 0 sets V')
CMP(0x4321)
eq('816: DIV by 0 leaves A')
CPX(0x1111)
eq('816: DIV by 0 leaves X')
CLV(); LDA(0x8000); MDi('DIV', -1)
vs('816: $8000 DIV -1 overflows')
CMP(0x8000)
eq('816: $8000 DIV -1 = $8000')
CLV(); LDA(300); MDi('MUL', 300)
vs('816: 300 * 300 overflows 16 bits')

# MUL in each addressing mode: 6 * 7, the 7 wherever the mode reaches
LDA(7); STAa(0x0420); STAa(0x0422); STAd(0x20)
LDA(0x0420); STAd(0x22); STAd(0x28); STAd(0x24)
db(0x64, 0x26)                  # STZ $26        [dp]'s bank 0
LDA(0x0420); STAd(0x2A)
LDX(2); LDY(2)
modes = [
    ('dp', [0x65, 0x20]), ('abs', [0x6D, 0x20, 0x04]),
    ('abs,X', [0x7D, 0x20, 0x04]), ('abs,Y', [0x79, 0x20, 0x04]),
    ('long', [0x6F, 0x20, 0x04, 0x00]), ('long,X', [0x7F, 0x20, 0x04, 0x00]),
    ('dp,X', [0x75, 0x1E]), ('(dp)', [0x72, 0x22]), ('(dp),Y', [0x71, 0x22]),
    ('(dp,X)', [0x61, 0x26]), ('[dp]', [0x67, 0x24]), ('[dp],Y', [0x77, 0x24]),
]
for name, code in modes:
    LDX(2)
    LDA(6); EXT(*code)
    CMP(42)
    eq(f'816: MUL {name}')
db(0xF4, 7, 0)                  # PEA #7
LDA(6); EXT(0x63, 1)            # MUL 1,S
CMP(42)
eq('816: MUL sr,S')
db(0x7A)                        # PLY
db(0xF4, 0x20, 0x04)            # PEA #$0420
LDY(2)
LDA(6); EXT(0x73, 1)            # MUL (1,S),Y
CMP(42)
eq('816: MUL (sr,S),Y')
db(0x7A)                        # PLY
LDA(100); EXT(0xCD, 0x20, 0x04) # DIV abs: 100 DIV 7
CMP(14)
eq('816: DIV abs')
CPX(2)
eq('816: DIV abs remainder')
LDA(0x1234); BSW()
CMP(0x3412)
eq('816: BSW 16-bit')
LDA(0x8001); SHF('ROR', 1)
CMP(0xC000)
eq('816: ROR #1 16-bit')
cs('816: ROR #1 C = new top bit')

if C816:
    # built without the 65C832 modes (C832=0): XFE does nothing
    SEC(); CLV()
    EXT(0xFB)
    cs('816 build: XFE leaves C')
    vc('816 build: XFE leaves V')
    assert aw() == 16
    LDA(0x00FF); STAa(0x0418)
    db(0xEE, 0x18, 0x04)                              # INC $0418 (tb_cpu wants MLB)
    LDAa(0x0418); CMP(0x0100)
    eq('816 build: INC abs 16-bit')
    XCE(1)                                            # part 2 starts in emulation
else:
    # XFE that changes nothing: C := E8 = 0, V := E16 = 1
    SEC(); CLV()
    XFE(0, 1)
    cc('816: XFE gives the old E8 in C')
    vs('816: XFE gives the old E16 in V')

    # ---- 65C832 native, a 32-bit accumulator and index registers ----
    XFE(1, 0)
    cc('XFE into 65C832: C = old E8 (0)')
    vs('XFE into 65C832: V = old E16 (1)')
    assert aw() == 32 and xw() == 32
    LDA(0x12345678)
    CMP(0x12345678)
    eq('832: LDA #/CMP # 32-bit')
    CMP(0x12345679)
    ne('832: CMP 32-bit not equal')
    cc('832: CMP 32-bit borrow')
    mi('832: CMP 32-bit N from bit 31')
    CLC(); LDA(0x0000FFFF); ADC(1)
    CMP(0x00010000)
    eq('832: ADC carries past bit 15')
    CLC(); LDA(0xFFFFFFFF); ADC(1)
    cs('832: ADC 32-bit carry out')
    eq('832: ADC 32-bit Z')
    CLC(); LDA(0x7FFFFFFF); ADC(1)
    vs('832: ADC 32-bit overflow')
    mi('832: ADC 32-bit N')
    SEC(); LDA(0x00010000); SBC(1)
    CMP(0x0000FFFF)
    eq('832: SBC borrows past bit 16')
    LDA(0xF0F0F0F0); AND(0x0FF0FF00); ORA(0x0000000F); EOR(0x10000001)
    CMP(0x10F0F00E)
    eq('832: AND ORA EOR 32-bit')

    # memory, 4 bytes little-endian
    LDA(0x89ABCDEF); STAa(0x0400)
    SEP(0x20); LDAa(0x0403); CMP(0x89)
    eq('832: STA abs wrote byte 3')
    LDAa(0x0400); CMP(0xEF)
    eq('832: STA abs wrote byte 0')
    REP(0x20)
    LDA(0); LDAa(0x0400)
    CMP(0x89ABCDEF)
    eq('832: LDA abs 32-bit')
    LDA(0x01020304); STAd(0x30); LDA(0); LDAd(0x30)
    CMP(0x01020304)
    eq('832: STA/LDA dp 32-bit')
    LDA(0x55667788); STAl(0x01F800)                  # past part 2's code
    LDX(0x0001F800); LDA(0); db(0xBD, 0x00, 0x00)  # LDA $0000,X
    CMP(0x55667788)
    eq('832: LDA abs,X with a 32-bit X reaches bank 1')
    LDY(0x00010000); LDA(0xF800); STAd(0x34)        # (dp),Y: $F800 + $10000
    LDA(0); db(0xB1, 0x34)                          # LDA ($34),Y
    CMP(0x55667788)
    eq('832: LDA (dp),Y with a 32-bit Y reaches bank 1')

    # INC/DEC and shifts, A and memory
    LDA(0x0000FFFF); db(0x1A)                       # INC A
    CMP(0x00010000)
    eq('832: INC A past bit 15')
    LDA(0); db(0x3A)                                # DEC A
    mi('832: DEC A to -1: N')
    CMP(0xFFFFFFFF)
    eq('832: DEC A to $FFFFFFFF')
    LDA(0x00FFFFFF); STAa(0x0408); db(0xEE, 0x08, 0x04)   # INC $0408
    LDAa(0x0408); CMP(0x01000000)
    eq('832: INC abs 32-bit')
    LDA(0x40000000); STAa(0x0408); db(0x0E, 0x08, 0x04)   # ASL $0408
    mi('832: ASL abs into bit 31')
    db(0x0E, 0x08, 0x04)
    cs('832: ASL abs C from bit 31')
    eq('832: ASL abs Z')
    SEC(); db(0x6E, 0x08, 0x04)                           # ROR $0408
    LDAa(0x0408); CMP(0x80000000)
    eq('832: ROR abs C into bit 31')
    LDA(0x80000001); db(0x0A)                             # ASL A
    cs('832: ASL A C from bit 31')
    CMP(0x00000002)
    eq('832: ASL A')
    CLC(); LDA(0x80000001); db(0x6A)                      # ROR A
    cs('832: ROR A C from bit 0')
    CMP(0x40000000)
    eq('832: ROR A')
    LDA(0x0F0F0000); STAa(0x040C)
    LDA(0x00F00000); db(0x0C, 0x0C, 0x04)                 # TSB $040C
    LDAa(0x040C); CMP(0x0FFF0000)
    eq('832: TSB 32-bit')
    LDA(0x0F000000); db(0x1C, 0x0C, 0x04)                 # TRB $040C
    LDAa(0x040C); CMP(0x00FF0000)
    eq('832: TRB 32-bit')
    LDA(0xC0000000); STAa(0x0410); LDA(0x00000001)
    db(0x2C, 0x10, 0x04)                                  # BIT $0410
    mi('832: BIT N from bit 31')
    vs('832: BIT V from bit 30')
    eq('832: BIT Z')

    # decimal, 8 digits
    db(0xF8)                                              # SED
    CLC(); LDA(0x12345678); ADC(0x87654321)
    CMP(0x99999999)
    eq('832: decimal ADC 8 digits')
    CLC(); ADC(1)
    cs('832: decimal ADC carry out of 8 digits')
    eq('832: decimal ADC wraps to 0')
    SEC(); LDA(0x10000000); SBC(1)
    CMP(0x09999999)
    eq('832: decimal SBC 8 digits')
    db(0xD8)                                              # CLD

    # the stack: 4-byte pushes (TSX: S zero-extended)
    db(0xBA); db(0x86, 0x38)                              # TSX / STX $38
    LDA(0xCAFEBABE); PHA()
    db(0xBA); TXA(); CLC(); ADC(4)
    db(0xC5, 0x38)                                        # CMP $38 (S + 4 = old S)
    eq('832: PHA pushes 4 bytes')
    LDA(0); PLA()
    CMP(0xCAFEBABE)
    eq('832: PLA pulls 4 bytes')
    LDX(0x89ABCDEF)
    CPX(0x89ABCDEF)
    eq('832: LDX #/CPX # 32-bit')
    db(0xDA)                                              # PHX
    db(0x7A)                                              # PLY
    CPY(0x89ABCDEF)
    eq('832: PHX/PLY 32-bit')
    TXA(); CMP(0x89ABCDEF)
    eq('832: TXA 32-bit')
    LDA(0x13572468); TAY(); CPY(0x13572468)
    eq('832: TAY 32-bit')
    db(0xBA)                                              # TSX
    CPX(0x000001FF)
    eq('832: TSX zero-extends S')

    # XBA, TDC, TSC: 16-bit, the top half kept
    LDA(0x11223344); db(0xEB)                             # XBA
    CMP(0x11224433)
    eq('832: XBA swaps the low two bytes only')
    LDA(0xAAAA5555); db(0x7B)                             # TDC (D = 0)
    eq('832: TDC Z of 16 bits')
    CMP(0xAAAA0000)
    eq('832: TDC keeps bits 16-31')

    # XCE in 65C832 mode: A between 32 and 16 bits
    LDA(0xAAAA5555)
    XCE(0)
    cs('832: XCE gives the old E8 (1)')
    assert aw() == 16 and xw() == 32
    LDA(0x1234)                                           # 3 bytes now
    XCE(1)
    CMP(0xAAAA1234)
    eq('832: A16 keeps bits 16-31')
    LDX(0x12345678); SEP(0x10)
    REP(0x10); CPX(0x00000078)
    eq('832: SEP #$10 clears X above bit 7')

    # the extension at 32 bits
    LDA(0x12345678); MDi('UML', 0x10000)
    CMP(0x56780000)
    eq('832: UML 32-bit low')
    CPX(0x1234)
    eq('832: UML 32-bit high')
    LDA(-2); MDi('MUL', 3)
    CMP(-6)
    eq('832: MUL -2 * 3')
    CPX(0xFFFFFFFF)
    eq('832: MUL -2 * 3 high half')
    LDA(0x00010000); MDi('MUL', 0x00010000)
    vs('832: MUL $10000 * $10000 overflows')
    LDA(-7); MDi('DIV', 2)
    CMP(-4)
    eq('832: -7 DIV 2')
    CPX(1)
    eq('832: -7 MOD 2')
    CLV(); LDA(0x80000000); MDi('DIV', -1)
    vs('832: MIN DIV -1 overflows')
    LDA(0x12345678); SHF('ROR', 8)
    CMP(0x78123456)
    eq('832: ROR #8')
    LDA(0x12345678); SHF('ROL', 4)
    CMP(0x23456781)
    eq('832: ROL #4')
    LDA(0x80000000); SHF('ASR', 31)
    CMP(0xFFFFFFFF)
    eq('832: ASR #31')
    LDA(0x12345678); BSW()
    CMP(0x78563412)
    eq('832: BSW 32-bit')
    LDA(0x11112222); STAa(0x0414)
    LDA(3); EXT(0x6D, 0x14, 0x04)                         # MUL abs, 32-bit
    CMP(0x33336666)
    eq('832: MUL abs, a 32-bit operand')

    # a block move past 64 KB: from $01:F000 (bank 0 + X) to $00:0440
    LDX(SRC); LDY(0x00000440); LDA(3)
    db(0x54, 0x00, 0x00)                                  # MVN $00,$00
    CMP(0xFFFFFFFF)
    eq('832: MVN count to -1 (32-bit)')
    CPX(SRC + 4)
    eq('832: MVN X stepped 32-bit')
    LDAa(0x0440); CMP(0xD4C3B2A1)
    eq('832: MVN copied from bank 1')

    # BRK, NMI and IRQ through the 65C832 vectors; the counters are bytes
    def count(d, n, desc):
        SEP(0x20); LDAd(d); CMP(n); REP(0x20)
        eq(desc)

    db(0x64, 0x60); db(0x64, 0x64)                        # STZ $60, $64 (4 bytes each)
    db(0x00, 0xEA)                                        # BRK
    count(0x60, 1, '832: BRK through $FFD6')
    SEP(0x20); LDA(1); STAa(0xF003); REP(0x20)            # NMI
    NOP(); NOP(); NOP(); NOP()
    count(0x62, 1, '832: NMI through $FFDA')
    CLI()
    for gap in range(4):                                  # IRQ just before a prefixed op
        SEP(0x20); LDA(1); STAa(0xF002); REP(0x20)
        for _ in range(gap): NOP()
        LDA(0x01020304); BSW(); MDi('UML', 2)
        CMP(0x08060402)
        eq(f'832: an IRQ {gap} NOPs before BSW/UML leaves them whole')
    SEI()
    count(0x61, 4, '832: IRQ through $FFDE, four times')

    # ABORT of a prefixed instruction: it is retried from the $42
    LDA(5)
    STXa(0xF005)                                          # arm (4 bytes: $F005-8)
    MDi('MUL', 3)                                         # aborted, then retried
    CMP(15)
    eq('832: ABORT of MUL #, retried')
    count(0x65, 1, '832: ABORT through $FFD8')

    # back: XFE to 65C816 native, X and Y cut to 16 bits
    LDX(0x12345678)
    XFE(0, 1)
    cs('XFE out of 65C832: C = old E8 (1)')
    vc('XFE out of 65C832: V = old E16 (0)')
    CPX(0x5678)
    eq('816: X cut to 16 bits by XFE')
    # into 65C832 with a 16-bit accumulator, then to emulation
    XFE(0, 0)
    assert aw() == 16 and xw() == 32
    LDX(0x11112222); LDA(0x3333)
    CPX(0x11112222)
    eq('832 A16: LDX # 32-bit')
    CMP(0x3333)
    eq('832 A16: LDA # 16-bit')
    XFE(1, 1)
    assert emu()
    LDA(0x5A); PHA(); LDA(0); PLA(); CMP(0x5A)
    eq('XFE into emulation: 8-bit, stack in page 1')
    db(0xBA)                                              # TSX
    CPX(0xFF)
    eq('XFE into emulation: S = $01FF')

db(0x5C); w24('random')                               # JML to part 2

# ---- the end ----
label('pass')
db(0xA9, 0x00)                  # LDA #$00 (any mode: SEP below)
label('fail')                   # PEA'd check number on the stack
db(0xE2, 0x20)                  # SEP #$20
db(0x68)                        # PLA
db(0x8F, 0x06, 0xF0, 0x00)      # STA $00F006
db(0x68)                        # PLA
db(0x8F, 0x07, 0xF0, 0x00)      # STA $00F007
db(0xA9, 0xFF)                  # LDA #$FF
db(0x8F, 0x00, 0xF0, 0x00)      # STA $00F000   FAIL
db(0xDB)                        # STP
label('done')
db(0xE2, 0x20)                  # SEP #$20
db(0xA9, 0x00)
db(0x8F, 0x00, 0xF0, 0x00)      # STA $00F000   PASS
db(0xDB)

# ---- handlers (65C832 native: they set 8 bits for what they touch) ----
label('brkh')
db(0x08, 0xE2, 0x20, 0xE6, 0x60, 0x28, 0x40)   # PHP SEP#$20 INC $60 PLP RTI
label('nmih')
db(0x08, 0xE2, 0x20, 0xE6, 0x62, 0x28, 0x40)   # ... INC $62
label('irqh')
db(0x08, 0xE2, 0x20, 0x48)                     # PHP SEP#$20 PHA
db(0xE6, 0x61)                                 # INC $61
db(0xA9, 0x00, 0x8D, 0x02, 0xF0)               # LDA #0 STA $F002 (IRQ off)
db(0x68, 0x28, 0x40)                           # PLA PLP RTI
label('aborth')
db(0x08, 0xE2, 0x20, 0xE6, 0x65, 0x28, 0x40)   # ... INC $65

org(0xFFD6); w16('brkh')
org(0xFFD8); w16('aborth')
org(0xFFDA); w16('nmih')
org(0xFFDE); w16('irqh')
org(0xFFFC); w16('start')


# ===========================================================================
# Part 2: random, bank 1, every width
# ===========================================================================
org(0x10000)
label('random')

def rnd(w):
    edges = [0, 1, 2, 3, mask(w), mask(w) - 1, 1 << (w - 1), (1 << (w - 1)) - 1,
             (1 << (w - 1)) + 1, 1 << (w // 2), mask(w // 2)]
    return random.choice(edges) if random.random() < 0.3 else random.getrandbits(w)

def preset():
    c, v = random.getrandbits(1), random.getrandbits(1)
    setc(c); setv(v)
    return c, v

def vec_md(name):
    w, xwd = aw(), xw()
    a, b = rnd(w), rnd(w)
    if name in ('DIV', 'UDV') and random.random() < 0.05:
        b = 0
    c, v = preset()
    sent = random.getrandbits(xwd)
    LDX(sent); LDA(a); MDi(name, b); PHP()
    r = m_md(name, a, b, w)
    if r is None:                             # by zero: V, nothing else
        ra, rx, p = a, sent, nz(a, w) | 0x40 | c
    else:
        ra, rx, ov = r
        rx &= mask(xwd)
        p = nz(ra, w) | (0x40 if ov else 0) | c
    d = f'{name} {a:#x},{b:#x} w{w} x{xwd}'
    CMP(ra); eq(d)
    CPX(rx); eq(d + ' X')
    flags_check(p, d)

def vec_shf(name):
    w, xwd = aw(), xw()
    a, n = rnd(w), random.randrange(0, 40)
    c, v = preset()
    sent = random.getrandbits(xwd)
    LDX(sent); LDA(a); SHF(name, n); PHP()
    r, rc = m_shf(name, a, n, w, c)
    d = f'{name} #{n} of {a:#x} w{w}'
    CMP(r); eq(d)
    CPX(sent); eq(d + ' X kept')
    flags_check(nz(r, w) | (v << 6) | rc, d)

def vec_bsw():
    w = aw()
    a = rnd(w)
    c, v = preset()
    LDA(a); BSW(); PHP()
    r = m_bsw(a, w)
    d = f'BSW {a:#x} w{w}'
    CMP(r); eq(d)
    flags_check(nz(r, w) | (v << 6) | c, d)

def batch(n):
    for _ in range(n):
        k = random.randrange(10)
        if k < 4: vec_md(['MUL', 'UML', 'DIV', 'UDV'][k])
        elif k < 9: vec_shf(['ASL', 'ROL', 'LSR', 'ROR', 'ASR'][k - 4])
        else: vec_bsw()

# emulation (part 1 ended there)
batch(110)
# 65C816 native: A16/X16, A8/X16, A16/X8
XCE(0); REP(0x30); batch(150)
SEP(0x20); batch(60)
REP(0x20); SEP(0x10); batch(60)
if not C816:
    # 65C832 native: A32/X32, A32/X8, A16/X32, A8/X32
    REP(0x10); XFE(1, 0); batch(260)
    SEP(0x10); batch(50)
    REP(0x10); XCE(0); batch(80)
    SEP(0x20); batch(50)
db(0x5C); w24('done')
assert pc < SRC, 'part 2 runs into the block move source'
for i, v in enumerate([0xA1, 0xB2, 0xC3, 0xD4]):
    mem[SRC + i] = v


# ===========================================================================
for kind, pos, name in fixups:
    v = labels[name]
    if kind == 'w16':
        mem[pos] = v & 0xFF
        mem[pos + 1] = (v >> 8) & 0xFF
    else:
        mem[pos] = v & 0xFF
        mem[pos + 1] = (v >> 8) & 0xFF
        mem[pos + 2] = (v >> 16) & 0xFF

with open(OUT + '.hex', 'w') as f:
    f.write('\n'.join(f'{b:02X}' for b in mem))
    f.write('\n')
with open(OUT + '.checks', 'w') as f:
    for i in sorted(descs):
        f.write(f'{i:5d}: {descs[i]}\n')

print(f'{OUT}.hex written: {tid} checks ({OUT}.checks)')
