//============================================================================
// video_pll.v -- 27 MHz -> the 5x serializer clock and the pixel clock
//
// 640x480@60 wants 25.175 MHz. 27 * 14/15 = 25.2 MHz is 0.1% fast, comfortably
// inside what monitors accept, and lands on integer PLL dividers:
//
//   CLKOUT = 27 * (FBDIV_SEL+1) / (IDIV_SEL+1) = 27 * 14/3 = 126 MHz
//   VCO    = CLKOUT * ODIV_SEL = 126 * 8 = 1008 MHz, inside the 400-1200 range
//
// 1024x768@60 (XGA) wants 65 MHz. 27 * 12/5 = 64.8 MHz is 0.3% slow:
//
//   CLKOUT = 27 * 12/1 = 324 MHz, VCO = 324 * 2 = 648 MHz
//
// tang_nano_20k.sdc declares the 640x480 ratio; build.tcl rewrites it for XGA.
//
// The pixel clock is then CLKDIV by 5 off the same PLL output, so the two are
// phase related by construction -- OSER10 needs exactly that.
//============================================================================
`default_nettype none

module video_pll #(
    parameter XGA = 0           // 1 = 1024x768
) (
    input  wire clk27,
    input  wire rst_n,
    output wire clk_pix,        // 25.2 MHz (64.8 MHz for XGA)
    output wire clk_pix5,       // 126 MHz (324 MHz)
    output wire locked
);
    wire clk5;

    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(XGA ? 0 : 2),     // /1, /3
        .FBDIV_SEL(XGA ? 11 : 13),  // x12, x14
        .ODIV_SEL(XGA ? 2 : 8),     // VCO = 648, 1008 MHz
        .DYN_IDIV_SEL("false"),
        .DYN_FBDIV_SEL("false"),
        .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"),
        .DYN_DA_EN("false"),
        .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1),
        .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0),
        .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW2AR-18C")
    ) u_pll (
        .CLKOUT(clk5), .LOCK(locked), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .CLKIN(clk27), .CLKFB(1'b0), .RESET(~rst_n), .RESET_P(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    assign clk_pix5 = clk5;

    // The /5 must be a CLKDIV primitive: the PLL's own CLKOUTD divider accepts
    // EVEN values only (DYN_SDIV_SEL is documented 2~128, even), so it cannot
    // produce 126/5 (or 324/5).
    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) u_div (
        .CLKOUT(clk_pix), .HCLKIN(clk5), .RESETN(rst_n), .CALIB(1'b0)
    );
endmodule

`default_nettype wire
