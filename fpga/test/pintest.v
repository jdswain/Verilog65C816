// Show the idle level of five candidate GPIO pins on LEDs, all with pull-ups.
// A free pin should read HIGH (LED lit). led[5] is a heartbeat.
`default_nettype none
module pintest (
    input  wire       clk,
    input  wire [4:0] cand,       // pins 26,27,28,29,30
    output wire [5:0] led
);
    reg [4:0] a = 0, b = 0;
    always @(posedge clk) begin a <= cand; b <= a; end
    reg [23:0] cnt = 0;
    always @(posedge clk) cnt <= cnt + 1'b1;
    assign led = ~{cnt[23], b};
endmodule
`default_nettype wire
