//============================================================================
// serial_r6501.v -- the three Rockwell R6501 serial registers, in page zero
//
// The Rockwell Forth talks to an on-chip UART rather than a 6551, and its
// register semantics are readable straight off the Forth's own routines:
//
//   XEMIT:  BIT SCSR / BVC XEMIT / STA SRDR   -> bit 6 = transmitter ready
//   XKEY:   LDA SCSR / AND #1 / BEQ .-  / LDA SRDR
//   ?TERM:  LDA SCSR / AND #1                 -> bit 0 = receiver full
//
// So:
//   $15 SCCR  control  -- stored and read back, does not retune anything
//   $16 SCSR  status   -- bit 6 TX ready, bit 0 RX full
//   $17 SRDR  data     -- read takes the received byte, write transmits
//
// Providing these lets the Forth run completely unmodified, which is cheaper
// and far less error-prone than retargeting its I/O.
//============================================================================
`default_nettype none

module serial_r6501 #(
    parameter integer DIVISOR = 234
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] reg_sel,     // 0 = SCCR, 1 = SCSR, 2 = SRDR
    input  wire [7:0] wdata,
    output reg  [7:0] rdata,
    input  wire       cs,          // one cycle per access
    input  wire       we,
    input  wire       rxd,
    output wire       txd
);
    reg [7:0] sccr;

    reg  [7:0] rx_data;
    reg        rx_full;

    wire       tx_busy;
    reg        tx_load;
    reg  [7:0] tx_data;
    wire       tx_ready = ~tx_busy & ~tx_load;

    wire [7:0] rx_bits;
    wire       rx_strobe, rx_frame_err;

    wire [7:0] status = {1'b0, tx_ready, 5'b0, rx_full};

    uart_tx #(.DIVISOR(DIVISOR)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .data(tx_data), .load(tx_load), .busy(tx_busy), .txd(txd)
    );

    uart_rx #(.DIVISOR(DIVISOR)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .rxd(rxd), .data(rx_bits), .strobe(rx_strobe), .frame_err(rx_frame_err)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sccr    <= 8'h00;
            rx_data <= 8'h00;
            rx_full <= 1'b0;
            tx_load <= 1'b0;
            tx_data <= 8'h00;
            rdata   <= 8'h00;
        end else begin
            tx_load <= 1'b0;

            if (rx_strobe) begin
                rx_data <= rx_bits;
                rx_full <= 1'b1;           // newest byte wins on overrun
            end

            if (cs & we) begin
                case (reg_sel)
                2'd0: sccr <= wdata;
                2'd1: ;                    // status is read-only here
                2'd2: begin
                    tx_data <= wdata;
                    tx_load <= 1'b1;
                end
                default: ;
                endcase
            end

            if (cs & ~we) begin
                case (reg_sel)
                2'd0: rdata <= sccr;
                2'd1: rdata <= status;
                2'd2: begin
                    rdata <= rx_data;
                    if (!rx_strobe) rx_full <= 1'b0;
                end
                default: rdata <= 8'hFF;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
