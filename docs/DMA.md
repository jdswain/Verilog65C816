# DMA for SCSI and the floppy

**Proposed.** A two-channel DMA engine in the FPGA that moves bytes between
SDRAM and the carrier's 53C80 (SCSI) and 82077AA (floppy), with a model of
it in em16 and DMA modes in em16's two chips, so that OS16's drivers can use
it before the carrier exists. `Hardware.md` (DMA) has the pins and the
carrier's side; this document is the engine itself.

## Why

OS16's Floppy driver moves a sector by polling (OS16 `doc/OS16_ToDo.md`).
The 82077AA's 16-byte FIFO leaves 128-512 µs between the sector's first
byte and an overrun, and no gap that long after it. A clock interrupt takes
1.4 ms, so a polled transfer needs interrupts off from the READ to its
result, which includes the seek and up to a revolution: 200 ms or more.
With DMA each byte is served in hardware and interrupts and preemption stay
on. SCSI is handshaked and never overruns, but DMA frees the CPU during the
data phase, and the same engine serves both.

## Overview

```
        53C80 DRQ ──► DRQ0 ┐                   ┌──► port 2 ──► SDRAM
     82077AA DRQ ──► DRQ1 ┤   dma.v            │   (shared with the
                          │   2 channels ──────┤    blitter: mm_mux)
                          │   registers $0400  │
   /DACK (select codes 4, 1)◄─┤                └──► cache invalidation
   TC ◄───────────────────┤
                          └──► external_bus.v DMA port (one cycle at a time,
                                                     ahead of the CPU's)
```

| Channel | Device | Request | Acknowledge | Terminal count |
|---|---|---|---|---|
| 0 | 53C80 | `DRQ0`, pin 79 | select code 4 (`$0840` slot) | `TC`, inverted to `/EOP` |
| 1 | 82077AA | `DRQ1`, pin 80 | select code 1 (`$0810` slot) | `TC` |

The channel-to-device mapping is fixed. Each channel has a 24-bit address
and a 24-bit count and moves one byte per external bus cycle. On the memory
side bytes are gathered into words for writes and read sixteen at a time,
so the SDRAM sees one transaction per four or sixteen bytes.

## Prerequisite: the external bus

The engine needs the bus as `Hardware.md` proposes it, which is not built
yet:

* Intel-style `RD#`/`WR#` only, on the 8.4 MHz timing (about 400 ns a
  cycle). `EXT_STYLE`, PHI0 and the 6502 cycle go.
* The four select pins as a three-bit code and an active-low enable
  driving a 74HCT138: eight 16-byte slots at `$0800 + n*16`, mirrored every
  128 bytes. The enable keeps the `/DACK` outputs from glitching; on the
  53C80 a glitch on `/DACK` clears `DRQ`.
* The SCC recovery hold for select 2, and `RD#` with `WR#` during `RES#`.

The addresses software uses today don't move: the 82077AA at `$0800`, the
SCC at `$0820` and the 53C80 at `$0830`. This is step 1 of the plan below,
and it is worth doing on its own, since it is three to five times faster
for every card access.

## Registers

At `$0400`, in the unclaimed `$0400`-`$04FF` range. The device decodes
`$0400`-`$043F`: `addr[4]` picks the channel and `addr[5]` is ignored, so
the pair repeats at `$0420`. Each channel has 16 bytes:

| Offset | Register | Read | Write |
|---|---|---|---|
| +0, +1, +2 | ADDR | the next byte's address, low, middle, bank | the start address |
| +3 | | 0 | ignored |
| +4, +5, +6 | COUNT | the bytes left, low, middle, high | the bytes to move |
| +7 | | 0 | ignored |
| +8 | CTRL | as written; EN reads 0 once the channel stops | see below |
| +9 | STATUS | see below | bit 0: 1 clears DONE |
| +A-+F | | 0 | ignored |

Channel 0 is at `$0400`, channel 1 at `$0410`.

**CTRL**

| Bit | Name | |
|---|---|---|
| 0 | EN | 0 to 1 starts the channel and clears DONE; 1 to 0 stops it |
| 1 | DIR | 0: device to memory (a read from the disk). 1: memory to device |
| 2 | TC | assert `TC` during the last byte's cycle |
| 3 | IE | interrupt while DONE is set |
| 7-4 | | 0 |

**STATUS**

| Bit | Name | |
|---|---|---|
| 7 | BUSY | the channel is running, or has bytes still to write to memory |
| 6 | DRQ | the request line, as synchronised (for debugging) |
| 0 | DONE | the count reached 0 and every byte is in memory (or out on the bus) |

