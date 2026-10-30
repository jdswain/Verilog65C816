//============================================================================
// soc.v -- 65C816 SoC: CPU + boot ROM + cached SDRAM + serial, video, ADB
//          and the external bus
//
// Board independent: it takes the system and pixel clocks and a reset, and
// exposes each device's pins. `top_tang20k.v` supplies the clocks and the pin
// mapping.
//
// Memory map (bank 0; all other banks read as $FF):
//   $00_0000-$7F_FFFF   SDRAM  8 MB   (in-package die), except:
//     $00_0000-$00_01FF RAM           (never decoded as I/O -- see below)
//     $00_0200-$00_0FFF I/O    3.5 KB (see below)
//     $00_E000-$00_FFFF ROM    8 KB   (block RAM, loaded from ROM_HEX); 16
//                                     or 32 KB from $C000 or $8000 with
//                                     ROM_BITS 14 or 15
//   $80_0000-$FF_FFFF   unmapped, reads $FF
//
// I/O lives at the BOTTOM of bank 0, because the boot ROM now wants the whole
// $E000-$FFFF for itself. The first two pages are deliberately left as RAM:
// putting registers over $0000-$00FF and $0100-$01FF would take away the
// default direct page and the emulation-mode stack, and the CPU comes out of
// reset in emulation mode with D = $0000.
//
//   $0200-$023F   unclaimed, reads $FF (was the 6551 ACIA)
//   $0240-$027F   palette: 16 entries x 4 bytes {red, green, blue, -}
//   $0280-$02BF   keyboard: Apple Desktop Bus host (adb_host.v)
//   $02C0-$02FF   SD card in SPI mode (sd_spi.v)
//   $0300-$033F   system control (ROM/RAM soft switch)
//   $0340-$037F   external bus control (external_bus.v)
//   $0380-$03BF   video control (graphics/text mode)
//   $03C0-$03FF   blitter (blitter.v)
//   $0400-$043F   DMA engine (dma.v)
//   $0440-$047F   interrupt status and mask, tick timer (timer.v)
//   $0480-$04FF   unclaimed, reads $FF
//   $0500-$057F   sound: two SIDs and a control register (sound.v)
//   $0580-$07FF   unclaimed, reads $FF
//   $0800-$0FFF   external bus window -- 4 cards x 16 registers:
//                   $0800+$00.. card 0 (IO0#)   $0820.. card 2 (IO2#)
//                   $0810..     card 1 (IO1#)   $0830.. card 3 (IO3#)
//                 and mirrored every 64 bytes to the end of the window.
//                 $0820-$082F is the emulated SCC (scc_85c30.v), the serial
//                 port, which answers instead of card 2.
//
// The boot ROM is a SOFT SWITCH. $0300 bit 0 resets to 1 (ROM mapped) and
// clearing it hands the ROM's range back to SDRAM, vectors included. Writes
// there always go to SDRAM whichever way the switch is set, so the boot ROM
// can copy itself, or load anything else, into the RAM underneath and then
// flip the switch -- after which the range is ordinary cached memory.
//
// The Makefile sizes the ROM to its image (tools/romimage.py): the smallest
// of 8, 16 or 32 KB that holds it, so only as much of bank 0 reads as ROM
// as the image needs.
//
// The SDRAM die is 64 Mbit = 8 MB, which is exactly banks $00-$7F. The other
// half of the 65C816's 16 MB space has no storage behind it: covering it would
// mean aliasing onto the lower half, which is left undone deliberately so that
// software running off the end of memory faults visibly instead of silently
// corrupting bank $00.
//
// The boot ROM has to stay in block RAM -- SDRAM is volatile and uninitialized
// at power-up, so something non-volatile must hold the reset vector. It and the
// I/O block are overlaid on top of the SDRAM range in bank 0.
//
// Bus timing: the core drives `addr`/`vld` and expects `rdata` to be valid on
// the rising edge where `rdy` is high. Block RAM reads are registered, so every
// access takes two cycles: cycle 0 presents the address with `rdy` low, cycle 1
// returns the data with `rdy` high. Because the core holds the bus steady
// across the wait state, peripherals must be strobed only on cycle 0 -- that is
// what `stb` is for. Using `vld` directly would run every side effect twice.
//============================================================================
`default_nettype none

module soc #(
    parameter         ROM_HEX   = "rom.mem",
    // Text-mode font. Like ROM_HEX this is resolved against the tool's working
    // directory; the default suits simulation from the repository root, and the
    // top level overrides it with an absolute path for synthesis.
    parameter         FONT_HEX  = "fpga/rom/font_st8x16.hex",
    parameter integer DIVISOR   = 234,      // clk cycles per serial bit
    parameter         USE_SDRAM = 1,
    // Memory map selection.
    //   MAP_MINIMON: 8 KB ROM at $E000, I/O block at $0200-$0FFF (SCC at $0820)
    //   MAP_FORTH:   16 KB ROM at $C000, R6501 serial at $0015-$0017
    // The Rockwell Forth is two ROMs -- kernel $F000-$FFFF and development
    // $C000-$DFFF -- with an I/O block at $E000 that would hold a disk
    // controller. We have no disk, so the whole $C000-$FFFF window is ROM and
    // the disk registers simply read back ROM filler.
    parameter integer MAP       = 0,
    parameter         USE_VIDEO = 1,
    parameter integer SYS_HZ    = 25_200_000,   // the clock: timings derive from it
    parameter integer ROM_BITS  = 13,       // 8 KB
    parameter [15:0]  ROM_BASE  = 16'hE000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rxd,
    output wire       txd,
    output wire       led,           // heartbeat, active high
    // Debug taps: let a wrapper watch what the CPU is doing without depending
    // on the serial port working.
    output wire [23:0] dbg_addr,
    output wire        dbg_vld,
    output wire        dbg_we,
    output wire        dbg_stopped,
    output wire [31:0] dbg_cache_hits,
    output wire [31:0] dbg_cache_misses,
    // SDRAM die (reserved port names, connected at the top level)
    output wire [10:0] sdram_a,
    output wire [1:0]  sdram_ba,
    inout  wire [31:0] sdram_dq,
    output wire [3:0]  sdram_dqm,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire        sdram_cke,
    output wire        sdram_clk,
    // video (pixel clock domain)
    input  wire        clk_pix,
    input  wire        pix_rst_n,
    output wire [7:0]  vid_red,
    output wire [7:0]  vid_green,
    output wire [7:0]  vid_blue,
    output wire        vid_hsync,
    output wire        vid_vsync,
    output wire        vid_de,
    // Apple Desktop Bus, split into drive and sense (5V level shifting is
    // external; the FPGA never drives the bus high).
    output wire        adb_drive,
    input  wire        adb_sense,
    // External peripheral bus (see external_bus.v). The data bus is split into
    // in/out/oe here; the top level builds the tristate.
    output wire [3:0]  ext_a,
    input  wire [7:0]  ext_d_in,
    output wire [7:0]  ext_d_out,
    output wire        ext_d_oe,
    output wire [2:0]  ext_sel,
    output wire        ext_sel_en_n,
    output wire        ext_rd_n,
    output wire        ext_wr_n,
    output wire        ext_res_n,
    input  wire        ext_irq_n,
    // DMA (dma.v, docs/DMA.md): the devices' requests, and terminal count
    input  wire [1:0]  dma_drq,
    output wire        dma_tc,
    // Sound: I2S to the board's MAX98357A, and its enable (see sound.v)
    output wire        i2s_bclk,
    output wire        i2s_lrck,
    output wire        i2s_din,
    output wire        amp_en,
    // The microSD slot in SPI mode (sd_spi.v)
    output wire        sd_clk,
    output wire        sd_mosi,
    output wire        sd_cs_n,
    input  wire        sd_miso
);
    localparam [15:0] ROM_MASK = ~((16'd1 << ROM_BITS) - 16'd1);
    localparam integer MAP_MINIMON = 0;
    localparam integer MAP_FORTH   = 1;

    //------------------------------------------------------------------
    // CPU
    //------------------------------------------------------------------
    wire [23:0] addr;
    wire [7:0]  wdata;
    reg  [7:0]  rdata;
    wire        we, vld;
    wire        rdy;
    wire        vpa, vda, vpb_n, mlb_n;
    wire        e_flag, m_flag, x_flag, stopped;
    wire        scc_int_n;
    // External bus outputs, declared early because they feed the CPU's IRQ
    // input and the wait-state logic, both of which sit above the instance.
    wire [7:0]  ext_q;
    wire        ext_ack;
    wire        ext_irq;
    wire [1:0]  dma_irq;
    wire        tmr_irq;

    //------------------------------------------------------------------
    // Interrupt status and mask, $0440
    //
    // The tick timer, the DMA engine's two channels, the external cards and
    // the SCC share the 816's single IRQ line. $0440 shows which of them is
    // asking, so the handler reads one register before going to the chips:
    //   $0440 ISTAT (read)  0 timer, 1 DMA channel 0, 2 DMA channel 1,
    //                       3 cards, 4 SCC; each is the source's own level
    //                       (cleared at the source), before the mask. Bit
    //                       4 is the emulated SCC; the real one will be on
    //                       the card line, bit 3
    //   $0441 IMASK         1 = the source reaches the IRQ; $FF at reset
    // The rest of $0440-$044F reads 0; the tick timer is at $0450
    // (timer.v), and $0440-$045F repeats at $0460.
    //
    // IRQ is a level input sampled between instructions, so registering the
    // merge costs nothing and keeps the extra gates out of the CPU's own
    // logic.
    //------------------------------------------------------------------
    wire [7:0] istat = {3'd0, ~scc_int_n, ext_irq, dma_irq, tmr_irq};
    reg  [7:0] imask;
    reg irq_n;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) irq_n <= 1'b1;
        else        irq_n <= ~|(istat & imask);
    end

    wire [7:0] sdram_q;
    wire [31:0] sdram_q32;              // the cache's word, for the CPU's queue
    reg  [31:0] rdata32;
    reg         r32;
    wire [7:0] blt_q;
    wire [7:0] dma_q;
    // The DMA engine's cycles on the external bus (external_bus.v's DMA port)
    wire        dma_breq, dma_bwe, dma_btc, dma_back;
    wire [2:0]  dma_bslot;
    wire [7:0]  dma_bwdata;
    wire [7:0]  bridge_q;
    wire       sdram_ack;
    wire       sdram_init_done;
    wire [31:0] cache_hits, cache_misses;

    // The SDRAM needs ~200 us of initialization before it will answer, and with
    // bank 0 in SDRAM the very first stack push would land there. Hold the CPU
    // in reset until the controller reports ready.
    wire cpu_rst_n = rst_n & sdram_init_done;

    cpu_65c816 u_cpu (
        .clk(clk), .rst_n(cpu_rst_n),
        .addr(addr), .wdata(wdata), .rdata(rdata),
        .rdata32(rdata32), .r32(r32),
        .we(we), .vld(vld), .rdy(rdy),
        .irq_n(irq_n), .nmi_n(1'b1), .abort_n(1'b1),
        .vpa(vpa), .vda(vda), .vpb_n(vpb_n), .mlb_n(mlb_n),
        .e_flag(e_flag), .m_flag(m_flag), .x_flag(x_flag), .stopped(stopped)
    );

    //------------------------------------------------------------------
    // Address decode (needed by the wait-state logic below)
    //------------------------------------------------------------------
    // Declared ahead of the decode it feeds; the register itself is written
    // further down, where the select that writes it exists.
    reg rom_en;

    wire bank0    = (addr[23:16] == 8'h00);

    // ROM occupies a power-of-two block at the top of bank 0, so this is a
    // compare of the leading address bits rather than a mask-and-match.
    wire rom_area = bank0 & ((addr[15:0] & ROM_MASK) == ROM_BASE);

    // The soft switch only redirects READS. Writes to the ROM range always
    // land in SDRAM, which is what lets software shadow the ROM into the RAM
    // underneath it and only then flip the switch.
    wire sel_rom  = rom_area & rom_en & ~we;

    // I/O block at $0200-$0FFF. Only in the default map: the Forth map puts
    // its ROM across $C000-$FFFF and its serial in page zero, so there is no
    // window -- and its page-zero registers would collide with this one.
    //
    // The (addr[11:9] != 0) term is what carves $0000-$01FF back out as RAM.
    wire page0    = (MAP == MAP_MINIMON) & bank0 & (addr[15:12] == 4'h0);
    wire sel_io   = page0 & (addr[11:9] != 3'd0);
    wire sel_ext  = sel_io & addr[11];                       // $0800-$0FFF
    wire io_lo    = sel_io & ~addr[11];
    wire sel_pal  = io_lo & (addr[10:6] == 5'd9);            // $0240-$027F
    wire sel_adb  = io_lo & (addr[10:6] == 5'd10);           // $0280-$02BF
    wire sel_sd   = io_lo & (addr[10:6] == 5'd11);           // $02C0-$02FF
    wire sel_sys  = io_lo & (addr[10:6] == 5'd12);           // $0300-$033F
    wire sel_extc = io_lo & (addr[10:6] == 5'd13);           // $0340-$037F
    wire sel_vid  = io_lo & (addr[10:6] == 5'd14);           // $0380-$03BF
    wire sel_blt  = io_lo & (addr[10:6] == 5'd15);           // $03C0-$03FF
    wire sel_dma  = io_lo & (addr[10:6] == 5'd16);           // $0400-$043F
    wire sel_irq  = io_lo & (addr[10:6] == 5'd17);           // $0440-$047F
    wire sel_snd  = io_lo & (addr[10:7] == 4'b1010);         // $0500-$057F
    wire sel_r6501 = (MAP == MAP_FORTH) & bank0 & (addr[15:8] == 8'h00)
                   & (addr[7:0] >= 8'h15) & (addr[7:0] <= 8'h17);
    wire sel_ser  = sel_r6501;
    // Everything below bank $80 that is not ROM or I/O.
    //
    // Note this excludes `sel_io`, not the device selects inside it: excluding
    // one of those as well is redundant -- and when the ACIA's was, it dragged
    // the I/O sub-decode (io_lo, then a 5-bit compare) into the path. That
    // matters because sel_sdram feeds `rdy`, which gates the CPU's ALU: the
    // chain was bank0 -> sel_io -> io_lo -> sel_acia -> sel_sdram -> rdy, three
    // comparators deep in series. Only sel_r6501 needs excluding separately,
    // because in the Forth map it sits in page zero rather than the I/O block.
    wire sel_sdram = (USE_SDRAM != 0) & ~addr[23] & ~sel_rom & ~sel_io
                                      & ~sel_r6501;

    //------------------------------------------------------------------
    // Wait states. Block RAM and on-chip I/O answer in one wait cycle; SDRAM
    // takes as long as it takes and reports completion with its own ack.
    //------------------------------------------------------------------
    // The held-word compare is NOT used to shortcut `rdy`. Timing analysis put
    // this comparator directly in front of the CPU's ALU:
    //   state -> address -> ROM tag compare -> byte mux -> rdata -> ALU -> fZ
    // which is the design's critical path. The ROM is only 8 KB and code of any
    // size runs from SDRAM, so the cache keeps its single-cycle hit and the ROM
    // gives one up: two cycles, but read data comes straight off a register.
    wire rom_hit  = 1'b0;
    wire rom_fast = 1'b0;

    // Selects that answer with their own ack rather than the fixed one-cycle
    // handshake: SDRAM (variable latency) and the external bus (1-2 us).
    wire slow = sel_sdram | sel_ext;

    // The SD controller can hold the second cycle open (sd_stall) while an
    // exchange it waits for finishes. sd_stall is a register of its own, so
    // this adds no decode to the paths into rdy.
    wire sd_stall;
    reg busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) busy <= 1'b0;
        else        busy <= (vld & ~slow & ~rom_fast & ~busy) | (busy & sd_stall);
    end

    wire stb = vld & ~slow & ~rom_fast & ~busy;

    //------------------------------------------------------------------
    // System control, $0300
    //
    //   bit 0   1 = boot ROM mapped at $E000-$FFFF (reset default)
    //           0 = SDRAM is mapped there instead, vectors included
    //
    // Resets to 1 because there is nothing else to boot from: SDRAM is
    // volatile and holds garbage at power-up, so the reset vector has to come
    // out of block RAM. Code that clears the bit must already be running from
    // somewhere other than the ROM, or have copied the ROM down first --
    // otherwise the very next instruction fetch comes from uninitialised RAM.
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    rom_en <= 1'b1;
        else if (stb & sel_sys & we)   rom_en <= wdata[0];
    end

    wire [7:0] sys_q = {7'd0, rom_en};

    //------------------------------------------------------------------
    // Video control, $0380
    //
    //   bit 0   0 = 640x480 16-colour graphics (reset default)
    //           1 = 80x30 text
    //
    // Both modes read the same memory at $70_0000; the bit only changes how
    // video.v interprets it, and takes effect at the top of the next frame.
    //------------------------------------------------------------------
    reg vid_text;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    vid_text <= 1'b0;
        else if (stb & sel_vid & we)   vid_text <= wdata[0];
    end

    wire [7:0] vid_q = {7'd0, vid_text};


    // A ROM word already in the buffer answers in the same cycle.
    // Kept as a mux chain. The OR-of-ANDs form that looks cheaper on paper
    // (busy is guaranteed 0 during a slow access, so it needs no guard) was
    // measured at 25.6 MHz against this version's 27.4 -- the mapper folds the
    // mux into the same LUT as the select and the flat form does not.
    assign rdy = sel_sdram ? sdram_ack : sel_ext ? ext_ack
                                         : (rom_fast | (busy & ~sd_stall));

    //------------------------------------------------------------------
    // Boot ROM, 32 bits wide.
    //
    // The CPU's instruction queue fills a word at a time, so a fetch from ROM
    // brings four bytes for one two-cycle access. Read data comes straight
    // off the block RAM output register.
    //
    // The image is a byte-wide memory file (`as -o rom.mem`): the bytes of
    // the ROM in order from its base, with no addresses in it, ROM_BYTES of
    // them (the Makefile pads a shorter image at the bottom). A word is read
    // as its four bytes.
    //------------------------------------------------------------------
    localparam integer ROM_BYTES = (1 << ROM_BITS);

    reg [7:0] rom [0:ROM_BYTES-1];
    initial $readmemh(ROM_HEX, rom);

    // 32 bits wide, for the CPU's instruction queue, which takes a word.
    wire [ROM_BITS-1:0] rom_word = {addr[ROM_BITS-1:2], 2'b00};

    reg [31:0] rom_q;
    always @(posedge clk)
        rom_q <= {rom[rom_word | 2'd3], rom[rom_word | 2'd2],
                  rom[rom_word | 2'd1], rom[rom_word]};

    // Straight off the block RAM output register, then a 4:1 byte select --
    // by the address bits as they were in the strobe cycle (see the read mux).
    reg         rom_r;
    reg  [1:0]  a10_r;
    wire [7:0]  rom_byte = rom_q[{a10_r, 3'b000} +: 8];

    //------------------------------------------------------------------
    // R6501 serial port, for the Forth map only. In the default map the
    // serial port is the SCC's channel A (below, with the external bus).
    //------------------------------------------------------------------
    wire [7:0] ser_q;
    wire       ser_txd, scc_txd;
    assign txd = ser_txd & scc_txd;     // only one of them is ever active

    generate
    if (MAP == MAP_FORTH) begin : g_r6501
        // $15 -> 0, $16 -> 1, $17 -> 2
        serial_r6501 #(.DIVISOR(DIVISOR)) u_ser (
            .clk(clk), .rst_n(rst_n),
            .reg_sel(addr[1:0] - 2'd1), .wdata(wdata), .rdata(ser_q),
            .cs(stb & sel_r6501), .we(we),
            .rxd(rxd), .txd(ser_txd)
        );
    end else begin : g_noser
        assign ser_q   = 8'hFF;
        assign ser_txd = 1'b1;
    end
    endgenerate

    //------------------------------------------------------------------
    // SDRAM
    //------------------------------------------------------------------
    generate
    if (USE_SDRAM != 0) begin : g_sdram
        // CPU -> cache -> port 1 of the burst controller. Port 0 is reserved
        // for the video fetch, which outranks the CPU because a late scanline
        // is visible and a late instruction fetch is merely slow.
        wire        c_mreq, c_mwe, c_mdone, c_mrvalid;
        wire [20:0] c_maddr;
        wire [31:0] c_mwdata, m_rdata;
        wire [3:0]  c_mwmask;

        // The memory-master port's signals (see below), declared here because
        // the cache snoops them: port 2 as mm_mux drives it.
        wire        b_req, b_we, b_done, b_rvalid;
        wire [20:0] b_addr;
        wire [31:0] b_wdata;
        wire [3:0]  b_wmask;
        wire        c_wr_busy;

        cache u_cache (
            .clk(clk), .rst_n(rst_n),
            .addr(addr[22:0]), .wdata(wdata), .rdata(sdram_q), .rdata32(sdram_q32),
            .ifetch(vpa & ~vda),          // the CPU's instruction-queue fills
            .req(vld & sel_sdram), .we(we), .ack(sdram_ack),
            .m_req(c_mreq), .m_we(c_mwe), .m_addr(c_maddr),
            .m_wdata(c_mwdata), .m_wmask(c_mwmask),
            .m_done(c_mdone), .m_rvalid(c_mrvalid), .m_rdata(m_rdata),
            // Every write the memory-master port retires is reported here, so
            // the cache never serves what a blit has since overwritten. The
            // master holds its request through the cycle `done` is high.
            .inv_valid(b_done & b_we), .inv_addr(b_addr),
            .wr_busy(c_wr_busy),
            .stat_hits(cache_hits), .stat_misses(cache_misses)
        );

        // The memory-master port: port 2 of the burst controller, below the
        // display and above the CPU. The blitter and the DMA engine share it
        // through mm_mux, the engine first.
        wire        bl_req, bl_we, bl_done, bl_rvalid;
        wire [20:0] bl_addr;
        wire [31:0] bl_wdata;
        wire [3:0]  bl_wmask;
        wire        dm_req, dm_we, dm_done, dm_rvalid;
        wire [20:0] dm_addr;
        wire [31:0] dm_wdata;
        wire [3:0]  dm_wmask;

        blitter u_blitter (
            .clk(clk), .rst_n(rst_n),
            .reg_addr(addr[5:0]), .wdata(wdata), .rdata(blt_q),
            .cs(stb & sel_blt), .we(we),
            .m_req(bl_req), .m_we(bl_we), .m_addr(bl_addr),
            .m_wdata(bl_wdata), .m_wmask(bl_wmask),
            .m_done(bl_done), .m_rvalid(bl_rvalid), .m_rdata(m_rdata),
            .busy()
        );

        // DRQ is looked at again some 80 ns after a cycle.
        dma #(.DRQ_HOLD((SYS_HZ + 6_250_000) / 12_500_000)) u_dma (
            .clk(clk), .rst_n(rst_n),
            .reg_addr(addr[4:0]), .wdata(wdata), .rdata(dma_q),
            .cs(stb & sel_dma), .we(we), .irq(), .irq_ch(dma_irq),
            .drq(dma_drq),
            .b_req(dma_breq), .b_we(dma_bwe), .b_slot(dma_bslot),
            .b_tc(dma_btc), .b_wdata(dma_bwdata),
            .b_rdata(bridge_q), .b_ack(dma_back),
            .m_req(dm_req), .m_we(dm_we), .m_addr(dm_addr),
            .m_wdata(dm_wdata), .m_wmask(dm_wmask),
            .m_done(dm_done), .m_rvalid(dm_rvalid), .m_rdata(m_rdata),
            .wr_busy(c_wr_busy)
        );

        mm_mux u_mm_mux (
            .clk(clk), .rst_n(rst_n),
            // The blitter, like the DMA engine, starts nothing while a CPU
            // store is still queued in the cache: it reads what was written.
            .b_req(bl_req), .b_hold(c_wr_busy), .b_we(bl_we), .b_addr(bl_addr),
            .b_wdata(bl_wdata), .b_wmask(bl_wmask),
            .b_done(bl_done), .b_rvalid(bl_rvalid),
            .d_req(dm_req), .d_we(dm_we), .d_addr(dm_addr),
            .d_wdata(dm_wdata), .d_wmask(dm_wmask),
            .d_done(dm_done), .d_rvalid(dm_rvalid),
            .p_req(b_req), .p_we(b_we), .p_addr(b_addr),
            .p_wdata(b_wdata), .p_wmask(b_wmask),
            .p_done(b_done), .p_rvalid(b_rvalid)
        );

        // Video owns port 0 and outranks the CPU on port 1.
        wire        v_req, v_we, v_done, v_rvalid;
        wire [20:0] v_addr;
        wire [31:0] v_wdata;
        wire [3:0]  v_wmask;

        if (USE_VIDEO != 0) begin : g_video
            video #(.FONT_HEX(FONT_HEX)) u_video (
                .clk(clk), .rst_n(rst_n),
                .m_req(v_req), .m_we(v_we), .m_addr(v_addr),
                .m_wdata(v_wdata), .m_wmask(v_wmask),
                .m_done(v_done), .m_rvalid(v_rvalid), .m_rdata(m_rdata),
                .clk_pix(clk_pix), .pix_rst_n(pix_rst_n),
                .red(vid_red), .green(vid_green), .blue(vid_blue),
                .hsync(vid_hsync), .vsync(vid_vsync), .de(vid_de),
                .pal_we(stb & sel_pal & we), .pal_idx(addr[5:2]),
                .pal_sel(addr[1:0]), .pal_byte(wdata),
                .text_mode(vid_text)
            );
        end else begin : g_no_video
            assign v_req = 1'b0; assign v_we = 1'b0; assign v_addr = 21'd0;
            assign v_wdata = 32'd0; assign v_wmask = 4'd0;
            assign vid_red = 8'd0; assign vid_green = 8'd0; assign vid_blue = 8'd0;
            assign vid_hsync = 1'b1; assign vid_vsync = 1'b1; assign vid_de = 1'b0;
        end

        sdram_burst #(.FREQ(SYS_HZ)) u_sdram (
            .clk(clk), .rst_n(rst_n),
            .p0_req(v_req), .p0_we(v_we), .p0_addr(v_addr),
            .p0_wdata(v_wdata), .p0_wmask(v_wmask),
            .p0_done(v_done), .p0_rvalid(v_rvalid),
            .p1_req(c_mreq), .p1_we(c_mwe), .p1_addr(c_maddr),
            .p1_wdata(c_mwdata), .p1_wmask(c_mwmask),
            .p1_done(c_mdone), .p1_rvalid(c_mrvalid),
            .p2_req(b_req), .p2_we(b_we), .p2_addr(b_addr),
            .p2_wdata(b_wdata), .p2_wmask(b_wmask),
            .p2_done(b_done), .p2_rvalid(b_rvalid),
            .rdata(m_rdata), .init_done(sdram_init_done),
            .sdram_a(sdram_a), .sdram_ba(sdram_ba), .sdram_dq(sdram_dq),
            .sdram_dqm(sdram_dqm), .sdram_cs_n(sdram_cs_n),
            .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
            .sdram_we_n(sdram_we_n), .sdram_cke(sdram_cke)
        );
        // The die runs on the inverted clock: its rising edge then sits in the
        // middle of our cycle, giving setup and hold on both directions.
        assign sdram_clk = ~clk;
    end else begin : g_no_sdram
        assign vid_red = 8'd0; assign vid_green = 8'd0; assign vid_blue = 8'd0;
        assign vid_hsync = 1'b1; assign vid_vsync = 1'b1; assign vid_de = 1'b0;
        assign sdram_q         = 8'hFF;
        assign sdram_q32       = 32'hFFFF_FFFF;
        assign blt_q           = 8'hFF;
        assign dma_q           = 8'hFF;
        assign dma_irq         = 2'd0;
        assign dma_breq        = 1'b0;
        assign dma_bwe         = 1'b0;
        assign dma_bslot       = 3'd0;
        assign dma_btc         = 1'b0;
        assign dma_bwdata      = 8'd0;
        assign cache_hits      = 32'd0;
        assign cache_misses    = 32'd0;
        assign sdram_ack       = 1'b1;
        assign sdram_init_done = 1'b1;
        assign sdram_a    = 11'd0;
        assign sdram_ba   = 2'd0;
        assign sdram_dq   = 32'hzzzz_zzzz;
        assign sdram_dqm  = 4'hF;
        assign sdram_cs_n = 1'b1;
        assign sdram_ras_n = 1'b1;
        assign sdram_cas_n = 1'b1;
        assign sdram_we_n  = 1'b1;
        assign sdram_cke   = 1'b0;
        assign sdram_clk   = 1'b0;
    end
    endgenerate

    //------------------------------------------------------------------
    // Apple Desktop Bus host (keyboard / mouse)
    //------------------------------------------------------------------
    wire [7:0] adb_q;

    adb_host #(.CLK_HZ(SYS_HZ)) u_adb (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(addr[3:0]), .wdata(wdata), .rdata(adb_q),
        .cs(stb & sel_adb), .we(we),
        .adb_drive(adb_drive), .adb_sense(adb_sense)
    );

    //------------------------------------------------------------------
    // The microSD slot in SPI mode, $02C0 (sd_spi.v)
    //------------------------------------------------------------------
    wire [7:0] sd_q, sd_rx;

    sd_spi #(.SYS_HZ(SYS_HZ)) u_sd (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(addr[1:0]), .wdata(wdata), .rdata(sd_q), .rx(sd_rx),
        .cs(stb & sel_sd), .we(we), .stall(sd_stall),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_cs_n(sd_cs_n), .sd_miso(sd_miso)
    );

    //------------------------------------------------------------------
    // Sound: two SIDs (reDIP SID, rtl/sid/) on the I2S amplifier
    //------------------------------------------------------------------
    wire [7:0] snd_q;

    sound #(.SYS_HZ(SYS_HZ)) u_snd (
        .clk(clk), .rst_n(rst_n),
        .addr(addr[6:0]), .wdata(wdata), .rdata(snd_q),
        .cs(stb & sel_snd), .we(we),
        .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_din(i2s_din),
        .amp_en(amp_en)
    );

    //------------------------------------------------------------------
    // External peripheral bus
    //
    // The window is $0800-$0FFF: eight slots of 16 registers, addr[6:4] the
    // select code for the carrier's '138 and addr[3:0] A3-A0, mirrored every
    // 128 bytes. Intel RD#/WR# strobes on an 8.4 MHz timing (external_bus.v).
    //
    // $0340 is the bridge's own control register (not on the external bus):
    //   write bit 0 = hold RES asserted to the cards
    //   read  bit 0 = card IRQ is asserted
    //------------------------------------------------------------------
    reg card_reset;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                         card_reset <= 1'b0;
        else if (stb & sel_extc & we)       card_reset <= wdata[0];
    end

    wire [7:0] extc_q = {7'd0, ext_irq};

    //------------------------------------------------------------------
    // Interrupt mask ($0441) and the tick timer ($0450); see $0440 above
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                                     imask <= 8'hFF;
        else if (stb & sel_irq & we & ~addr[4] & (addr[3:0] == 4'd1))
                                                        imask <= wdata;
    end

    wire [7:0] tmr_q;
    // The timer counts at 25.2 MHz at any system clock of 25.2 MHz or more
    // (SYS_HZ a multiple of 100 kHz).
    timer #(.TNUM(252), .TDEN(SYS_HZ / 100_000)) u_timer (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(addr[3:0]), .wdata(wdata), .rdata(tmr_q),
        .cs(stb & sel_irq & addr[4]), .we(we), .pending(tmr_irq)
    );

    wire [7:0] irq_q = addr[4]             ? tmr_q :
                       addr[3:0] == 4'd0   ? istat :
                       addr[3:0] == 4'd1   ? imask : 8'd0;

    //------------------------------------------------------------------
    // Emulated SCC, $0820-$082F
    //
    // The SCC half of the Z85C80 that will be on the carrier, at the
    // address the carrier gives it: card select 2 of the external bus. Until
    // the board exists this answers instead, with channel A on the board's
    // serial port, and the bridge never sees the access. It answers through
    // the external bus's handshake, so the wait-state logic is unchanged.
    //------------------------------------------------------------------
    wire       scc_slot = (addr[6:4] == 3'd2);     // slot 2, mirrored as the bridge's
    wire       scc_req  = vld & sel_ext & scc_slot;
    wire [7:0] scc_q;
    wire       bridge_ack;
    reg  [1:0] scc_st;                  // 0 idle, 1 ack, 2 gap
    wire       scc_cs = scc_req & (scc_st == 2'd0);
    wire       scc_ack = (scc_st == 2'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) scc_st <= 2'd0;
        else case (scc_st)
            2'd0:    if (scc_req) scc_st <= 2'd1;
            2'd1:    scc_st <= 2'd2;     // the CPU takes the data and moves on
            default: scc_st <= 2'd0;
        endcase
    end

    scc_85c30 #(.DIVISOR(DIVISOR)) u_scc (
        .clk(clk), .rst_n(rst_n),
        .addr(addr[1:0]), .wdata(wdata), .rdata(scc_q),
        .cs(scc_cs), .we(we), .int_n(scc_int_n),
        .rxd(rxd), .txd(scc_txd)
    );

    assign ext_ack = bridge_ack | scc_ack;
    assign ext_q   = scc_ack ? scc_q : bridge_q;

    // T at least 119 ns, H at least 40 ns, in system clocks.
    external_bus #(
        .T_CLKS((SYS_HZ + 8_399_999) / 8_400_000),
        .H_CLKS((SYS_HZ + 25_199_999) / 25_200_000)
    ) u_ext (
        .clk(clk), .rst_n(rst_n),
        .addr(addr[10:0]), .wdata(wdata), .rdata(bridge_q),
        .req(vld & sel_ext & ~scc_slot), .we(we), .ack(bridge_ack),
        .dma_req(dma_breq), .dma_we(dma_bwe), .dma_slot(dma_bslot),
        .dma_tc(dma_btc), .dma_wdata(dma_bwdata), .dma_ack(dma_back),
        .card_reset(card_reset), .irq(ext_irq),
        .ext_a(ext_a), .ext_d_in(ext_d_in), .ext_d_out(ext_d_out),
        .ext_d_oe(ext_d_oe), .ext_sel(ext_sel), .ext_sel_en_n(ext_sel_en_n),
        .ext_rd_n(ext_rd_n), .ext_wr_n(ext_wr_n), .ext_tc(dma_tc),
        .ext_res_n(ext_res_n), .ext_irq_n(ext_irq_n)
    );

    //------------------------------------------------------------------
    // Read mux.
    //
    // Nothing here is selected by the address decode of the current cycle.
    // It used to be -- a one-hot OR over every select -- and that put the
    // CPU's address generation and the whole decode in front of the read
    // data, and so in front of the ALU and the flags:
    //     state -> address -> decode -> this mux -> adder -> flags
    // was the design's critical path. Each kind of access now says for itself,
    // from a register, when its data is the one on the bus:
    //
    //   ROM and on-chip I/O  take two cycles. The decode is done in the first
    //       (the strobe cycle) and registered, one flop per device; `busy`
    //       marks the second cycle, in which those flops pick the byte.
    //   The external bus     flags its data with `ext_ack`.
    //   SDRAM                is whatever is left: the cache has its own
    //       registered select inside it.
    //
    // Only the selects are registered, not the data. Some devices register
    // their own read data on the strobe (the R6501 serial port does), so it is not there to
    // be captured until the cycle after.
    //
    // Anything unclaimed reads $FF: it takes the I/O path, and the palette
    // and the empty ranges set none of the flops.
    //
    // The SD card's DATA and NEXT are read from its own register, not
    // captured on the strobe: an access that waits gets the byte at the end.
    //------------------------------------------------------------------
    reg r_ser, r_adb, r_extc, r_sys, r_vid, r_blt, r_dma, r_irq, r_snd, r_none;
    reg r_sd, r_sdrx;

    always @(posedge clk) if (stb) begin
        rom_r  <= sel_rom;
        a10_r  <= addr[1:0];
        r_ser  <= sel_ser;
        r_adb  <= sel_adb;
        r_extc <= sel_extc;
        r_sys  <= sel_sys;
        r_vid  <= sel_vid;
        r_blt  <= sel_blt;
        r_dma  <= sel_dma;
        r_irq  <= sel_irq;
        r_snd  <= sel_snd;
        r_sd   <= sel_sd;
        r_sdrx <= ~addr[1];
        r_none <= ~(sel_ser | sel_adb | sel_extc | sel_sys | sel_vid | sel_blt
                    | sel_dma | sel_irq | sel_snd | sel_sd);
    end

    // The ADB host's, the blitter's, the DMA engine's and $0440's read data
    // are combinational from the address, which put address -> device mux ->
    // rdata -> ALU back on the critical path. Capture them on the strobe.
    reg [7:0] adb_q_r, blt_q_r, dma_q_r, irq_q_r, sd_q_r;
    always @(posedge clk) if (stb) begin
        sd_q_r  <= sd_q;
        adb_q_r <= adb_q;
        blt_q_r <= blt_q;
        dma_q_r <= dma_q;
        irq_q_r <= irq_q;
    end

    wire [7:0] io_q = ({8{r_ser}}  & ser_q)
                    | ({8{r_adb}}  & adb_q_r)
                    | ({8{r_extc}} & extc_q)
                    | ({8{r_sys}}  & sys_q)
                    | ({8{r_vid}}  & vid_q)
                    | ({8{r_blt}}  & blt_q_r)
                    | ({8{r_dma}}  & dma_q_r)
                    | ({8{r_irq}}  & irq_q_r)
                    | ({8{r_snd}}  & snd_q)
                    | ({8{r_sd}}   & (r_sdrx ? sd_rx : sd_q_r))
                    | {8{r_none}};

    always @* begin
        if (busy)         rdata = rom_r ? rom_byte : io_q;
        else if (ext_ack) rdata = ext_q;
        else              rdata = sdram_q;
    end

    // The whole word, for the CPU's instruction queue: ROM and SDRAM have
    // one (r32); I/O and the external bus give their byte only.
    always @* begin
        if (busy)         begin rdata32 = rom_q;     r32 = rom_r; end
        else if (ext_ack) begin rdata32 = 32'h0;     r32 = 1'b0;  end
        else              begin rdata32 = sdram_q32; r32 = 1'b1;  end
    end

    //------------------------------------------------------------------
    // Status LEDs
    //------------------------------------------------------------------
    reg [23:0] heartbeat;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) heartbeat <= 24'd0;
        else        heartbeat <= heartbeat + 1'b1;
    end

    // Only one LED survives: the other five pins went to the external bus.
    assign led = heartbeat[23];

    assign dbg_addr    = addr;
    assign dbg_vld     = vld;
    assign dbg_we      = we;
    assign dbg_stopped = stopped;
    assign dbg_cache_hits   = cache_hits;
    assign dbg_cache_misses = cache_misses;
endmodule

`default_nettype wire
