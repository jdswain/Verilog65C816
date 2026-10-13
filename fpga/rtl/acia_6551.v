//============================================================================
// acia_6551.v -- 6551-compatible ACIA (register subset), 8N1
//
// Register map (as the monitor's serial.asm expects):
//   0  R: receive data      W: transmit data
//   1  R: status            W: programmed reset
//   2  R/W: command
//   3  R/W: control
//
// Status bits: 7 IRQ, 6 DSR, 5 DCD, 4 TX empty, 3 RX full, 2 overrun,
//              1 framing error, 0 parity error.
//
// The baud rate is fixed by the DIVISOR parameter; the control register's
// rate field is stored and read back but does not retune the generator, and
// the word-length/stop-bit fields are ignored (the link is always 8N1).
//============================================================================
`default_nettype none

module acia_6551 #(
    parameter integer DIVISOR = 234
) (
    input  wire       clk,
    input  wire       rst_n,
    // register interface
    input  wire [1:0] addr,
    input  wire [7:0] wdata,
    output reg  [7:0] rdata,
    input  wire       cs,          // access this cycle
    input  wire       we,
    output wire       irq_n,
    // serial pins
    input  wire       rxd,
    output wire       txd
);
    reg [7:0] command;
    reg [7:0] control;

    reg [7:0] rx_data;
    reg       rx_full;
    reg       overrun;
    reg       frame_err;

    wire       tx_busy;
    reg        tx_load;
    reg  [7:0] tx_data;
    wire       tx_empty = ~tx_busy & ~tx_load;

    wire [7:0] rx_bits;
    wire       rx_strobe;
    wire       rx_frame_err;

    // Interrupts: receiver-full raises IRQ unless masked by command bit 1
    // (IRQD). Transmitter interrupts are not implemented.
    wire irq = rx_full & ~command[1];
    assign irq_n = ~irq;

    wire [7:0] status = {irq, 1'b0, 1'b0, tx_empty, rx_full,
                         overrun, frame_err, 1'b0};

    wire write = cs & we;
    wire read  = cs & ~we;

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
            command   <= 8'h00;
            control   <= 8'h00;
            rx_data   <= 8'h00;
            rx_full   <= 1'b0;
            overrun   <= 1'b0;
            frame_err <= 1'b0;
            tx_load   <= 1'b0;
            tx_data   <= 8'h00;
            rdata     <= 8'h00;
        end else begin
            tx_load <= 1'b0;

            // Receiver: a byte arriving while one is still unread is an
            // overrun; the newest byte wins, as on the real part.
            if (rx_strobe) begin
                rx_data   <= rx_bits;
                frame_err <= rx_frame_err;
                if (rx_full) overrun <= 1'b1;
                rx_full <= 1'b1;
            end

            if (write) begin
                case (addr)
                2'd0: begin
                    tx_data <= wdata;
                    tx_load <= 1'b1;
                end
                2'd1: begin                        // programmed reset
                    command <= 8'h00;
                    overrun <= 1'b0;
                end
                2'd2: command <= wdata;
                2'd3: control <= wdata;
                endcase
            end

            if (read) begin
                case (addr)
                2'd0: begin
                    rdata <= rx_data;
                    if (!rx_strobe) rx_full <= 1'b0;
                    overrun <= 1'b0;
                end
                2'd1: rdata <= status;
                2'd2: rdata <= command;
                2'd3: rdata <= control;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
