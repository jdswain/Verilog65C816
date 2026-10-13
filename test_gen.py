#!/usr/bin/env python3
"""Generate test.hex: a self-checking 65C816 test program (hand-assembled).

Result protocol (watched by tb_cpu.v):
  write to $00F000: 0 = PASS, n = number of the failing check
Each check is a branch-if-ok over a 9-byte fail stub:
  SEP #$20 / LDA #<id> / STA $00F000 (long) / STP
"""

MEM_SIZE = 0x20000          # banks $00 and $01
mem = bytearray(MEM_SIZE)
labels = {}
fixups = []                 # (kind, pos, name)
pc = 0
tid = 0
descs = []


def org(a):
    global pc
    pc = a

def db(*bs):
    global pc
    for b in bs:
        mem[pc] = b & 0xFF
        pc += 1

def label(name):
    labels[name] = pc

def w16(name):              # 16-bit absolute value of a label
    fixups.append(('w16', pc, name))
    db(0, 0)

def r16(name):              # 16-bit PC-relative (PER/BRL): target - (pos+2)
    fixups.append(('r16', pc, name))
    db(0, 0)

def expect(br_opcode, desc):
    """Emit: B?? +9 (branch over stub if condition holds = check passed)."""
    global tid
    tid += 1
    descs.append((tid, desc))
    db(br_opcode, 0x09)
    db(0xE2, 0x20)                      # SEP #$20      (force 8-bit A)
    db(0xA9, tid)                       # LDA #id
    db(0x8F, 0x00, 0xF0, 0x00)          # STA $00F000   (long: DBR-immune)
    db(0xDB)                            # STP

def expect_eq(d): expect(0xF0, d)       # pass if Z=1
def expect_ne(d): expect(0xD0, d)       # pass if Z=0
def expect_cs(d): expect(0xB0, d)       # pass if C=1
def expect_cc(d): expect(0x90, d)       # pass if C=0
def expect_mi(d): expect(0x30, d)       # pass if N=1
def expect_vs(d): expect(0x70, d)       # pass if V=1


# ===========================================================================
org(0x8000)
label('start')
# --- emulation mode (E=1, 8-bit A/X/Y) -----------------------------------
db(0xA2, 0xFF)                  # LDX #$FF
db(0x9A)                        # TXS            S=$01FF

# basic load/store/compare
db(0xA9, 0x42)                  # LDA #$42
db(0x85, 0x10)                  # STA $10
db(0xA9, 0x00)                  # LDA #$00
db(0xA5, 0x10)                  # LDA $10
db(0xC9, 0x42)                  # CMP #$42
expect_eq('emu LDA/STA dp')

# ADC carry/zero
db(0x18)                        # CLC
db(0xA9, 0xFF)                  # LDA #$FF
db(0x69, 0x01)                  # ADC #$01      -> $00, C=1 Z=1
expect_eq('emu ADC wraps to zero')
expect_cs('emu ADC sets carry')

# SBC
db(0x38)                        # SEC
db(0xA9, 0x40)                  # LDA #$40
db(0xE9, 0x01)                  # SBC #$01      -> $3F
db(0xC9, 0x3F)                  # CMP #$3F
expect_eq('emu SBC result')

# shifts
db(0xA9, 0x81)                  # LDA #$81
db(0x0A)                        # ASL A         -> $02, C=1
expect_cs('emu ASL carry out')
db(0xC9, 0x02)                  # CMP #$02
expect_eq('emu ASL result')
db(0x6A)                        # ROR A         -> $81 (C in), C=0
db(0xC9, 0x81)                  # CMP #$81
expect_eq('emu ROR result')

# index registers
db(0xA2, 0x10)                  # LDX #$10
db(0xE8)                        # INX
db(0xE0, 0x11)                  # CPX #$11
expect_eq('emu INX/CPX')
db(0xA0, 0x05)                  # LDY #$05
db(0x88)                        # DEY
db(0xC0, 0x04)                  # CPY #$04
expect_eq('emu DEY/CPY')

