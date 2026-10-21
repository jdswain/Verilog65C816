# Banked direct page and stack

An extension of the core, for preemptive multitasking: each process can
have its own direct page and stack in its own bank, instead of all of them
sharing bank 0. It is implemented in `cpu_65c816.v` and in em16's EmCore,
which runs under `em16 -fpga`, and both are checked by `banked.s`.

## The idea

On the 65C816 the direct page and the stack are always in bank 0. D is
already 16 bits, and PHD, PLD, TCD and TDC already move all 16 bits, but
those bits only say where in bank 0 the direct page starts.

In banked mode, D is read differently: it holds a page number. Its high
byte is the bank and its low byte is the page within that bank. The stack
uses the same bank, D's high byte. So:

| | standard | banked (native mode) |
|---|---|---|
| direct page base | `$00:D` (any byte) | `DH:DL:00` (a page boundary) |
| `dp`, `dp,X`, `dp,Y` | `$00:(D + dp + X)` | `DH:(DL00 + dp + X)` |
| pointers of `(dp)`, `(dp,X)`, `(dp),Y`, `[dp]`, `[dp],Y`, PEI | read from bank 0 | read from bank DH |
| stack: pushes, pulls, JSR/RTS/JSL/RTL, interrupts, RTI | `$00:S` | `DH:S` |
| `sr,S` and the pointer of `(sr,S),Y` | `$00:(S + sr)` | `DH:(S + sr)` |

D=`$0130`, for example, puts the direct page at `$01:3000` and the stack at
`$01:S`. As in standard native mode, addresses wrap within the bank: with
D=`$01FF`, `sta $20,X` with X=`$0100` writes `$01:0020`. The second byte of
a word at `$01:FFFF` is at `$01:0000`.

Nothing else changes. The data those pointers point to is still in DBR,
or in the pointer's own bank for `[dp]`. Absolute and long addressing,
block moves, vectors (still in bank 0) and every flag are as before. No
instruction is added or changed: a process's whole place in memory,
direct page and stack, is D and S, so PHD/PLD and TSC/TCS save and restore
it.

The limits are those of the idea. The direct page starts on a page
boundary, and the direct page and the stack share one bank. Neither is a
loss for a process that owns a bank.

## Turning it on and off

| | |
|---|---|
| `wdm #$B1` | banked mode on |
| `wdm #$B0` | banked mode off |

The mode is off at reset, so code that uses D as a bank 0 address runs
unchanged. MiniMon turns it on as it starts, so the operating system and
anything run with `go` find it on (below). Every other WDM operand is
still a two-byte no-operation. ($B0 and $B1 stay clear of 1, 2 and $FF,
which em16's own non-`-fpga` processor, EmCPU, uses for host I/O.) On a
stock 65C816 the two WDMs do nothing, so code that depends on the mode is
specific to this core.

The mode only applies in **native** mode. In emulation mode the stack is
page 1 of bank 0 and D is a bank 0 address, as on the chip, whatever the
mode. Back in native mode, banking resumes.

The mode bit is not in P, so interrupts neither save nor change it. It is
meant to be set once, by MiniMon at startup, and left on: the kernel and
every process run banked. Code that runs with it on must treat D as a page
number. Switching the mode reinterprets the current D: D=`$0130` is
`$00:0130` with the mode off and `$01:3000` with it on.

## Moving the stack

Changing D moves the stack to D's bank at once, at the same S. Changing D
and then S, a context switch, leaves a moment in between when S points
into the wrong bank. Nothing may use the stack then, so interrupts must be
off, as they are in an interrupt handler.

PLD pulls both bytes from the old stack and then moves it. PHD pushes onto
the current one.

## A context switch

An interrupt pushes PBR, PC and P onto the running process's stack, in
the process's bank. The handler pushes the registers there too, then
records the process's D and S, and switches to the kernel's:

```
irq:    rep #$30            ; save A, X and Y whole
        pha
        phx
        phy
        phb
        tdc                 ; the process: Y = D, X = S
        tay
        tsc
        tax
        lda #KERNEL_D       ; kernel bank and page
        tcd                 ; (the stack is in the kernel bank now, at the old S)
        stx cur_s           ; into the process table, through the kernel's DP
        sty cur_d
        ldx #KERNEL_S
        txs                 ; the kernel's own stack
        ...                 ; schedule: the next process's entry
        ldx next_s
        lda next_d
        tcd                 ; the next process's bank, at the kernel's S...
        txs                 ; ...and its S: no stack use in between
        plb
        ply
        plx
        pla
        rti                 ; P restores the process's register widths
```

A new process starts with a stack built to look like this: P, PC and PBR,
as RTI pulls them, and below them B, Y, X and A.

## What it costs

In the core, two multiplexers decide where the direct page's base and bank
come from (`dbase`, `dbank`), plus the mode bit and its WDM decode. The core
has no dummy cycles, so the 65C816's extra cycle for D not on a page
boundary has no counterpart here, and banked mode costs no time.

## Things to know

- MiniMon runs with D = 0 and its stack in page 1, which are the same
  addresses in either mode, and it turns banked mode on at startup, so the
  operating system need not. `go` turns it on again when the code returns,
  in case the code turned it off; the code must have its stack back in bank
  0 for the `RTL`. MiniMon has no BRK or interrupt entry. Mandelbrot sets
  the mode itself and gives its direct page as D = `$003F`. Forth leaves D
  alone, and Business Basic sets D = 0, the same in either mode.
- An interrupt pushes four bytes onto whichever stack is running, so every
  process's stack needs room for the interrupt frame and the handler's
  pushes.
- The test, `banked.s`, runs under the core's test bench (`make banked`,
  assembled with `-D BENCH=1`) and under em16 (`make test` in
  65Tools/em16, `-D BENCH=0`). The Harte vectors still pass as before, with
  the mode off.