**The rules:**
* ADDR and COUNT can only be written while the channel is stopped; writes
  while BUSY are ignored. They are plain bytes, so a 16-bit `sta` writes
  two of them.
* Starting with COUNT = 0 sets DONE at once, with no bus cycle.
* The address counts up through all 24 bits, across banks. It addresses
  SDRAM directly: `$00:0200`-`$00:0FFF` and the ROM overlay are the SDRAM
  under them, never I/O or ROM. Addresses at `$80:0000` and above wrap onto
  the SDRAM (`addr[22:0]`).
* **Stopping early.** Writing EN = 0 finishes the byte in progress, writes
  any gathered bytes to memory, and clears BUSY. DONE is not set. ADDR and
  COUNT then say exactly where the transfer stopped: SCSI uses this when the
  target changes phase before the count runs out.
* COUNT and ADDR change while the channel runs; reading three bytes of a
  running channel can tear. Stop it first, or wait for DONE.
* IRQ: the engine raises the CPU's IRQ while either channel has DONE and IE
  set, ORed in `soc.v` with the SCC and the cards. Writing 1 to STATUS bit 0
  clears it. OS16's probe reads `$0409` and `$0419`.

### Programming a transfer

```
        ; channel 1: read a 512-byte sector into $02:4000
        sep #$20
        stz $0418           ; stopped (CTRL)
        lda #$00
        sta $0410
        lda #$40
        sta $0411
        lda #$02
        sta $0412           ; ADDR = $02:4000
        stz $0414
        lda #$02
        sta $0415
        stz $0416           ; COUNT = $000200
        lda #$0D            ; IE, TC, device to memory, EN
        sta $0418
        ; ... then the READ DATA command to the 82077AA
```

## The engine

`rtl/dma.v`, one module with two channel contexts, a memory-side state
machine and a bus-side state machine. Only one external bus cycle can
happen at a time, so the channels take turns for the bus; each has its own
memory buffers.

### Choosing a channel

A channel wants the bus when it is enabled, COUNT is not 0, its DRQ is
high, and (memory to device) its next byte is in its line buffer, or
(device to memory) its write buffer has room. When both want it, they take
turns: the one that didn't have the last cycle gets the next. The floppy
then waits at most one SCSI cycle, about 0.5 µs, against a FIFO that lasts
128 µs at 1 Mbit/s and more at the slower rates.

### The bus cycle

The bridge gets a second requester. A DMA cycle is a CPU cycle without an
address:

| | CPU cycle | DMA cycle |
|---|---|---|
| select code | `addr[6:4]` | 4 (channel 0) or 1 (channel 1) |
| `ext_a[3:0]` | `addr[3:0]` | 0 (the chips ignore it during `/DACK`) |
| strobe | `RD#` read, `WR#` write | `RD#` device to memory, `WR#` memory to device |
| `TC` | low | high from T1 to the strobe's rise, on the last byte when CTRL.TC |
| timing | T1-T3 as in `Hardware.md` | the same |

The bridge takes a DMA request before a CPU one when both are waiting at
the start of a cycle, so a CPU access to the cards waits at most one DMA
cycle. The emulated SCC never goes through the bridge and never waits.

**Sampling DRQ again.** Both chips drop DRQ during the `/DACK` cycle if
they have no further byte. The synchroniser adds two clocks, so the engine
ignores a channel's DRQ until three clocks after its strobe rose. **Check**
the 82077AA's and 53C80's DRQ-from-strobe times against this; if either is
slower, add a clock.

### The memory side

The engine is one master on port 2, behind `mm_mux` (below). It keeps the
port's protocol: it holds `req` through the cycle `done` is high and drops
it for a cycle after each `done`, so the CPU gets one transaction between
each of its own.

**Device to memory: a write buffer.** Each channel gathers bytes into a
32-bit word with a byte mask. The word goes to memory when its last byte
(address bits 1-0 = 3) is filled, when COUNT reaches 0, or when the channel
is stopped: a start or end that isn't word-aligned gives a partial mask.
A full word moves to a one-word queue and is written from there, so the
next byte can be gathered while it is written; the channel waits for the
bus only if the queue is still full when the next word fills, which at four
bus cycles a word does not happen. DONE is set only after the last write
has retired.

**Memory to device: a line buffer.** Each channel holds the sixteen bytes
of one aligned 16-byte block, read as one burst (four words). The block is
fetched when the channel starts and again each time the address crosses
into the next block. SCSI then stalls for one burst (about 0.5 µs) every 16
bytes, about 5%. A second line, fetched ahead, would remove that stall if it
matters. With logic short, the buffer can shrink to a word, at four times
the reads.

