// Bring-up test: transmit "U" forever at 115200 on the UART pin, and blink.
// Isolates the serial path (pin choice, direction, baud, host port) from the
// CPU and the ACIA entirely.
`default_nettype none

module uarttest (
    input  wire       clk,           // 27 MHz
    output wire       uart_tx,
    output wire [5:0] led
);
    localparam integer DIVISOR = 234;   // 115200 from 27 MHz

    // Power-on reset: the transmitter needs a real one, otherwise its state
    // registers never initialize.
    reg [7:0] por = 8'd0;
    wire rst_n = por[7];
    always @(posedge clk) if (!rst_n) por <= por + 1'b1;

    reg [25:0] cnt = 26'd0;
    always @(posedge clk) cnt <= cnt + 1'b1;

    wire busy;
    // Kick off a new character whenever the transmitter is idle.
    reg  load = 1'b0;
    always @(posedge clk) load <= rst_n & ~busy & ~load;

    uart_tx #(.DIVISOR(DIVISOR)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .data(8'h55),                  // 'U' = 0x55, alternating bits
        .load(load), .busy(busy), .txd(uart_tx)
    );

    assign led = ~{cnt[24], 4'b0000, busy};
endmodule

`default_nettype wire
