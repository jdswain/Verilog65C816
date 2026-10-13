//============================================================================
// uart_tx.v -- 8N1 transmitter
//
// Assert `load` for one cycle with `data` valid to start a character; `busy`
// stays high until the stop bit has been sent.
//============================================================================
`default_nettype none

module uart_tx #(
    parameter integer DIVISOR = 234        // clk cycles per bit
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       load,
    output wire       busy,
    output reg        txd
);
    localparam integer CW = $clog2(DIVISOR);

    reg [CW-1:0] cnt;
    reg [3:0]    bit_idx;                  // 0 = idle, 1..10 = start/data/stop
    reg [9:0]    shifter;                  // {stop, data[7:0], start}

    assign busy = (bit_idx != 4'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= {CW{1'b0}};
            bit_idx <= 4'd0;
            shifter <= 10'h3FF;
            txd     <= 1'b1;
        end else if (!busy) begin
            txd <= 1'b1;
            if (load) begin
                shifter <= {1'b1, data, 1'b0};
                bit_idx <= 4'd10;
                cnt     <= DIVISOR[CW-1:0] - 1'b1;
                txd     <= 1'b0;           // start bit begins immediately
            end
        end else if (cnt != {CW{1'b0}}) begin
            cnt <= cnt - 1'b1;
        end else begin
            cnt     <= DIVISOR[CW-1:0] - 1'b1;
            shifter <= {1'b1, shifter[9:1]};
            txd     <= shifter[1];
            bit_idx <= bit_idx - 1'b1;
        end
    end
endmodule

`default_nettype wire
