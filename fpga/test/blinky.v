// Minimal bring-up test: clock and LEDs only, no reset input, no CPU.
// If this counts visibly the 27 MHz clock and the whole toolchain-to-board
// path are good, and any fault in the SoC is downstream of that.
`default_nettype none

module blinky (
    input  wire       clk,
    output wire [5:0] led          // active low on this board
);
    reg [25:0] cnt = 26'd0;
    always @(posedge clk) cnt <= cnt + 1'b1;

    // Binary count on the LEDs; the fastest bit changes about 3x a second.
    assign led = ~cnt[25:20];
endmodule

`default_nettype wire