# JSR/RTS
db(0x20); w16('sub1')           # JSR sub1
db(0xC9, 0x77)                  # CMP #$77
expect_eq('emu JSR/RTS')

# --- switch to native mode, 16-bit A and X/Y ------------------------------
db(0x18)                        # CLC
db(0xFB)                        # XCE           E=0
db(0xC2, 0x30)                  # REP #$30      m16, x16

db(0xA9, 0x34, 0x12)            # LDA #$1234
db(0x18)                        # CLC
db(0x69, 0x11, 0x11)            # ADC #$1111    -> $2345
db(0xC9, 0x45, 0x23)            # CMP #$2345
expect_eq('16-bit ADC')
db(0xA9, 0xFF, 0xFF)            # LDA #$FFFF
db(0x18)                        # CLC
db(0x69, 0x01, 0x00)            # ADC #$0001    -> $0000, C=1 Z=1
expect_eq('16-bit ADC wraps')
expect_cs('16-bit ADC carry')

# 16-bit stack
db(0xA9, 0xEF, 0xBE)            # LDA #$BEEF
db(0x48)                        # PHA
db(0xA9, 0x00, 0x00)            # LDA #$0000
db(0x68)                        # PLA
db(0xC9, 0xEF, 0xBE)            # CMP #$BEEF
expect_eq('16-bit PHA/PLA')

# abs,X
db(0xA2, 0x04, 0x00)            # LDX #$0004
db(0xA9, 0x5A, 0xA5)            # LDA #$A55A
db(0x9D, 0x00, 0x02)            # STA $0200,X
db(0xA9, 0x00, 0x00)            # LDA #$0000
db(0xBD, 0x00, 0x02)            # LDA $0200,X
db(0xC9, 0x5A, 0xA5)            # CMP #$A55A
expect_eq('STA/LDA abs,X')

# direct page register relocation
db(0xA9, 0x00, 0x03)            # LDA #$0300
db(0x5B)                        # TCD           D=$0300
db(0xA9, 0x21, 0x43)            # LDA #$4321
db(0x85, 0x20)                  # STA $20       -> $0320
db(0xAD, 0x20, 0x03)            # LDA $0320
db(0xC9, 0x21, 0x43)            # CMP #$4321
expect_eq('TCD direct page relocation')
db(0xA9, 0x00, 0x00)            # LDA #$0000
db(0x5B)                        # TCD           D=0

# (dp) indirect
db(0xA9, 0x40, 0x02)            # LDA #$0240
db(0x85, 0x30)                  # STA $30       pointer
db(0xA9, 0x77, 0x88)            # LDA #$8877
db(0x92, 0x30)                  # STA ($30)
db(0xAD, 0x40, 0x02)            # LDA $0240
db(0xC9, 0x77, 0x88)            # CMP #$8877
expect_eq('STA/LDA (dp)')

# (dp),Y
db(0xA0, 0x02, 0x00)            # LDY #$0002
db(0xA9, 0xCD, 0xAB)            # LDA #$ABCD
db(0x8D, 0x42, 0x02)            # STA $0242
db(0xB1, 0x30)                  # LDA ($30),Y   -> $0242
db(0xC9, 0xCD, 0xAB)            # CMP #$ABCD
expect_eq('LDA (dp),Y')

# long addressing into bank 1
db(0xA9, 0x5C, 0xC3)            # LDA #$C35C
db(0x8F, 0x00, 0x80, 0x01)      # STA $018000
db(0xA9, 0x00, 0x00)            # LDA #$0000
db(0xAF, 0x00, 0x80, 0x01)      # LDA $018000
db(0xC9, 0x5C, 0xC3)            # CMP #$C35C
expect_eq('STA/LDA long (bank 1)')

