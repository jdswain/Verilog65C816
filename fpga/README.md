# 65C816 SoC on the Tang Nano 20K

The CPU core running the MiniMon monitor from a block-RAM boot ROM, with 8 MB
of cached SDRAM, 640x480 video on the HDMI port (16-colour graphics or 80x30
text), an Apple
Desktop Bus host for the keyboard, an external peripheral bus, and a console on
both the display and the board's onboard USB serial bridge.

**Running on hardware.** `make boot` prints the banner and `make talk C="..."`
drives the monitor interactively:

```
$ make boot
MiniMon 0.01

$ make talk C="dm e000 20"
dm e000 20
00E000: 18 FB E2 20 C2 10 20 46  E0 20 E9 E6 A2 1B E0 20  ... .. F. .....
00E010: C0 E6 20 81 E3 20 52 E4  4C 12 E0 4D 69 6E 69 4D  .. .. R.L..MiniM
>
```

The same session appears on the HDMI display; see [Console](#console) and
[Monitor commands](#monitor-commands).

This document describes the SoC as it is. The board it is heading for, with
the 5V peripherals on a carrier (SCC, SCSI, floppy, DMA), is specified in
[`docs/Hardware.md`](../docs/Hardware.md).

```
   27 MHz crystal --> rPLL x14/3 = 126 MHz --> /5 = 25.2 MHz (system + pixel clock)

     +------------------+        rdy
     |   cpu_65c816     |<---------------------+
     +--------+---------+                      |
              | addr/wdata/rdata/we/vld        |
     +--------v-----------------------------+  |
     |            address decode            |--+
     +--+---------+-----------------+-------+
        |         |                 |
   ROM 8K BSRAM  cache          I/O block $00_0200
   $00_E000       | port 1        scc_85c30 ----> BL616 --> USB serial
                  |               palette ----------+
            +-----v-------+       adb_host          |
            | sdram_burst |       system control    |
            +-----^-------+       external_bus      |
                  | port 0 (priority)               |
               video scanout <----------------------+
                  |
               hdmi_out --> HDMI
```

## Memory map

| Range | Size | Contents |
|---|---|---|
| `$00_0000`-`$7F_FFFF` | 8 MB | SDRAM (in-package die) |
| &nbsp;&nbsp;`$00_0000`-`$00_01FF` | 512 B | RAM -- zero page and stack, never decoded as I/O |
| &nbsp;&nbsp;`$00_0200`-`$00_0FFF` | 3.5 KB | I/O block, overlaid in bank 0 |
| &nbsp;&nbsp;`$00_E000`-`$00_FFFF` | 8 KB | boot ROM (16-bit wide), overlaid, **switchable** |
| `$80_0000`-`$FF_FFFF` | 8 MB | unmapped, reads `$FF` |

I/O sits at the **bottom** of bank 0 because the boot ROM wants the whole
`$E000`-`$FFFF` for itself. The first two pages are deliberately left as RAM:
registers over `$0000`-`$00FF` and `$0100`-`$01FF` would take away the default
direct page and the emulation-mode stack, and the CPU comes out of reset in
emulation mode with `D = $0000`. So zero page, `JSR` and interrupts all work
before the boot ROM has configured anything.

### I/O block

3.5 KB at `$00_0200`. The lower part is on-chip peripherals, `$0800` up is the
window for the external bus:

| Range | Device |
|---|---|
| `$0200`-`$023F` | unclaimed, reads `$FF` (was the 6551 ACIA, replaced by the SCC) |
| `$0240`-`$027F` | palette: 16 entries x 4 bytes `{red, green, blue, -}` |
| `$0280`-`$02BF` | keyboard: Apple Desktop Bus host |
| `$02C0`-`$02FF` | SD card *(not implemented, reads `$FF`)* |
| `$0300`-`$033F` | system control (ROM/RAM soft switch) |
| `$0340`-`$037F` | external bus control |
| `$0380`-`$03BF` | video control (graphics/text mode) |
| `$03C0`-`$03FF` | blitter |
| `$0400`-`$04FF` | unclaimed, reads `$FF` |
| `$0500`-`$057F` | sound: two SIDs and a control register (see [Sound](#sound)) |
| `$0580`-`$07FF` | unclaimed, reads `$FF` |
| `$0800`-`$0FFF` | external bus window: 4 cards x 16 registers |
| &nbsp;&nbsp;`$0820`-`$082F` | emulated Z85C30 SCC, answering instead of card 2 (see [Serial: the SCC](#serial-the-scc)) |

Each device decodes a 64-byte slot, so its registers repeat within that slot.
Anything unclaimed in the block reads `$FF`.

### System control -- `$0300`

| Bit | Write | Read |
|---|---|---|
| 0 | 1 = boot ROM mapped at `$E000`-`$FFFF`, 0 = SDRAM mapped there | current setting |
| 1-7 | ignored | 0 |

The bit **resets to 1**, because there is nothing else to boot from: SDRAM is
volatile and holds garbage at power-up, so the reset vector has to come out of
block RAM.

The switch only redirects **reads**. Writes to `$E000`-`$FFFF` always go to
SDRAM whichever way it is set, which is what makes the handover safe:

```
        ldx #0                  ; shadow the ROM into the RAM underneath it
shadow  lda.w $e000,x           ; reads come from ROM
        sta.w $e000,x           ; writes go to SDRAM
        inx
        cpx #$2000
        bne shadow

        stz $0300               ; hand $E000-$FFFF to RAM
```

Execution continues straight across the `stz` because both sides hold identical
bytes. Afterwards the 8 KB is ordinary cached memory: patchable, and no longer
costing a ROM rebuild to change. **Clearing the bit without shadowing first
fetches the next instruction out of uninitialised RAM** -- and takes the
interrupt and reset vectors at `$FFE0`-`$FFFF` with it.

`make romswitch` builds a ROM that walks through exactly this, using `$FF00`
(past the end of the code, so the ROM image holds fill there) as a probe:

```
$0300 = 01
probe from ROM      = FF
probe after write   = FF      <- write passed through, read still sees ROM
probe with RAM in   = A5      <- the switch works
$0300 = 00
probe with ROM back = FF
```

### Palette -- `$0240`, write-only

16 entries of 4 bytes. Entry *n* component *c* lives at `$0240 + n*4 + c`:

| Offset | Component |
|---|---|
| +0 | red |
| +1 | green |
| +2 | blue |
| +3 | unused (writes ignored) |

So entry 0 is `$0240`-`$0243`, entry 1 is `$0244`-`$0247`, ... entry 15 is
`$027C`-`$027F`. Each component is a full 8 bits and goes straight to the
corresponding TMDS channel, so `$FF,$FF,$FF` is white and `$00,$00,$00` black.

The port is **write-only**: reading it returns `$FF`. A 24-bit-wide port would
have needed shadow registers in the decoder to assemble three bytes from an
8-bit CPU, and nothing needs to read the palette back -- keep a copy in RAM if
you want one.

Palette writes take effect at the next pixel, not at the next frame. Rewriting
an entry mid-frame will show a horizontal seam; do it during vblank if that
matters.

### Video control -- `$0380`

| Bit | Meaning |
|---|---|
| 0 | `0` = 640x480 16-colour graphics (reset default), `1` = 80x30 text |
| 7-1 | unused, read as 0 |

Readable and writable. Both modes display the same memory at `$70_0000`; the
bit only changes how it is interpreted, so switching does not clear anything --
text bytes show as coloured dots in graphics mode and vice versa. A change takes
effect at the top of the next frame, never part-way down the screen.

### Text buffer

In text mode the screen is 80 columns by 30 rows of 8x16-pixel cells, in the
Atari ST system font.

| | |
|---|---|
| Size | 80 x 30 cells |
| Base | `$70_0000` |
| Cell | 2 bytes: character, then attribute |
| Row stride | 160 bytes |
| Total | 4800 bytes (`$12C0`) |

Address of the cell at (*column*, *row*):

```
    $700000 + row * 160 + column * 2      character
    $700000 + row * 160 + column * 2 + 1  attribute
```

The attribute's **low nibble is the foreground** (ink) colour and its **high
nibble the background** (paper), both indices into the same 16-entry
[palette](#palette----0240-write-only) the graphics mode uses. `$07` is grey on
black with the default palette, `$1F` white on blue. There is no blink bit: all
16 colours are available as a background.

The character is an index into the font, which has all 256 glyphs of the Atari
ST set: ASCII in `$20`-`$7E`, accented letters and symbols above that, and
drawable glyphs rather than control actions in `$00`-`$1F`. Nothing interprets
control characters, scrolls, or draws a cursor -- that is software's job; a
cursor is most easily made by swapping a cell's attribute nibbles.

### Graphics buffer

The framebuffer is **not** a device -- it is plain SDRAM at `$70_0000`, so it is
written with ordinary stores and goes through the cache like anything else. The
cache is write-through specifically so scanout sees writes without a flush.

| | |
|---|---|
| Resolution | 640 x 480 |
| Colour | 4 bits per pixel through the 16-entry palette |
| Base | `$70_0000` (banks `$70`-`$72`) |
| Line stride | 320 bytes |
| Size | 150 KB (`$25_800`) |
| Refresh | 60 Hz, 25.2 MHz pixel clock |

Address of the byte holding pixel (*x*, *y*):

```
    $700000 + y * 320 + (x >> 1)
```

**The low nibble is the left pixel.** Byte `$700000` holds pixel (0,0) in bits
3-0 and pixel (1,0) in bits 7-4 -- little-endian in the same sense the rest of
the machine is, so a 32-bit word read out of SDRAM unpacks left-to-right from
its low end. Two pixels of the same colour *n* are `n | (n << 4)`.

Nothing enforces the 150 KB: the bytes past the end of a line are simply the
start of the next, and writing past `$72_5800` writes ordinary memory. There is
no double buffering in hardware -- the line buffer inside `video.v` is double
buffered by line parity, but that is an internal detail of scanout, not a page
flip. For flicker-free animation, either draw during vblank or implement page
flipping in software by moving `FB_WORD_BASE` (currently a build-time parameter,
not a register).

Scanout costs 9.2 MB/s of read bandwidth, about a fifth of what the burst
controller sustains; the rest is left for the CPU.

### Blitter -- `$03C0`

Copies or fills a rectangle of pixels in hardware, combining source and
destination through a logic operation and optionally skipping one colour. The
register model is the Atari ST BLiTTER's; the differences come from this
display being packed pixels rather than bitplanes.

**Addresses are in pixels, not bytes.** A pixel is a nibble, so a pixel address
is the byte address times two, plus one for the right-hand pixel of the byte --
and 8 MB is exactly 2^24 pixels, so it fits in 24 bits. The screen at `$70_0000`
is pixel `$E0_0000`, and pixel (*x*, *y*) is:

```
    $E00000 + y * 640 + x
```

Strides and the width are in pixels as well. There are no skew or end-mask
registers: the blitter works them out from the addresses and the width.

| Address | Register | |
|---|---|---|
| `$03C0`-`$03C2` | SRC | source pixel address |
| `$03C4`-`$03C6` | DST | destination pixel address |
| `$03C8`-`$03C9` | SRC_STRIDE | added to SRC after each line, signed |
| `$03CA`-`$03CB` | DST_STRIDE | added to DST after each line, signed |
| `$03CC`-`$03CD` | WIDTH | pixels per line, 1-1024 |
| `$03CE`-`$03CF` | HEIGHT | lines, 1-65535 |
| `$03D0` | OP | logic operation, low 4 bits |
| `$03D1` | COLOUR | low nibble: fill colour. High nibble: transparent colour |
| `$03D2` | CONTROL | write: bit 0 start, bit 1 fill, bit 2 transparent. Read: bit 7 busy |

Multi-byte registers are little-endian. Set everything up, write CONTROL with
bit 0 set, then poll bit 7 until it clears. Writes while a blit is running are
ignored. A blit does not change the registers, so the same one can be started
again, or the next one can change only what differs.

* **Fill** (bit 1): the source is the fill colour, not memory; SRC and
  SRC_STRIDE are ignored.
* **Transparent** (bit 2): source pixels equal to the transparent colour leave
  the destination alone.

OP is a truth table over source and destination bits, in the ST's numbering:

| OP | Result | | OP | Result |
|---|---|---|---|---|
| 0 | 0 | | 6 | S xor D |
| 1 | S and D | | 7 | S or D |
| 3 | S (copy) | | 12 | not S |
| 5 | D (no change) | | 15 | 1 |

In general bit 0 of OP is the result where S=1 and D=1, bit 1 where S=1 D=0,
bit 2 where S=0 D=1, and bit 3 where S=0 D=0.

**Overlapping blits.** Each line is read completely before any of it is
written, so source and destination may overlap horizontally in either
direction. Vertically, blit in the direction that reads each line before
overwriting it: top-down to move something up, and bottom-up -- addresses
pointing at the last line, both strides negative -- to move it down.

It works on any memory, not just the screen, and in text mode too: a text row
is 320 "pixels" at stride 320, so scrolling the 80x30 screen up a line is one
blit of width 320, height 29, from pixel `$E00140` to `$E00000`.

The CPU keeps running during a blit, sharing memory with it turn and turn
about, and sees every byte the blitter writes as soon as the blit is finished
-- see [Blitter and the memory-master port](#blitter-and-the-memory-master-port).

### External bus

`$0800`-`$0FFF` is a window onto an external card connector, wired much like an
Apple II slot. Within it `addr[5:4]` picks one of four active-low card selects
and `addr[3:0]` drives A3-A0, so each card sees 16 registers -- enough for a
WD1773 (4) or an 82077AA (8):

| Card | Registers | Select |
|---|---|---|
| 0 | `$0800`-`$080F` | `IO0#` |
| 1 | `$0810`-`$081F` | `IO1#` |
| 2 | `$0820`-`$082F` | `IO2#` |
| 3 | `$0830`-`$083F` | `IO3#` |

...mirrored every 64 bytes to the end of the window. Decoding the selects in the
FPGA costs one pin over exposing A5-A4 and a '139, and removes a part from the
board.

Every access stalls the CPU for the whole external cycle, 1-2 us. That is
transparent to code, but it means a tight polling loop on a card register runs
at roughly 500 kHz, not at CPU speed.

#### External bus control -- `$0340`

| Bit | Write | Read |
|---|---|---|
| 0 | 1 = hold `RES#` asserted to the cards | 1 = a card is asserting `IRQ#` |
| 1-7 | ignored | 0 |

`RES#` is also asserted while the SoC itself is in reset, so cards come up
reset without software help; the bit is for re-resetting a wedged card. It is a
**level**, not a pulse -- set it, wait, clear it:

```
        lda #$01
        sta $0340
        ldx #2000               ; ~ms; far longer than any card needs
res     dex
        bne res
        stz $0340
```

The read side is the live state of the `IRQ#` pin, synchronised but not
latched: it follows the card and clears when the card clears it. The card IRQ
is ORed with the SCC's into the 816's single `IRQ` line, so an ISR must check
both sources.

#### Bus style

A **build-time** parameter, because both styles share the same two strobe pins:

| `EXT_STYLE` | `ext_rw` | `ext_phi0` | For |
|---|---|---|---|
| 0 (default) | R/W, high = read | free-running 1 MHz PHI0 | WD1773 and other 65xx-bus cards |
| 1 | `WR#` | `RD#` | 82077AA and other Intel-bus parts |

In 6502 style the bridge waits for a falling edge of PHI0 before asserting the
select, so the card sees address and R/W set up during the low phase and data
transferred during the high phase, exactly as a 6502 would present them. In
Intel style address, select and write data go out first and the strobe follows
half a PHI0 period later, which is the `tAR`/`tDW` setup the parts ask for.

#### Connector pinout

20 pins, scraped together from three places on the board. There was no single
free bank big enough. The notes are from Sipeed's schematic (revision 3923):

| Signal | Pins | What else is on them |
|---|---|---|
| `ext_d[7:0]` | 25, 29, 30, 41, 42, 48, 49, 77 | the LCD connector and the edge headers; see below for 25 and 49 |
| `ext_a[3:0]` | 15, 16, 17, 18 | four of the six LEDs, and the LCD connector's touch pins |
| `ext_sel_n[3:0]` | 71, 72, 73, 74 | headers only (they carry HSPI labels but don't reach the BL616) |
| `ext_rw` | 75 | the BL616's SPI link (MISO) |
| `ext_phi0` | 76 | the BL616's SPI link (MOSI) |
| `ext_res_n` | 86 | the BL616's SPI link (DIR) |
| `ext_irq_n` | 19 | the fifth LED |

Things to watch:

* **Pin 25 (`ext_d[0]`) is HDMI CEC**, through 100R with a 27k pull-up. With a
  monitor connected, the monitor sits on data bit 0. `docs/Hardware.md`
  moves this bit to pin 31.
* **Pin 49 (`ext_d[6]`) is the LCD backlight boost enable.** The boost
  converter runs with no load whenever the bit is high.
* **Pins 75, 76 and 86 go to the BL616**, which also has pin 13. They are
  free only while its firmware leaves that link idle. If a card misbehaves in
  a way that looks like someone else driving the bus, suspect this first.
* **Pin 26 is the HDMI hot-plug detect line**: 2.2k to the connector, which
  has 5.1k to ground, easily beating an internal pull-up. It reads low unless
  a monitor asserts hot-plug. That is what caused a spurious SRQ on every ADB
  transaction before it was tracked down. It is usable only as that input.

`ext_d` and `ext_irq_n` are pulled up internally, so an empty connector reads
`$FF` and no interrupt rather than floating. A card's driver trivially
overrides a ~50k pull.

The connector is a 3.3V bus and **the FPGA's pins are not 5V tolerant**. 5V
cards need level shifting; `docs/Hardware.md` specifies it for the target
board.

`make exttest` builds a ROM that pulses `RES#`, dumps all four cards' 16
registers and performs a write. With nothing plugged in it prints `FF`
everywhere and `ctrl=00`; that alone proves the window decodes, the FSM runs a
full cycle and acks, and the CPU is released again.

#### Finding more pins

From Sipeed's schematic (revision 3923). The LCD connector is not a source of
pins: every LCD signal is either also on an edge header, or is one of the
eight HDMI pins (33-40 double as LCD colour bits). Exactly one pin is wired to
the LCD connector and nothing else: **32**. A 40-pin 0.5 mm FPC breakout would
reach it, but for one pin it is poor value -- and FPC pins 1-2 are the
backlight boost converter's output, which runs unloaded whenever pin 49 is
high, so they must be left unconnected.

What is available, most usable first:

| Pins | Where | Cost |
|---|---|---|
| 31 | header J6-14 and the LCD connector | none |
| 32 | LCD connector only | none, but needs the FPC breakout |
| 80, 85 | header | SD card 4-bit mode (SPI mode still works); 10k pull-ups |
| 79 | header | the RGB LED (WS2812); 5.1k pull-down |
| 51, 54, 55, 56 | header | the audio amplifier; 54-56 need "SSPI as regular I/O" |
| 52, 53 | header | HDMI DDC (EDID); 2.2k pull-ups, and the monitor is on the lines |
| 81-84 | microSD slot only | the SD card entirely; needs a microSD breakout |

So one pin is free today, nine without any adapter, eleven counting the DDC
pair. `docs/Hardware.md` allocates 31, 79, 80 and 85 for the target board.

### Writing ROM sources against this map

ROM sources assemble at `org=$e000` and are built straight into the ROM image
by the 65Tools assembler, whose `.mem` output is a Verilog memory file:

```
as -o rom/name.mem name.asm
```

The file holds the bytes of the program in order from its lowest address,
with `$FF` in the gaps and no addresses, and `soc.v` reads it into an array
that starts at the base of the ROM. So the first thing in the source must be
at the ROM's base, and the source ends with its own vectors:

```
	org=$fffc
	data.w start		; reset
	data.w start		; IRQ/BRK in emulation mode
```

The first line of the file is a comment with the range it covers
(`// $E000-$FFFF`), which must agree with `ROM_BITS`/`ROM_BASE` in the
Makefile. If it does not, the reset vector is not where the CPU looks and the
failure looks like a completely dead SoC.

An assembler trap that has already cost time here:

* `sta $0000,x` assembles as **direct page** (`$95`) and always addresses bank
  0, ignoring DBR. Use the `.w` suffix (`$9D`) for absolute indexed. `!$0000`
  does not help -- it parses as an operator and silently yields `sta $01,x`.

### Checking the map

Two ROMs cover it between them, because neither alone does:

* `make memtest` walks banks `$01`-`$7F` -- fill, a multi-second pause to catch
  a refresh fault, then verify. The pattern includes the bank number so a
  decode that aliased every bank onto one would not compare equal. It
  **deliberately skips bank 0**, which is the only bank with holes in it.
* `make maptest` covers bank 0, which is what the holes need:

```
bank 0 map test
$0000-$01FF RAM  ok      <- zero page and stack are RAM, not I/O
$1000-$DEFF RAM  ok      <- main memory
$0200-$0FFF I/O  ok      <- writes there do NOT store: it is not SDRAM
$E000-$FFFF ROM  ok      <- reads ignore writes while $0300 bit 0 is set
PASS
```

  `$DF00`-`$DFFF` is reserved for the test's own stack and variables, so it is
  the one part of bank 0 nothing checks. Direct page is avoided throughout for
  the same reason: `$0000`-`$00FF` is itself under test. The RAM patterns fold
  in *both* halves of the address, so a decode that aliased one page onto
  another is caught rather than comparing equal.

### Why only half the address space

The die is 64 Mbit = **8 MB**, which is exactly banks `$00`-`$7F`. The 65C816
addresses 16 MB, so the upper half has no storage behind it. This is a hard
physical limit, not a mapping choice:

* The controller already uses **all 32 data bits** — each 32-bit word holds four
  consecutive CPU bytes (`word_addr = addr[22:2]`, `addr[1:0]` picks the lane
  via DQM). There is no unused half of the bus to reclaim.
* Interleaving or striping changes *which* bits store *which* address, not how
  many bits exist. No address mapping turns 8 MB into 16 MB.

Banks `$80`-`$FF` are therefore left unmapped rather than aliased onto the lower
half. Aliasing would make software that runs off the end of memory silently
corrupt bank `$00`; reading `$FF` makes it fail visibly.

The boot ROM has to stay in block RAM: SDRAM is volatile and uninitialized at
power-up, so something non-volatile must hold the reset vector. It and the I/O block
are overlaid on top of the SDRAM range in bank 0, costing 12 KB of the 8 MB.

### Reset

**S1 is active HIGH on this board** -- measured idle low, going high when
pressed (`test/btntest.v` puts both button pins on LEDs to check). The
conventional `por_done & btn[1]` therefore held the whole SoC in reset forever,
which was the first hardware fault found here; the button has to be inverted.

Holding S1 resets the CPU, cache and SDRAM controller together, which re-runs
the SDRAM power-up sequence.

### Reset ordering

The SDRAM needs ~200 us of initialization before it answers, and with bank 0 in
SDRAM the very first stack push lands there. `soc.v` therefore holds the CPU in
reset until the controller asserts `init_done`.

## Bus timing

The core samples `rdata` on the rising edge where `rdy` is high, and holds
`addr`/`vld` steady while `rdy` is low. Block RAM reads are registered, so
every access takes two clocks: cycle 0 presents the address with `rdy` low,
cycle 1 returns data with `rdy` high.

**Peripherals must be strobed on cycle 0 only.** `soc.v` derives `stb` for
this. Using `vld` directly would repeat every side effect -- transmitting each
character twice, consuming two bytes per receive-register read, and so on.

That describes the block RAM and the peripherals. SDRAM accesses go through the
cache instead, which answers in one cycle when the byte is in the word it is
already holding and takes longer on a miss -- see [Cache](#cache).

At 25.2 MHz a two-clock access is ~12.6 M bus cycles/s, and this core has no
dummy cycles, so it gets more done per bus cycle than a real W65C816.

## Simulating

```sh
make sim            # boot the monitor, print what it transmits
make send S=hello   # type a string in once it has booted
make real           # same, at a realistic clock / baud ratio (see below)
make lint           # elaborate the synthesis top-level
```

`make sim` should print:

```
MiniMon 0.01

>
```

The default simulation uses `DIVISOR=8` so a character costs 80 clocks instead
of 2340. That makes the serial link enormously fast relative to the CPU, which
exaggerates receive overruns; `make real` uses a realistic one. It still models
the original 27 MHz clock (`DIVISOR=234`), where the board now runs at 25.2 MHz
with `DIVISOR=219` -- 6% apart, which does not change what the test shows.

### About overruns

The monitor echoes each character, and `ser_putc` blocks until the transmitter
drains, so the CPU is unavailable for a full character time after every byte it
receives. The SCC holds three received bytes (the ACIA held one), so input
arriving back-to-back -- a terminal paste, not a human typing -- will still
drop bytes and set the overrun bit, which MiniMon ignores. Interrupt-driven
input is the fix when that starts to matter.

## Building the ROM

```sh
make rom                       # MON_DIR=~/Developer/1av/65/OS16/rom
make rom MON_DIR=/path/to/rom  # elsewhere
```

This assembles the monitor into `rom/minimon.mem`. MiniMon's sources are
`rom/` of the OS16 repository ([jdswain/OS16](https://github.com/jdswain/OS16)),
checked out beside this one; `make` there builds the same image, and an 8K
binary of it for `em16 -fpga -bootrom`.

The sources are in the syntax of the current (Oberon) 65Tools assembler:
section names are quoted (`section "text"`), there is no `entry` directive, and
an undefined symbol is an error. The older C assembler accepted a branch to an
undefined symbol and assembled it to nothing, which is what made the
transmitter drop every other character before the fix in `rom/mon-fixes/`.

## Monitor fixes

`rom/mon-fixes/` is the record of what the monitor needed before it would build
and run on the board. All of it is now in MiniMon's sources (OS16's `rom/`); the
files stay here as history, and `apps/mandel.asm` includes the `65816.asm` copy.

* **`65816.asm`** -- the include `minimon.asm` expected at
  `65/os16/include/65816.asm` was missing from disk. This copy was recovered
  verbatim from the byte columns of the stale `mon/src/minimon.lst`. It defines
  the flag constants, the direct-page register block, and the `native` /
  `long_a` / `short_a` / `sframe` / `eframe` macros. It is now `65816.asm`
  beside MiniMon's sources.
* **`mon.patch`** -- three source fixes:
  * `serial.asm`: `ser_putc`'s wait loop branched back to the `pha`, pushing a
    byte on every poll iteration. It only worked against a transmitter that was
    always instantly ready, which the emulator is and real hardware is not.
  * `readline.asm`: `/* ... */` block comments, which this assembler does not
    accept, converted to `*` line comments.
  * `minimon.asm`: `math.asm` excluded -- see below.
* **`monitor.patch`** -- the display console, ADB keyboard input and the
  command interpreter (see [Console](#console) and
  [Monitor commands](#monitor-commands)), plus the line buffer's move out of
  the I/O block. The patch is the record of what changed, from before the
  monitor was under version control.

**`math.asm` does not assemble.** Its `print_i` routine uses three addressing
modes that do not exist on the 65C816: `sty <off>,s` (STY has no stack-relative
form), `dec (dp,x)`, and `cpy (dp)`. Nothing else in the monitor references
`print_i`, so excluding it costs only decimal number printing. Fixing it means
reworking the routine against the `sframe` frame convention.

## Synthesis (Gowin EDA)

```sh
make bit     # synthesis + place & route -> impl/pnr/soc816.fs
make scan    # is a board attached?
make prog    # load into FPGA SRAM (fast, lost on power cycle)
make flash   # write to SPI flash (~21 s, survives power cycles)
```

`prog` uses operation 2 ("SRAM Program"); `flash` uses **operation 9**
("exFlash Erase,Program,Verify"). The GAO-Bridge variants (36-39) need a debug
bridge in the design and fail immediately without one. Note that an unplugged
board also fails instantly with the same `Error 50`, so check `make scan` before
concluding an operation index is wrong.

Flashing is always recoverable: the FPGA accepts a JTAG SRAM load regardless of
what is in flash.

`build.tcl` drives `gw_sh` headlessly, so no IDE interaction is needed. Both
`gw_sh` and `programmer_cli` are unsigned and will be blocked by macOS
Gatekeeper on first run; approve them in System Settings > Privacy & Security.
Use the programmer bundled inside `GowinIDE.app`, not a standalone install --
the standalone one's Python framework is rejected by system policy.

Results on `GW2AR-LV18QN88C8/I7` (Gowin V1.9.11.03 Education):

| Resource | Used | % |
|---|---|---|
| Logic (LUT/ALU) | 11957 / 20736 | 58% |
| Registers | 1585 / 15915 | 10% |
| BSRAM | 16 / 46 | 35% |

The 16 BSRAM blocks are 7 `pROM` -- 5 for the 8 KB boot ROM and 2 for the 4 KB
text font -- and 9 `SDPB`, which the cache, the video line buffer and the
blitter's two line buffers share. Main memory is SDRAM, so none of it is block
RAM any more. The blitter and the cache invalidation together cost about 1,100
LUTs and 400 registers.

Two faults showed up only on hardware, both now fixed:

* **The reset was gated by the button on pin 87**, which reads LOW when idle on
  this board even with `PULL_MODE=UP`. The obvious `por_done & btn[1]` held the
  whole SoC in reset permanently -- LEDs lit but frozen, nothing on the serial
  port. Reset now comes from the power-on counter alone; see the comment in
  `top_tang20k.v` before putting the button back.
* **A blank ROM builds silently** (see below).

If the SoC ever appears dead again, the fastest triage is `test/`: `blinky.v`
(clock and pins only), `uartmsg.v` (serial path only, with a deliberately
asymmetric message -- a pattern like `0x55` is alternating bits and aliases to
itself at the wrong baud, which sent this investigation down a false trail),
and `socdbg.v`, which streams the CPU's address bus out of a known-good
transmitter. That last one is what proved the core was fine: it showed the CPU
looping over `$00E02E`-`$00E033` and `$00C001`, which is `ser_getc` polling the
ACIA status register -- the monitor waiting for a keystroke.

Timing closes with no violations -- setup and hold TNS both 0.000 across 0
endpoints. **Fmax is 27.8 MHz against the 25.2 MHz system clock, 10% margin**,
with the SIDs in. Placement varies a lot from build to build: the previous
build, with nothing but a small change to the ADB controller between them,
reached 35.5 MHz. Every one of the 25 worst paths runs inside the CPU, from its
state register into the ALU's flags and A, X and Y, so that is the path to
work on if the margin ever gets thin.
It was 31.2 MHz before the SCC went in; see below.

It had fallen to 3% (26.0 MHz) once the blitter was in. The path was

```
CPU state -> address -> [cache held-word compare | address decode] -> read-data mux -> ALU -> flags
```

and the fix was to stop the read data depending on the address at all in the
cycle it is used:

* **In the cache**, the 21-bit "is this the held word?" compare selected
  between the held byte and the slow path's byte. It now only decides whether
  the CPU takes the data (`ack`), which is a late-arriving enable; the data is
  selected by `ack_r`, a register. The two are equivalent -- see the comment at
  `rdata` in `cache.v`.
* **In `soc.v`**, the read mux was a one-hot OR over every device select, all
  decoded from the live address. ROM and on-chip I/O take two cycles, so their
  selects are now registered in the first and used in the second; the external
  bus flags its own data with `ext_ack`; SDRAM is the default.

The blitter's and ADB host's read data were still picked by the low address
bits, so the CPU's address went through their register selects into the read
data and the ALU. Adding the SCC moved placement enough for that path to
take Fmax down to 26.4 MHz. Their read data is now captured on the strobe,
and Fmax was 30.0 MHz; with the ACIA removed it is 32.0 MHz. What is left
on the worst path is the CPU's own address generation and the ALU, whose two
chained adders -- binary then decimal correction -- are the larger part of
it.

The selects are registered rather than all the I/O data, because the ACIA
(since replaced by the SCC) registered its own read data on the strobe, so
the byte was not there to capture until the cycle after. The first attempt registered the data and dropped serial
characters in simulation, which is what `make sim` and the test ROMs are for. The first bring-up ran
straight from the 27 MHz crystal with 8% margin; as the cache and SDRAM went in
that fell to under 1%, and the fix was to register the ROM read path and move
the SoC onto the PLL's 25.2 MHz pixel clock (see the note in `top_tang20k.v`).

## Talking to the board

```sh
make boot            # program and capture the boot banner
make talk C="hello"  # type a line at the monitor, print the reply
```

Both go through `tools/board.py`. Three things about this board's USB bridge
cost real time to find, and the tool encodes all of them:

* **The bridge exposes two CDC ports and only the higher-numbered one is the
  UART.** The lower one is FTDI channel A, the JTAG interface. Opening it makes
  macOS's serial driver claim the channel, after which the programmer fails
  with `Cable open failed` until the board is physically unplugged. Never touch
  it.
* **Closing and reopening the UART wedges it** -- the first read after an open
  works, then the port goes silent until a replug. `board.py` does all its work
  on one file descriptor, changing line settings with `termios` rather than
  reopening.
* **The driver buffers aggressively.** A read taken right after programming can
  return seconds-old output from the *previous* bitstream. Read twice and
  discard the first if a result looks stale.

Seeing nothing after programming is usually not a fault: the banner is printed
once at reset and the monitor is then silent, waiting for input. `make boot`
holds the port open across programming to catch it.

### Watch the ROM warning

A missing or unreadable ROM image is only a *warning* to the Gowin tools --
they build a perfectly good bitstream with a blank ROM, which then boots into
nothing. This bit us once already: `$readmemh` resolves relative to the tool's
working directory, and synthesis runs from `impl/gwsynthesis/`, so the
original relative path silently failed.

The fix is `rtl/rom_path.vh`, generated by `make` with an absolute path, and
`make bit` greps the synthesis log for `Cannot open file` and fails the build
rather than handing back a hollow bitstream. The symptom to recognise if it
ever regresses: BSRAM usage drops from 16 blocks to 11 with no boot `pROM`, because an
uninitialized ROM gets optimized away entirely.

## Video

640x480 at 60 Hz over HDMI, scanned out of SDRAM through port 0 of the burst
controller, as either 4bpp graphics or 80x30 text.

This section is about the hardware; the software-facing layout is under
[Video control](#video-control----0380), [Text buffer](#text-buffer),
[Graphics buffer](#graphics-buffer) and [Palette](#palette----0240-write-only).

| | |
|---|---|
| Framebuffer | `$70_0000`, 320 bytes/line, 150 KB |
| Pixel format | 4bpp, two pixels per byte, **low nibble first** |
| Palette | 16 entries x 24-bit RGB |
| Bandwidth | 9.2 MB/s, about 19% of what the controller sustains |

Pixel clock is 25.2 MHz (27 x 14/15), 0.1% fast of the nominal 25.175 and well
inside tolerance, from `rPLL` at 126 MHz divided by 5. `hdmi_out.v` runs three
TMDS encoders into four `OSER10` serializers (three data channels plus a clock
channel sending a fixed `0000011111`) and out through `ELVDS_OBUF`.

### Text mode

Text reuses the graphics scanout almost unchanged. Each scanline still fetches
its own data from SDRAM into the line buffer; in text mode it fetches the 40
words of the row it belongs to instead of 80 words of pixels, so a row of text
is simply read 16 times over. That is half the bandwidth of graphics, and it
means there is no separate character buffer, no second fetch engine, and no
special case for the top or bottom of a row.

On the pixel side the cell under the beam indexes a 4 KB font ROM by
`{character, scanline within the row}`, and the selected bit of the result
picks the attribute's foreground or background nibble as the palette index. The
font ROM is a registered read, which adds a pipeline stage; graphics goes
through the same stage unused, so both modes have the same latency and the
picture does not move sideways when the mode changes.

The font is the 8x16 system font from [EmuTOS](https://emutos.sourceforge.io/),
the free replacement for the Atari ST's TOS, and is **GPL v2 or later** -- see
the header of `font/fnt_st_8x16.c`. `make font` runs `tools/mkfont.py` to turn
that source into `rom/font_st8x16.hex`. A GEM font stores all its glyphs side by
side in one wide bitmap; the tool regroups them glyph by glyph so the ROM
address is a plain concatenation.

The font path has the same trap as the boot ROM's: it must be absolute for
synthesis, so it is generated into `rtl/rom_path.vh` alongside it, and a font
that fails to load is caught by the same check in `make bit`.

### Things that are easy to get wrong here

* **Two clock domains, currently the same clock.** `video.v` was written with
  pixels leaving at 25.2 MHz and SDRAM and the CPU at 27 MHz. The whole SoC has
  since moved onto the 25.2 MHz pixel clock, so the crossing no longer crosses
  anything, but it is kept: the line buffer is written as words on the memory
  clock and read as pixels on the pixel clock, which is what a dual-port block
  RAM does natively, and the line/frame pulse goes through a toggle and two
  flops rather than being used raw. A faster memory clock would need it again.
* **The line buffer stride must be a power of two.** The half is selected by
  concatenation, which strides by 128, not by the 80 words a line uses. Sized at
  2x80 the upper half runs off the end after 32 words and every odd line loses
  everything past pixel 256.
* **Start the fetch at the start of the line, not at its blanking.** Because the
  buffer is double-buffered, line y+1 can be fetched throughout line y -- a full
  ~32 us. Triggering at the end of the active area leaves only the ~6 us
  horizontal blanking, and a line takes ~9 us to read.
* **TMDS disparity arithmetic must be signed throughout.** `cnt` declared signed
  but combined with unsigned operands makes Verilog evaluate the expression as
  unsigned, silently destroying the DC balancing -- a picture no monitor locks
  onto, with nothing else to go on.

### Testing it

**Running on hardware.** `fbtest` (greyscale ramp), `imgload` (a dithered
16-colour picture) and `texttest` (the full font and all 16 colours in text
mode) all display correctly on a monitor, which covers the SDRAM scanout, the
nibble order, the palette port, the mode switch, the font ROM and the HDMI
output together.

`sim/tb_tmds.v` round-trips every byte through the encoder and decodes it back
(1024 encodings), and checks the running disparity stays bounded on constant
`00`/`FF` streams -- the solid-colour worst case. `sim/tb_video.v` preloads the
SDRAM model with a known framebuffer and checks all 640 pixels of a line.

`sim/tb_video_text.v` does the same for text mode, but checks a whole frame --
all 307,200 pixels -- against the font image, since the likely faults there are
per-row. `rom/texttest.asm` draws the full character set and all 16 colours
from the CPU (`make texttest && make bit ROM=rom/texttest.mem && make prog`).

`test/hdmitest.v` is the bring-up ladder rung for video: colour bars straight
from the timing generator, no SDRAM and no CPU, proving clocks, encoding,
serializers and pins on their own. `rom/fbtest.asm` fills the framebuffer from
the CPU so the whole path can be checked at once.

`rom/imgload.asm` shows a real picture. At 150 KB the image cannot live in the
8 KB ROM, so the ROM receives it over the serial port instead -- 64 bytes of
palette, then the framebuffer -- and prints a 16-bit checksum that the host
compares with its own:

```sh
make imgload && make bit ROM=rom/imgload.mem    # once
make show                                       # img/nextcube.png, ~14 s to send
make show IMG=img/other.png                     # any 8-bit PNG
make show IMG_DISPLAY=4:3 IMG_BACK=000000       # square pixels, black surround
```

`tools/mkimage.py` does the conversion with the standard library alone: scale to
fit 640x480, median-cut to 15 colours plus black, and Floyd-Steinberg dither.
It also writes `*_preview.png`, which is what is in the framebuffer.

Two settings shape the result. `IMG_DISPLAY` is the shape of the monitor: the
default, `16:9`, is for a widescreen that stretches the 640x480 picture to fill
its screen, so the picture is stored narrower than it should look (and the
preview looks narrow too). Use `4:3` for a monitor that keeps the pixels
square. `IMG_BACK` is the colour around the picture: `edge`, the default, takes
it from the picture's top left corner, or give it as `RRGGBB`.

### Mandelbrot viewer

`apps/mandel.asm` is a program for the monitor rather than a ROM: it draws
the Mandelbrot set in graphics mode, and you can move around it and zoom in.

```sh
make mandel-load    # assemble, load at $2000 with tools/mload.py, and run
```

| Key | Does |
|---|---|
| arrows or WASD | move a quarter of the screen |
| `+` or `=`, `-` | zoom in, zoom out |
| `>` or `.`, `<` or `,` | 32 more or fewer iterations (32 to 512) |
| `R` | back to the starting view |
| `Q` | quit to the monitor |

Keys come from the serial port (the arrows as ANSI escape sequences) or from
the ADB keyboard. Any key starts the picture again from the top, so there is
no need to wait for a draw to finish. On quitting, the viewer restores the
default palette and text mode and clears the screen.

The arithmetic is 16-bit fixed point with 13 fraction bits, which allows
coordinates up to ±4. Multiplication uses a 32 KB table of squares built at
`$4000` when the program starts: x² and y² come from the table, and
2xy = 4((x+y)/2)² − x² − y², which is exact modulo 2¹⁶. The zoom stops at one
fixed-point step (1/8192) per pixel, five zooms in from the whole set, or
about 44 times. The direct page is moved to `$3F00` (D = `$003F`, as the
banked mode reads it), so the program uses nothing in the monitor's low
memory.

## Monitor commands

**Running on hardware.**

| Command | Does |
|---|---|
| `dm addr [count]` | dump memory: 64 bytes, or `count` |
| `sm addr byte ...` | set memory: store the bytes from `addr` upwards |
| `go addr` | call the code at `addr` |
| `ld` | load binary records from the serial port |
| `?` | list the commands |

Numbers are hexadecimal, up to six digits, with an optional leading `$`.
Addresses are 24 bits, so every bank is reachable -- `dm 700000` shows the
display memory. Commands and digits may be in either case. Anything the
monitor cannot parse gets a `?` and does nothing, except that `sm` stores byte
by byte and so has already written whatever came before a mistake.

`dm` prints 16 bytes to a line, then the same bytes as characters:

```
>dm 2000 6
002000: A9 2A 8D 00 30 6B                                 .*..0k
```

It reads each byte twice, once for each column, which matters only when
pointed at a register with read side effects such as the SCC's data register.

`go` enters the code with a long call, in native mode with an 8-bit
accumulator and 16-bit index registers. **Return with `RTL`**, not `RTS`. On
return the monitor restores its own modes, data bank and direct page, so the
code may leave those however it likes -- but it must leave the stack as it
found it.

MiniMon turns on the core's **banked direct page and stack**
([../docs/BankedDP.md](../docs/BankedDP.md)) at reset, so code entered with
`go` runs banked: D is a bank and page, and D = `$1230` puts the direct page
at `$12:3000` and the stack in bank `$12`. The monitor's own direct page (0)
and stack (page 1) are where they always were. Code may turn the mode off
(`WDM #$B0`); `go` turns it on again on the way back. It may move its direct
page and stack to another bank, but must have the stack back in bank 0 for
the `RTL`. A complete round trip:

```
>sm 2000 a9 2a 8d 00 30 6b      lda #$2a / sta $3000 / rtl
>go 2000
>dm 3000 1
003000: 2A                                                *
```

`ld` is for a program, not for typing: it takes a memory image far faster
than `sm`, because nothing is echoed or parsed. After the command the monitor
reads records, each a count (2 bytes, low first), an address (3 bytes, low
first), that many bytes of data and the sum of all of those modulo 256. It
answers a record with `+` if the sum is right and `-` if not, on the serial
port only, and the sender repeats a record answered with `-`. A record with a
count of zero ends the load. The bytes of a record need no pacing; the sender
only has to wait for the answer before the next record. If nothing arrives for
a few seconds the load is given up with a `?`. `tools/mload.py` is a sender.

Low memory in use: the direct page `$40`-`$6B` belongs to the console and the
interpreter, and the line buffer is the 256 bytes at `$1000`. Everything else
in SDRAM is free.

The interpreter is `interp.asm` and the commands `command.asm` in the mon tree.

## Console

**Running on hardware.** MiniMon prints to the display as well as the serial
port. Everything it sends goes to both, so the serial tools (`make boot`,
`make talk`) work exactly as before and the screen shows the same session.
Input comes from the serial port or an ADB keyboard, whichever has something
first.

The driver is `console.asm` in the mon tree. The monitor's output calls go to
`con_putc` instead of `ser_putc`, which sends the byte to the serial port and then
interprets it for the screen:

| Input | Effect on the display |
|---|---|
| printable | written at the cursor, cursor right, wrapping at column 80 |
| CR, LF, BS | column 0; down a row, scrolling at the bottom; cursor left |
| `ESC [ A` `B` `C` `D` | cursor up, down, right, left by one |
| `ESC [ K` | clear to end of line |
| any other `ESC [` sequence | swallowed |

That is the set the monitor itself emits -- `readline` edits the line with
cursor-left and clear-to-end-of-line -- not a general VT100. Counts in a
sequence are ignored; every move is by one.

The cursor is a cell with its attribute inverted. It is removed before each
character is handled and redrawn afterwards, so no other code has to know it
exists.

Scrolling and clearing are done by the [blitter](#blitter----03c0). A scroll is
one blit of rows 1-29 onto rows 0-28, followed by blanking the last row by
hand -- a blank cell is two different bytes, so it is not something a
single-colour fill can write. Clearing the screen blanks row 0 by hand and then
blits row 0 onto row 1 with a height of 29: the blitter works a line at a time,
so each line copies the one it has just written and the blank row spreads down
the screen. The console reads the cursor's attribute back through the CPU's
cache straight after a scroll, which works only because blitter writes
invalidate the cache.

It uses direct-page locations `$40`-`$59`, and text is grey on black (`$07`).

### Keyboard

**Tested in simulation only -- the external ADB circuit is not built yet.** On
the board, with nothing attached, the monitor polls a floating input for 20
seconds without producing a character and serial input is unaffected; that is
all the hardware can show so far.

While `con_getc` waits it polls the keyboard with Talk register 0 to device 2,
the default keyboard address. Three things shape the code:

* **Polling never blocks.** A transaction takes about 2 ms, which is 25
  character times at 115200 baud, and the serial port holds three received
  bytes. So the
  loop starts a poll, goes on checking the serial port, and collects the answer
  when the host reports it finished.
* **Only a clean packet counts**: done, no timeout, exactly two bytes, no
  collision. With no keyboard the sense pin floats, and noise must not turn
  into keystrokes.
* **A packet holds two events**, either of which can produce a character, so
  the second is kept for the next call. Cursor keys return three characters
  (`ESC [ D`) the same way, since that is what `readline` expects from a
  terminal.

Each event is a key code with bit 7 set on release. Shift, Control and Caps
Lock (either side) are tracked as held state; every other key acts on the way
down, through the US-layout tables in `kbdmap.asm`.

| Key | Gives |
|---|---|
| letters, digits, punctuation, keypad | the character; Shift and Caps Lock as usual |
| Control + letter | the control character, e.g. ctrl-A = `$01` |
| Return, keypad Enter | CR |
| Delete | `$7F`, which `readline` treats as backspace |
| forward Delete | ctrl-D, `readline`'s delete-forward |
| Tab, Escape | `$09`, `$1B` |
| arrows | `ESC [ A` `B` `C` `D` |
| Command, Option, function keys | nothing |

There is no key repeat, and the keyboard is not reset or re-addressed at start
-- it is assumed to be at its power-on address.

`sim/adb_kbd_model.v` is a behavioural keyboard for `tb_soc`: it answers Talk
register 0 with queued packets and is otherwise silent, as a real one is. Key
events are given in hex, two to a packet with `FF` for none:

```sh
# Shift+h, i, Shift+1, left arrow, Return  ->  "Hi!", cursor left, enter
vvp fpga/soc_con +screen +adbkeys=380484B822A238FF1292B8FF3BBB24A4
```

**The readline buffer moved from `$0200` to `$1000`.** When the I/O block went
to `$0200` the buffer was left sitting on top of it, so every typed character
was also written into an ACIA register -- including, every fourth character, the
one that resets it.

To see the screen without a board, ask the simulation for a dump. `make sim`
is too short and types too fast to scroll, so build a longer, slower one:

```sh
iverilog -g2005 -Irtl -Ptb_soc.TIMEOUT=60000000 \
    -Ptb_soc.SEND_DELAY=600000 -Ptb_soc.TYPE_GAP=200 -o soc_con \
    ../cpu_65c816.v rtl/*.v sim/tb_soc.v sim/sdram_model.v sim/adb_kbd_model.v \
    $GOWIN_SIM
cd .. && vvp fpga/soc_con +screen +send=hello +times=7    # enough to scroll
```

## Sound

Two SIDs, played through the board's MAX98357A amplifier and speaker
connector. The emulation is [reDIP SID](https://github.com/daglem/reDIP-SID)
by Dag Lem (CERN-OHL-S v2), in `rtl/sid/` with the changes listed in its
README; `rtl/sound.v` connects it to the SoC.

| Address | Register |
|---|---|
| `$0500`-`$051F` | SID 1, laid out as `$D400`-`$D41F` on a C64 |
| `$0520`-`$053F` | SID 2 |
| `$0540` | control, mirrored to `$057F` |

Control register:

| Bit | Meaning |
|---|---|
| 0 | amplifier on (pin 51). Resets to 1 |
| 1 | stereo: SID 1 left, SID 2 right. 0 (reset) puts the mix in both channels, for the mono amplifier |
| 2 | SID 1 is an 8580 (0: 6581) |
| 3 | SID 2 is an 8580 |
| 6 | read: a write was lost because the queue was full. Writing the register clears it |
| 7 | read: writes are still queued |

* **Clock.** The SIDs run at 985248 Hz (PAL), a clock enable from the
  25.2 MHz system clock, so the usual PAL frequency tables apply: 440 Hz is
  `$1D45`.
* **Writes are posted.** They go into a 64-entry queue, and one reaches the
  SIDs each SID cycle, in order, so the CPU never waits. A full register
  dump plays out within about 30 us, and timed tricks such as samples
  through the volume register keep their timing. Bit 7 of the control
  register says when the queue is empty.
* **Reads never wait.** OSC3 (`$1B`) and ENV3 (`$1C`) of each SID are read
  in idle SID cycles, so they return the latest value. POTX and POTY read
  `$FF` (nothing is connected), and the write-only registers read 0.
* **Audio.** Each SID gives a 24-bit sample every SID cycle. A one-pole
  lowpass at about 20 kHz takes off most of what would alias, and I2S takes
  49.2 kHz samples from it: BCLK is 25.2 MHz / 8, and a frame is 64 bits
  with 24 used in each half. The amplifier plays the left channel.
* **Stereo** needs a DAC on the same three pins, which are on the edge
  header too; see the Sound section of `docs/Hardware.md`.

From the monitor, a 440 Hz triangle on SID 1:

```
sm 505 09 f0        attack 0, decay 9, sustain 15, release 0
sm 518 0f           volume 15
sm 500 45 1d        frequency $1D45
sm 504 11           triangle, gate on   (sm 504 10 to release it)
```

**Simulation.** Icarus cannot parse reDIP SID's SystemVerilog, so the
simulations use `sim/sid_api_stub.v` in its place: same ports, takes writes
the same way, no sound. `sim/tb_sound.v` tests `sound.v` against it (posted
writes in order, the shadow reads, the control register, and mono and stereo
I2S frames):

```sh
iverilog -g2005 -o sound_sim rtl/sound.v sim/sid_api_stub.v sim/tb_sound.v
vvp sound_sim
```

**Synthesis** runs in SystemVerilog mode (`build.tcl`) for the SIDs; the rest
of the design is plain Verilog-2001 and reads the same. Gowin finds the SID
lookup tables relative to the source file.

## Serial: the SCC

The console's serial port is channel A of a Z85C30 SCC, the SCC half of the
Z85C80 that will be on the carrier board ([`docs/Hardware.md`](../docs/Hardware.md)).
Until the board exists, `rtl/scc_85c30.v` emulates it at the address the real
chip will have, so software moves across unchanged.

| Address | Register |
|---|---|
| `$0820` | channel B control |
| `$0821` | channel B data |
| `$0822` | channel A control: RR0 when the pointer is 0 |
| `$0823` | channel A data |

* **Channel A** is the board's serial port, through the BL616.
* **Channel B** has no pins: what is written to it is dropped, and it never
  receives.
* **Control port.** The first write to a control port sets the register
  pointer (WR0); the next access reads or writes that register and puts the
  pointer back to 0. A read of the control port therefore gives RR0 when
  nothing is pending. Polling needs RR0 bit 0 (a character is waiting) and
  bit 2 (the transmit buffer is empty).
* **Speed.** It runs at a fixed 115200 baud, 8N1, whatever the time constant
  says. MiniMon writes the values for 115200 from a 7.3728 MHz clock anyway,
  so its code is right for the real chip.
* **What's emulated.** The receive FIFO, overrun and framing errors, the Rx
  and Tx interrupts, MIE, RR2 and RR3 behave as on the real part. The
  module's header lists what doesn't, including the real part's recovery
  time between accesses.
* **Bus handshake.** It answers through the external bus's handshake, but
  the access never reaches the bus pins.

It replaces the 6551 ACIA that was at `$0200`. MiniMon, Business Basic,
Rockwell Forth and the test ROMs (through `rom/scc.asm`) all use it.

* **Interrupts.** After its hardware reset the SCC raises no interrupts
  until WR1 and MIE (WR9 bit 3) enable them. The Forth runs with IRQs on and
  relies on this.

`sim/tb_scc.v` checks the emulation against MiniMon's initialisation, with
channel A looped back:

```sh
iverilog -g2005 -o scc_sim rtl/scc_85c30.v rtl/uart_tx.v rtl/uart_rx.v sim/tb_scc.v
vvp scc_sim
```

## Blitter and the memory-master port

`rtl/blitter.v`; the software interface is under
[Blitter](#blitter----03c0).

### The memory-master port

The SDRAM controller has a third port for anything that reads and writes
memory by itself. Priority is fixed: display (port 0), then the memory-master
port (port 2), then the CPU's cache (port 1). The blitter is the only master on
it so far; DMA would share it through a multiplexer in `soc.v`.

A master on this port must do two things, and gets one for free:

* **Drop `req` for a cycle after every `done`.** It outranks the CPU, so a
  master that re-requests at once locks the CPU out. With the gap, the CPU gets
  one transaction between each of the master's.
* **Hold `req`, `we` and `addr` through the cycle `done` is high.** That is the
  cycle the cache samples them.
* **Cache coherency is automatic.** `soc.v` reports every write the port
  retires to the cache; a master needs no logic of its own for it.

### Cache invalidation

The cache used to rely on the CPU being the only writer. A write through the
memory-master port goes straight to SDRAM, so the cache is told about each one
and drops the line holding that word if it has it. Only a matching line is
dropped: blitting to the screen does not evict the program doing it.

Clearing the tag is the easy part. Three windows needed closing, each of which
the stress test in `sim/tb_cache.v` found or would have:

* **The held word** is answered without consulting the tag, so it is dropped
  the moment the report arrives rather than when the tag is cleared.
* **A lookup already in progress** may have read the tag while it was valid and
  be about to keep its data as the new held word. An invalidation that lands
  on the access in progress poisons it: the access completes, but leaves no
  held word.
* **A lookup starting during the few cycles an invalidation takes** would read
  the tag just before it is cleared. New lookups wait those cycles.

What is *not* a hazard: an invalidation can never overtake a line fill that
read the old data. A report is made only after the master's write has retired,
SDRAM transactions are serialized, and such a fill finished before the write
began.

The tag store now has a second read port for this, which the tools implement
by duplicating it.

### How the blitter works

A line at a time: read the source line into a buffer, read the destination
line into another, then write the destination back a word at a time. Reading
everything first is what makes horizontal overlap safe, and it suits the
memory -- SDRAM reads are aligned bursts of four words, writes are single
words, and a word in which every pixel is skipped is not written at all.

Bursts are aligned to four words, which is 32 pixels, so each line is read
from its address rounded down to a multiple of 32 and the low five bits say
where it starts in the buffer. Source pixel *q* of its buffer lands on
destination word *j*, pixel *q - K + 8 - 8j*, where *K* is the source offset
plus 8 minus the destination's offset within its first word. So the shift
between them is the constant *K mod 8* pixels, and the source word index just
counts up -- one 64-to-32-bit shifter and no per-word arithmetic.

The destination line is always read, even for a plain copy that overwrites
every pixel, because the partial words at each end need it and treating every
word alike keeps the control simple. That is about a quarter of the bandwidth
and the obvious thing to optimise. Burst writes would be the next.

### Testing it

`sim/tb_blitter.v` checks blits against a reference that knows nothing about
words, shifts or masks: an array of pixels, updated the way the definition
says. Ten directed cases (single pixel, full 1024 width, overlap, scrolling
both ways, fill, XOR, transparency, zero width) and 400 random ones, with
random alignment, strides of either sign, all 16 operations and deliberate
overlap. A second master reads continuously on the CPU's port throughout, to
check the blitter leaves it room.

`sim/tb_cache.v` has a master writing behind the cache: a cached line, the
held word, a different line in the same set (which must not be evicted), and
40 rounds of a write racing a CPU read at every phase offset.

`rom/blttest.asm` runs on the board (`make blttest && make bit
ROM=rom/blttest.mem && make prog`). It fills over bytes the CPU has just read
-- so they are cached and the last is the held word -- and checks the CPU reads
the fill back; with the invalidation disconnected that test fails. Then an
unaligned copy checked byte for byte, then a picture: blue screen, 16 colour
bars, the bars copied lower and 13 pixels right, and copied again with black
transparent.

## Boot ROM

8 KB at `$E000`-`$FFFF`, **16 bits wide**, and switchable out for RAM (see
[System control](#system-control----0300)).

The width is because instruction fetch is by far the largest source of bus
traffic and the 65C816 fetches it a byte at a time, so a 16-bit word covers two
consecutive byte addresses and halves the number of block RAM accesses.

It was briefly paired with a **one-word buffer** that answered the second byte
of a word in a single cycle -- measured 2.00 -> 1.55 cycles per ROM access over
159k accesses. That buffer is **disabled**, and deliberately so: its tag
comparator landed directly in front of the CPU's ALU
(`state -> address -> ROM tag compare -> byte mux -> rdata -> ALU -> fZ`) and
became the design's critical path. ROM reads are back to a flat **2 cycles**,
straight off the block RAM output register. Code of any size runs from SDRAM,
where the cache's held word gives a 1-cycle hit anyway, so the ROM was the
right place to give the cycle back. `rom_hit`/`rom_fast` are still in `soc.v`,
tied to 0.

The image itself is byte-wide: `soc.v` reads a word as its two bytes, and the
synthesiser builds the 16-bit read out of block RAM. That takes more blocks
than a word-wide image did (11 ROM blocks against 7 with the 16 KB Forth
ROM), with no change in timing.

## Apple Desktop Bus

`rtl/adb_host.v` is an ADB host controller for keyboard and mouse. Writing the
command register starts a transaction; length and data must be set up first.

| Address | Register |
|---|---|
| `$0280` | command `AAAA CCRR` -- **write triggers the transaction** |
| `$0281` | status `{busy, done, timeout, srq, count[3:0]}` |
| `$0282` | length: bytes to send for a Listen |
| `$0283` | write: bit 0 issues a 3 ms bus reset. read: bit 0 collision, bit 1 the line now (1 = high), bit 2 our drive now (1 = pulling low) |
| `$0288`-`$028F` | data 0-7 |

A command byte is address, command, register. `CC` = 11 Talk, 10 Listen; Flush
is lower nibble `0001` and SendReset is `$00`, neither of which has a data
phase. Interrupts are not implemented -- poll `busy`.

### Signalling

| | |
|---|---|
| bit cell | 100 us: `1` = 35 low / 65 high, `0` = 65 low / 35 high |
| attention | 800 us low |
| sync | 70 us high |
| data packet | `1` start bit, 2-8 bytes, `0` stop bit |
| SRQ | device holds the line low past the command stop bit |
| reset | 3 ms low |
| idle | at least 3 ms between transactions (`US_IDLE`) |

**Every duration is a parameter, deliberately.** The published figures disagree
with each other -- Microchip's AN591 gives Tlt as both 65-160 us and 160-240 us
in different paragraphs -- and devices are allowed +/-30% tolerance, so these
will need tuning against real hardware.

Transmit is timed open-loop; receive is edge-driven, decoding each bit from how
long the line was held low.

**The bus rests between transactions.** A command written less than
`US_IDLE` (3 ms) after the previous transaction ended is held, with busy set,
until it has. The published figures give no minimum gap, but a real keyboard
loses keys without one. Polled back to back, as MiniMon does at its prompt,
it lost about half of them. It still answered every poll cleanly, so the
missing keys were never sent at all. A 0.5 ms gap still lost one key in
seven, while 2 ms lost none in a hundred. The gap is enforced in the
controller, so every program that polls gets it. It is counted from the end
of our last transaction, not from the line going high, so a bus held down
still gets its command sent and reported as a collision, instead of waiting
forever.

### Wiring

Two unidirectional pins rather than one bidirectional: ADB is a 5V
open-collector bus and this is a 3.3V part, so an external buffer pulls the line
low (`adb_drive`, **pin 27**) and a level shifter feeds `adb_sense` (**pin 28**).
The FPGA never drives the bus high.

**Not pin 26.** It reads low on this board even with a pull-up, because it is
the HDMI hot-plug detect line (2.2k to the connector, 5.1k to ground). The
first symptom was a spurious SRQ on every transaction, because the host saw a
permanently low bus. `test/pintest.v` puts candidate pins on the LEDs to
check; 27-30 all float high.

### Bringing it up on hardware

**Working on a breadboard** with a 2N3904 and an Apple keyboard: Talk
register 3 to device 2 returns `$6x $02` (a random address, then handler 2),
and typing at MiniMon's prompt arrives without a key lost.

`$0283` bits 1 and 2 show the line and the drive as they are now, which is
what bringing the circuit up needs. `dm 283 1` should read `$02` with the
line idle and `$04` while it is driven. Two things that misled the bring-up:

* **MiniMon polls the keyboard continuously** while it waits at its prompt,
  so the line is never idle there. A multimeter averages the pulses: pin 27
  reads about 2V, the base about 0.5V and the data line about 1.9V, all with
  a working circuit. Measure with the CPU held in a loop that leaves ADB
  alone.
* A Talk to register 0 times out whenever no key is waiting; that is
  normal. Talk register 3 is the test: a keyboard always answers it.
* **Keys lost while every reply is clean** means polls are too close
  together (see the idle gap above), not a wiring fault.

* `adb_drive` (**pin 27**) -> an inverting transistor that pulls the bus low.
  FPGA high = bus low. `PULL_MODE=DOWN` keeps the transistor off while the FPGA
  is unconfigured, so the bus stays released.
* `adb_sense` (**pin 28**) <- a level shifter from the 5V bus.
  `PULL_MODE=NONE`: the bus has its own pull-up (R3) and an internal one would
  fight it and shift the sensed levels.
* The bus needs its pull-up and the device needs +5V; ADB's mini-DIN 4 carries
  data, power switch, +5V and ground.

**With nothing attached the sense pin floats**, so readings are meaningless
until R3 and the shifter are present -- that is the correct trade for real
hardware, not a bug.

`rom/adbtest.asm` issues a Talk to device 2 register 0, which is where a
keyboard lives by default, and prints the status. Reading the result:

| Result | Meaning |
|---|---|
| `status=60` | done, timeout -- nothing answered. Check wiring and levels. |
| `status=4x` | done, no timeout, `x` bytes returned. Working. |
| collision set (`$0283` bit 0) | the bus reads low while the host has released it. A drive polarity that is inverted the wrong way looks exactly like this, because the host would hold the bus down permanently. |
| `srq` set with nothing attached | the sense input is stuck low -- the symptom that showed pin 26 (HDMI hot-plug detect) could not be used. |

If a device answers but the data is wrong, the timings are all parameters on
`adb_host` (`US_BIT`, `US_LOW_1`, `US_LOW_0`, `US_TLT_MAX`, `US_RX_THRESH`,
`US_GLITCH`, `US_IDLE` ...). Devices are allowed +/-30% tolerance and the published Tlt
figures disagree with each other, so expect to tune `US_TLT_MAX` and
`US_RX_THRESH` first.

### Testing

`sim/tb_adb.v` runs the host against a behavioural device that decodes bit
cells the way a real one does, by measuring low time -- so a host that gets the
low/high split or the bit order wrong fails in simulation rather than on the
bench. It covers Talk (data returned and counted), a Talk to an absent device
(timeout), and Listen (bytes arriving at the device).

`rom/adbtest.asm` issues a Talk from the CPU and prints the status. With nothing
attached it reports `status=60` -- done, timeout, no SRQ -- which matches the
simulation exactly.

## Cache

`rtl/cache.v` sits between the CPU and SDRAM: direct-mapped, 256 lines x 16
bytes = 4 KB, in block RAM. A line is exactly one SDRAM read burst, so a miss
costs one burst and nothing is fetched that is not used.

**Write-through, because a display shares the memory.** The video scan reads the
framebuffer out of SDRAM continuously and asynchronously, so there is no safe
moment to flush dirty lines -- "flush before the next scan" means every frame.
Writing through keeps SDRAM authoritative at all times, which is what makes the
video read path correct with no coherency machinery at all. Writes do not
allocate: a store that misses updates SDRAM only.

**Stores are posted.** The write is handed to SDRAM and the CPU released in the
same cycle, and read hits continue to be served from the array while it drains.
An earlier version retired the write only when the CPU went idle -- and the CPU
is essentially never idle, so every store stalled behind the previous one and
the cache was barely faster than none. Ordering is kept by making anything that
needs the SDRAM port (a line fill, or another store) wait for the in-flight
write; a read that hits needs no port, so it never waits.

### The read path is 32 bits wide

The storage always was -- four byte-wide arrays read in parallel -- but the
interface used to hand back one byte and discard the other three, so every byte
cost a full lookup. The last word read is now held and any further byte inside
it is answered combinationally in one cycle.

Measured on memtest (SDRAM-heavy), against the uncached 6.06 cycles per access:

| | Uncached | Byte cache | **32-bit cache** |
|---|---|---|---|
| SDRAM reads | 6.06 cyc | 3.06 cyc | **1.02 cyc** |
| SDRAM writes | 6.06 cyc | 5.98 cyc | **3.03 cyc** |
| Cache hit | - | 3 cyc | **1 cyc** |

Writes improved as a side effect: reads no longer occupy the port for three
cycles each, so stores queue behind them far less.

On hardware the full 128-bank memtest went from 10.1 s to 8.6 s; about 4 s of
that is the fixed retention delay, so the actual work is roughly 25% faster.

**This costs timing.** Slack fell to +0.076 ns on a 37 ns period -- 0.2% margin,
33 logic levels. The critical path is inside the CPU (`state` -> `fZ`, the ALU
flag path), and the cache's combinational ack feeds its enable term. It works at
room temperature but there is no margin for process, voltage or temperature.
Registering the fast-path ack would take same-word reads from 1 cycle back to 2
-- still far better than 3 -- and remove the contribution.

That margin was at 27 MHz. The system clock has since come down to 25.2 MHz,
and the compare has been taken out of the read-data path altogether without
giving up the single-cycle hit -- see [Synthesis](#synthesis-gowin-eda).

Reads are at the structural floor for this handshake: one cycle to read the
array, one to compare and answer, one for the CPU to see the ack and present
the next address. Writes are unchanged because they are port-bound, not
latency-bound -- consecutive stores queue behind each other. **A deeper write
buffer is the next worthwhile optimisation**; a single posted write absorbs an
isolated store but not a burst of them.

### Keep equality off the carry chain

The held-word comparator is written as an XOR followed by a NOR-reduce, not as
`==`. Written as three `==` compares the tools mapped 21 bits onto the **carry
chain** -- seven ripple stages -- and this comparator gates the combinational
`ack` that feeds the CPU's ALU, so it landed squarely on the critical path.
XOR-reduce gives a LUT tree of about three levels instead: **26.3 -> 27.8 MHz,
margin 4.3% -> 10.2%**, with the single-cycle hit intact.

Worth remembering for any wide equality that feeds `rdy` or the ALU.

### Byte lanes and block RAM

The data store is four byte-wide arrays, not one 32-bit array. A cache has to
write a single byte lane, and block RAM has no partial-word write: expressed as
`data[n][7:0] <= x` the Gowin tools cannot infer BSRAM and sit in "Running
inference" for minutes. One array per lane makes every write a whole-element
write and infers immediately.

## SDRAM

`rtl/sdram_ctrl.v` drives the 64 Mbit die inside the GW2AR-18 package:
4 banks x 2048 rows x 256 columns x **32 bits** = 8 MB.

Two things about it are unlike the rest of the design:

* **Its pins are not in the `.cst`.** The die is bonded inside the package and
  the tools connect it by *reserved port names* — `O_sdram_addr`, `IO_sdram_dq`
  and friends on the top-level module. Adding them to the constraints file is
  wrong; leaving them out is what makes it work.
* **It runs on the inverted clock.** `O_sdram_clk` is `~clk`, so the SDRAM's
  rising edge lands in the middle of our cycle and both directions get setup
  and hold. This is the cheap equivalent of the 180-degree PLL output other
  designs use, and at 25.2 MHz there is enormous margin.

Every access is issued with **auto-precharge**, so the controller never tracks
open rows and refresh can go out whenever it is idle. Addresses are mapped
`{row, bank, column}` so sequential bytes stay within one row — the row only
changes every 1 KB, which is what makes a future burst or cache layer pay off.

Measured in simulation, an SDRAM access costs **6.06 cycles** against block
RAM's **2.00** — about 3x. With all of bank 0 (direct page, stack, everything)
now in SDRAM, that slowdown applies to essentially all data traffic; only
instruction fetch from the boot ROM still runs at two cycles. This is the
motivation for the cache in `docs/soc-architecture-notes.md`, not a defect.

Removing the block RAM freed 16 of the 20 BSRAM blocks the design used (44% ->
9% of the device), which is the budget that cache will want.

### An assembler trap when crossing banks

`sta $0000,x` assembles to **direct-page** indexed (`$95`), which always
addresses bank 0 and ignores DBR — so a bank-crossing loop silently writes over
bank 0 instead. Use the `.w` suffix (`sta.w $0000,x` -> `$9D`) to force
absolute,X, which is DBR-relative. Note that `!$0000` does *not* force absolute
here: the `!` is parsed as an operator, quietly yielding `sta $01,x`.

### Testing it

```sh
make memtest                  # assemble rom/memtest.asm
make bit ROM=rom/memtest.mem  # bake it in
make boot                     # run it
```

`rom/memtest.asm` fills banks `$01`-`$7F` with a pattern, waits about four
seconds, then verifies — printing `PASS` or the failing bank and offset. Two
details make it an actual test rather than a formality:

* **Fill everything first, verify last.** The earliest bytes are checked many
  seconds after they were written, which is what exercises refresh. A
  write-then-immediately-read test never reaches the 64 ms retention window and
  would pass with refresh completely broken.
* **The pattern includes the bank number.** With a bank-independent pattern
  every bank holds identical data, so a broken bank decode that aliased all of
  them onto one would still compare equal and pass.

It covers every bank the die has, so the full 8 MB decode is exercised.

`sim/tb_sdram.v` drives the controller against `sim/sdram_model.v`, a
behavioural model written to the datasheet definition of the protocol rather
than to match this controller — it complains about accesses to closed rows,
reads before initialization and out-of-range addresses. It caught two real bugs
during bring-up: the auto-precharge bit placed at `A8` instead of `A10`, and a
missing recovery cycle that made every access run twice. Run it with:

```sh
iverilog -g2005 -o /tmp/sdsim rtl/sdram_ctrl.v sim/sdram_model.v sim/tb_sdram.v && vvp /tmp/sdsim
```

## Next

### Blocking demo work

* **Keyboard input through MiniMon is untested on hardware.** The ADB host
  talks to a real keyboard (see [Apple Desktop Bus](#apple-desktop-bus)), but
  typing into the monitor has not yet been tried with a display attached.

### Performance

* **Deeper write buffer.** Stores cost 3.03 cycles against reads at 2.03: they
  are port-bound, not latency-bound, and consecutive stores queue. One posted
  write absorbs an isolated store but not a burst.
* **Eliminate the fetch cycle.** The 6502 hides its opcode fetch in the previous
  instruction's last cycle, so `IR` and the control signals are ready before the
  instruction starts. This core cannot: it has no dead cycles to hide a fetch
  in. `rtl/prefetch.v` (32-bit, tested, **not integrated**) is the fetch source
  that would make it possible, and it only pays off as part of this change --
  on throughput alone the cache's held word already beats it.
* **Split I/D caches.** The architecture notes argued against them because of
  self-modifying code; that constraint has since been dropped, which removes the
  objection. Instruction fetch is 84% of traffic and purely sequential, so an
  I-cache with a wide line suits it while data keeps the write-through path.
* **Faster SDRAM clock.** Would not help the critical path -- the SDRAM
  controller is not on it -- but would cut miss cost (~18 cycles, mostly burst)
  and roughly quadruple video bandwidth headroom. Needs a clock-domain crossing.
* **True 16-bit CPU data bus.** *Measured and deprioritised.* Only ~12% of bus
  accesses are 16-bit data pairs at all, and measured alignment was 1-2% (hot
  loops sit at fixed addresses, so a loop is lucky or unlucky forever). The
  realistic gain is 0-6% of accesses for a restructure of an FSM reached from 16
  call sites. The wins came from the ROM width, the 32-bit cache path and the
  registered decode instead.

### Features not started

* **SPI flash bootloader.** Load RAM from flash at boot instead of running from
  the 8 KB ROM: programs stop being size-limited, and the BSRAM comes back. The
  ROM/RAM soft switch at `$0300` is the half of this that now exists -- a
  bootloader would shadow flash into `$E000`-`$FFFF` and clear the bit, exactly
  as `make romswitch` demonstrates. Not needed for timing; registering the ROM
  read path already fixed that.

### Rockwell Forth

RSC-FORTH (source in `../../RockwellForth/src`) runs on this board in two
ways, from the same source:

```sh
make forth-load                    # into RAM under MiniMon, then a terminal
make forth-load L="HEX 1F 2 + ."   # ... or type these lines and print the replies
make forth-rom forth-bit           # as a ROM in place of MiniMon
```

`make forth-load` assembles the `T20K` target, 16 KB at `$A000`-`$DFFF`, sends
it with the monitor's `ld` command (`tools/mload.py`) and starts it with
`go c008`. The board must be at the MiniMon prompt and nothing else may have
the serial port open. `tools/mload.py prog.hex start` loads any program built
with `as -o prog.hex` the same way.

`make forth-rom forth-bit` builds the `T20KROM` target, the same Forth at
`$C000`-`$FFFF`, into a bitstream with a 16 KB ROM. Either way the development
ROM comes first, then the console driver at +`$2000` and the kernel at
+`$3000`:

* 65C816 **native mode** with 8-bit registers. The kernel is still 6502 code;
  only the three places that relied on zero-page wrap-around and the two `TXS`
  uses were changed, because native mode does neither the 6502 way.
* Console on the **text display and the serial port**, input from serial or
  the ADB keyboard, using MiniMon's driver (`ForthConsole-T20K.asm`).
* User variables and input buffer at `$1000`, dictionary from `$1100`, disk
  buffers in the 2 KB below the Forth -- all moved out of the I/O block.
* `BANK@`, `BANK!`, `BANKC@ ( addr bank -- b )` and `BANKC! ( b addr bank -- )`
  reach all 8 MB:
  `HEX 41 0 70 BANKC!` puts an `A` in the top left of the screen.
* No disk: the disk registers point at eight zero bytes in the image.

`make forth-rom forth-bit FORTH_MACHINE=65C02 FORTH_MAP=1` builds the unmodified
6502 Forth instead, in emulation mode against the R6501 serial registers of the
old Forth map (no display).

Why the earlier attempt hung: the 65C816 cold start never cleared `INTFLAG`,
which `NEXT` tests on every word, and the development ROM held about fifty raw
addresses that were only right for the R6501Q layout. Both are fixed in the
source; the R6501Q target still assembles byte-for-byte to the Rockwell ROMs.

### Housekeeping

* Only **one LED** is left (pin 20, heartbeat). The other five went to the
  external bus, which needs 20 pins and the board has barely that many free.
  `test/blinky.v` and `test/btntest.v` still declare `led[5:0]` and will not
  place against the current `.cst`.
* The I/O move to `$0200` touched the **mon tree** as well: `minimon.asm` now
  assembles at `org=$e000`. Its `serial.asm` now drives the SCC at `$0820`.
  That tree is outside this repo.
* The simulation's UART monitor in `sim/tb_soc.v` drops characters on
  back-to-back output; hardware does not. Trust the board, not the sim, for
  anything that prints a lot.
* `math.asm` is still excluded from minimon (invalid addressing modes in
  `print_i`), so no decimal number printing.
