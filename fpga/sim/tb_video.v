//============================================================================
// tb_video.v -- scan a known pattern out of SDRAM and check the pixels.
//
// Preloads the model with a framebuffer whose nibbles are a known function of
// position, then samples the RGB output during the first active line and
// checks each pixel against the palette entry it should have selected.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_video;
    reg clk = 0;     always #18.5 clk = ~clk;        // 27 MHz
    reg clk_pix = 0; always #19.8 clk_pix = ~clk_pix; // ~25.2 MHz
    reg rst_n = 0;

    wire        m_req, m_we, m_done, m_rvalid;
    wire [20:0] m_addr;
    wire [31:0] m_wdata, m_rdata;
    wire [3:0]  m_wmask;
    wire [7:0]  red, green, blue;
    wire        hsync, vsync, de;

    video #(.FB_WORD_BASE(21'd0)) dut (
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

    sdram_model #(.MEM_WORDS(40960), .CAS(2)) mem (
        .clk(~clk), .cke(scke), .cs_n(scs), .ras_n(sras), .cas_n(scas),
        .we_n(swe), .a(sa), .ba(sba), .dqm(sdqm), .dq(sdq)
    );

    // Expected pixel n of line 0: nibble = n & 15
    function [23:0] pal(input [3:0] n);
        case (n)
        0: pal=24'h000000; 1: pal=24'h0000AA; 2: pal=24'h00AA00; 3: pal=24'h00AAAA;
        4: pal=24'hAA0000; 5: pal=24'hAA00AA; 6: pal=24'hAA5500; 7: pal=24'hAAAAAA;
        8: pal=24'h555555; 9: pal=24'h5555FF; 10:pal=24'h55FF55; 11:pal=24'h55FFFF;
        12:pal=24'hFF5555; 13:pal=24'hFF55FF; 14:pal=24'hFFFF55; 15:pal=24'hFFFFFF;
        endcase
    endfunction

    integer errors = 0, npix = 0, i, w;
    reg [31:0] word;

    initial begin
        // Fill every line identically, so whichever active line we happen to
        // sample has pixel n = nibble (n & 15).
        for (w = 0; w < 80; w = w + 1) begin
            word = 32'd0;
            for (i = 0; i < 8; i = i + 1)
                word[i*4 +: 4] = (w*8 + i) & 15;
            for (i = 0; i < 480; i = i + 1)
                mem.mem[i*80 + w] = word;
        end

        repeat (5) @(posedge clk); rst_n = 1;
        wait (idone);

        // Wait for the first active line, then check its pixels.
        @(posedge vsync);            // leave vertical sync
        @(negedge de);               // ensure we start at a line boundary
        // advance to the first active pixel of the next line
        @(posedge clk_pix);
        while (!de) @(posedge clk_pix);
        while (npix < 640) begin
            if (!de) begin
                $display("FAIL: display enable dropped after %0d pixels", npix);
                errors = errors + 1;
                npix = 640;
            end else begin
                if ({red, green, blue} !== pal(npix[3:0])) begin
                    if (errors < 6)
                        $display("FAIL pixel %0d: got %06x want %06x",
                                 npix, {red, green, blue}, pal(npix[3:0]));
                    errors = errors + 1;
                end
                npix = npix + 1;
                @(posedge clk_pix);
            end
        end
        $display("checked %0d pixels, %0d error(s)", npix, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end

    initial begin #40_000_000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