# [dp] long indirect
db(0xA9, 0x00, 0x80)            # LDA #$8000
db(0x85, 0x40)                  # STA $40       pointer lo/hi
db(0xE2, 0x20)                  # SEP #$20      m8
db(0xA9, 0x01)                  # LDA #$01
db(0x85, 0x42)                  # STA $42       pointer bank
db(0xC2, 0x20)                  # REP #$20      m16
db(0xA7, 0x40)                  # LDA [$40]     -> $018000
db(0xC9, 0x5C, 0xC3)            # CMP #$C35C
expect_eq('LDA [dp]')

# [dp],Y
db(0xA0, 0x02, 0x00)            # LDY #$0002
db(0xA9, 0x78, 0x56)            # LDA #$5678
db(0x8F, 0x02, 0x80, 0x01)      # STA $018002
db(0xB7, 0x40)                  # LDA [$40],Y   -> $018002
db(0xC9, 0x78, 0x56)            # CMP #$5678
expect_eq('LDA [dp],Y')

# JSL/RTL
db(0x22); w16('subl'); db(0x00) # JSL $00:subl
db(0xC9, 0xAA, 0x55)            # CMP #$55AA
expect_eq('JSL/RTL')

# MVN block move
db(0xA9, 0x11, 0x22)            # LDA #$2211
db(0x8D, 0x00, 0x05)            # STA $0500
db(0xA9, 0x33, 0x44)            # LDA #$4433
db(0x8D, 0x02, 0x05)            # STA $0502
db(0xA2, 0x00, 0x05)            # LDX #$0500
db(0xA0, 0x10, 0x05)            # LDY #$0510
db(0xA9, 0x03, 0x00)            # LDA #$0003    (4 bytes)
db(0x54, 0x00, 0x00)            # MVN $00,$00
db(0xAD, 0x10, 0x05)            # LDA $0510
db(0xC9, 0x11, 0x22)            # CMP #$2211
expect_eq('MVN copied bytes 0-1')
db(0xAD, 0x12, 0x05)            # LDA $0512
db(0xC9, 0x33, 0x44)            # CMP #$4433
expect_eq('MVN copied bytes 2-3')

# decimal mode, 8-bit
db(0xE2, 0x20)                  # SEP #$20      m8
db(0xF8)                        # SED
db(0x18)                        # CLC
db(0xA9, 0x15)                  # LDA #$15
db(0x69, 0x27)                  # ADC #$27      -> $42 BCD
db(0xC9, 0x42)                  # CMP #$42
expect_eq('decimal ADC 8-bit')
db(0xA9, 0x99)                  # LDA #$99
db(0x18)                        # CLC
db(0x69, 0x01)                  # ADC #$01      -> $00, C=1
expect_eq('decimal ADC 8-bit wrap')
expect_cs('decimal ADC 8-bit carry')
db(0xD8)                        # CLD

# decimal mode, 16-bit
db(0xC2, 0x20)                  # REP #$20      m16
db(0xF8)                        # SED
db(0x18)                        # CLC
db(0xA9, 0x34, 0x12)            # LDA #$1234
db(0x69, 0x21, 0x43)            # ADC #$4321    -> $5555 BCD
db(0xC9, 0x55, 0x55)            # CMP #$5555
expect_eq('decimal ADC 16-bit')
db(0x38)                        # SEC
db(0xA9, 0x50, 0x00)            # LDA #$0050
db(0xE9, 0x25, 0x00)            # SBC #$0025    -> $0025 BCD
db(0xC9, 0x25, 0x00)            # CMP #$0025
expect_eq('decimal SBC 16-bit')
db(0xD8)                        # CLD

# TSB / TRB (8-bit)
db(0xE2, 0x20)                  # SEP #$20      m8
db(0xA9, 0xF0)                  # LDA #$F0
db(0x85, 0x50)                  # STA $50
db(0xA9, 0x0F)                  # LDA #$0F
db(0x04, 0x50)                  # TSB $50       Z=1 ($0F & $F0 == 0)
expect_eq('TSB Z flag')
db(0xA5, 0x50)                  # LDA $50
db(0xC9, 0xFF)                  # CMP #$FF
expect_eq('TSB set bits')
db(0xA9, 0x30)                  # LDA #$30
db(0x14, 0x50)                  # TRB $50       -> $CF
db(0xA5, 0x50)                  # LDA $50
db(0xC9, 0xCF)                  # CMP #$CF
expect_eq('TRB cleared bits')

