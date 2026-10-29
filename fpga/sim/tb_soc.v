//============================================================================
// tb_soc.v -- simulate the SoC and print whatever it sends over the serial
// line, so the boot ROM can be exercised without hardware.
//
//   vvp soc_sim                 run to the timeout
//   vvp soc_sim +send=dm e000   type a command into the monitor after boot
//   vvp soc_sim +send=x +times=6   ... six times over, to make it scroll
//   vvp soc_sim +screen         print the text screen at the timeout
//   vvp soc_sim +adbkeys=04842224   press keys on the ADB keyboard: hex key
//                               events, two to a packet, FF = no event
//============================================================================
`timescale 1ns / 1ps
`default_nettype none
// The ROM `make` chose (ROM=, default MiniMon), sized to its image
`include "rom_path.vh"

module tb_soc #(
    // Overridable at build time, e.g.
    //   iverilog -Ptb_soc.DIVISOR=234 -Ptb_soc.CLK_HALF=19 ...
    // to model the real 27 MHz / 115200 baud ratio.
    parameter integer DIVISOR  = 8,         // short bit cells: this is a sim
    parameter integer CLK_HALF = 5,         // 100 MHz nominal
    parameter integer TIMEOUT  = 4_000_000,
    // Idle time between typed characters. The monitor echoes each character
    // and ser_putc blocks until the transmitter drains, so input sent with no
    // gap overruns the SCC's three-byte receive FIFO -- which is what a real
    // terminal paste does too. A human typing leaves a gap this wide.
    parameter integer TYPE_GAP = 30,
    // The image as the ROM holds it (rtl/rom_image.mem, padded to the ROM's
    // size) and the ROM's size and base, from rom_path.vh. To run another
    // image, `make sim ROM=rom/X.mem` rather than overriding these: the
    // three must agree, or the reset vector is fetched from past the end
    // of the loaded image, reads x, and the SoC sits there with rdy = x.
    parameter         ROM_HEX   = `ROM_HEX_PATH,
    parameter integer MAP       = 0,
    parameter integer ROM_BITS  = `ROM_BITS_DEF,
    parameter [15:0]  ROM_BASE  = `ROM_BASE_DEF,
    parameter integer SEND_DELAY = 200_000,
    // Words of SDRAM modelled: all 8 MB, because the monitor's console writes
    // the text screen at $70_0000. Run with +screen to print that screen at
    // the timeout.
    parameter integer MEM_WORDS = 2097152
) ();

    reg clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    reg rst_n = 1'b0;

    wire txd;
    reg  rxd = 1'b1;
    wire       led;

    // 25.2 MHz pixel clock, near enough for simulation.
    reg clk_pix = 1'b0;
    always #20 clk_pix = ~clk_pix;

    wire [10:0] sa; wire [1:0] sba; wire [3:0] sdqm; wire [31:0] sdq;
    wire scs_n, sras_n, scas_n, swe_n, scke, sclk;

    // ADB, open collector: low if either end pulls (see below).
    wire adb_drive, kbd_drive;
    wire adb_bus = ~(adb_drive | kbd_drive);

    // DRQ1 as the bare board has it with +drq1 (pin 80's pull-up): channel 1
    // always sees a request. Otherwise neither channel does.
    reg drq1 = 1'b0;
    initial if ($test$plusargs("drq1")) drq1 = 1'b1;

    // The microSD slot (see the card model below)
    wire sd_clk, sd_mosi, sd_cs_n, sd_card_miso, sd_card_oe;
    wire sd_miso = sd_card_oe ? sd_card_miso : 1'b1;

    soc #(.ROM_HEX(ROM_HEX), .DIVISOR(DIVISOR),
          .MAP(MAP), .ROM_BITS(ROM_BITS), .ROM_BASE(ROM_BASE)) dut (
        .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd), .led(led),
        .dbg_addr(), .dbg_vld(), .dbg_we(), .dbg_stopped(),
        .dbg_cache_hits(), .dbg_cache_misses(),
        .sdram_a(sa), .sdram_ba(sba), .sdram_dq(sdq), .sdram_dqm(sdqm),
        .sdram_cs_n(scs_n), .sdram_ras_n(sras_n), .sdram_cas_n(scas_n),
        .sdram_we_n(swe_n), .sdram_cke(scke), .sdram_clk(sclk),
        // The video side needs a real clock and reset. Left unconnected they
        // are x, the video master's SDRAM request goes x, and sdram_ack -- and
        // so the CPU's rdy -- is x from the first cycle: the SoC never boots.
        .clk_pix(clk_pix), .pix_rst_n(rst_n),
        // No card attached: IRQ must be tied high or it floats into the CPU.
        .ext_d_in(8'hFF), .ext_irq_n(1'b1), .dma_drq({drq1, 1'b0}),
        .adb_drive(adb_drive), .adb_sense(adb_bus),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_cs_n(sd_cs_n), .sd_miso(sd_miso)
    );

    //------------------------------------------------------------------
    // The microSD slot: a card when +sd=image.hex names an image (a byte a
    // line, as `xxd -p -c1` writes it); without one MISO floats high, as the
    // pin's pull-up holds it.
    //------------------------------------------------------------------
    sd_card_model sdcard (
        .sclk(sd_clk), .mosi(sd_mosi), .cs_n(sd_cs_n),
        .miso(sd_card_miso), .miso_oe(sd_card_oe)
    );

    //------------------------------------------------------------------
    // ADB: an open-collector bus with a keyboard on it. Left unconnected the
    // sense input is x, which reaches the CPU the first time the monitor polls.
    // adb_host counts SYS_HZ/1e6 = 25 clocks to the microsecond whatever the
    // clock really is, so that is the keyboard's time unit too.
    //------------------------------------------------------------------

    adb_kbd_model #(.US(25.0 * 2 * CLK_HALF)) kbd (.bus(adb_bus), .drive(kbd_drive));

    reg [8*64-1:0] adbkeys;
    integer ak;
    initial begin : adb_stimulus
        if ($value$plusargs("adbkeys=%h", adbkeys)) begin
            repeat (SEND_DELAY) @(posedge clk);
            // Leading zero bytes are padding from the %h, but 00 is also the
            // code for 'A' -- so skip only whole leading 0000 packets.
            ak = 63;
            while (ak > 1 && adbkeys[8*ak +: 8] == 8'h00 &&
                             adbkeys[8*(ak-1) +: 8] == 8'h00) ak = ak - 2;
            for (ak = ak; ak > 0; ak = ak - 2)
                kbd.push(adbkeys[8*ak +: 8], adbkeys[8*(ak-1) +: 8]);
        end
    end

    // Only a window of the SDRAM is modelled; the memory test is sized to fit.
    sdram_model #(.MEM_WORDS(MEM_WORDS), .CAS(2)) sdram (
        .clk(sclk), .cke(scke), .cs_n(scs_n),
        .ras_n(sras_n), .cas_n(scas_n), .we_n(swe_n),
        .a(sa), .ba(sba), .dqm(sdqm), .dq(sdq)
    );

    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
    end

    //------------------------------------------------------------------
    // Receive whatever the SoC transmits and print it
    //------------------------------------------------------------------
    integer i;
    reg [7:0] ch;

    initial begin : rx_monitor
        forever begin
            wait (txd === 1'b1);                     // resync to idle first
            @(negedge txd);                          // start bit
            repeat (DIVISOR + DIVISOR/2) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                ch[i] = txd;
                repeat (DIVISOR) @(posedge clk);
            end
            if (ch == 8'h0D)      $write("\n");
            else if (ch == 8'h0A) ;                  // CR already broke the line
            else if (ch >= 8'h20 && ch < 8'h7F) $write("%c", ch);
            else $write("<%02x>", ch);
            $fflush;
        end
    end

    //------------------------------------------------------------------
    // Optionally type a string into the monitor once it has booted
    //------------------------------------------------------------------
    reg [8*64-1:0] send;
    integer send_len;
    integer j, k, times, t;

    task uart_put(input [7:0] b);
        begin
            rxd = 1'b0;                              // start
            repeat (DIVISOR) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                rxd = b[k];
                repeat (DIVISOR) @(posedge clk);
            end
            rxd = 1'b1;                              // stop
            repeat (TYPE_GAP*DIVISOR) @(posedge clk);
        end
    endtask

    initial begin : stimulus
        if ($value$plusargs("send=%s", send)) begin
            // wait for the banner to finish before typing
            repeat (SEND_DELAY) @(posedge clk);
            send_len = 0;
            for (j = 63; j >= 0; j = j - 1)
                if (send[8*j +: 8] != 8'h00 && send_len == 0) send_len = j + 1;
            if (!$value$plusargs("times=%d", times)) times = 1;
            for (t = 0; t < times; t = t + 1) begin
                for (j = send_len - 1; j >= 0; j = j - 1)
                    if (send[8*j +: 8] != 8'h00) uart_put(send[8*j +: 8]);
                uart_put(8'h0D);
                // let the reply finish before typing the next line
                if (t + 1 < times) repeat (SEND_DELAY) @(posedge clk);
            end
        end
    end

    //------------------------------------------------------------------
    // Print the 80x30 text screen straight out of the SDRAM model: characters
    // only, with the cursor's cell (inverted attribute) shown as '_' if blank.
    //------------------------------------------------------------------
    localparam integer SCREEN_WORD = 21'h1C0000;     // $70_0000 / 4
    integer sr, sc;
    reg [31:0] sw;
    reg [7:0]  s_ch, s_at;

    task dump_screen;
        begin
            $display("-- screen --");
            for (sr = 0; sr < 30; sr = sr + 1) begin
                $write("|");
                for (sc = 0; sc < 80; sc = sc + 1) begin
                    sw   = sdram.mem[SCREEN_WORD + sr*40 + sc/2];
                    s_ch = sc[0] ? sw[23:16] : sw[7:0];
                    s_at = sc[0] ? sw[31:24] : sw[15:8];
                    if (s_at === 8'h70 && s_ch === 8'h20) $write("_");
                    else if (s_ch >= 8'h20 && s_ch < 8'h7F) $write("%c", s_ch);
                    else $write("?");
                end
                $write("|\n");
            end
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("soc.vcd");
            $dumpvars(0, tb_soc);
        end
        #TIMEOUT;
        $write("\n");
        if ($test$plusargs("screen")) dump_screen;
        $display("-- timeout after %0d ns --", TIMEOUT);
        $finish;
    end

endmodule

`default_nettype wire
