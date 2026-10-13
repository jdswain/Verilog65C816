// Bring-up test: send a distinctive message repeatedly, with a gap between
// repeats so the USB bridge is never overrun.
//
// The message is deliberately asymmetric. A pattern like 0x55 is alternating
// bits and can alias to itself when the host's baud is a multiple of the
// sender's, which makes it useless for identifying the true bit rate. Only the
// correct baud will decode this into readable ASCII.
`default_nettype none

module uartmsg (
    input  wire       clk,
    output wire       uart_tx,
    output wire [5:0] led
);
    localparam integer DIVISOR = 234;      // 115200 if the clock really is 27 MHz
    localparam integer LAST    = 16;

    reg [7:0] por = 8'd0;
    wire      rst_n = por[7];
    always @(posedge clk) if (!rst_n) por <= por + 1'b1;

    reg [4:0]  idx  = 5'd0;
    reg [19:0] gap  = 20'd0;               // inter-message pause
    reg        load = 1'b0;
    wire       busy;

    reg [7:0] ch;
    always @* begin
        case (idx)
        5'd0 : ch = 8'h54;   // 'T'
        5'd1 : ch = 8'h61;   // 'a'
        5'd2 : ch = 8'h6E;   // 'n'
        5'd3 : ch = 8'h67;   // 'g'
        5'd4 : ch = 8'h32;   // '2'
        5'd5 : ch = 8'h30;   // '0'
        5'd6 : ch = 8'h4B;   // 'K'
        5'd7 : ch = 8'h20;   // ' '
        5'd8 : ch = 8'h55;   // 'U'
        5'd9 : ch = 8'h41;   // 'A'
        5'd10: ch = 8'h52;   // 'R'
        5'd11: ch = 8'h54;   // 'T'
        5'd12: ch = 8'h20;   // ' '
        5'd13: ch = 8'h4F;   // 'O'
        5'd14: ch = 8'h4B;   // 'K'
        5'd15: ch = 8'h0D;   // '\r'
        5'd16: ch = 8'h0A;   // '\n'
        default: ch = 8'h2E;
        endcase
    end

    always @(posedge clk) begin
        load <= 1'b0;
        if (!rst_n) begin
            idx <= 5'd0;
            gap <= 20'd0;
        end else if (gap != 20'd0) begin
            gap <= gap - 1'b1;             // idle between messages
        end else if (!busy && !load) begin
            load <= 1'b1;
            if (idx == LAST[4:0]) begin
                idx <= 5'd0;
                gap <= 20'hFFFFF;
            end else begin
                idx <= idx + 1'b1;
            end
        end
    end

    uart_tx #(.DIVISOR(DIVISOR)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .data(ch), .load(load), .busy(busy), .txd(uart_tx)
    );

    reg [25:0] cnt = 26'd0;
    always @(posedge clk) cnt <= cnt + 1'b1;
    assign led = ~{cnt[24], 4'b0000, busy};
endmodule

`default_nettype wire