# BIT
db(0xA9, 0xC0)                  # LDA #$C0
db(0x85, 0x51)                  # STA $51
db(0xA9, 0x40)                  # LDA #$40
db(0x24, 0x51)                  # BIT $51       N=1 V=1 Z=0
expect_mi('BIT sets N from memory')
expect_vs('BIT sets V from memory')
expect_ne('BIT Z from A&M')

# XBA
db(0xC2, 0x20)                  # REP #$20
db(0xA9, 0x34, 0x12)            # LDA #$1234
db(0xE2, 0x20)                  # SEP #$20
db(0xEB)                        # XBA           A=$12, B=$34
db(0xC9, 0x12)                  # CMP #$12
expect_eq('XBA swaps bytes')

# PEA
db(0xC2, 0x20)                  # REP #$20      m16
db(0xF4, 0x0D, 0xF0)            # PEA $F00D
db(0x68)                        # PLA
db(0xC9, 0x0D, 0xF0)            # CMP #$F00D
expect_eq('PEA/PLA')

# PER (push PC-relative address)
db(0x62); r16('perlbl')         # PER perlbl
db(0x68)                        # PLA
label('perlbl')
db(0xC9); w16('perlbl')         # CMP #perlbl
expect_eq('PER pushes target address')

# JMP (abs) and JMP (abs,X)
db(0xA9); w16('tgt27')          # LDA #tgt27
db(0x8D, 0x60, 0x02)            # STA $0260
db(0x6C, 0x60, 0x02)            # JMP ($0260)
db(0xDB)                        # STP  (trap: fell through)
label('tgt27')
db(0xA9); w16('tgt28')          # LDA #tgt28
db(0x8D, 0x62, 0x02)            # STA $0262
db(0xA2, 0x02, 0x00)            # LDX #$0002
db(0x7C, 0x60, 0x02)            # JMP ($0260,X) -> ($0262)
db(0xDB)                        # STP  (trap)
label('tgt28')

# JSR (abs,X)
db(0xA9); w16('sub2')           # LDA #sub2
db(0x8D, 0x70, 0x02)            # STA $0270
db(0xA2, 0x00, 0x00)            # LDX #$0000
db(0xFC, 0x70, 0x02)            # JSR ($0270,X)
db(0xC9, 0xDE, 0xC0)            # CMP #$C0DE
expect_eq('JSR (abs,X)/RTS')

# BRK (native vector $FFE6)
db(0xE2, 0x20)                  # SEP #$20      m8
db(0x64, 0x60)                  # STZ $60
db(0x00, 0x00)                  # BRK #$00
db(0xA5, 0x60)                  # LDA $60
db(0xC9, 0x01)                  # CMP #$01
expect_eq('BRK/RTI native')

# stack-relative
db(0xC2, 0x20)                  # REP #$20      m16
db(0xA9, 0x99, 0x88)            # LDA #$8899
db(0x48)                        # PHA
db(0xA3, 0x01)                  # LDA $01,S
db(0xC9, 0x99, 0x88)            # CMP #$8899
expect_eq('LDA sr,S')
db(0x68)                        # PLA (discard)
db(0xF4, 0x80, 0x02)            # PEA $0280     pointer on stack
db(0xA9, 0xEE, 0x77)            # LDA #$77EE
db(0x8D, 0x81, 0x02)            # STA $0281
db(0xA0, 0x01, 0x00)            # LDY #$0001
db(0xB3, 0x01)                  # LDA ($01,S),Y -> $0281
db(0xC9, 0xEE, 0x77)            # CMP #$77EE
expect_eq('LDA (sr,S),Y')
db(0x68)                        # PLA (discard)

