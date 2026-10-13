// Measure the idle and pressed levels of the two buttons.
// led[0] follows pin 87 (S1), led[1] follows pin 88 (S2), led[5] is a
// heartbeat so it is obvious the design is running.
`default_nettype none

module btntest (
    input  wire       clk,
    input  wire       s1,          // pin 87
    input  wire       s2,          // pin 88
    output wire [5:0] led
);
    reg [1:0] a = 2'b00, b = 2'b00;
    always @(posedge clk) begin
        a <= {a[0], s1};
        b <= {b[0], s2};
    end
    reg [23:0] cnt = 24'd0;
    always @(posedge clk) cnt <= cnt + 1'b1;

    // LEDs are active low, so an LED is LIT when its pin reads 1.
    assign led = ~{cnt[23], 3'b000, b[1], a[1]};
endmodule

`default_nettype wire