**Ordering against the CPU's stores.** The cache is write-through with one
store in flight: the CPU carries on before its store reaches SDRAM, and
port 2 outranks the CPU's port. A driver that fills a buffer and then
starts a channel could have the engine read a word whose store is still
waiting. So the cache exposes `wr_busy` (a store accepted but not yet
retired), and the engine doesn't issue a read while it is high. **Check**
whether the blitter has the same exposure; the same signal fixes it.

**The cache.** The engine's writes go past the cache, which snoops port 2
already: `inv_valid`/`inv_addr` come from the multiplexed port instead of
the blitter's. The prefetch queue doesn't snoop, as for the blitter: code
read from disk is only stale if it is within two words of the PC, and a
jump to it flushes the queue (`prefetch.v`).

### `mm_mux`: sharing port 2

A small arbiter in front of port 2, between the blitter and the engine. A
master is granted when the port is idle and holds the grant until its
`done`. If both are asking, the engine wins: it has deadlines and the
blitter doesn't, and it asks at most once every four bus cycles. Read data
and `rvalid` go to the granted master; `done & we` with the granted
address go to the cache's invalidation input. The rule that a master drops
`req` for a cycle after `done` gives the blitter its turn too.

### Throughput and cost

* **Rate:** a cycle is about 400 ns plus the three clocks before DRQ is
  sampled again: about 1.9 MB/s. The 53C80 can do 3 MB/s and the floppy needs
  at most 125 KB/s (2.88M), so neither chip is ever kept waiting long.
* **SDRAM:** at the full SCSI rate, one word write every 2 µs, a few percent
  of the controller's time.
* **Logic:** the registers (2 x 52 bits), the write buffers and queues
  (2 x 72), the line buffers (2 x 128), counters and state: about 600
  flip-flops and 800-1000 LUTs, estimated. The design uses 72% of the logic
  today, so it fits, but it is the largest addition left. The line buffers
  are the first thing to shrink.

## Signals, pins and the carrier

From `Hardware.md`, unchanged: `DRQ0` on pin 79, `DRQ1` on pin 80 and `TC`
on pin 85, three new pins, plus the select decoder. Two points to add there:

* **The 82077AA tristates `DRQ` (and `INT`) while the DOR's DMA gate is
  off.** Its input to the 74LVC buffer would float. The carrier needs a
  pull-down on that input, on the 5V side. The 53C80's `DRQ` is driven
  (**Check**), but the same pull-down there costs nothing.
* **`TC` on both chips.** The 82077AA accepts `TC` only while `/DACK` is
  asserted (datasheet: "TC is accepted only while DACK is active"), so one
  shared pin serves both; the `Hardware.md` **Check** on this can be
  closed once it has been read against the datasheet itself.

**On the bare board** pin 80 reads high (its 10k pull-up to the SD card's
D2), so channel 1 always sees a request, and `ext_d` is pulled up, so it
reads `$FF`. A channel 1 transfer then runs to its count at bus speed: memory
to device sends bytes nowhere, device to memory fills memory with `$FF`.
That tests the memory side, the cache invalidation and the interrupt on the
board before the carrier exists. Pin 79 reads low (5.1k pull-down), so
channel 0 never runs.

## The chips' side

### 82077AA (channel 1)

* SPECIFY with ND = 0 (DMA mode), and the DOR's DMA gate on for the whole
  command: with the gate off, `DRQ` is tristated (and pulled down) and the
  transfer pauses.
* READ DATA: `DRQ` rises for each byte in the FIFO (with the FIFO on, it
  asks for bursts up to the threshold); each `/DACK` and `RD#` cycle takes
  one. WRITE DATA is the same with `WR#`.
* `TC` on the last byte of the last sector ends the command normally after
  that sector: ST0 `$00`, not the "end of cylinder" ending a polled transfer
  gets today. The result phase raises `INT`.
* In DMA mode `INT` comes only at the result phase (and for seeks), not for
  each byte. In the result phase the MSR shows RQM and DIO, so the driver's
  probe can tell a finished command without turning the gate off.

### 53C80 (channel 0)

* Mode register bit 1 (DMA mode), bit 3 (EOP interrupt) if the driver
  wants the chip's interrupt at the end; then write register 5 (start DMA
  send), 6 (start DMA target receive; not used) or 7 (start DMA initiator
  receive).
* `DRQ` asks for each byte while the phase matches; `/DACK` with `RD#`
  reads the input data register, `/DACK` with `WR#` writes the output data
  register. The chip does the REQ/ACK handshake by itself.