# STZ and 16-bit RMW
db(0xA9, 0xFF, 0xFF)            # LDA #$FFFF
db(0x8D, 0x90, 0x02)            # STA $0290
db(0x9C, 0x90, 0x02)            # STZ $0290
db(0xAD, 0x90, 0x02)            # LDA $0290     Z=1
expect_eq('STZ abs 16-bit')
db(0xEE, 0x90, 0x02)            # INC $0290     -> $0001
db(0xAD, 0x90, 0x02)            # LDA $0290
db(0xC9, 0x01, 0x00)            # CMP #$0001
expect_eq('INC abs 16-bit')
db(0x0E, 0x90, 0x02)            # ASL $0290     -> $0002
db(0xAD, 0x90, 0x02)            # LDA $0290
db(0xC9, 0x02, 0x00)            # CMP #$0002
expect_eq('ASL abs 16-bit')

# dp,X
db(0xA2, 0x04, 0x00)            # LDX #$0004
db(0xA9, 0x57, 0x13)            # LDA #$1357
db(0x95, 0x70)                  # STA $70,X     -> $0074
db(0xA5, 0x74)                  # LDA $74
db(0xC9, 0x57, 0x13)            # CMP #$1357
expect_eq('STA dp,X')

# dp,Y (STX/LDX)
db(0xA2, 0x68, 0x24)            # LDX #$2468
db(0xA0, 0x02, 0x00)            # LDY #$0002
db(0x96, 0x80)                  # STX $80,Y     -> $0082
db(0xA6, 0x82)                  # LDX $82
db(0xE0, 0x68, 0x24)            # CPX #$2468
expect_eq('STX dp,Y / CPX 16-bit')

# (dp,X)
db(0xA2, 0x04, 0x00)            # LDX #$0004
db(0xA9, 0xA0, 0x02)            # LDA #$02A0
db(0x85, 0x94)                  # STA $94       pointer at $90+X
db(0xA9, 0xCE, 0xFA)            # LDA #$FACE
db(0x8D, 0xA0, 0x02)            # STA $02A0
db(0xA1, 0x90)                  # LDA ($90,X)
db(0xC9, 0xCE, 0xFA)            # CMP #$FACE
expect_eq('LDA (dp,X)')

# abs,Y
db(0xA0, 0x06, 0x00)            # LDY #$0006
db(0xA9, 0x22, 0x11)            # LDA #$1122
db(0x99, 0xB0, 0x02)            # STA $02B0,Y   -> $02B6
db(0xAD, 0xB6, 0x02)            # LDA $02B6
db(0xC9, 0x22, 0x11)            # CMP #$1122
expect_eq('STA abs,Y')

# long,X
db(0xA2, 0x02, 0x00)            # LDX #$0002
db(0xA9, 0xAA, 0x77)            # LDA #$77AA
db(0x9F, 0x00, 0x81, 0x01)      # STA $018100,X
db(0xAF, 0x02, 0x81, 0x01)      # LDA $018102
db(0xC9, 0xAA, 0x77)            # CMP #$77AA
expect_eq('STA long,X')

# MVP (descending block move)
db(0xA9, 0xBB, 0xAA)            # LDA #$AABB
db(0x8D, 0x30, 0x05)            # STA $0530
db(0xA9, 0xCC, 0x00)            # LDA #$00CC
db(0x8D, 0x32, 0x05)            # STA $0532
db(0xA2, 0x32, 0x05)            # LDX #$0532    (last source byte)
db(0xA0, 0x42, 0x05)            # LDY #$0542    (last dest byte)
db(0xA9, 0x02, 0x00)            # LDA #$0002    (3 bytes)
db(0x44, 0x00, 0x00)            # MVP $00,$00
db(0xAD, 0x40, 0x05)            # LDA $0540
db(0xC9, 0xBB, 0xAA)            # CMP #$AABB
expect_eq('MVP copied bytes 0-1')
db(0xAD, 0x42, 0x05)            # LDA $0542
db(0xC9, 0xCC, 0x00)            # CMP #$00CC
expect_eq('MVP copied byte 2')

