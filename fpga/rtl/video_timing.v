//============================================================================
// video_timing.v -- the sync generator: 640x480 or 1024x768 @ 60 Hz (VESA)
//
// 640x480 (XGA = 0): the pixel clock is nominally 25.175 MHz; we run 25.2 MHz
// (27 MHz * 14/15), which is 0.1% fast and well inside what any monitor
// tolerates.
//
//   horizontal: 640 active + 16 front + 96 sync + 48 back = 800
//   vertical:   480 active + 10 front +  2 sync + 33 back = 525
//
// 1024x768 (XGA = 1): nominally 65 MHz; we run 64.8 MHz (27 MHz * 12/5),
// 0.3% slow, so 59.8 Hz.
//
//   horizontal: 1024 active + 24 front + 136 sync + 160 back = 1344
//   vertical:    768 active +  3 front +   6 sync +  29 back =  806
//
// Both syncs are active low in both modes.
//============================================================================
`default_nettype none

module video_timing #(
    parameter XGA = 0
) (
    input  wire        clk,          // pixel clock
    input  wire        rst_n,
    output reg  [10:0] x,            // 0..H_TOTAL-1
    output reg  [9:0]  y,            // 0..V_TOTAL-1
    output wire [10:0] active_x,     // 0..H_ACTIVE-1, valid when de
    output wire [9:0]  active_y,     // 0..V_ACTIVE-1, valid when de
    output wire        hsync,
    output wire        vsync,
    output wire        de,           // display enable (active pixel)
    output wire        line_start,   // one pulse per line, at the front porch
    output wire        frame_start   // one pulse per frame
);
    localparam H_ACTIVE = XGA ? 1024 : 640, H_FRONT = XGA ? 24 : 16,
               H_SYNC   = XGA ?  136 :  96, H_BACK  = XGA ? 160 : 48;
    localparam V_ACTIVE = XGA ?  768 : 480, V_FRONT = XGA ?  3 : 10,
               V_SYNC   = XGA ?    6 :   2, V_BACK  = XGA ?  29 : 33;
    localparam H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;   // 800 / 1344
    localparam V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;   // 525 / 806

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 11'd0;
            y <= 10'd0;
        end else if (x == H_TOTAL - 1) begin
            x <= 11'd0;
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
    // fetched throughout line y, giving a whole line time (~32 us, or ~21 us
    // at 1024x768) instead of just the horizontal blanking (~6 us) -- and a
    // 640x480 4bpp line takes about 9 us to read, so the blanking alone is not
    // enough.
    assign line_start  = (x == 11'd0);
    assign frame_start = (x == 11'd0) && (y == V_TOTAL - 1);
endmodule

`default_nettype wire
