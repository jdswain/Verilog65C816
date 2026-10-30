# Verilog 65C816 CPU Core

A synthesizable Verilog-2001 implementation of the WDC 65C816, optimized for
**functional compatibility and throughput, not cycle accuracy**. Every bus
cycle does useful work: there are none of the dummy/phantom reads and writes
of the real chip (or the 6502), and most instructions finish in fewer cycles
than the original part.

## Files

| File | Description |
|------|-------------|
| `cpu_65c816.v` | The CPU core (single module, no dependencies) |
| `tb_cpu.v`     | Self-checking testbench (128 KB RAM, result/console/IRQ magic ports) |
| `test_gen.py`  | Generates `test.hex`: a hand-assembled program with 64 self-checks |
| `tb_harte.v`   | Testbench that runs the SingleStepTests (TomHarte) vectors |
| `harte_run.py` | Downloads, converts, runs and aggregates the TomHarte vectors |
| `banked.s`     | Checks of the banked direct page and stack (`make banked`) |
| `tb_irqwait.v`, `irqwait.s` | IRQs taken while the bus waits, on a cache-like bus (`make irqwait`) |
| `Makefile`     | `make run` builds with Icarus Verilog and runs the test suite |

## Running the tests

```sh
make run            # expects iverilog/vvp and python3 on PATH
vvp sim +trace=200  # optional: print the first 200 bus cycles
make banked         # the banked direct page and stack: PASS  (642 cycles)
make irqwait        # IRQs under wait states: the same checksum, the bus held (45 s)
```

Expected output: `PASS  (1410 cycles)`. The 70 checks cover all addressing
modes, 8/16-bit register widths, emulation/native switching, decimal mode,
block moves (including an IRQ taken mid-transfer), the stack/relocation
instructions (PEA/PEI/PER, PHD/PLD, PLB, TCD/TCS...), BRK/COP, hardware
IRQ/NMI, WAI/STP, and ABORT (write suppressed + instruction retried).

## Implemented features

- All 256 opcodes (including MVN/MVP, BRL, JSL/RTL, stack-relative modes,
  `[dp]`/`[dp],Y` long indirection, WDM as a 2-byte NOP).
- Native and emulation modes; M/X width control with the proper register
  high-byte forcing (XH/YH cleared when x=1, SH forced to $01 when E=1).
- Decimal mode ADC/SBC in both 8- and 16-bit widths.
- Interrupts: RES, NMI (edge), IRQ (level), BRK, COP, with the correct
  native/emulation vectors and stack frames; WAI and STP.
- ABORT: aborts the running instruction (all writes suppressed, registers
  restored from a pre-instruction snapshot) and vectors through the ABORT
  vector ($00FFE8 native / $00FFF8 emulation) with the *opcode* address
  pushed, so RTI retries the instruction. Useful for virtual memory / bus
  faults.
- Bus-cycle classification pins (W65C816 style): VPA/VDA (program vs data vs
  internal vs opcode-fetch), VPB (vector pull), MLB (memory lock during RMW).
- An extension, off at reset: **banked direct page and stack**
  ([docs/BankedDP.md](docs/BankedDP.md)). After `WDM #$B1`, in native mode,
  D holds a bank and page: the direct page is at `DH:DL:00` and the stack at
  `DH:S`, so each process of a multitasking system can have both in its own
  bank. `WDM #$B0` turns it off again.

## Bus interface

Simple SRAM-style synchronous bus, 24-bit address / 8-bit data:

| Port | Dir | Description |
|------|-----|-------------|
| `addr[23:0]`  | out | bank:address |
| `rdata[7:0]`  | in  | read data, sampled on posedge clk when `rdy` |
| `rdata32[31:0]` | in | the aligned 32-bit word holding `addr`, when `r32` |
| `r32`         | in  | this read also returns the whole word (`rdata32`): the instruction queue takes all four bytes |
| `wdata[7:0]`  | out | write data |
| `we`          | out | 1 = write cycle |
| `vld`         | out | a bus cycle is in progress |
| `rdy`         | in  | low inserts wait states |
| `irq_n/nmi_n` | in  | interrupts (NMI is falling-edge detected) |
| `abort_n`     | in  | abort the running instruction (active low) |
| `vpa/vda`     | out | cycle class: 00=internal, 10=program, 01=data, 11=opcode fetch |
| `vpb_n`       | out | vector pull, active low (low during vector fetches) |
| `mlb_n`       | out | memory lock, active low (low across an RMW read+write) |
| `e_flag/m_flag/x_flag/stopped` | out | status |

Reads assume **asynchronous (combinational) memory**: the core drives `addr`
and samples `rdata` on the same rising edge. For registered (block-RAM style)
memory, hold `rdy` low for one cycle per access, or add a bridge. Writes
commit on the rising edge when `vld & we & rdy`.

Instruction bytes do not come over the bus one at a time. An 8-byte queue in
the core fills a word at a time (`rdata32`, flagged `r32`; a memory without
`r32` gives one byte a fill) in the cycles the core does not need the bus,
and the opcode and operand states take a byte a cycle from it. A fill holds
the bus until `rdy` like any access; a state that does not use the bus keeps
running meanwhile. A jump empties the queue. Queue fills are the cycles with
`vpa` high and `vda` low. Self-modifying code is not supported: a store to
bytes already in the queue does not change them.

## Cycle counts (rdy held high)

