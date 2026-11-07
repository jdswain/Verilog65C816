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
* **Drawn**: in the dev board's KiCad schematic (github.com/jdswain/65-16),
  which is the carrier as it is being built.

## Summary

| Function | Part | Where | Status |
|---|---|---|---|
| CPU, cache, 8 MB SDRAM, boot ROM | 65C816 core, GW2AR-18 | FPGA | Built |
| Video, 640x480 HDMI, text and 16-colour graphics | | FPGA | Built |
| Blitter | | FPGA | Built |
| Console serial | Z85C30 SCC channel A | Emulated in the FPGA on the BL616 USB bridge; the real chip's port A is the modem Mini-DIN-8 | Emulation built; it replaced the ACIA |
| Keyboard and mouse | ADB host | FPGA, plus a transistor and a divider | Working on a breadboard; Drawn |
| Two serial ports, Mac Mini-DIN-8s at RS-422/423 levels | Z85C80 SCC half, a 26C31 and two 26C32s | Carrier | Drawn |
| SCSI, an internal 50-pin header and an external DB-25 | Z85C80 SCSI half (53C80) | Carrier | Drawn |
| Floppy, one 34-pin header for two drives, 2.88 MB capable | 82077AA | Carrier | Drawn |
| DMA, two channels | | FPGA | Built; untested on the board |
| Interrupt status and mask | | FPGA | Built |
| Tick timer, the operating system's clock | | FPGA | Built |
| Sound, two SIDs | reDIP SID emulation | FPGA, onboard I2S amplifier; stereo DAC optional on the carrier | Built |
| Ethernet | ENC424J600, parallel mode 5 | Carrier, on the external bus, select 5 | Drawn |
| SD card, a test boot device | `sd_spi.v`, SPI mode | The Tang Nano's microSD slot | Built; untested on the board |
| Power | 24-pin ATX header; +5V, +3.3V, +12V, -12V from the supply | Carrier | Drawn |
| Encryption engine, keyboard power-on | | | Open |

