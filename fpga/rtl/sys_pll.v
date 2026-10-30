//============================================================================
// sys_pll.v -- 27 MHz -> the system clock
//
// The CPU, memory and peripherals run from this clock; video keeps the
// pixel clock from video_pll.v, and video.v's line buffer is the crossing.
//
//   CLKOUT = 27 * (FBDIV_SEL+1) / (IDIV_SEL+1)
//   VCO    = CLKOUT * ODIV_SEL, inside the 400-1200 MHz range
//
// The dividers are parameters so top_tang20k.v can pick the frequency (and
// pass the same SYS_HZ to everything that counts clocks).
//============================================================================
`default_nettype none

module sys_pll #(
    parameter integer IDIV_SEL  = 4,    // /5
    parameter integer FBDIV_SEL = 6,    // x7: 37.8 MHz
    parameter integer ODIV_SEL  = 16    // VCO 604.8 MHz
) (
    input  wire clk27,
    output wire clk,
    output wire locked
);
    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(IDIV_SEL),
        .FBDIV_SEL(FBDIV_SEL),
        .ODIV_SEL(ODIV_SEL),
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
        .CLKOUT(clk), .LOCK(locked), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .CLKIN(clk27), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
endmodule

`default_nettype wire
