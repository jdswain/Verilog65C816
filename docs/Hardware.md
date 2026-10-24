# Target hardware

The board this SoC is heading for: a test system for OS development. It is a
Tang Nano 20K on a carrier board that holds the 5V peripherals. This document
covers the hardware outside the FPGA and the changes needed inside it.
`fpga/README.md` covers the SoC as it is now, with its register-level detail.
[PCB requirements](#pcb-requirements) at the end collects everything the
carrier board has to provide.

Until the carrier exists, software development runs on the bare Tang Nano
with the parts it needs emulated in the FPGA at their final addresses. See
[Emulation](#emulation).

Each item is marked:

* **Built**: in the RTL and tested.
* **Proposed**: decided here but not built.
* **Open**: still to be decided.
* **Check**: depends on a datasheet or board fact that hasn't been confirmed.

## Summary

| Function | Part | Where | Status |
|---|---|---|---|
| CPU, cache, 8 MB SDRAM, boot ROM | 65C816 core, GW2AR-18 | FPGA | Built |
| Video, 640x480 HDMI, text and 16-colour graphics | | FPGA | Built |
| Blitter | | FPGA | Built |
| Console serial | Z85C30 SCC channel A | Emulated in the FPGA on the BL616 USB bridge; later the real chip | Emulation built; it replaced the ACIA |
| Keyboard and mouse | ADB host | FPGA, plus a transistor and level shifter | Working on a breadboard |
| Two serial ports (one internal, one external) | Z85C80 SCC half | Carrier | Proposed |
| SCSI (one internal, one external connector) | Z85C80 SCSI half (53C80) | Carrier | Proposed |
| Floppy (one internal port, two drives) | 82077AA | Carrier | Proposed |
| DMA, two channels | | FPGA | Built; untested on the board |
| Interrupt status and mask | | FPGA | Built |
| Tick timer, the operating system's clock | | FPGA | Built |
| Sound, two SIDs | reDIP SID emulation | FPGA, onboard I2S amplifier; stereo DAC optional on the carrier | Built |
| Ethernet | W5100S | Carrier, on the external bus | Open: proposed below |
| SD card | | | **Not used**; its pins are free |
| Encryption engine, keyboard power-on | | | Open |

The TIM bus is not implemented.

## The Z85C80

The Z85C80 SCSCI is a Z85C30 SCC and a Z53C80 (5380-compatible) SCSI
controller in one 68-pin PLCC. It runs from 5V only (4.75-5.25V).

**The parts on hand are the 8 MHz grade**, so PCLK must not exceed 8 MHz. The
Zilog product specification in hand covers only the 10 and 16 MHz grades.
**Check:** the 8 MHz bus timings. The tables below use the 10 MHz figures,
and the bus timing leaves room for slower ones.

What the two halves share and don't share:

| | Shared | SCC only | SCSI only |
|---|---|---|---|
| Data bus | D7-D0 | | |
| Strobes | `/RD`, `/WR` | | |
| Select | | `/SCCCS` | `/SCSICS` |
| Register address | | `A//B` (channel), `D//C` (data or control) | A2-A0 |
| Interrupt | | `/INT`, open-drain, active low | `IRQ`, active high, push-pull |
| DMA | | `/W//REQA`, `/W//REQB`, `/DTR//REQA`, `/DTR//REQB` | `DRQ` (active high), `/DACK`, `/EOP` |
| Reset | | none: `/RD` and `/WR` low together resets it | `/RESET` |
| Clock | `PCLK`, `/RTxCA`, `/RTxCB` | | |

* **The DMA pins are not shared**, so SCC DMA does not come free with SCSI
  DMA. The SCC has its own request pins, two per channel. SCSI DMA uses `DRQ`
  and `/DACK`.
* **The chip saves parts, not pins.** It still needs two selects and has two
  interrupt outputs. Separate 85C30 and 53C80 chips would use the same FPGA
  pins.
* The SCSI `READY` output is not connected inside the chip. DMA uses `DRQ` and
  `/DACK`, which is all we need.
* The `/TRxCA` and `/CTSA` inputs share one pin, `/CTSA//TRxCA`. Channel B is
  the same.
* **`/INTACK` must be pulled up** when it isn't used. The 65C816 has no
  interrupt acknowledge cycle, so it isn't used.
* **SCC recovery time.** There must be at least 3.5 PCLK periods between the
  falling strobe of one SCC access and the falling strobe of the next. That
  is 475 ns at 7.3728 MHz. The bridge enforces it; see
  [Timing](#timing).
* `/W//REQA` and `/W//REQB` come out of reset as open-drain Wait outputs. They
  need pull-ups if they are wired to anything.

Source: Zilog Z85C80 product specification.

## Voltage levels

**The FPGA's pins are 3.3V and not 5V tolerant.** Everything on the carrier
except the W5100S runs from 5V: the Z85C80, the 82077AA, the ADB bus and the
floppy drives. No 5V signal may reach an FPGA pin directly.

| Signal group | Direction | Part | Notes |
|---|---|---|---|
| `ext_d[7:0]` | both ways | 74LVC245 at 3.3V | Its inputs are 5V tolerant, and its 3.3V output meets the TTL input high level. `DIR` comes from `RD#`; `/OE` comes from the select enable. Neither needs a pin. |
| `ext_a`, select code and enable, `RD#`, `WR#`, `RES#`, `TC` | FPGA to carrier | 74HCT541 and 74HCT138 at 5V | HCT inputs accept 3.3V. The buffer also protects the FPGA pins. |
| `DRQ` inputs | carrier to FPGA | 74LVC125 or 74LVC244 at 3.3V | Inputs are 5V tolerant. |
| `ext_irq_n` | carrier to FPGA | Open-drain node pulled up to 3.3V | See [Interrupts](#interrupts). It needs no shifter. |
| ADB | both ways | Transistor and level shifter | See [ADB](#adb). |

**Strobes and selects need pull-ups on the 5V side.** The cards must stay idle
while the FPGA is unconfigured and its pins float.

## External bus

**Built** (`rtl/external_bus.v`, tested by `sim/tb_extbus.v`):
* an 8-bit data bus
* four address lines
* a three-bit select code and an enable, for eight selects
* Intel `RD#`/`WR#` strobes, on the 8.4 MHz timing below
* the SCC recovery hold
* `RES#` to the cards, with `RD#` and `WR#` held low while it is asserted
* one `IRQ#` input

### One bus style, at 8 MHz

**Built:** the bus is standardised on Intel-style `RD#`/`WR#` strobes
with timing based on an 8 MHz bus clock. The 6502 style, with its free-running
PHI0, is dropped, and with it 6502-family peripherals such as the WD1773.
`EXT_STYLE` and the PHI0 generator are gone from `external_bus.v`, and pin 76
is permanently `RD#`.

Every planned device is an Intel-bus part: the 82077AA, both halves of the
Z85C80, and the W5100S.

### Timing

The system clock is 25.2 MHz, so the nearest bus clock is a third of it:
8.4 MHz, T = 119 ns. No clock goes to the cards, because Intel-bus parts
don't need one. T is only the unit the bridge counts in.

| Step | When | Notes |
|---|---|---|
| Address, select code, write data out | start of T1 | |
| Select enable asserted | T1 + 40 ns (one system clock) | The decoder outputs settle before the enable |
| `RD#` or `WR#` falls | start of T2 | 119 ns of address and select setup |
| Read data sampled | last system clock of T3 | |
| Strobe rises | end of T3 | Strobe width 238 ns |
| Enable released, then address | 40 ns after the strobe | Hold |

A cycle takes about 480 ns from the address going out to the data released (it took 1-2 us with the 6502-style bus); the CPU sees about 560 ns.

The timing against the Z85C30's 10 MHz figures:
* Address setup: 50 ns needed, 119 ns given.
* `/RD` low width: 125 ns needed, 238 ns given.
* `/RD` to data valid: 120 ns, sampled at about 230 ns.
* Address to data valid: 180 ns, sampled at about 350 ns.

The 8 MHz grade will be somewhat slower, and the level shifters add 5-20 ns
each way. **Check** the 8 MHz figures, and the 82077AA, 53C80 and W5100S
figures, against this table.

**SCC recovery.** The bridge can start a cycle 13 clocks (516 ns) after the
last began, and the CPU's back-to-back accesses come about 560 ns apart: both
just above the SCC's 475 ns, with little margin, and a DMA cycle could come
sooner. The bridge therefore holds off an SCC access until 5T (595 ns) after
the previous SCC strobe fell. It applies this only to select 2.

### Select decoding

Seven selects are needed and the bus has four:

| Select | Device |
|---|---|
| 0 | 82077AA `/CS` |
| 1 | 82077AA `/DACK` |
| 2 | Z85C80 `/SCCCS` |
| 3 | Z85C80 `/SCSICS` |
| 4 | Z85C80 `/DACK` |
| 5 | W5100S `/CS` |
| 6, 7 | spare |

**Built:** the four select pins are a three-bit code plus an active-low
enable, driving a 74HCT138. That uses the same four pins and gives eight
selects.

* The enable is what keeps the decoder outputs from glitching while the code
  changes. This matters for `/DACK`, because on the 53C80 `/DACK` clears
  `DRQ`.
* The FPGA asserts the enable after the code has settled and holds the code
  until the enable is released.
* The I/O window becomes eight slots of 16 bytes: `addr[6:4]` is the code and
  `addr[3:0]` drives A3-A0. Slot *n* is at `$0800 + n*16`, mirrored every
  128 bytes to `$0FFF`.
* The CPU can reach the `/DACK` slots too. Reading or writing them is
  pseudo-DMA, as the Macintosh does it, which is useful while bringing the
  board up.

The `external_bus.v` header explains why the selects were decoded in the FPGA:
that saves a part. With seven selects needed the trade goes the other way.

### Register addresses

`ext_a[3:0]` connect to each chip like this:

| Chip | Slot | Connections | Registers |
|---|---|---|---|
| 82077AA | `$0800` | A2-A0 to `ext_a[2:0]` | +0 to +7, the PC/AT layout (SRA, SRB, DOR, TDR, MSR/DSR, FIFO, -, DIR/CCR) |
| Z85C80 SCC | `$0820` | `D//C` to `ext_a[0]`, `A//B` to `ext_a[1]` | +0 B control, +1 B data, +2 A control, +3 A data |
| Z85C80 SCSI | `$0830` | A2-A0 to `ext_a[2:0]` | +0 to +7, the 5380 layout |
| W5100S | `$0850` | A1-A0 to `ext_a[1:0]` | +0 mode, +1 address high, +2 address low, +3 data (indirect bus mode) |

`ext_a[3]` is spare.

### Reset

| Chip | Reset input | Wiring |
|---|---|---|
| Z85C80 SCSI | `/RESET`, active low | from `RES#` through the HCT buffer |
| 82077AA | `RESET`, active high (**Check**) | `RES#` through one inverter gate |
| Z85C80 SCC | none | `/RD` and `/WR` asserted together |
| W5100S | `/RESET`, active low | from `RES#` |

**Built:** while `RES#` is asserted, the bridge also pulls `RD#` and `WR#`
low together. CPU accesses to the window meanwhile end at once and read
`$FF`, since a cycle would end the SCC's reset.
* Only the SCC treats that as a reset.
* The other chips are not selected, so they ignore it.

Software can also reset the SCC by writing `$C0` to WR9.

## DMA

**Built** in the FPGA (`rtl/dma.v`); the carrier's side is proposed. There
are two channels: channel 0 for SCSI and channel 1 for the floppy. The engine is in the FPGA, reads and writes SDRAM through the
memory-master port, and uses the external bus to reach the device. The
engine's design, its registers and the plan are in [DMA.md](DMA.md); this
section is the carrier's side.

### Signals

| Signal | Direction | Pins | Notes |
|---|---|---|---|
| `DRQ0` | from the 53C80 | 1 | Active high |
| `DRQ1` | from the 82077AA | 1 | Active high |
| `/DACK0`, `/DACK1` | to the chips | 0 | Decoder outputs 4 and 1 |
| `TC` | to both chips | 1 | See below |

That is **three new pins**.

`TC` is shared between the two chips:
* It goes to the 82077AA `TC` (active high) directly.
* It goes to the 53C80 `/EOP` through an inverter.
* Each chip only acts on its terminal-count input while its own `/DACK` is
  asserted, so one pin serves both. **Check:** this is true of the 82077AA
  `TC`.

The 53C80 can also end a transfer without `/EOP`, by clearing its DMA Mode
bit. The 82077AA needs `TC`.

### Bus cycles

One byte takes one external bus cycle, with `/DACK` and `RD#` or `WR#` and
no address. The engine gathers bytes into words and reads memory sixteen
bytes at a time, so the memory-master port sees one transaction per four or
sixteen bytes ([DMA.md](DMA.md#the-memory-side)).

The CPU waits if it accesses the external bus while a DMA cycle is in
progress. It keeps running from the cache and SDRAM.

### Throughput

* **Floppy:** a 1.44 MB disk delivers 62.5 KB/s, or one byte every 16 us.
  That is no load at all.
* **SCSI:** about 1.5 MB/s at best, limited by the bus cycle and the engine's
  wait before it looks at `DRQ` again. The 53C80 itself can do 3 MB/s.

### Registers

At `$0400`, which is unclaimed today: channel 0 at `$0400`, channel 1 at
`$0410`, each with a 24-bit address, a 24-bit count, a control and a status
register. See [DMA.md](DMA.md#registers).

### SCC DMA

**Open.** The SCC's request pins aren't wired.
* Asynchronous serial at 115200 baud is about 11.5 KB/s, which interrupts
  handle easily.
* A third channel would need one more input pin, for `/W//REQA`.

## Interrupts

**Built:** the tick timer, the two DMA channels, the card `IRQ#` and the
emulated SCC share the 65C816's single `IRQ`, through the interrupt status
and mask registers at `$0440` and `$0441` (below). Bit 0 of `$0340` still
reads the card line.

**Proposed:** keep one pin for the cards by wire-ORing their interrupts on the
carrier.

| Source | Polarity | Into the node |
|---|---|---|
| Z85C80 SCC `/INT` | open-drain, active low | directly |
| Z85C80 SCSI `IRQ` | active high | through a 74HC05 open-drain inverter |
| 82077AA `INT` | active high | through a 74HC05 open-drain inverter |
| W5100S `/INT` | active low, push-pull (**Check**) | through a 74HC05 after an inverter, or a diode |

* The node has its own pull-up to 3.3V, so it goes straight to the existing
  pin 19 (`ext_irq_n`) with no level shifter.
* The 74HC05 runs at 5V, but its open-drain outputs only ever pull down.

Software finds the source by reading each chip:
* **SCC:** RR3 on channel A.
* **53C80:** Bus and Status register, bit 4.
* **82077AA:** the main status register, or Sense Interrupt Status for a seek.
* **W5100S:** its interrupt register.

**82077AA in PC/AT mode:** `INT` and `DRQ` stay disabled until bit 3 of DOR
(the DMA gate) is set. **Check.**

**Built:** an interrupt status register at `$0440` with one bit for each
source the FPGA can tell apart, and a mask at `$0441` (`$FF` at reset):

| Bit | Source |
|---|---|
| 0 | the tick timer (`$0450`, `rtl/timer.v`) |
| 1 | DMA channel 0 done |
| 2 | DMA channel 1 done |
| 3 | the card line |
| 4 | the SCC (while it is emulated) |

Bits 5-7 are free for sound, if the SIDs get an interrupt, and ADB, once
it has one. Separating the card sources would need more pins. The register
map is in `fpga/README.md`.

The tick timer replaces the SCC's channel B baud-rate generator as OS16's
clock: on the carrier channel B is a serial port, and the real SCC's
`PCLK` comes from the carrier's oscillator, not the system clock. The
timer is on `IRQ`, not `NMI`, so a tick can't interrupt an IRQ handler.

## Clocks

| Clock | Source | Notes |
|---|---|---|
| FPGA, 27 MHz | onboard crystal | Built: PLL to 25.2 MHz for the system and the pixel clock |
| Z85C80 `PCLK` | oscillator on the carrier | 8 MHz maximum for the parts on hand |
| Z85C80 `/RTxCA`, `/RTxCB` | the same oscillator | Supplies the baud-rate generators |
| 82077AA | 24 MHz crystal or oscillator (**Check**) | |
| W5100S | 25 MHz crystal (**Check**) | |

**Proposed:** one 7.3728 MHz oscillator drives `PCLK` and both `/RTxC` pins.
It is under the 8 MHz limit, and it divides exactly to the standard baud
rates: 115200 is a time constant of 0 at x16.

## Serial

* **Console:** SCC channel A. Until the carrier exists it is emulated in the
  FPGA on the BL616 USB bridge, at 115200 8N1. Once the carrier exists, which
  of the BL616 and the carrier's channel A owns the console is **Open**.
* **SCC channel A, external:** the line drivers are **Open**:
  * RS-232: a MAX232 or MAX3232
  * RS-422, as on the Macintosh: a 26LS31 and 26LS32
* **SCC channel B, internal:** a header at TTL level, or the same drivers.
  **Open.**

## SCSI

* The 53C80 drives the bus directly. Its open-drain outputs sink 48 mA, so
  there are no external drivers.
* The carrier is one end of the bus, so it needs terminators. TERMPWR comes
  from +5V through a diode and a fuse.
* There are two connectors on the one bus: an internal 50-pin IDC header and
  an external connector. **Open:** the external connector type, DB-25 as on
  the Macintosh or Centronics-50.

## Floppy

* The 82077AA drives a 34-pin drive cable for two drives.
* **Check:** whether its drive interface outputs can drive the cable directly.
* 3.5" drives need +5V only.

## Sound

**Built:** two SIDs emulated in the FPGA, played through the board's own
amplifier, with **no new pins**. The emulation is reDIP SID (Dag Lem,
CERN-OHL-S v2) in `fpga/rtl/sid/`; `fpga/rtl/sound.v` connects it, and the
Sound section of `fpga/README.md` has the registers.

The Tang Nano 20K has a MAX98357A I2S amplifier (mono, about 3W) with a
speaker connector:

| Pin | Signal |
|---|---|
| 56 | I2S BCLK |
| 55 | I2S LRCK |
| 54 | I2S DIN |
| 51 | the amplifier's `SD_MODE`, through 0R: high plays the left channel, low shuts it down |

* Pins 54-56 double as the FPGA's SSPI configuration pins; `build.tcl` sets
  "use SSPI as regular I/O".
* I2S from the 25.2 MHz system clock with no PLL: BCLK = 25.2 MHz / 8 =
  3.15 MHz, 64 bits a frame, 49.2 kHz samples, 24-bit words.
* The SID clock is a clock enable of 985248 Hz (PAL) from 25.2 MHz.
* **Mono or stereo**, chosen by a control bit. Mono (the reset state) puts
  the mix of both SIDs in both channels, which is what the onboard amplifier
  plays. Stereo puts SID 1 left and SID 2 right.
* **Resources:** about 2,000 logic cells, 7 block RAMs and 1.5 DSP blocks.
  With it the design uses 70% of the logic and 23 of 46 block RAMs, and
  meets timing at 25.2 MHz with Fmax 35 MHz.

### Stereo on the carrier

I2S carries both channels on the same three lines, and pins 54-56 are on the
edge header as well as at the amplifier. A stereo DAC on the carrier can
therefore share them, with **no new pins**:

* A **PCM5102A** suits: 3.3V, I2S, no master clock (it locks to BCLK, and
  takes 64 bits a frame), line output.
* The control register's stereo bit sends the SIDs to separate channels;
  pin 51 low mutes the onboard speaker meanwhile.

## Ethernet

**Open; proposed:** a WIZnet W5100S on the external bus, select 5.

* The W5100S has a parallel "indirect bus" interface of four registers,
  which fits a 16-byte slot. It needs no FPGA pins: it uses the data bus, two
  address lines, `RD#`, `WR#`, a select and the shared interrupt.
* It does TCP/IP itself (four sockets), so the 65C816 only moves data.
* It runs from 3.3V with 5V-tolerant inputs, so it can sit on either side of
  the level shifters. **Check.**
* It needs a magnetics jack (RJ45 with transformer) and a 25 MHz crystal.

The alternative is a W5500 or ENC28J60 on SPI. With the SD card unused, the
microSD slot's four pins (81-84) are free for that. They are reachable only
through a microSD breakout plugged into the slot, though, and the SPI
controller would have to be built. The W5100S on the bus is simpler.

## ADB

The FPGA side is built (`rtl/adb_host.v`), and the circuit below **works on
a breadboard** with a 2N3904 and an Apple keyboard, which answers Talk
register 3 and types without losing keys. Base: 1kΩ from pin 27 and 1kΩ to
ground; R3 1kΩ to +5V. The keyboard needs the bus idle for a few
milliseconds between transactions, and the controller enforces this (see
`fpga/README.md`).

* **`adb_drive`, pin 27:** an NPN transistor or N-MOSFET that pulls the bus
  low.
  * FPGA high means bus low.
  * The pin has a pull-down, so the bus stays released while the FPGA is
    unconfigured.
* **`adb_sense`, pin 28:** a level shifter from the 5V bus. The pin has no
  pull-up, because one would fight the bus pull-up.
* **Bus pull-up R3:** to +5V. A few kilohms is typical; **Check** the value.
* **Connector:** 4-pin mini-DIN.
  * Pin 1 is data.
  * Pin 2 is power-on, the keyboard power key.
  * Pin 3 is +5V.
  * Pin 4 is ground.
* **Keyboard power-on (Open):** the power key pulls pin 2 low. Nothing reads
  it yet.

## Power

**Open.** The carrier needs a 5V supply of its own, for:
* the Z85C80 and 82077AA
* SCSI TERMPWR
* the ADB bus, and the device's +5V
* the floppy drives, about 1A each while their motors spin up

It also needs 3.3V for the level shifters and the W5100S. That can come from
a regulator on the carrier rather than from the Tang Nano.

Plan on at least 2A at 5V. The Tang Nano can take 5V from the carrier or keep
its USB-C power; the two supplies need a common ground.

## Emulation

The carrier is some way off, so software development carries on with the
devices it needs emulated in the FPGA. **Each emulated device sits at the
address the real one will have**, so software written against it runs on
the real part unchanged.

### SCC (built)

`rtl/scc_85c30.v` emulates enough of the Z85C30 for a polled or interrupt
driven serial console, at `$0820`-`$0823`.
* Channel A is the board's serial port, on the BL616 USB bridge.
* Channel B has no pins.

It has the real part's register pointer, its three-byte receive FIFO, the
transmit buffer, the Rx and Tx interrupts, RR3, and the vector in RR2. It
runs at a fixed 115200 baud whatever the time constant says. The module's
header lists what is left out.

* It does **not** enforce the recovery time. Software that goes faster than
  the real chip allows still works here; the bridge will enforce the
  recovery time on the real part.
* The access never reaches the external bus pins.
* It replaced the 6551 ACIA, which has been removed.

MiniMon, Business Basic, Rockwell Forth and the test ROMs use it.
em16 (65Tools) emulates the SCC as well (`EmSCC.Mod`), so Business Basic's
test suite runs against it.

em16 also emulates the carrier's disk controllers at the addresses above, for
polled drivers to be written before the carrier exists:
* the 82077AA at `$0800` (`Em82077.Mod`), with two floppy drives (`-disk0`,
  `-disk1`)
* the 53C80 at `$0830` (`EmSCSI.Mod`), with a disk at SCSI ID 0 (`-scsi`)

Both can also move their data by DMA, with the SoC's engine (`EmDMA.Mod`).
em16 has the tick timer and `$0440` as well (`EmTimer.Mod`). The 65Tools
README covers the disks under "Disks under -fpga".

### Later

The same approach suits the other carrier devices if software needs them
before the board: a 53C80 in front of a disk image in SDRAM, for instance.
Nothing is planned yet.

## Pins

The pins come from the Sipeed schematic (revision 3923) and from measurements
on this board. The Source column says which.

Sources:
* **Board:** measured on this board.
* **Sch:** read from the schematic.
* **Built:** in the current `.cst`.
* **Proposed:** a change from the current `.cst`.

### Unchanged

| Pin | Signal | Source | Notes |
|---|---|---|---|
| 4 | `clk`, 27 MHz | Built | |
| 87 | `rst`, button S1 | Built, Board | Active **high** |
| 20 | `led` | Built | The one LED left |
| 69, 70 | `uart_tx`, `uart_rx` | Built | To the BL616 |
| 33-40 | HDMI, four TMDS pairs | Built | |
| 27 | `adb_drive` | Built, Board | LCD B7 on the schematic; nothing else on it |
| 28 | `adb_sense` | Built, Board | LCD B6 on the schematic; nothing else on it |
| 29, 30, 41, 42, 48, 77 | `ext_d[1:5]`, `ext_d[7]` | Built | LCD connector and header only |
| 15-18 | `ext_a[3:0]` | Built | LED0-LED3, also LCD connector pins 37-40 (touch) |
| 75 | `ext_wr_n` (`WR#`) | Built, Sch | BL616 SPI MISO |
| 76 | `ext_rd_n` (`RD#`) | Built, Sch | BL616 SPI MOSI |
| 86 | `ext_res_n` | Built, Sch | BL616 SPI DIR |
| 19 | `ext_irq_n` | Built | LED4 |

The BL616 is connected to the FPGA on pins 13, 75, 76 and 86 (its SPI link) as
well as the UART.
* Pins 75, 76 and 86 are free only while the BL616 firmware leaves that link
  idle. If a card misbehaves as though something else were driving it, suspect
  this first.
* The BL616's boot strap is its own GPIO 2, with a button, not pin 75.

### Changed or new

| Pin | Signal | Source | Was | Why |
|---|---|---|---|---|
| 31 | `ext_d[0]` | Sch, Proposed | unused | It moves here from pin 25. |
| 25 | **unused** | Sch | `ext_d[0]` | It goes to HDMI CEC through 100R, with a 27k pull-up. With a monitor connected, the monitor sits on data bit 0. |
| 49 | `ext_d[6]` | Sch | unchanged | This is the LCD backlight boost enable. Whenever the bit is high the boost converter runs with no load. **Check:** the converter tolerates an open load, or move this bit too. |
| 71, 72, 73 | `ext_sel[2:0]`, the select code | Sch, Built | `ext_sel_n[2:0]` | Header only. They carry HSPI labels but don't reach the BL616. |
| 74 | `ext_sel_en_n`, the select enable | Sch, Built | `ext_sel_n[3]` | Header only |
| 79 | `dma_drq[0]`, SCSI | Sch, Built | unused | The WS2812 LED, with a 5.1k pull-down. The pull-down suits an active-high input. The LED may flicker during DMA. |
| 80 | `dma_drq[1]`, floppy | Sch, Built | unused | SD D2, with a 10k pull-up. Free, because the SD card isn't used. |
| 85 | `dma_tc` | Sch, Built | unused | SD D1, with a 10k pull-up. Free for the same reason. |
| 51, 54, 55, 56 | sound | Sch, Proposed | unused | The onboard I2S amplifier. See [Sound](#sound). |

### Spare or not usable

| Pin | Status |
|---|---|
| 81-84 | Spare: the microSD slot, now unused. Reachable only through a microSD breakout in the slot. |
| 52, 53 | Spare, with care: HDMI DDC, with 2.2k pull-ups, and the monitor is on the lines. |
| 32 | Spare, with difficulty: LCD connector only. It needs an FPC breakout, and FPC pins 1-2 carry the backlight boost output. |
| 26 | Not usable: HDMI hot-plug detect, 2.2k to the connector and 5.1k to ground. It reads low without a monitor asserting hot-plug, which was the cause of the spurious ADB SRQ. It is usable only as that input. |
| 13 | Not usable: BL616 SPI clock. |

That accounts for 23 external-bus and DMA pins, up from 20, and four for sound.
Six spare pins remain: four through the microSD slot and two on the DDC lines.

## PCB requirements

Everything the carrier board has to provide, in one list. Each line refers
to the section that explains it.

### Connection to the Tang Nano

- [ ] Sockets for the Tang Nano 20K's two edge headers. Every FPGA signal in
      [Pins](#pins) except the microSD slot comes through them.
- [ ] A common ground with the Tang Nano, and a decision on whether the
      carrier powers it ([Power](#power)).
- [ ] Clearance for the HDMI, USB-C and speaker connectors and the microSD
      slot.

### Power

- [ ] A 5V supply of at least 2A, for the chips, SCSI TERMPWR, ADB and two
      floppy drives.
- [ ] 3.3V for the level shifters and the W5100S, from a regulator on the
      carrier.
- [ ] Decoupling on every chip, and bulk capacitance by the floppy power
      connector.
- [ ] A fuse and diode on SCSI TERMPWR.

### Level shifting and bus buffering

- [ ] A 74LVC245 on `ext_d[7:0]`. `DIR` comes from `RD#` and `/OE` from the
      select enable.
- [ ] A 74HCT541 (or similar) on the FPGA outputs: `ext_a[3:0]`, `RD#`,
      `WR#`, `RES#` and `TC`.
- [ ] A 74LVC125 or 74LVC244 on the inputs to the FPGA: `DRQ0` and `DRQ1`.
- [ ] No 5V signal reaches an FPGA pin anywhere.

### Select decoding

- [ ] A 74HCT138: the select code on A-C, the select enable on `/G2A`, and
      `G1` tied high ([Select decoding](#select-decoding-proposed-change)).
- [ ] Pull-ups on the 5V side for every select, `RD#` and `WR#`.

### Interrupts and DMA

- [ ] A 74HC05 for the interrupt wire-OR: open-drain inverters for the
      SCSI `IRQ` and the floppy `INT`, and whatever the W5100S `/INT` needs
      ([Interrupts](#interrupts)).
- [ ] A pull-up to 3.3V on the interrupt node, which goes to pin 19.
- [ ] `DRQ0` (53C80) and `DRQ1` (82077AA) to pins 79 and 80, through the
      LVC buffer.
- [ ] Pull-downs on both `DRQ` inputs to the buffer, on the 5V side: the
      82077AA tristates `DRQ` while its DMA gate is off ([DMA.md](DMA.md)).
- [ ] `TC` from pin 85 to the 82077AA `TC`, and through an inverter to the
      53C80 `/EOP`.
- [ ] Decoder outputs 1 and 4 to the 82077AA and 53C80 `/DACK`.

### Z85C80

- [ ] A 68-pin PLCC socket.
- [ ] A 7.3728 MHz oscillator to `PCLK`, `/RTxCA` and `/RTxCB`.
- [ ] `/INTACK` pulled up.
- [ ] Pull-ups on `/W//REQA` and `/W//REQB`, or leave them unconnected.
- [ ] `/RESET` (SCSI) from `RES#`.
- [ ] `D//C` to `ext_a[0]`, `A//B` to `ext_a[1]`, SCSI A2-A0 to
      `ext_a[2:0]`.
- [ ] Channel A: line drivers and the external connector (**Open**: RS-232
      or RS-422).
- [ ] Channel B: the internal header, at TTL level or with drivers (**Open**).
- [ ] The modem lines (`/CTS`, `/DCD`, `/RTS`, `/DTR`) to the connectors, or
      tied inactive.

### SCSI

- [ ] An internal 50-pin IDC header and an external connector (**Open**:
      DB-25 or Centronics-50), on the same bus.
- [ ] Termination at the carrier end, active or 220/330 passive.
- [ ] TERMPWR from +5V through a diode and a fuse.
- [ ] The 53C80's bus pins wired straight to the connectors. Its outputs
      drive the bus directly.

### Floppy

- [ ] An 82077AA, in a 68-pin PLCC socket.
- [ ] A 24 MHz crystal or oscillator (**Check**).
- [ ] `RESET` from `RES#` through an inverter (**Check** the polarity).
- [ ] A2-A0 to `ext_a[2:0]`.
- [ ] A 34-pin drive header for two drives, and drive power connectors.
- [ ] Whatever the drive interface needs between the 82077AA and the cable
      (**Check**).

### Ethernet

- [ ] A W5100S, in indirect bus mode, on select 5. A1-A0 to `ext_a[1:0]`.
- [ ] A 25 MHz crystal (**Check**).
- [ ] An RJ45 jack with integrated magnetics.
- [ ] `/RESET` from `RES#`, and `/INT` into the interrupt node.

### ADB

- [ ] A transistor from pin 27 that pulls the ADB line low when the pin is
      high ([ADB](#adb)).
- [ ] A level shifter from the ADB line to pin 28.
- [ ] The bus pull-up, R3, to +5V (**Check** the value).
- [ ] A 4-pin mini-DIN: data, power key, +5V, ground.
- [ ] The power key line brought to somewhere it can be read, if keyboard
      power-on is wanted (**Open**).

### Test and bring-up

- [ ] A header carrying the external bus signals for a logic analyser:
      data, address, the select code and enable, `RD#`, `WR#`, `IRQ#`, `DRQ`
      and `TC`.
- [ ] Test points on 5V, 3.3V and ground.
- [ ] Jumpers or 0R links to isolate each chip's interrupt and DMA lines.

### Stereo audio (optional)

- [ ] A PCM5102A stereo DAC on the I2S lines from the edge header: BCLK
      (56), LRCK (55), DIN (54). Its SCK pin tied low, so it locks to BCLK
      ([Stereo on the carrier](#stereo-on-the-carrier)).
- [ ] Line-out jack, with the DAC's recommended output filter.

### Not on the carrier

- Mono sound uses the Tang Nano's own amplifier and speaker connector.
- The SD card is not used.

## Still to do

1. Run a continuity check on the board for pins 25, 26, 31, 49, 71-76, 79, 80,
   85 and 86, and turn **Sch** into **Board** in the tables.
2. Confirm the **Check** items against the datasheets:
   * the Z85C80 8 MHz grade's bus timing
   * the 82077AA's reset polarity, its crystal, whether `TC` is qualified by
     `/DACK`, the DOR bit 3 gating, its drive outputs, and its bus timing
   * the W5100S's bus timing, its `/INT` output, its 5V tolerance and its
     crystal
3. Decide the **Open** items: serial line drivers, the console's home once
   the carrier exists, the external SCSI connector, power, SCC DMA, and
   whether to build the Ethernet as proposed.
4. RTL changes:
   * ~~Intel-only `external_bus.v` at the 8 MHz timing, with the SCC
     recovery hold-off~~ (done)
   * ~~select code and enable~~ (done)
   * ~~the SCC reset on `RES#`~~ (done)
   * ~~the DMA engine and its multiplexer on the memory-master port~~ (done)
   * ~~the interrupt register~~ (done, with the tick timer)
   * the `.cst` pin moves