| Instruction type | Cycles | Real W65C816 |
|---|---|---|
| Implied register ops (TAX, INX, CLC, XCE, ASL A, ...) | 1 | 2 |
| Immediate / branch / REP / SEP | 2 (3 if 16-bit imm) | 2-3 |
| LDA dp (8-bit / 16-bit) | 3 / 4 | 3 / 4 |
| LDA abs (8-bit / 16-bit) | 4 / 5 | 4 / 5 |
| RMW abs (e.g. INC) 8-bit | 5 | 6 |
| JSR abs / RTS | 5 / 3 | 6 / 6 |
| Block move (MVN/MVP) | 2 per byte + 3 | 7 per byte |
| Interrupt entry (native) | 11 | 8 |

(The opcode fetch is counted in each row; there are no penalty cycles for
page/bank crossing, indexing, or `D` misalignment.)

These assume the instruction queue already holds the bytes. A jump, branch
taken, return or interrupt empties it, and the target's word is then fetched
before its opcode can be taken; a data access may also wait behind a queue
fill. A push takes one cycle more than the table's pattern suggests (a setup
cycle), and a pull fetched straight after a read or implied instruction waits
one cycle for its execute. With slow memory (the SoC's cache) the queue wins
far more than these cost; with zero-wait memory, as in `make run`, it costs
about 10% more cycles.

## TomHarte (SingleStepTests) vectors

The core is validated against the
[SingleStepTests/65816](https://github.com/SingleStepTests/65816) per-opcode
vectors (256 opcodes × {native, emulation} × 10 000 cases = ~5.12 M tests):

```sh
python3 harte_run.py                 # all opcodes, both modes (downloads JSON)
python3 harte_run.py a9 6d --mode n  # selected opcodes, native only
python3 harte_run.py --jobs 10       # parallelism; writes harte/failures.txt
```

Because the core is **not cycle accurate**, the harness compares only the
final architectural state — every register (A/X/Y/S/D/PC/DBR/PBR/P/E) and
every RAM byte the vector lists — not the per-cycle bus trace. It deposits the
vector's initial state, runs one instruction to completion, and diffs.

Result: **all opcodes pass except MVN/MVP** (see below). Getting there
required modelling several real-silicon behaviours that the vectors check:

- **Decimal-mode flags** (65C816 semantics, not 6502): ADC takes N/Z from the
  BCD-corrected result and V from the result *before* the final high-nibble
  correction; SBC takes N/Z from the corrected result and V from the binary
  subtraction. C is exact in both.
- **Emulation-mode direct-page wrap** (E=1, DL=$00): the base offset
  `dp + index` wraps within page 0 (high byte = DH), while the `+1`/`+2` that
  fetch the upper bytes of a word or pointer are plain 16-bit increments and
  may leave the page.
- **Emulation-mode stack invariants**: SH is hardwired to $01, index high
  bytes to 0. The "new" 65816 stack instructions (PEA, PEI, PER, PHD, PLD,
  PLB, JSL, RTL) use a true 16-bit stack pointer during the transfer — so they
  can cross between page 1 and page 0 — and restore SH=$01 afterward; the
  6502-era stack ops stay within page 1.

### MVN / MVP are the one documented exception

The TomHarte vectors are cycle-bounded and capture block moves *mid-loop*
(PC sitting on the operand, only part of the count moved). A non-cycle-accurate
core cannot reproduce that intermediate state, so `54`/`44` are expected to
differ. The implementation here is functionally correct end-to-end (verified
by `tb_cpu.v`).

Unlike the real chip — which re-fetches its own 3 instruction bytes for every
byte moved (7 cycles/byte) — this core sets the banks up once and then loops
the read/write pair internally at **2 cycles/byte** (3-cycle setup + 2·N). It
stays interruptible: between bytes it checks for a pending IRQ/NMI, and if one
is present it rewinds PC onto the opcode and takes it, so the pushed PC
re-enters the move and resumes after RTI. (As on real hardware, an interrupt
handler that runs during a move must preserve A/X/Y — the move count lives in
C; `tb_cpu.v`'s `irqh` does this and the suite exercises a mid-move IRQ.)

## Known deviations from the real chip

- **Not cycle accurate**; bus traffic ordering differs (e.g. RMW writes the
  low byte first, no read-before-write on stores). MVN/MVP intermediate state
  therefore differs from the cycle-stepped TomHarte vectors (above).
- Indexed data accesses use full 24-bit arithmetic and may cross banks even
  in emulation mode (matches the W65C816).
- The multiplexed bank/data bus of the real part (BA0-7 on the data pins
  during PHI2 low) is not implemented; the bank is on `addr[23:16]` directly.
  Because there are no internal/phantom cycles, the VPA=VDA=0 "internal"
  class appears only during WAI/STP and interrupt/abort entry, not as filler.
- Interrupts are recognized between instructions only (and, per the real chip,
  between the byte transfers of a block move) and during WAI.
- ABORT is recognized on any instruction-execution cycle and aborts the
  current instruction; writes already committed on the bus before recognition
  are not undone (assert ABORT on the faulting access's address cycle, as on
  real hardware). The abort input is passed through one synchronizing flop.


## Licence

Copyright (C) Jason Swain.

This source describes Open Hardware and is licensed under the CERN-OHL-S v2
(strongly reciprocal); the full text is in `LICENSE`. You may redistribute and
modify it and make products using it under the terms of that licence.

It is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY, INCLUDING OF
MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A PARTICULAR PURPOSE.
Please see the CERN-OHL-S v2 for applicable conditions.

The SID emulation in `fpga/rtl/sid/` is reDIP SID by Dag Lem, also CERN-OHL-S
v2, with the changes listed in `fpga/rtl/sid/README.md`.