# BRL
db(0x82); r16('brlt')           # BRL brlt
db(0xDB)                        # STP  (trap)
label('brlt')

# PEI
db(0xA9, 0xAD, 0xDE)            # LDA #$DEAD
db(0x85, 0x98)                  # STA $98
db(0xD4, 0x98)                  # PEI ($98)
db(0x68)                        # PLA
db(0xC9, 0xAD, 0xDE)            # CMP #$DEAD
expect_eq('PEI pushes dp word')

# EOR / AND / ORA
db(0xA9, 0xF0, 0xF0)            # LDA #$F0F0
db(0x49, 0xF0, 0x0F)            # EOR #$0FF0    -> $FF00
db(0x29, 0xFF, 0xF0)            # AND #$F0FF    -> $F000
db(0x09, 0x0F, 0x00)            # ORA #$000F    -> $F00F
db(0xC9, 0x0F, 0xF0)            # CMP #$F00F
expect_eq('EOR/AND/ORA 16-bit')

# TSC / TCS
db(0x3B)                        # TSC
db(0x8D, 0xC0, 0x02)            # STA $02C0     save S
db(0xA9, 0xF0, 0x01)            # LDA #$01F0
db(0x1B)                        # TCS
db(0x3B)                        # TSC
db(0xC9, 0xF0, 0x01)            # CMP #$01F0
expect_eq('TCS/TSC')
db(0xAD, 0xC0, 0x02)            # LDA $02C0
db(0x1B)                        # TCS           restore S

# PHX / PLY
db(0xA2, 0x34, 0x12)            # LDX #$1234
db(0xDA)                        # PHX
db(0x7A)                        # PLY
db(0xC0, 0x34, 0x12)            # CPY #$1234
expect_eq('PHX/PLY 16-bit')

# PLD (D relocation via stack)
db(0xA9, 0x00, 0x02)            # LDA #$0200
db(0x48)                        # PHA
db(0x2B)                        # PLD           D=$0200
db(0xA9, 0xEE, 0xFF)            # LDA #$FFEE
db(0x85, 0x00)                  # STA $00       -> $0200
db(0xAD, 0x00, 0x02)            # LDA $0200
db(0xC9, 0xEE, 0xFF)            # CMP #$FFEE
expect_eq('PLD direct page')
db(0xA9, 0x00, 0x00)            # LDA #$0000
db(0x5B)                        # TCD           D=0

# --- 8-bit batch ---
db(0xE2, 0x20)                  # SEP #$20      m8

# 8-bit RMW on dp
db(0xA9, 0x40)                  # LDA #$40
db(0x85, 0x52)                  # STA $52
db(0xE6, 0x52)                  # INC $52       -> $41
db(0x46, 0x52)                  # LSR $52       -> $20, C=1
db(0x26, 0x52)                  # ROL $52       -> $41
db(0xA5, 0x52)                  # LDA $52
db(0xC9, 0x41)                  # CMP #$41
expect_eq('INC/LSR/ROL dp 8-bit')

# PHK
db(0x4B)                        # PHK
db(0x68)                        # PLA
db(0xC9, 0x00)                  # CMP #$00
expect_eq('PHK pushes PBR')

# PHB / PLB (data bank register)
db(0xA9, 0x01)                  # LDA #$01
db(0x48)                        # PHA
db(0xAB)                        # PLB           DBR=1
db(0x8D, 0x50, 0x80)            # STA $8050     -> $018050
db(0xAF, 0x50, 0x80, 0x01)      # LDA $018050
db(0xC9, 0x01)                  # CMP #$01
expect_eq('PLB redirects abs to bank 1')
db(0xA9, 0x00)                  # LDA #$00
db(0x48)                        # PHA
db(0xAB)                        # PLB           DBR=0