The TIM bus as such is not implemented, but the carrier has one slot in the
Apple II form carrying the Intel bus, for test points and cards built for it;
see [Slot](#slot).

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
except the ENC424J600 runs from 5V: the Z85C80, the 82077AA, the ADB bus and
the floppy drives. No 5V signal may reach an FPGA pin directly.

| Signal group | Direction | Part | Notes |
|---|---|---|---|
| `ext_d[7:0]` | both ways | 74LVC245A at 3.3V (SN74LVC245AN is DIP-20) | Its inputs are 5V tolerant, and its 3.3V output meets the 5V chips' input high level (2.0-2.2V). `DIR` comes from `RD#` and `/OE` from the select enable, both on the FPGA side. Neither needs a pin. |
| `ext_a[3:0]`, `RD#`, `WR#`, `RES#`, `TC` | FPGA to carrier | 74HCT541 at 5V (74AHCT541 for less delay) | HCT inputs accept 3.3V, and the outputs swing a full 5V. The eight signals fill it. It also protects the FPGA pins. |
| Select code and enable | FPGA to carrier | 74HCT138 at 5V | It shifts and decodes in one part. |
| `DRQ0`, `DRQ1` | carrier to FPGA | 74LVC125A at 3.3V | Inputs are 5V tolerant. |
| `adb_sense` | carrier to FPGA | A 10k/15k divider with a BAT54S clamp to 3.3V (Drawn) | 3.0V at a 5V high, so the clamp never conducts. A 74LVC1G17, whose Schmitt input suits the slow edges of a pulled-up ADB cable, is the alternative if they prove a problem; the pin can also take `HYSTERESIS=HIGH`. See [ADB](#adb). |
| `adb_drive` | FPGA to bus | 2N3904 | See [ADB](#adb). |
| `ext_irq_n` | carrier to FPGA | Open-drain node pulled up to 3.3V | See [Interrupts](#interrupts). It needs no shifter. |

Nothing else crosses between 3.3V and 5V:
* The I2S lines to a PCM5102A are 3.3V at both ends.
* The ENC424J600 runs at 3.3V on the 5V side of the bus. Its parallel-port
  pins are 5V tolerant inputs, and its data pins drive 3.3V on reads, which
  the 74LVC245 reads as a high (DS39935C, section 5.1).
* The serial ports are RS-422/423 through a 26C31 and two 26C32s at 5V, with
  the handshake inputs inverted into the SCC by 74HC05 gates. Nothing there
  reaches the FPGA.
* The floppy cable needs no drivers: with `INVERT` tied to ground the
  82077AA's own 40 mA outputs and receivers drive it. The drive's
  open-collector outputs need pull-ups (typically 1k).

**Hold the carrier idle while the FPGA is unconfigured.** The FPGA pins float
until it is configured, and the '541 and '138 drive their outputs from
whatever they see, so a pull-up on the 5V side would do nothing. The
resistors go on the FPGA side, at the buffer and decoder inputs:
* Pull-ups to 3.3V on `RD#`, `WR#` and the select enable. The enable also
  turns the 74LVC245 off.
* A pull-down on `RES#`, so the cards sit in reset until the FPGA runs.
* A pull-down on `TC`.

Never pull an FPGA-side net to 5V.

**Check: a short bus fight at the end of a read.** `RD#` rises one system
clock (40 ns) before the select enable is released. For that time `DIR` has
already turned the 74LVC245 towards the cards while the card's outputs are
still turning off. It is brief and usually harmless. Gating `/OE` so the
buffer is enabled only while a strobe is low would remove it.

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
Z85C80, and the ENC424J600 in its parallel mode 5.

### Timing

The bridge counts in a bus clock T of at least 119 ns (8.4 MHz) and an edge
gap of at least 40 ns, each a whole number of system clocks. At the 45 MHz
system clock T is 6 clocks, 133 ns, and the gap is 2 clocks, 44 ns. No
clock goes to the cards, because Intel-bus parts don't need one. T is only
the unit the bridge counts in.

| Step | When | Notes |
|---|---|---|
| Address, select code, write data out | start of T1 | |
| Select enable asserted | T1 + 40 ns or more | The decoder outputs settle before the enable |
| `RD#` or `WR#` falls | start of T2 | One T of address and select setup |
| Read data sampled | last system clock of T3 | |
| Strobe rises | end of T3 | Strobe width 2T, 266 ns at 45 MHz |
| Enable released, then address | 40 ns or more after the strobe | Hold |

A cycle takes about 480 ns from the address going out to the data released (it took 1-2 us with the 6502-style bus); the CPU sees about 560 ns.

The timing against the Z85C30's 10 MHz figures:
* Address setup: 50 ns needed, 119 ns given.
* `/RD` low width: 125 ns needed, 238 ns given.
* `/RD` to data valid: 120 ns, sampled at about 230 ns.
* Address to data valid: 180 ns, sampled at about 350 ns.

The 8 MHz grade will be somewhat slower, and the level shifters add 5-20 ns
each way. **Check** the 8 MHz figures, and the 82077AA and 53C80 figures,
against this table. The ENC424J600's parallel-port timings are all under
10 ns bar a 75 ns read access (DS39935C, Table 17-10), so it is not the limit.

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
| 5 | ENC424J600 `CS`, through the glue that makes it active high |
| 6 | the slot's `/DEVSEL` |
| 7 | the slot's `/IOSEL` |

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
| ENC424J600 | `$0850` | `ext_a[0]` picks the address latch or data; `ext_a[1]` is `AD8` | +0 write: address low byte with `AD8` = 0 (the SFRs, from 7E00h); +2 write: address low byte with `AD8` = 1 (from 7F00h); +1 and +3 read/write: data at the latched address. See [Ethernet](#ethernet). |

`ext_a[3]` is spare.

### Reset

| Chip | Reset input | Wiring |
|---|---|---|
| Z85C80 SCSI | `/RESET`, active low | from `RES#` through the HCT buffer |
| 82077AA | `RESET`, active high | `RES#` through a 74HCT04 gate |
| Z85C80 SCC | none | `/RD` and `/WR` asserted together |
| ENC424J600 | none: power-on reset, and a software reset through ECON2 | — |

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
* It goes to the 53C80 `/EOP` through a 74HCT04 gate.
* Each chip only acts on its terminal-count input while its own `/DACK` is
  asserted, so one pin serves both. The 82077AA datasheet says so of its
  `TC`, which is active high in AT mode.

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

**Drawn:** one pin for the cards, their interrupts wire-ORed on the carrier,
each through a jumper that can take it off the line.

| Source | Polarity | Into the node |
|---|---|---|
| Z85C80 SCC `/INT` | open-drain, active low | directly |
| Z85C80 SCSI `IRQ` | active high | through a 74HC05 open-drain inverter |
| 82077AA `INT` | active high | through a 74HC05 open-drain inverter, with a pull-down at its input |
| ENC424J600 `/INT` | active low, push-pull; the pin doubles as the `SPISEL` strap, pulled down 100k | through a 74LVC1G07 open-drain buffer |
| the slot's `/IRQ` | open collector from the card | through an SS14 Schottky, anode on the node |

* The node has its own pull-up to 3.3V, so it goes straight to the existing
  pin 19 (`ext_irq_n`) with no level shifter.
* The 74HC05 runs at 5V, but its open-drain outputs only ever pull down.
* The 82077AA tristates `INT`, as it does `DRQ`, while its DMA gate is off in
  AT mode. The pull-down keeps the 74HC05 input from floating.
* An inverting '05 gate can't take the ENC424J600's active-low push-pull
  output, hence the non-inverting open-drain buffer. A diode would not do
  either: with the node pulled up to 3.3V it would forward-bias into the
  100k pull-down on `INT/SPISEL` and the chip would latch SPI mode at
  power-up.
* There is no priority encoder. A 74HC148 would need three more input pins,
  and none are free. Software reads each chip, as below.

Software finds the source by reading each chip:
* **SCC:** RR3 on channel A.
* **53C80:** Bus and Status register, bit 4.
* **82077AA:** the main status register, or Sense Interrupt Status for a seek.
* **ENC424J600:** EIR.

**82077AA in PC/AT mode:** `INT` and `DRQ` are tristated until bit 3 of DOR
(the DMA gate) is set; confirmed in the Intel datasheet's DOR description.
The carrier pulls both down.

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
| FPGA, 27 MHz | onboard crystal | Built: one PLL to the 45 MHz system clock, another to the 25.2 MHz pixel clock |
| Z85C80 `PCLK` | oscillator on the carrier | 8 MHz maximum for the parts on hand |
| Z85C80 `/RTxCA`, `/RTxCB` | the same oscillator | Supplies the baud-rate generators |
| 82077AA | 24 MHz parallel-resonant fundamental crystal, or a MOS-level clock on X1 with X2 open (Intel datasheet) | Drawn: a crystal with 22 pF |
| ENC424J600 | 25 MHz parallel-resonant crystal, ±50 ppm total, or a 3.3V clock on OSC1 (DS39935C, section 2.1) | Drawn: a crystal with 22 pF; **Check** the load capacitance against the crystal chosen |

**Decided:** one 7.3728 MHz oscillator drives `PCLK` and both `/RTxC` pins.
It is under the 8 MHz limit, and it divides exactly to the standard baud
rates: 115200 is a time constant of 0 at x16.

**No AppleTalk.** LocalTalk's DPLL clock is 16 times 230.4 kbit/s, which is
3.6864 MHz on `/RTxC`, and 7.3728 MHz can't give it: directly it is twice
that, and through the baud-rate generator (at most a quarter) it is half.
Networking will be Ethernet (see [Ethernet](#ethernet)), so the IIgs
crystal is not needed. The connectors and drivers drawn are LocalTalk-capable;
only the clock is not.

With an oscillator on `/RTxCA` there is no crystal, so WR11 bit 7 (RTxC
Xtal/No Xtal) stays 0, as OS16's serial driver writes it. `/SYNCA` is then an
input that only sets the Sync/Hunt bit in RR0, so **pull `/SYNCA` up** (10k)
rather than leave it floating. `SYNCB` is grounded inside the Z85C80.

## Serial

The SCC is kept because it comes in the Z85C80 with the SCSI controller,
and it needs no FPGA pins of its own: it is on the shared bus, with a select
code and the wired-OR interrupt. Its uses are small: a serial console that
does not depend on the BL616, slow data transfer (115200 baud is about
11 KB/s; Ethernet does this better), and perhaps a vintage serial printer.
The oscillator is the one part the chip needs to run at all: a 7.3728 MHz
DIP-8 can (Drawn).

**Drawn:** both channels on Mac-pinout Mini-DIN-8s at RS-422/423 levels, so
every Macintosh modem, printer and RS-232 adapter cable fits. Channel A is
the modem port, channel B the printer port.

| Pin | Mac name | Wired to |
|---|---|---|
| 1 | `HSKo` | a 26C31 driver's inverting output, fed by `/RTS`: RTS asserted puts the positive level on the line |
| 2 | `HSKi` | a 26C32 receiver against ground, inverted by a 74HC05 gate into `/CTS` (the shared `/TRxC` pin, so it can also be an external clock) |
| 3 | `TxD-` | the inverting output of the TxD driver pair |
| 4 | ground | |
| 5 | `RxD-` | the receiver's B input |
| 6 | `TxD+` | the non-inverting output of the TxD driver pair |
| 7 | `GPi` | a receiver against ground, inverted by a 74HC05 gate into `/DCD` |
| 8 | `RxD+` | the receiver's A input |

* One 26C31 drives both ports; each port has a 26C32, with one receiver
  spare.
* With A on `RxD+` and B on `RxD-`, an RS-232 adapter cable (which grounds
  `RxD+` and puts the device's TxD on `RxD-`) reads mark when idle.
* 10k bias on every input: `RxD+`, `HSKi` and `GPi` up, `RxD-` down, so an
  unplugged port reads idle with CTS and DCD asserted. The 10k pull-ups on
  `/CTS` and `/DCD` are the '05 gates' loads.
* `/DTR//REQ` and `/W//REQ` are not connected.
* **Console:** the BL616 USB bridge, through the FPGA's emulation of channel
  A, at 115200 8N1. The real channel A is the console when a real serial
  port is wanted.

## SCSI

* The 53C80 drives the bus directly. Its open-drain outputs sink 48 mA, so
  there are no external drivers.
* **Drawn:** two connectors on the one bus, an internal 50-pin IDC header in
  the SCSI-1 ribbon pinout (odd pins ground) and an external DB-25 in the
  Apple pinout. **Check** the DB-25 table on the schematic against an Apple
  SCSI cable before fabrication.
* With two connectors the carrier is an end of the bus only while one of
  them is in use, so its terminators are four socketed 220/330 SIP packs:
  fitted then, pulled when both internal and external devices are attached
  and the far devices terminate.
* TERMPWR comes from +5V through a 1.1 A polyfuse and a Schottky to both
  connectors and the packs, with 10 µF on it.

## Floppy

**Drawn**, from the Intel datasheet's PC/AT design (section 9):

* One 34-pin header in the PC pinout, odd pins ground, for a twisted PC
  cable: the drive beyond the twist is drive 0 (`DS0`, `ME0`), the one
  before it drive 1 (`DS1`, `ME1`).
* PC/AT mode: `IDENT` high with `MFM` open (it has an internal pull-up),
  `INVERT` low so the chip's 40 mA outputs and its receivers serve the cable
  directly (confirmed: no external drivers), `PLL0` high (floppy, not tape),
  `DRV2` pulled up, `TC` active high, `/DACK` from decoder output 1.
* 1k pull-ups on the five drive inputs, the datasheet's value for 3.5"
  drives (150R suits 5.25" open-collector drives).
* A 24 MHz crystal with 22 pF, and 4.7 nF between `HIFIL` and `LOFIL`.
* 2.88 MB: the chip's 1 Mbps rate needs nothing more. `DENSEL` reaches the
  header through a three-pin jumper, either as the chip drives it (high for
  500k/1M, the 5.25" sense) or inverted through a spare 74HCT04 gate (the
  3.5" sense). `DRATE0/1` can reach the header's spare pins 4 and 6 through
  solder jumpers, for ED drives that want a rate signal; most sense the
  media.
* Two 4-pin drive power headers (+5V, two grounds, +12V unused) with 10 µF
  bulk. 3.5" drives need +5V only.

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
* I2S from the system clock with no PLL of its own: BCLK = 45 MHz / 8 =
  5.625 MHz, 64 bits a frame, 87.9 kHz samples, 24-bit words.
* The SID clock is a clock enable of 985248 Hz (PAL) from the system clock.
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

**Drawn:** a Microchip ENC424J600 (10/100 MAC and PHY with a 24 KB packet
buffer, 44-pin TQFP) on the external bus, select 5. It replaces the W5100S
proposed earlier. Source: DS39935C.

* **Parallel mode 5.** The 44-pin part offers only its parallel modes 5 and
  6, both 8-bit with the address multiplexed onto the data pins and latched
  inside the chip by an `AL` strobe. The SFR space needs nine address bits,
  `AD<8:0>`, and the buffer is reached through the auto-incrementing
  `EGPDATA`, `ERXDATA` and `EUDADATA` windows in that space, so `AD<14:9>`
  are tied high and a 16-byte slot is enough: it needs no FPGA pins, like
  the W5100S it replaces.
* **Register map** in slot 5: `$0850` write = the address low byte with
  `AD8` = 0 (SFRs from 7E00h); `$0852` write = the address low byte with
  `AD8` = 1 (from 7F00h); `$0851` and `$0853` read or write = data at the
  latched address. `AD8` is simply `ext_a[1]` during the address write; the
  latch keeps the address until the next `AL`, so back-to-back data accesses
  need no new address cycle.
* **Glue.** The chip's `RD`, `WR`, `AL` and `CS` are active high, so a
  74HCT02 makes `RD = NOR(RD#, A0#)`, `WR = NOR(WR#, A0#)`,
  `AL = NOR(WR#, A0)` and `CS = NOT(ETH_CS#)`, with `A0#` from a spare
  74HCT04 gate. `PSPCFG0` low selects mode 5; `INT/SPISEL` pulled down 100k
  selects the parallel port at power-up.
* **Levels.** It runs from the 3.3V rail; its parallel-port pins are 5V
  tolerant inputs and the data pins drive 3.3V on reads (section 5.1), so it
  sits on the 5V side of the bus with no shifting of its own.
* **Interrupt:** `/INT` is push-pull and shares the `SPISEL` strap, so it
  goes to the node through a 74LVC1G07 open-drain buffer and a jumper
  ([Interrupts](#interrupts)).
* **Parts:** a 25 MHz crystal with 22 pF, 12.4k 1% on `RBIAS`, 10 µF low-ESR
  on `VCAP`, 100 nF on each of the five supply pairs and 1 nF across the PLL
  and TX pairs, and the magnetics of the datasheet's Figure 2-5: 49.9R 1%
  from each `TPOUT` and `TPIN` to its common node, 10R to 3.3V on the TX
  centre tap, 6.8 nF in series with each `TPIN`, 10 nF on both common nodes,
  into a HanRun HR911105A jack with the transformers, the 75R common-mode
  network and two LEDs inside. **Check** the jack's LED pin polarity.
* **Software:** unlike the W5100S it has no TCP/IP of its own; the 65C816
  runs the stack. em16 does not emulate it.

The alternative was its SPI port, on the microSD slot's SPI lines with a
spare pin as chip select. It was rejected: the slot's four pins (81-84) are
not on the edge headers, and the only spare pins are the DDC level-shifter
side (52, 53), CEC (25) and the LED (20), three of which share wires with
the monitor.

## Slot

**Drawn:** one 50-pin slot in the Apple II form, kept for test points and for
cards built for this bus; it costs little. It carries the Intel bus on the 5V
side:

| Slot pin | Signal |
|---|---|
| 42-49 | `D7`-`D0`, the Apple order |
| 2-5 | `A0`-`A3` |
| 41 `/DEVSEL` | decoder select 6, `$0860` |
| 1 `/IOSEL` | decoder select 7, `$0870` |
| 18 `R/W` | `WR#`: high for reads and idle, low during a write. True 6502 timing would need `R/W` held either side of a clock, which the two strobes cannot give without a latch and a delayed `PHI0`; at this bus speed no 6500-family part would keep up anyway |
| 35, 36 | the raw `RD#` and `WR#`, on the `COLORREF` and `7M` positions, which no I/O card uses |
| 31 `/RES` | `RES#` |
| 30 `/IRQ` | into the interrupt node through an SS14, anode on the node: a card may only pull it down |
| 27, 28 `DMA IN`, `INT IN` | pulled up 3k3, as a lone slot has no neighbour |
| 25, 26, 33, 50 | +5V, ground, -12V, +12V |

`PHI0`, `RDY`, `/NMI`, `/DMA`, `/INH`, `-5V` and the clocks are not
connected. A 68881 on a card would need its `DSACK` handshake honoured, which
means a wait input into the bridge; `RDY` is wired to nothing because no FPGA
pin is spare for it, and one of the DDC pins is the only candidate.

## SD card

The Tang Nano's microSD slot, in SPI mode, as a test boot device. The
controller is `rtl/sd_spi.v` at `$02C0`; its registers are in
`fpga/README.md`. It needs nothing on the carrier.

| SD signal | SPI use | Pin |
|---|---|---|
| CLK | SCLK | 83 |
| CMD | MOSI | 82 |
| D0 | MISO, pulled up in the FPGA | 84 |
| D3 | chip select | 81 |
| D1 | not used in SPI mode | 85, `dma_tc` |
| D2 | not used in SPI mode | 80, `dma_drq[1]` |

**D1 and D2 are shared with DMA, and that is safe with a card in the slot.**
A card in SPI mode neither drives nor reads its D1 and D2, so `TC` (an
output) and `DRQ1` (driven by the carrier's 74LVC125A) only see the card's
input load and the board's 10k pull-ups. Before SPI mode a card is in SD
mode, where it drives its data lines only in reply to a data command. The
first command it gets is CMD0 with chip select low, which puts it in SPI
mode. **Check** on the board: a floppy DMA transfer with a card in the slot.

4-bit SD mode would need D1 and D2 as well, and there are no pins to move
DMA to. SPI at 22.5 MHz is over 2 MB/s on the wire; a CPU loop reading a
block is the limit.

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
* **`adb_sense`, pin 28:** drawn as a 10k/15k divider from the bus, 3.0V at
  a 5V high, with a BAT54S clamp to 3.3V. A 74LVC1G17, whose Schmitt input
  suits the slow edges, is the alternative. The pin has no pull-up, because
  one would fight the bus pull-up.
* **Bus pull-up:** 470R to +5V (drawn), as Apple's host has it; the
  breadboard ran with 1k.
* **Connector:** 4-pin mini-DIN.
  * Pin 1 is data.
  * Pin 2 is power-on, the keyboard power key.
  * Pin 3 is +5V.
  * Pin 4 is ground.
* **Keyboard power-on (Open):** the power key pulls pin 2 low. Nothing reads
  it yet.

## Power

**Drawn:** a 24-pin ATX header, for a picoPSU off a 12V brick or any SFX or
ATX supply. The supply provides every rail, so the carrier has no regulator:

| Rail | For |
|---|---|
| +5V | the Z85C80, 82077AA and logic, the serial drivers, ADB, SCSI TERMPWR, the floppy drives, and the Tang Nano |
| +3.3V | the level shifters, the ENC424J600 and the FPGA-side pull-ups |
| +12V | a disk-drive power connector and the slot |
| -12V | the slot |

The budget at 5V is about 2A typical and 3 to 4A with two floppies spinning
up (the Tang Nano 0.3 to 0.5A, chips and logic 0.3A, ADB up to 0.5A,
TERMPWR up to 0.9A, two drives 1.5A at spin-up); 12V is drawn only by a
vintage SCSI disk. `PS_ON#` goes to a two-pin header: a shunt for always-on,
or a switch.

**The Tang Nano's 5V pin is USB VBUS itself.** Measured on the board with
only USB connected: 5.18V, with no diode on the Tang Nano. The carrier
therefore feeds that pin through a Schottky and a jumper: with USB plugged in
the host's higher voltage powers the Tang Nano and the diode stays off, so
nothing flows back into the carrier rail; with USB unplugged the carrier
feeds it at about 4.7V, which its 3.3V buck regulator (MT3520B) is happy
with. Pulling the jumper leaves the Tang Nano on USB alone during bring-up.
The Tang Nano's own 3.3V output is not used.

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
| 31 | `ext_d[0]` | Sch, Built | unused | It moved here from pin 25. |
| 25 | **unused** | Sch | `ext_d[0]` | It goes to HDMI CEC through 100R, with a 27k pull-up. With a monitor connected, the monitor sits on data bit 0. |
| 49 | `ext_d[6]` | Sch | unchanged | This is the LCD backlight boost enable. Whenever the bit is high the boost converter runs with no load. **Check:** the converter tolerates an open load, or move this bit too. |
| 71, 72, 73 | `ext_sel[2:0]`, the select code | Sch, Built | `ext_sel_n[2:0]` | Header only. They carry HSPI labels but don't reach the BL616. |
| 74 | `ext_sel_en_n`, the select enable | Sch, Built | `ext_sel_n[3]` | Header only |
| 79 | `dma_drq[0]`, SCSI | Sch, Built | unused | The WS2812 LED, with a 5.1k pull-down. The pull-down suits an active-high input. The LED may flicker during DMA. |
| 80 | `dma_drq[1]`, floppy | Sch, Built | unused | SD D2, with a 10k pull-up. A card in SPI mode doesn't use it; see [SD card](#sd-card). |
| 85 | `dma_tc` | Sch, Built | unused | SD D1, with a 10k pull-up. The same. |
| 81, 82, 83, 84 | SD card: chip select, MOSI, SCLK, MISO | Sch, Built | unused | The microSD slot's D3, CMD, CLK and D0, in SPI mode. See [SD card](#sd-card). |
| 51, 54, 55, 56 | sound | Sch, Built | unused | The onboard I2S amplifier. See [Sound](#sound). |

### Spare or not usable

| Pin | Status |
|---|---|
| 52, 53 | Spare, with care: the 3.3V side of 2N7002 level shifters to the monitor's 5V DDC lines, with 2.2k pull-ups to 3.3V (Sipeed schematic rev 3923). An output here drives the monitor's DDC too. |
| 32 | Spare, with difficulty: LCD connector only. It needs an FPC breakout, and FPC pins 1-2 carry the backlight boost output. |
| 26 | Not usable: HDMI hot-plug detect, 2.2k to the connector and 5.1k to ground. It reads low without a monitor asserting hot-plug, which was the cause of the spurious ADB SRQ. It is usable only as that input. |
| 13 | Not usable: BL616 SPI clock. |

That accounts for 23 external-bus and DMA pins, up from 20, four for sound
and four for the SD card.
Two spare pins remain, on the DDC lines; the microSD slot's four are the SD
card's.

### Edge headers

The carrier reaches the FPGA through the Tang Nano's two 1x20 headers, J5 and
J6, 2.54 mm pitch, the rows 20.32 mm apart. Seen from above with USB-C at the
top, J5 is the right-hand row and J6 the left, and pin 1 of each is at the
USB-C end, so J5-1 faces J6-1. The board is 54.04 x 22.55 mm (Sipeed
dimension drawing, revision 3921).

| J5 | Pin | Signal | | J6 | Pin | Signal |
|---|---|---|---|---|---|---|
| 1 | | +5V | | 1 | 73 | `ext_sel[2]` |
| 2 | | GND | | 2 | 74 | `ext_sel_en_n` |
| 3 | 76 | `ext_rd_n` | | 3 | 75 | `ext_wr_n` |
| 4 | 80 | `dma_drq[1]` | | 4 | 85 | `dma_tc` |
| 5 | 42 | `ext_d[4]` | | 5 | 77 | `ext_d[7]` |
| 6 | 41 | `ext_d[3]` | | 6 | 15 | `ext_a[0]` |
| 7 | 56 | `i2s_bclk` | | 7 | 16 | `ext_a[1]` |
| 8 | 54 | `i2s_din` | | 8 | 27 | `adb_drive` |
| 9 | 51 | `amp_en` | | 9 | 28 | `adb_sense` |
| 10 | 48 | `ext_d[5]` | | 10 | 25 | unused (HDMI CEC) |
| 11 | 55 | `i2s_lrck` | | 11 | 26 | not usable (HDMI hot-plug) |
| 12 | 49 | `ext_d[6]` | | 12 | 29 | `ext_d[1]` |
| 13 | 86 | `ext_res_n` | | 13 | 30 | `ext_d[2]` |
| 14 | 79 | `dma_drq[0]` | | 14 | 31 | `ext_d[0]` |
| 15 | | GND | | 15 | 17 | `ext_a[2]` |
| 16 | | +3V3 | | 16 | 20 | `led` |
| 17 | 72 | `ext_sel[1]` | | 17 | 19 | `ext_irq_n` |
| 18 | 71 | `ext_sel[0]` | | 18 | 18 | `ext_a[3]` |
| 19 | 53 | spare (HDMI DDC) | | 19 | | +3V3 |
| 20 | 52 | spare (HDMI DDC) | | 20 | | GND |

* The clock (4), S1 (87), the BL616 UART (69, 70) and HDMI (33-40) stay on
  the Tang Nano and are not on the headers.
* The pin assignments are from the schematic (revision 3923). The
  orientation is from two published carrier boards' footprints (WonderTANG,
  VDAC4), not from Sipeed. Confirmed on the board (November 2026): the pin
  by the USB-C end of the right-hand row reads 5.18V with only USB
  connected, so it is +5V, and USB VBUS itself ([Power](#power)).
* WonderTANG's symbol has pin 78 at J5-3, where the schematic has 76.
  **Check** J5-3 against pin 76 on the board.
* KiCad: the symbol `Tang_Nano_20K` in 65Parts numbers J5 as 1-20 and J6 as
  21-40, and the footprint `My_Parts:Tang_Nano_20K` matches it.

## PCB requirements

Everything the carrier board has to provide, in one list. Each line refers
to the section that explains it. Ticked items are in the 65-16 schematic;
the rest are layout.

### Connection to the Tang Nano

- [ ] Sockets for the Tang Nano 20K's two edge headers. Every FPGA signal in
      [Pins](#pins) except the microSD slot comes through them.
- [x] A common ground with the Tang Nano, which the carrier powers through
      a jumper and a Schottky ([Power](#power)).
- [ ] Clearance for the HDMI, USB-C and speaker connectors and the microSD
      slot.

### Power

- [x] A 24-pin ATX header: +5V (2A typical, 4A peak), +3.3V, +12V and -12V
      from a picoPSU or any SFX/ATX supply; `PS_ON#` on a two-pin header.
- [x] 3.3V for the level shifters and the ENC424J600 from the supply; no
      regulator on the carrier.
- [x] Decoupling on every chip, bulk capacitance at the ATX header and by
      the floppy power connectors, and a Molex drive power connector with
      +12V and +5V.
- [x] A polyfuse and a Schottky on SCSI TERMPWR.

### Level shifting and bus buffering

- [x] A 74LVC245A at 3.3V on `ext_d[7:0]`. `DIR` comes from `RD#` and `/OE`
      from the select enable, both on the FPGA side.
- [x] A 74HCT541 at 5V on the FPGA outputs: `ext_a[3:0]`, `RD#`, `WR#`,
      `RES#` and `TC`.
- [x] A 74LVC125A at 3.3V on the inputs to the FPGA: `DRQ0` and `DRQ1`.
- [x] A 74HCT04: `TC` to the 53C80 `/EOP`, `RES#` to the 82077AA `RESET`,
      `DENSEL` for 3.5" drives, and `A0#` for the ENC424J600 glue.
- [x] On the FPGA side of the buffers: pull-ups to 3.3V on `RD#`, `WR#` and
      the select enable, and pull-downs on `RES#` and `TC`
      ([Voltage levels](#voltage-levels)).
- [x] No 5V signal reaches an FPGA pin anywhere, and no FPGA-side net is
      pulled to 5V.

### Select decoding

- [x] A 74HCT138: the select code on A-C, the select enable on `/G2A`, and
      `G1` tied high ([Select decoding](#select-decoding)).
- [x] The select enable's pull-up to 3.3V (above) keeps the decoder off
      while the FPGA is unconfigured.

### Interrupts and DMA

- [x] A 74HC05 for the interrupt wire-OR: open-drain inverters for the
      SCSI `IRQ` and the floppy `INT` ([Interrupts](#interrupts)); its other
      four gates invert the serial handshake inputs.
- [x] A pull-down on the 82077AA `INT`, at the 74HC05 input.
- [x] A 74LVC1G07 for the ENC424J600 `/INT`, and an SS14 for the slot's
      `/IRQ`.
- [x] A 4k7 pull-up to 3.3V on the interrupt node, which goes to pin 19.
- [x] `DRQ0` (53C80) and `DRQ1` (82077AA) to pins 79 and 80, through the
      LVC buffer.
- [x] Pull-downs on both `DRQ` inputs to the buffer, on the 5V side: the
      82077AA tristates `DRQ` while its DMA gate is off ([DMA.md](DMA.md)).
- [x] `TC` from pin 85 to the 82077AA `TC`, and through the 74HCT04 to the
      53C80 `/EOP`.
- [x] Decoder outputs 1 and 4 to the 82077AA and 53C80 `/DACK`.

### Z85C80

- [x] A 68-pin PLCC socket.
- [x] A 7.3728 MHz oscillator (DIP-8 can) to `PCLK`, `/RTxCA` and `/RTxCB`.
- [x] `/INTACK` pulled up.
- [x] `/SYNCA` pulled up (10k); no crystal on `/RTxCA` and `/SYNCA`.
- [x] `/W//REQA`, `/W//REQB`, `/DTR//REQA` and `/DTR//REQB` unconnected.
- [x] `/RESET` (SCSI) from `RES#`.
- [x] `D//C` to `ext_a[0]`, `A//B` to `ext_a[1]`, SCSI A2-A0 to
      `ext_a[2:0]`.
- [x] Both channels on Mac Mini-DIN-8s through a 26C31 and two 26C32s:
      `HSKo` from `/RTS`, `HSKi` and `GPi` inverted into `/CTS` and `/DCD`
      by 74HC05 gates with 10k pull-ups, 10k bias so an empty port reads
      idle ([Serial](#serial)).

### SCSI

- [x] An internal 50-pin IDC header and an external DB-25 (Apple pinout),
      on the same bus.
- [x] Termination: four socketed 220/330 SIP packs, fitted only while the
      carrier is a bus end.
- [x] TERMPWR from +5V through a polyfuse and a Schottky.
- [x] The 53C80's bus pins wired straight to the connectors. Its outputs
      drive the bus directly.

### Floppy

- [x] An 82077AA, in a 68-pin PLCC socket.
- [x] A 24 MHz fundamental-mode parallel-resonant crystal with 22 pF, and
      4.7 nF between `HIFIL` and `LOFIL`.
- [x] `RESET` (active high) from `RES#` through the 74HCT04.
- [x] A2-A0 to `ext_a[2:0]`.
- [x] A 34-pin drive header for two drives on a twisted cable, and two
      drive power headers.
- [x] `INVERT` tied to ground, so the 82077AA's own drivers and receivers
      serve the cable directly; 1k pull-ups on the five drive inputs.
- [x] `IDENT` high, `MFM` open, `PLL0` high, `DRV2` pulled up; the `DENSEL`
      polarity jumper and the `DRATE0/1` solder jumpers for 2.88 MB drives.

### Ethernet

- [x] An ENC424J600 in parallel mode 5 on select 5: data on `AD<7:0>`,
      `ext_a[1]` on `AD8`, `AD<14:9>` pulled high ([Ethernet](#ethernet)).
- [x] A 74HCT02 making the active-high `RD`, `WR`, `AL` and `CS`.
- [x] `PSPCFG0` low; `INT/SPISEL` pulled down 100k.
- [x] A 25 MHz crystal with 22 pF (**Check** the load capacitance), 12.4k
      on `RBIAS`, 10 µF on `VCAP`.
- [x] The Figure 2-5 magnetics network into a HanRun HR911105A jack
      (**Check** its LED pin polarity).
- [x] `/INT` into the interrupt node through the 74LVC1G07 and a jumper.

### ADB

- [x] A transistor from pin 27 that pulls the ADB line low when the pin is
      high ([ADB](#adb)).
- [x] A 10k/15k divider with a BAT54S clamp from the ADB line to pin 28.
- [x] The bus pull-up, 470R to +5V.
- [x] A 4-pin mini-DIN: data, power key, +5V, ground.
- [ ] The power key line brought to somewhere it can be read, if keyboard
      power-on is wanted (**Open**).

### Slot

- [x] A 50-pin slot in the Apple II form carrying the 5V-side bus
      ([Slot](#slot)): `D0`-`D7`, `A0`-`A3`, `/DEVSEL` and `/IOSEL` from
      selects 6 and 7, `R/W` from `WR#`, the raw strobes on pins 35 and 36,
      `/RES`, `/IRQ` through an SS14, `INT IN` and `DMA IN` pulled up, +5V,
      +12V and -12V.

### Test and bring-up

- [x] A 40-pin logic analyser header: pins 2-9 `D0`-`D7`, 11-14 `A0`-`A3`,
      15-18 `RD#`, `WR#`, `RES#`, `TC`, 20-25 the six decoded selects, 26-27
      the two DRQs, 29-30 `SCSI_IRQ` and `FDC_INT`, 31 the `IRQ#` node,
      32-35 the select code and enable, 36-37 the FPGA-side `RD#` and `WR#`,
      38 `EOP#`; grounds on 1, 10, 19, 28, 39 and 40. Nothing in series.
- [x] Loop test points on 5V, 3.3V and ground.
- [x] Jumpers isolating each chip's interrupt and DMA line: the SCC's
      `/INT`, the two 74HC05 outputs, the ENC424J600's buffered `/INT`, and
      both DRQs, with the DRQ pull-downs on the FPGA side of the jumper.

### Stereo audio (optional)

- [ ] A PCM5102A stereo DAC on the I2S lines from the edge header: BCLK
      (56), LRCK (55), DIN (54). Its SCK pin tied low, so it locks to BCLK
      ([Stereo on the carrier](#stereo-on-the-carrier)).
- [ ] Line-out jack, with the DAC's recommended output filter.

### Not on the carrier

- Mono sound uses the Tang Nano's own amplifier and speaker connector.
- The SD card is the Tang Nano's own microSD slot.

## Still to do

1. Run a continuity check on the board for pins 25, 26, 31, 49, 71-76, 79, 80,
   85 and 86, and turn **Sch** into **Board** in the tables.
2. Confirm the **Check** items:
   * the Z85C80 8 MHz grade's bus timing
   * the 82077AA's bus timing (its DOR gating is confirmed)
   * the ENC424J600 crystal's load capacitance, and the HR911105A's LED
     pin polarity
   * the DB-25 SCSI pinout against an Apple cable
3. Decide the **Open** items: SCC DMA, and keyboard power-on.
4. RTL changes:
   * ~~Intel-only `external_bus.v` at the 8 MHz timing, with the SCC
     recovery hold-off~~ (done)
   * ~~select code and enable~~ (done)
   * ~~the SCC reset on `RES#`~~ (done)
   * ~~the DMA engine and its multiplexer on the memory-master port~~ (done)
   * ~~the interrupt register~~ (done, with the tick timer)
   * ~~the `.cst` pin moves~~ (done)
5. Lay out the 65-16 board from the schematic, and write the ENC424J600
   driver (and an em16 model, if software wants it before the board).
