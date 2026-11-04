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
// The pixel clock is CLKDIV by 5 off CLKOUT, so the two are phase related by
// construction -- OSER10 needs exactly that. The divider has its own reset,
// div_rst_n (top_tang20k.v); holding it stops clk_pix.
//
// The serializers' 5x clock, clk_ser, is CLKOUTP: the same 324 MHz, in
// phase, on a PLL output of its own rather than the CLKOUT that feeds the
// divider. That separation is what ended the 1024x768 sync loss. With the
// divider and the serializers on one output, every 1024x768 build but one
// lost sync under blitter traffic -- flashing, or black, depending on the 5x
// clock the serializers' reset release landed on -- with our serializers
// and with Gowin's DVI_TX IP alike (top_tang20k.v has the reset history).
// The separate output was built on 2026-11-04 to sweep its phase at run
// time (DYN_DA_EN, a register at $03B2), on the theory that the divider's
// output, which reaches each OSER10's PCLK over the general clock network
// 2.3 ns after the 5x clock reaches FCLK over the HCLK network (the timing
// report: 2.27 against 0.12 ns), had to be moved away from a 5x edge. The
// sweep disproved the theory: every phase from 0 to 337.5 degrees and every
// reset lag was steady, and so was the OS16 desktop. The structure is what
// matters, so the phase is static here and the register is gone. Why the
// shared output failed is not documented and was not established. 640x480
// never had the problem: at 126 MHz every delay involved is a small fraction
// of a 5x cycle.
//
// PSDA_SEL "0100" is 90 degrees, not 180 (UG286 table 7-6); an earlier
// version clocked the reset shift register by CLKOUTP believing 180, and
// the .sdc declared 180.
//
// calib goes to the divider's CALIB (a phase step per two pulses, by the
// simulation model); stepping it made no visible difference, so it is tied
// low.
//============================================================================
`default_nettype none

module video_pll #(
    parameter XGA = 0           // 1 = 1024x768
) (
    input  wire       clk27,
    input  wire       rst_n,     // the PLL's reset: outputs held low while low
    input  wire       div_rst_n, // the divider's reset (top_tang20k.v)
    input  wire       calib,     // CLKDIV's CALIB: a phase step per two pulses
    output wire       clk_pix,   // 25.2 MHz (64.8 MHz for XGA)
    output wire       clk_pix5,  // 126 MHz (324 MHz): the divider's clock, CLKOUT
    output wire       clk_ser,   // the same, in phase: the serializers' FCLK, CLKOUTP
    output wire       locked
);
    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(XGA ? 0 : 2),     // /1, /3
        .FBDIV_SEL(XGA ? 11 : 13),  // x12, x14
        .ODIV_SEL(XGA ? 2 : 8),     // VCO = 648, 1008 MHz
        .DYN_IDIV_SEL("false"),
        .DYN_FBDIV_SEL("false"),
        .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"),          // CLKOUTP in phase with CLKOUT
        .DYN_DA_EN("false"),
        .DUTYDA_SEL("1000"),        // 50% duty
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
        .CLKOUT(clk_pix5), .LOCK(locked), .CLKOUTP(clk_ser), .CLKOUTD(), .CLKOUTD3(),
        .CLKIN(clk27), .CLKFB(1'b0), .RESET(~rst_n), .RESET_P(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    // The /5 must be a CLKDIV primitive: the PLL's own CLKOUTD divider accepts
    // EVEN values only (DYN_SDIV_SEL is documented 2~128, even), so it cannot
    // produce 126/5 (or 324/5).
    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) u_div (
        .CLKOUT(clk_pix), .HCLKIN(clk_pix5), .RESETN(div_rst_n), .CALIB(calib)
    );
endmodule

`default_nettype wire