# IRQ (native vector $FFEE), handler increments $61 and deasserts
db(0x64, 0x61)                  # STZ $61
db(0x58)                        # CLI
db(0xA9, 0x01)                  # LDA #$01
db(0x8D, 0x02, 0xF0)            # STA $F002     assert IRQ
db(0xEA, 0xEA, 0xEA)            # NOP x3
db(0x78)                        # SEI
db(0xA5, 0x61)                  # LDA $61
db(0xC9, 0x01)                  # CMP #$01
expect_eq('IRQ taken once')

# WAI with I=1: released by IRQ but not vectored
db(0xA9, 0x01)                  # LDA #$01
db(0x8D, 0x02, 0xF0)            # STA $F002     assert IRQ (masked)
db(0xCB)                        # WAI
db(0xA9, 0x00)                  # LDA #$00
db(0x8D, 0x02, 0xF0)            # STA $F002     deassert
expect_eq('WAI released by masked IRQ')   # Z=1 from LDA #$00

# NMI (native vector $FFEA)
db(0x64, 0x62)                  # STZ $62
db(0xA9, 0x01)                  # LDA #$01
db(0x8D, 0x03, 0xF0)            # STA $F003     pulse NMI
db(0xEA, 0xEA, 0xEA, 0xEA)      # NOP x4
db(0xA5, 0x62)                  # LDA $62
db(0xC9, 0x01)                  # CMP #$01
expect_eq('NMI taken')

# IRQ during a block move: the move must complete correctly AND the handler
# must have run (the testbench asserts IRQ only at the move's 2nd byte, so a
# run handler proves the move was interrupted mid-transfer and resumed).
db(0xE2, 0x20)                  # SEP #$20      m8 for byte-wise setup
for i, v in enumerate([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]):
    db(0xA9, v)                 # LDA #v
    db(0x8D, 0x00 + i, 0x07)    # STA $0700+i   (source bytes)
db(0xA9, 0x00)                  # LDA #$00
db(0x85, 0x61)                  # STA $61       clear IRQ counter
db(0x8D, 0x04, 0xF0)            # STA $F004     arm mid-move IRQ
db(0xC2, 0x30)                  # REP #$30      m16, x16
db(0xA2, 0x00, 0x07)           # LDX #$0700    source
db(0xA0, 0x00, 0x08)           # LDY #$0800    dest
db(0xA9, 0x07, 0x00)           # LDA #$0007    8 bytes (count-1)
db(0x58)                        # CLI           enable IRQ
db(0x54, 0x00, 0x00)           # MVN $00,$00   interrupted partway through
db(0x78)                        # SEI
db(0xE2, 0x20)                  # SEP #$20      m8 to inspect bytes
db(0xAD, 0x00, 0x08)           # LDA $0800
db(0xC9, 0x11)                  # CMP #$11
expect_eq('MVN-during-IRQ first byte')
db(0xAD, 0x07, 0x08)           # LDA $0807
db(0xC9, 0x88)                  # CMP #$88
expect_eq('MVN-during-IRQ last byte resumed')
db(0xA5, 0x61)                  # LDA $61       handler count (nonzero)
expect_ne('IRQ taken mid-block-move')

# ABORT: a store is aborted (write suppressed, registers preserved), the
# handler runs, then RTI retries the instruction and it completes.
db(0xE2, 0x20)                  # SEP #$20      m8
db(0xA9, 0xAA)                  # LDA #$AA
db(0x8D, 0x50, 0x06)           # STA $0650     target = old value $AA
db(0xA9, 0x00)                  # LDA #$00
db(0x85, 0x64)                  # STA $64       clear "was-suppressed" flag
db(0x85, 0x65)                  # STA $65       clear abort counter
db(0xA9, 0x55)                  # LDA #$55      value to store
db(0x8D, 0x05, 0xF0)           # STA $F005     arm ABORT for the next instr
db(0x8D, 0x50, 0x06)           # STA $0650     <- aborted, then retried
db(0xAD, 0x50, 0x06)           # LDA $0650
db(0xC9, 0x55)                  # CMP #$55      retry completed the store
expect_eq('ABORT: store retried and completed')
db(0xA5, 0x64)                  # LDA $64       handler saw old value
db(0xC9, 0x01)                  # CMP #$01
expect_eq('ABORT: write suppressed during aborted attempt')
db(0xA5, 0x65)                  # LDA $65       handler ran (nonzero)
expect_ne('ABORT: handler invoked')

