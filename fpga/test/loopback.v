// Pure wire loopback: whatever the USB bridge sends to the FPGA is sent
// straight back. Tests both directions of the serial path with no baud,
// no reset and no state machine involved.
`default_nettype none

module loopback (
    input  wire       clk,
    input  wire       uart_rx,      // pin 70, bridge -> FPGA
    output wire       uart_tx,      // pin 69, FPGA -> bridge
    output wire [5:0] led
);
    assign uart_tx = uart_rx;

    reg [25:0] cnt = 26'd0;
    always @(posedge clk) cnt <= cnt + 1'b1;

    // led[5] heartbeat, led[0] lights while the incoming line is low (data).
    assign led = ~{cnt[24], 4'b0000, ~uart_rx};
endmodule

`default_nettype wire
