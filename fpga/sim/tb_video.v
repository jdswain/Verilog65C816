//============================================================================
// tb_video.v -- scan a known pattern out of SDRAM and check the pixels.
//
// Preloads the model with a framebuffer whose nibbles are a known function of
// position, then samples the RGB output during the first four active lines and
// checks each pixel against the palette entry it should have selected.
//
//   iverilog ... -Ptb_video.XGA=1    for 1024x768 (45 MHz memory clock and a
//                                    64.8 MHz pixel clock, as on the board)
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_video #(
    parameter XGA = 0
);
    localparam integer W = XGA ? 1024 : 640, H = XGA ? 768 : 480;
    localparam integer WPL = W / 8;                   // words per line
    localparam real    T_MEM = XGA ? 11.111 : 18.5;   // 45 / 27 MHz
    localparam real    T_PIX = XGA ? 7.716 : 19.8;    // 64.8 / ~25.2 MHz
    reg clk = 0;     always #(T_MEM) clk = ~clk;
    reg clk_pix = 0; always #(T_PIX) clk_pix = ~clk_pix;
    reg rst_n = 0;

    wire        m_req, m_we, m_done, m_rvalid;
    wire [20:0] m_addr;
    wire [31:0] m_wdata, m_rdata;
    wire [3:0]  m_wmask;
    wire [7:0]  red, green, blue;
    wire        hsync, vsync, de;

    video #(.XGA(XGA), .FB_WORD_BASE(21'd0)) dut (
        .clk(clk), .rst_n(rst_n),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_wmask(m_wmask), .m_done(m_done), .m_rvalid(m_rvalid), .m_rdata(m_rdata),
        .clk_pix(clk_pix), .pix_rst_n(rst_n),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .de(de),
        .pal_we(1'b0), .pal_idx(4'd0), .pal_sel(2'd0), .pal_byte(8'd0),
        .text_mode(1'b0)
    );

    wire [10:0] sa; wire [1:0] sba; wire [3:0] sdqm; wire [31:0] sdq;
    wire scs, sras, scas, swe, scke, idone;

    sdram_burst u_sd (
        .clk(clk), .rst_n(rst_n),
        .p0_req(m_req), .p0_we(m_we), .p0_addr(m_addr),
        .p0_wdata(m_wdata), .p0_wmask(m_wmask),
        .p0_done(m_done), .p0_rvalid(m_rvalid),
        .p1_req(1'b0), .p1_we(1'b0), .p1_addr(21'd0), .p1_wdata(32'd0),
        .p1_wmask(4'd0), .p1_done(), .p1_rvalid(),
        .p2_req(1'b0), .p2_we(1'b0), .p2_addr(21'd0), .p2_wdata(32'd0),
        .p2_wmask(4'd0), .p2_done(), .p2_rvalid(),
        .rdata(m_rdata), .init_done(idone),
        .sdram_a(sa), .sdram_ba(sba), .sdram_dq(sdq), .sdram_dqm(sdqm),
        .sdram_cs_n(scs), .sdram_ras_n(sras), .sdram_cas_n(scas),
        .sdram_we_n(swe), .sdram_cke(scke)
    );

    sdram_model #(.MEM_WORDS(98304), .CAS(2)) mem (
        .clk(~clk), .cke(scke), .cs_n(scs), .ras_n(sras), .cas_n(scas),
        .we_n(swe), .a(sa), .ba(sba), .dqm(sdqm), .dq(sdq)
    );

    // Pixel n of line y: nibble = (n / 8 + n % 8 + y) & 15, so a word fetched
    // from the wrong place in the line, or the wrong line, shows.
    function [23:0] pal(input [3:0] n);
        case (n)
        0: pal=24'h000000; 1: pal=24'h0000AA; 2: pal=24'h00AA00; 3: pal=24'h00AAAA;
        4: pal=24'hAA0000; 5: pal=24'hAA00AA; 6: pal=24'hAA5500; 7: pal=24'hAAAAAA;
        8: pal=24'h555555; 9: pal=24'h5555FF; 10:pal=24'h55FF55; 11:pal=24'h55FFFF;
        12:pal=24'hFF5555; 13:pal=24'hFF55FF; 14:pal=24'hFFFF55; 15:pal=24'hFFFFFF;
        endcase
    endfunction

    integer errors = 0, npix = 0, i, w, line;
    reg [31:0] word;
    reg [3:0]  want;

    initial begin
        for (line = 0; line < H; line = line + 1)
            for (w = 0; w < WPL; w = w + 1) begin
                word = 32'd0;
                for (i = 0; i < 8; i = i + 1)
                    word[i*4 +: 4] = (w + i + line) & 15;
                mem.mem[line*WPL + w] = word;
            end

        repeat (5) @(posedge clk); rst_n = 1;
        wait (idone);

        // The first active line after vertical sync is line 0.
        @(posedge vsync);            // leave vertical sync
        for (line = 0; line < 4; line = line + 1) begin
            @(posedge clk_pix);
            while (!de) @(posedge clk_pix);
            for (npix = 0; npix < W; npix = npix + 1) begin
                want = (npix / 8 + npix % 8 + line) & 15;
                if (!de) begin
                    $display("FAIL: line %0d: display enable dropped after %0d pixels",
                             line, npix);
                    errors = errors + 1;
                    npix = W;
                end else begin
                    if ({red, green, blue} !== pal(want)) begin
                        if (errors < 6)
                            $display("FAIL line %0d pixel %0d: got %06x want %06x",
                                     line, npix, {red, green, blue}, pal(want));
                        errors = errors + 1;
                    end
                    @(posedge clk_pix);
                end
            end
            if (de) begin
                $display("FAIL: line %0d is longer than %0d pixels", line, W);
                errors = errors + 1;
            end
        end
        $display("%0dx%0d: checked 4 lines of %0d pixels, %0d error(s)", W, H, W, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end

    initial begin #40_000_000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
