// Bring-up test for the video path: colour bars straight from the timing
// generator, no SDRAM and no CPU. Proves the PLL, the pixel clock, the TMDS
// encoding, the serializers and the pin constraints in one go.
`default_nettype none

module hdmitest (
    input  wire       clk,            // 27 MHz
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire [5:0] led
);
    reg [7:0] por = 8'd0;
    wire      rst_n = por[7];
    always @(posedge clk) if (!rst_n) por <= por + 1'b1;

    wire clk_pix, clk_pix5, locked;
    video_pll u_pll (.clk27(clk), .rst_n(rst_n),
                     .clk_pix(clk_pix), .clk_pix5(clk_pix5), .locked(locked));

    wire vrst_n = rst_n & locked;

    wire [9:0] x, y;
    wire hsync, vsync, de;
    video_timing u_tim (.clk(clk_pix), .rst_n(vrst_n), .x(x), .y(y),
                        .active_x(), .active_y(), .hsync(hsync), .vsync(vsync),
                        .de(de), .line_start(), .frame_start());

    // Eight vertical colour bars, with a white band across the middle so a
    // vertical offset is obvious too.
    wire [2:0] bar = x[9:7];
    reg [7:0] r, g, b;
    always @* begin
        if (y >= 10'd220 && y < 10'd260) begin
            r = 8'hFF; g = 8'hFF; b = 8'hFF;
        end else begin
            r = bar[2] ? 8'hFF : 8'h00;
            g = bar[1] ? 8'hFF : 8'h00;
            b = bar[0] ? 8'hFF : 8'h00;
        end
    end

    hdmi_out u_hdmi (
        .clk_pix(clk_pix), .clk_pix5(clk_pix5), .rst_n(vrst_n),
        .red(r), .green(g), .blue(b),
        .hsync(hsync), .vsync(vsync), .de(de),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    // led[5] blinks off the pixel clock, led[0] shows PLL lock.
    reg [23:0] cnt = 24'd0;
    always @(posedge clk_pix) cnt <= cnt + 1'b1;
    assign led = ~{cnt[23], 4'b0000, locked};
endmodule

`default_nettype wire
