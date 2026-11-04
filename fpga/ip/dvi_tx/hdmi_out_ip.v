//============================================================================
// hdmi_out_ip.v -- the HDMI output stage done by Gowin's DVI_TX IP
//
// The same ports as hdmi_out.v, so top_tang20k.v can pick either. The IP
// (DVI_TX_Top, fpga/ip/dvi_tx/dvi_tx.v: Gowin's encrypted rgb2dvi core as
// generated for Sipeed's Tang Nano 20K HDMI example, TLVDS output buffers,
// external pixel clock) encodes and serializes inside; we give it the pixel
// clock, the 5x clock and the serializers' reset, which it releases its own
// OSER10s from. Its pins want IO_TYPE=LVDS25 in the .cst.
//
// Tried 2026-11-03 because our own encoders and OSER10s lose sync in a way
// that depends on when the TMDS words reach the OSER10 D inputs, and the IP
// is what the vendor tests this part with. It behaved the same (flashing or
// black by the reset lag); the fix was the serializers' own PLL output
// (video_pll.v), and this stays as the alternative it was.
//
// Kept here, beside the IP and out of rtl/, because the Makefile's wildcard
// (lint, the simulations) would pick it up with no DVI_TX_Top to resolve;
// build.tcl adds both files.
//============================================================================
`default_nettype none

module hdmi_out_ip (
    input  wire       clk_pix,      // pixel clock (25.2 or 64.8 MHz)
    input  wire       clk_pix5,     // 5x pixel clock (126 or 324 MHz)
    input  wire       rst_n,        // unused: the IP has one reset
    input  wire       ser_rst_n,    // the IP's reset (top_tang20k.v)

    input  wire [7:0] red,
    input  wire [7:0] green,
    input  wire [7:0] blue,
    input  wire       hsync,
    input  wire       vsync,
    input  wire       de,

    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);
    DVI_TX_Top u_ip (
        .I_rst_n(ser_rst_n), .I_serial_clk(clk_pix5), .I_rgb_clk(clk_pix),
        .I_rgb_vs(vsync), .I_rgb_hs(hsync), .I_rgb_de(de),
        .I_rgb_r(red), .I_rgb_g(green), .I_rgb_b(blue),
        .O_tmds_clk_p(tmds_clk_p), .O_tmds_clk_n(tmds_clk_n),
        .O_tmds_data_p(tmds_d_p), .O_tmds_data_n(tmds_d_n)
    );
endmodule

`default_nettype wire
