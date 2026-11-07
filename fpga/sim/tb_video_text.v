//============================================================================
// tb_video_text.v -- text mode: scan a known screen and check every pixel.
//
// Preloads the SDRAM model with 80x30 cells (128x48 with -Ptb_video_text.XGA=1)
// whose character and attribute are a known function of position, then checks
// one whole frame -- all 307200 pixels, or 786432 -- against the font image. A whole frame rather than one line because
// the things most likely to be wrong are per-row: the row address, the
// scanline within the cell, and the line buffer's two halves.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_video_text #(
    parameter XGA = 0                                 // -Ptb_video_text.XGA=1
);
    localparam integer W = XGA ? 1024 : 640, H = XGA ? 768 : 480;
    localparam integer COLS = W / 8, ROWS = H / 16;   // 80x30 or 128x48
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
        .text_mode(1'b1)
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

    sdram_model #(.MEM_WORDS(40960), .CAS(2)) mem (
        .clk(~clk), .cke(scke), .cs_n(scs), .ras_n(sras), .cas_n(scas),
        .we_n(swe), .a(sa), .ba(sba), .dqm(sdqm), .dq(sdq)
    );

    function [23:0] pal(input [3:0] n);
        case (n)
        0: pal=24'h000000; 1: pal=24'h0000AA; 2: pal=24'h00AA00; 3: pal=24'h00AAAA;
        4: pal=24'hAA0000; 5: pal=24'hAA00AA; 6: pal=24'hAA5500; 7: pal=24'hAAAAAA;
        8: pal=24'h555555; 9: pal=24'h5555FF; 10:pal=24'h55FF55; 11:pal=24'h55FFFF;
        12:pal=24'hFF5555; 13:pal=24'hFF55FF; 14:pal=24'hFFFF55; 15:pal=24'hFFFFFF;
        endcase
    endfunction

    // The screen: every character code appears, and foreground and background
    // always differ so a swapped or missing attribute cannot hide.
    function [7:0] cell_char(input integer col, input integer row);
        cell_char = col * 3 + row * 7 + 33;
    endfunction
    function [7:0] cell_attr(input integer col, input integer row);
        reg [3:0] fg, bg;
        begin
            fg = col + row;
            bg = fg + 1 + (row % 15);
            cell_attr = {bg, fg};
        end
    endfunction

    reg [7:0] font [0:4095];
    initial $readmemh("rom/font_st8x16.hex", font);

    integer errors = 0, npix = 0, px, py, col, row;
    reg [7:0]  ch, at, bits;
    reg [23:0] want;

    initial begin
        // Rows above the screen are left as X, so a fetch from the wrong
        // address shows up rather than reading plausible data.
        for (row = 0; row < ROWS; row = row + 1)
            for (col = 0; col < COLS; col = col + 2)
                mem.mem[row*(COLS/2) + col/2] = {cell_attr(col+1, row), cell_char(col+1, row),
                                           cell_attr(col,   row), cell_char(col,   row)};

        repeat (5) @(posedge clk); rst_n = 1;
        wait (idone);

        @(posedge vsync);            // end of a vertical sync: next de is (0,0)
        for (py = 0; py < H; py = py + 1) begin
            @(negedge clk_pix);
            while (!de) @(negedge clk_pix);
            for (px = 0; px < W; px = px + 1) begin
                ch   = cell_char(px >> 3, py >> 4);
                at   = cell_attr(px >> 3, py >> 4);
                bits = font[{ch, py[3:0]}];
                want = pal(bits[7 - (px & 7)] ? at[3:0] : at[7:4]);
                if (!de || {red, green, blue} !== want) begin
                    if (errors < 8)
                        $display("FAIL (%0d,%0d) char %02x: de=%b got %06x want %06x",
                                 px, py, ch, de, {red, green, blue}, want);
                    errors = errors + 1;
                end
                npix = npix + 1;
                @(negedge clk_pix);
            end
            if (de) begin
                if (errors < 8) $display("FAIL line %0d: de still high after %0d", py, W);
                errors = errors + 1;
            end
        end
        $display("%0dx%0d text: checked %0d pixels, %0d error(s)", W, H, npix, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end

    initial begin #80_000_000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