# back to emulation mode
db(0x38)                        # SEC
db(0xFB)                        # XCE           E=1, m8/x8 forced
db(0xA9, 0x5A)                  # LDA #$5A
db(0x48)                        # PHA
db(0xA9, 0x00)                  # LDA #$00
db(0x68)                        # PLA
db(0xC9, 0x5A)                  # CMP #$5A
expect_eq('emulation mode restored, stack ok')

# ---- success ----
db(0xA9, 0x00)                  # LDA #$00
db(0x8F, 0x00, 0xF0, 0x00)      # STA $00F000   -> PASS
db(0xDB)                        # STP

# ---- subroutines ----
label('sub1')                   # called in emulation mode
db(0xA9, 0x77)                  # LDA #$77
db(0x60)                        # RTS

label('subl')                   # called in native m16
db(0xA9, 0xAA, 0x55)            # LDA #$55AA
db(0x6B)                        # RTL

label('sub2')                   # called in native m16
db(0xA9, 0xDE, 0xC0)            # LDA #$C0DE
db(0x60)                        # RTS

label('brkh')                   # native BRK handler (m8 at entry)
db(0xE6, 0x60)                  # INC $60
db(0x40)                        # RTI

label('irqh')                   # native IRQ handler (preserves A: it may
db(0x08)                        # PHP            interrupt a block move whose
db(0xC2, 0x20)                  # REP #$20       count lives in C)
db(0x48)                        # PHA           save 16-bit A
db(0xE2, 0x20)                  # SEP #$20
db(0xE6, 0x61)                  # INC $61
db(0xA9, 0x00)                  # LDA #$00
db(0x8D, 0x02, 0xF0)            # STA $F002     deassert IRQ
db(0xC2, 0x20)                  # REP #$20
db(0x68)                        # PLA           restore 16-bit A
db(0x28)                        # PLP
db(0x40)                        # RTI

label('nmih')                   # native NMI handler
db(0xE2, 0x20)                  # SEP #$20
db(0xE6, 0x62)                  # INC $62
db(0x40)                        # RTI

label('aborth')                 # native ABORT handler (m8 at entry)
db(0x48)                        # PHA
db(0xAD, 0x50, 0x06)           # LDA $0650     read aborted store's target
db(0xC9, 0xAA)                  # CMP #$AA      still old? (write suppressed)
db(0xD0, 0x04)                  # BNE +4        skip if already changed
db(0xA9, 0x01)                  # LDA #$01
db(0x85, 0x64)                  # STA $64       record "was suppressed"
db(0xE6, 0x65)                  # INC $65       count the abort  (+0 target)
db(0x68)                        # PLA
db(0x40)                        # RTI           retries the aborted instruction

# ---- vectors ----
org(0xFFE6); w16('brkh')        # native BRK
org(0xFFE8); w16('aborth')      # native ABORT
org(0xFFEA); w16('nmih')        # native NMI
org(0xFFEE); w16('irqh')        # native IRQ
org(0xFFFC); w16('start')       # RESET

# ===========================================================================
for kind, pos, name in fixups:
    v = labels[name]
    if kind == 'r16':
        v = (v - (pos + 2)) & 0xFFFF
    mem[pos] = v & 0xFF
    mem[pos + 1] = (v >> 8) & 0xFF

with open('test.hex', 'w') as f:
    f.write('\n'.join(f'{b:02X}' for b in mem))
    f.write('\n')

print(f'test.hex written: {tid} checks')
for i, d in descs:
    print(f'  {i:3d}: {d}')