* `/EOP` (our `TC`) on the last byte sets End of DMA in the bus and status
  register, and interrupts if mode bit 3 is set.
* **The target can end the data phase early** (a short read, or a check
  condition). `DRQ` stops, phase match clears, and in DMA mode the chip
  interrupts. The driver then stops the channel and reads COUNT to see how
  many bytes moved.
* **The last byte of a send.** When the engine has written the last byte
  the chip still has it to hand over on the SCSI bus. The driver waits for
  it to go (the 53C80's "last byte sent", target command register bit 7,
  **Check**) before clearing DMA mode.

## em16

em16 has the 82077AA (`Em82077`) and the 53C80 (`EmSCSI`) at their carrier
addresses, without DMA. The model needs:

* **The eight-slot decode** in `EmSoC`'s card access (`card := AND(a DIV
  16, 7)`): today `$0840`, the 53C80's `/DACK` slot, decodes as the floppy.
  The CPU's accesses to slots 1 and 4 are pseudo-DMA: a byte from or to the
  chip, as a `/DACK` cycle with `TC` low.
* **`EmDMA`**, the engine: the same registers at `$0400`. Each `Tick`, a
  running channel whose device asks moves one byte, at most one every 13
  cycles (about the 400 ns cycle and the wait for DRQ), reading and writing
  memory through `EmSDRAM`. It raises its IRQ into `EmSoC`'s IRQ the way the
  cards do. Memory timing and the port 2 contention are not modelled.
* **`Em82077`'s DMA mode:** with ND = 0, DRQ and a `Dack(read, tc)`
  procedure instead of the warning. The bytes should arrive at the data
  rate, one per byte time (806, 403 or 201 cycles), not as fast as they are
  taken. Modelling the FIFO's overrun at the same time, as the OS16 ToDo
  asks, makes em16 fail where the board would.
* **`EmSCSI`'s DMA mode:** mode bit 1, start registers 5 and 7, DRQ while
  REQ is asserted and the phase matches, `Dack(read, eop)`, End of DMA, the
  EOP and phase-mismatch interrupts, and "last byte sent".
* **A test**, `test/dma.s`: sectors read and written by DMA on both
  devices, compared with the same sectors moved by programmed I/O; a stop
  partway through, checked against COUNT; and `TC` ending the floppy's
  command normally.

## OS16

The driver work, in outline (the drivers are OS16's to design):

* **Floppy:** SPECIFY with DMA, the gate on through the command, channel 1
  set up for the sector with TC and IE, READ or WRITE DATA, then Await. The
  probe sees either the engine's DONE or the controller's result phase
  (MSR RQM and DIO); both lead to reading the result. Seeks and
  recalibrates keep today's gate-toggling probe, since no DMA runs then.
* **SCSIManager:** the data phases by DMA, the rest by programmed I/O as
  now. Count = the bytes the command should move, TC on; wait for DONE or
  the 53C80's interrupt; stop the channel, read COUNT, clear DMA mode.
* **InterruptManager:** a probe for the engine (STATUS of each channel).

## Plan

Each step can be tested before the next starts.

1. **The external bus** to one style, the 8.4 MHz timing and the eight-slot
   decode (`external_bus.v`, `top_tang20k.v`, the `.cst`, `fpga/README.md`).
   Test: the SoC simulation and a card bus model in a test bench; on the
   board, the timing on a logic analyser.
2. **The engine:** `dma.v`, `mm_mux`, the bridge's DMA port, `wr_busy`
   from the cache, the IRQ, and the new pins (`DRQ0`, `DRQ1`, `TC`).
   `sim/tb_dma.v`: the engine with the bridge, a memory model and
   models of both chips (an 82077AA-like FIFO with a byte time, a
   53C80-like device that can change phase partway through): counts, TC on
   the last byte and only with `/DACK`, unaligned starts and ends, a stop
   with COUNT read back, CPU card accesses between DMA cycles, the store
   ordering, and turn-taking with both channels running. Then the SoC
   simulation, a timing build, and the bare-board test through `DRQ1`.
3. **em16:** the decode, `EmDMA`, and the two chips' DMA modes, with
   `test/dma.s`.
4. **OS16:** Floppy, then SCSIManager, then a test that sectors move with
   interrupts on and other processes running.
5. **The carrier:** the DMA wiring and pull-downs, and the **Check** items
   above against the datasheets and the board.

Steps 1-2 are this repository's and step 3 is 65Tools'. They don't depend on
each other, since em16 implements the registers as this document gives them.
