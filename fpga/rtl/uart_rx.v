//============================================================================
// uart_rx.v -- 8N1 receiver
//
// `strobe` pulses for one cycle when `data` holds a freshly received byte.
// The input is synchronized to `clk`; bits are sampled mid-cell.
//============================================================================
`default_nettype none

module uart_rx #(
    parameter integer DIVISOR = 234        // clk cycles per bit
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rxd,
    output reg  [7:0] data,
    output reg        strobe,
    output reg        frame_err
);
    localparam integer CW = $clog2(DIVISOR);

    reg [1:0]    sync;                     // input synchronizer
    wire         rx = sync[1];
    reg [CW-1:0] cnt;
    reg [3:0]    bit_idx;                  // 0 = idle, else bits still to take
    reg [7:0]    shifter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync      <= 2'b11;
            cnt       <= {CW{1'b0}};
            bit_idx   <= 4'd0;
            shifter   <= 8'h00;
            data      <= 8'h00;
            strobe    <= 1'b0;
            frame_err <= 1'b0;
        end else begin
            sync   <= {sync[0], rxd};
            strobe <= 1'b0;

            if (bit_idx == 4'd0) begin
                // Idle: wait for a start bit, then aim at the middle of it.
                if (!rx) begin
                    bit_idx <= 4'd10;      // start + 8 data + stop
                    cnt     <= (DIVISOR / 2) - 1;
                end
            end else if (cnt != {CW{1'b0}}) begin
                cnt <= cnt - 1'b1;
            end else begin
                cnt <= DIVISOR[CW-1:0] - 1'b1;
                case (bit_idx)
                4'd10: begin
                    // Mid start bit: if it is gone it was a glitch, not a byte.
                    bit_idx <= rx ? 4'd0 : 4'd9;
                end
                4'd1: begin
                    // Mid stop bit: a low here is a framing error.
                    data      <= shifter;
                    strobe    <= 1'b1;
                    frame_err <= ~rx;
                    bit_idx   <= 4'd0;
                end
                default: begin
                    shifter <= {rx, shifter[7:1]};
                    bit_idx <= bit_idx - 1'b1;
                end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
