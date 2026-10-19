#=============================================================================
# fpga/Makefile -- simulation and ROM build for the Tang Nano 20K SoC
#
#   make sim        build and run the SoC simulation (fast, accelerated baud)
#   make real       same, but at the true 27 MHz / 115200 clock ratio
#   make send S=dm  type a command into the monitor after boot
#   make rom        rebuild fpga/rom/minimon.mem from the monitor sources
#   make lint       elaborate the synthesis top-level
#
# Synthesis is driven from the Gowin IDE; see fpga/README.md for the file list
# and project settings.
#=============================================================================
IVERILOG ?= iverilog
VVP      ?= vvp
AS816    ?= $(HOME)/Developer/1av/65/65Tools/bin/as

TOP      := top_tang20k
ROOT     := ..
RTL      := $(ROOT)/cpu_65c816.v $(wildcard rtl/*.v)
IFLAGS   := -Irtl
# sid_api_stub.v stands in for the SIDs (rtl/sid/), whose SystemVerilog
# Icarus cannot parse.
TB       := sim/tb_soc.v sim/sdram_model.v sim/adb_kbd_model.v sim/sid_api_stub.v
# Which image gets baked into the bitstream. Override to build a variant:
#   make bit ROM=rom/memtest.mem
ROM      ?= rom/minimon.mem
# Memory map baked into the bitstream: 0 = minimon (8 KB ROM at $E000, I/O
# block at $0200), 1 = Rockwell Forth (16 KB ROM at $C000, R6501 serial at $0015).
MAP      ?= 0
ROM_BITS ?= 13
ROM_BASE ?= 16'hE000
ROM_VH   := rtl/rom_path.vh
# Text-mode font, built from the EmuTOS source by `make font`.
FONT     := rom/font_st8x16.hex

# Where the monitor sources live. `make rom` needs the fixes described in
# fpga/README.md applied there.
MON_DIR  ?= $(HOME)/Developer/1av/65/mon/src

# Real board ratio: 27 MHz crystal, 115200 baud.
REAL_PARAMS := -Ptb_soc.DIVISOR=234 -Ptb_soc.CLK_HALF=19 \
               -Ptb_soc.TIMEOUT=30000000 -Ptb_soc.TYPE_GAP=5

GOWIN    ?= /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA
# Vendor primitive models (rPLL, CLKDIV, OSER10, ELVDS_OBUF). Needed to
# elaborate the top level outside the Gowin tools; synthesis supplies its own.
GOWIN_SIM := $(GOWIN)/IDE/simlib/gw2a/prim_sim.v
GW_SH    := $(GOWIN)/IDE/bin/gw_sh
GW_ENV   := DYLD_FRAMEWORK_PATH=$(GOWIN)/IDE/lib DYLD_LIBRARY_PATH=$(GOWIN)/IDE/lib
BIT      := impl/pnr/soc816.fs
PROG     := $(GOWIN)/Programmer/bin/programmer_cli
DEVICE   := GW2AR-18C

.PHONY: all sim real send lint rom image show memtest exttest romswitch adbtest fbtest maptest imgload texttest blttest font forth forth-load forth-rom forth-bit mandel mandel-load bit prog boot talk flash scan clean

all: sim

soc_sim: $(RTL) $(TB) $(ROM) $(ROM_VH)
	$(IVERILOG) -g2005 $(IFLAGS) -o $@ $(RTL) $(TB) $(GOWIN_SIM)

soc_sim_real: $(RTL) $(TB) $(ROM) $(ROM_VH)
	$(IVERILOG) -g2005 $(IFLAGS) $(REAL_PARAMS) -o $@ $(RTL) $(TB) $(GOWIN_SIM)

sim: soc_sim
	@cd $(ROOT) && $(VVP) fpga/soc_sim

real: soc_sim_real
	@cd $(ROOT) && $(VVP) fpga/soc_sim_real

# Type a string into the monitor once it has booted:  make send S="dm e000"
send: soc_sim
	@cd $(ROOT) && $(VVP) fpga/soc_sim +send=$(S)

lint: $(RTL) $(ROM_VH)
	$(IVERILOG) -g2005 $(IFLAGS) -s lint_top -o /dev/null $(RTL) sim/lint_top.v sim/sid_api_stub.v $(GOWIN_SIM)

# The assembler resolves includes relative to the source file and stores the
# cwd in a 100-byte buffer, so it must run from the source directory and the
# path to it must be short.
rom:
	cd $(MON_DIR) && $(AS816) -o $(CURDIR)/rom/minimon.mem minimon.asm

# The Rockwell Forth, 16 KB: the development ROM, the console driver and the
# kernel. `make forth-load` assembles it at $A000, sends it to the board with
# MiniMon's ld command and starts it, then passes the terminal through until
# control-]. The board must be running a MiniMon that has ld, and nothing else
# may have the serial port open. L="HEX 1F 2 + ." types lines instead.
FORTH_SRC   ?= $(HOME)/Developer/1av/65/RockwellForth/src
FORTH_ENTRY ?= c008
forth:
	cd $(FORTH_SRC) && $(AS816) -o $(CURDIR)/rom/forth.hex -Dmachine='"T20K"' ForthDevelopment.asm

forth-load: forth
	python3 tools/mload.py rom/forth.hex $(FORTH_ENTRY) $(if $(L),"$(L)")

# Programs that run in RAM under MiniMon, in apps/. `make mandel` assembles
# the Mandelbrot viewer to apps/mandel.hex; `make mandel-load` sends it with
# MiniMon's ld and starts it at $2000, then passes the terminal through (its
# keys work from the terminal as well as the ADB keyboard) until control-].
apps/mandel.hex: apps/mandel.asm rom/mon-fixes/65816.asm
	cd apps && $(AS816) -o mandel.hex mandel.asm

mandel: apps/mandel.hex

mandel-load: apps/mandel.hex
	python3 tools/mload.py apps/mandel.hex 2000

# The same Forth as a ROM at $C000 in place of the monitor, and the bitstream
# with it. The 65C02 build runs in emulation mode against the R6501 serial
# registers of the old Forth map:
#   make forth-rom forth-bit FORTH_MACHINE=65C02 FORTH_MAP=1
FORTH_MACHINE ?= T20KROM
FORTH_MAP     ?= 0
forth-rom:
	cd $(FORTH_SRC) && $(AS816) -o $(CURDIR)/rom/forth.mem -Dmachine='"$(FORTH_MACHINE)"' ForthDevelopment.asm

forth-bit: forth-rom
	$(MAKE) bit ROM=rom/forth.mem MAP=$(FORTH_MAP) ROM_BITS=14 ROM_BASE="16'hC000"

# The SDRAM exerciser. Self-contained: its macro include lives in rom/.
memtest:
	cd rom && $(AS816) -o memtest.mem memtest.asm

# The ADB and framebuffer exercisers.
adbtest fbtest maptest imgload texttest blttest:
	cd rom && $(AS816) -o $@.mem $@.asm

# Show a picture on the display: convert it, then program the already-built
# imgload bitstream and send the picture over the serial port (~14 s).
#   make imgload && make bit ROM=rom/imgload.mem && make show
# This deliberately does not depend on $(BIT), which would rebuild it around
# whatever ROM is the default.
# IMG_DISPLAY is the shape of the monitor: 16:9 for a widescreen that stretches
# the 640x480 picture to fill the screen, 4:3 for one that keeps it square.
IMG ?= img/nextcube.png
IMG_DISPLAY ?= 16:9
IMG_BACK ?= edge
image:
	python3 tools/mkimage.py $(IMG) $(IMG:.png=.fb) --preview $(IMG:.png=_preview.png) \
	    --display $(IMG_DISPLAY) --background $(IMG_BACK)

show: image
	python3 tools/board.py load $(BIT) $(IMG:.png=.fb)

# Rebuild the text-mode font ROM from the EmuTOS source.
font:
	python3 tools/mkfont.py font/fnt_st_8x16.c $(FONT)

# The ROM/RAM soft switch exerciser.
romswitch:
	cd rom && $(AS816) -o romswitch.mem romswitch.asm

# The external-bus exerciser.
exttest:
	cd rom && $(AS816) -o exttest.mem exttest.asm

# $readmemh resolves relative to the tool's working directory, and Gowin runs
# synthesis from impl/gwsynthesis/, so the path has to be absolute.
#
# This is always regenerated rather than being timestamp-driven: its contents
# depend on the ROM *variable*, so `make bit ROM=other.mem` followed by a plain
# `make bit` would otherwise leave a newer-looking file still naming the old
# image and quietly build the wrong ROM into the bitstream. It only replaces
# the file when the contents actually change, so nothing rebuilds needlessly.
.PHONY: $(ROM_VH)
$(ROM_VH):
	@printf '// Generated by make -- do not edit.\n`define ROM_HEX_PATH "%s"\n`define FONT_HEX_PATH "%s"\n`define ROM_MAP %s\n`define ROM_BITS_DEF %s\n`define ROM_BASE_DEF %s\n' \
	    "$(abspath $(ROM))" "$(abspath $(FONT))" "$(MAP)" "$(ROM_BITS)" "$(ROM_BASE)" > $@.tmp
	@if cmp -s $@.tmp $@; then rm -f $@.tmp; \
	 else mv $@.tmp $@; echo "generated $@ -> $(abspath $(ROM))"; fi

# Synthesis + place & route. A missing ROM image is only a warning to the
# Gowin tools -- they will happily build a bitstream with a blank ROM -- so
# check for it explicitly and fail the build instead.
bit: $(ROM) $(FONT) $(ROM_VH) $(RTL) tang_nano_20k.cst tang_nano_20k.sdc build.tcl
	$(GW_ENV) $(GW_SH) build.tcl
	@if grep -q 'Cannot open file' impl/gwsynthesis/soc816.log; then \
	    echo; echo "*** ROM or font image was not loaded:"; \
	    grep 'Cannot open file' impl/gwsynthesis/soc816.log; \
	    echo "*** the bitstream would have a blank ROM or font -- refusing."; \
	    rm -f $(BIT); exit 1; \
	fi
	@echo "bitstream: $(BIT)"

# Load into FPGA SRAM: takes effect immediately, lost on power cycle.
# This is the one to use while iterating.
prog: $(BIT)
	cd $(GOWIN)/Programmer/bin && ./programmer_cli \
	    --device $(DEVICE) --operation_index 2 \
	    --fsFile $(abspath $(BIT))

# Write the bitstream to the board's external SPI flash so it survives a power
# cycle. Operation 9 is "exFlash Erase,Program,Verify"; 2 (used by `prog`) loads
# FPGA SRAM and is lost on power-down. Flashing takes appreciably longer than
# an SRAM load, and is always recoverable -- the FPGA still accepts a JTAG SRAM
# load regardless of what is in flash.
flash: $(BIT)
	@cd $(GOWIN)/Programmer/bin && ./programmer_cli \
	    --device $(DEVICE) --operation_index 9 \
	    --fsFile $(abspath $(BIT)) \
	    | grep -viE 'programing:|programming\.\.\.|erasing|verify\.\.\.' 

# Program and show the boot banner.
boot: $(BIT)
	python3 tools/board.py boot $(BIT)

# Type a line at the monitor:  make talk C="dm e000"
talk:
	python3 tools/board.py send "$(C)"

# Is a board attached?
scan:
	cd $(GOWIN)/Programmer/bin && ./programmer_cli --scan

clean:
	rm -f soc_sim soc_sim_real $(ROM_VH) $(ROOT)/soc.vcd
	rm -rf impl
