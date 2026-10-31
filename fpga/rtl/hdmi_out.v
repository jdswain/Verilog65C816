//============================================================================
// hdmi_out.v -- DVI-over-HDMI output stage for the Tang Nano 20K
//
// Three TMDS encoders plus four 10:1 serializers (three data channels and the
// clock channel, which sends a fixed 0000011111 pattern so the receiver gets a
// clock at the pixel rate). Gowin's OSER10 does the serialization using both
// edges of a 5x clock, and ELVDS_OBUF drives each differential pair.
//
// DVI channel assignment: channel 0 carries blue *and* the syncs, 1 green,
// 2 red. TMDS sends bit 0 first, which is why D0 takes dout[0].
//
// The TMDS pins are not ordinary I/O: each pair is constrained by giving both
// pin numbers to the _p port in the .cst, and only the _p name appears there.
//============================================================================
`default_nettype none

module hdmi_out (
    input  wire       clk_pix,      // pixel clock (25.2 or 64.8 MHz)
    input  wire       clk_pix5,     // 5x pixel clock (126 or 324 MHz)
    input  wire       rst_n,

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
    wire [9:0] tm_blue, tm_green, tm_red;

    // Channel 0 carries the syncs during blanking; the other two send ctrl 00.
    tmds_encoder u_b (.clk(clk_pix), .rst_n(rst_n), .din(blue),
                      .ctrl({vsync, hsync}), .de(de), .dout(tm_blue));
    tmds_encoder u_g (.clk(clk_pix), .rst_n(rst_n), .din(green),
                      .ctrl(2'b00), .de(de), .dout(tm_green));
    tmds_encoder u_r (.clk(clk_pix), .rst_n(rst_n), .din(red),
                      .ctrl(2'b00), .de(de), .dout(tm_red));

    wire reset = ~rst_n;
    wire [2:0] ser_d;
    wire       ser_clk;

    OSER10 u_ser0 (.Q(ser_d[0]),
        .D0(tm_blue[0]), .D1(tm_blue[1]), .D2(tm_blue[2]), .D3(tm_blue[3]),
        .D4(tm_blue[4]), .D5(tm_blue[5]), .D6(tm_blue[6]), .D7(tm_blue[7]),
        .D8(tm_blue[8]), .D9(tm_blue[9]),
        .PCLK(clk_pix), .FCLK(clk_pix5), .RESET(reset));

    OSER10 u_ser1 (.Q(ser_d[1]),
        .D0(tm_green[0]), .D1(tm_green[1]), .D2(tm_green[2]), .D3(tm_green[3]),
        .D4(tm_green[4]), .D5(tm_green[5]), .D6(tm_green[6]), .D7(tm_green[7]),
        .D8(tm_green[8]), .D9(tm_green[9]),
        .PCLK(clk_pix), .FCLK(clk_pix5), .RESET(reset));

    OSER10 u_ser2 (.Q(ser_d[2]),
        .D0(tm_red[0]), .D1(tm_red[1]), .D2(tm_red[2]), .D3(tm_red[3]),
        .D4(tm_red[4]), .D5(tm_red[5]), .D6(tm_red[6]), .D7(tm_red[7]),
        .D8(tm_red[8]), .D9(tm_red[9]),
        .PCLK(clk_pix), .FCLK(clk_pix5), .RESET(reset));

    // Clock channel: five lows then five highs, i.e. one cycle per pixel.
    OSER10 u_serc (.Q(ser_clk),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0), .D4(1'b0),
        .D5(1'b1), .D6(1'b1), .D7(1'b1), .D8(1'b1), .D9(1'b1),
        .PCLK(clk_pix), .FCLK(clk_pix5), .RESET(reset));

    ELVDS_OBUF u_buf_c (.I(ser_clk),  .O(tmds_clk_p),  .OB(tmds_clk_n));
    ELVDS_OBUF u_buf_0 (.I(ser_d[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF u_buf_1 (.I(ser_d[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF u_buf_2 (.I(ser_d[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
endmodule

`default_nettype wire
