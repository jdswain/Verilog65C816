//============================================================================
// video_timing.v -- 640x480 @ 60 Hz sync generator (VESA)
//
// Pixel clock is nominally 25.175 MHz; we run 25.2 MHz (27 MHz * 14/15), which
// is 0.1% fast and well inside what any monitor tolerates.
//
//   horizontal: 640 active + 16 front + 96 sync + 48 back = 800
//   vertical:   480 active + 10 front +  2 sync + 33 back = 525
//
// Both syncs are active low for this mode.
//============================================================================
`default_nettype none

module video_timing (
    input  wire        clk,          // pixel clock
    input  wire        rst_n,
    output reg  [9:0]  x,            // 0..799
    output reg  [9:0]  y,            // 0..524
    output wire [9:0]  active_x,     // 0..639, valid when de
    output wire [9:0]  active_y,     // 0..479, valid when de
    output wire        hsync,
    output wire        vsync,
    output wire        de,           // display enable (active pixel)
    output wire        line_start,   // one pulse per line, at the front porch
    output wire        frame_start   // one pulse per frame
);
    localparam H_ACTIVE = 640, H_FRONT = 16, H_SYNC = 96, H_BACK = 48;
    localparam V_ACTIVE = 480, V_FRONT = 10, V_SYNC =  2, V_BACK = 33;
    localparam H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;   // 800
    localparam V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;   // 525

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 10'd0;
            y <= 10'd0;
        end else if (x == H_TOTAL - 1) begin
            x <= 10'd0;
            y <= (y == V_TOTAL - 1) ? 10'd0 : y + 1'b1;
        end else begin
            x <= x + 1'b1;
        end
    end

    assign de       = (x < H_ACTIVE) && (y < V_ACTIVE);
    assign active_x = x;
    assign active_y = y;
    assign hsync    = ~((x >= H_ACTIVE + H_FRONT) &&
                        (x <  H_ACTIVE + H_FRONT + H_SYNC));
    assign vsync    = ~((y >= V_ACTIVE + V_FRONT) &&
                        (y <  V_ACTIVE + V_FRONT + V_SYNC));

    // Fetch triggers, at the START of a line rather than at the start of its
    // blanking. Because the line buffer is double-buffered, line y+1 can be
    // fetched throughout line y, giving a whole line time (~32 us) instead of
    // just the horizontal blanking (~6 us) -- and a 640x480 4bpp line takes
    // about 9 us to read, so the blanking alone is not enough.
    assign line_start  = (x == 10'd0);
    assign frame_start = (x == 10'd0) && (y == V_TOTAL - 1);
endmodule

`default_nettype wire
