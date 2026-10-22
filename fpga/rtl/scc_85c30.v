//============================================================================
// scc_85c30.v -- the part of a Z85C30 SCC that serial software needs
//
// A stand-in for the SCC half of the Z85C80 until the carrier board exists.
// It sits where the real chip will, so software written against it runs
// unchanged on the real part. Channel A is the board's serial port (the
// BL616 USB bridge). Channel B has no pins: what is written to it is
// discarded and it never receives.
//
// Register addressing, as the carrier wires the real chip:
//   addr[0] = D//C   0 = control, 1 = data
//   addr[1] = A//B   0 = channel B, 1 = channel A
// so +0 B control, +1 B data, +2 A control, +3 A data.
//
// The control port is the SCC's: with the pointer at 0 a write is WR0, which
// sets the pointer for the next control access (and "point high" adds 8);
// any other access to the control port uses the register the pointer names
// and puts the pointer back to 0. Each channel has its own pointer. WR2 and
// WR9 are one register shared by both channels.
//
// What is emulated:
//   * asynchronous 8N1 at a fixed rate (DIVISOR). WR4, WR10-WR14 are stored,
//     and WR12/WR13 read back as RR12/RR13, but do not change the rate.
//   * the receiver (WR3 bit 0 enables it) with the real part's 3-byte FIFO,
//     overrun and framing errors in RR1, and WR0 Error Reset.
//   * the transmitter (WR5 bit 3 enables it) with its one-byte buffer,
//     Tx Buffer Empty in RR0 and All Sent in RR1.
//   * interrupts: receive (WR1 bits 4-3; mode 01, first character, is treated
//     as 10, every character), transmit (WR1 bit 1, cleared by writing data
//     or WR0 Reset Tx Int Pending), MIE (WR9 bit 3), RR3, and RR2 read from
//     channel B with the status in it (WR9 bits 0 and 4).
//   * channel and hardware resets through WR9.
//   * the baud-rate generators, for their zero count: while WR14 bit 0 is
//     set and bit 1 selects PCLK (clk; RTxC has no pin), each counts down
//     from its time constant (WR13:WR12) and reloads it, a zero count every
//     time constant + 2 clocks. With WR15 bit 1 and WR1 bit 0 a zero count
//     latches the channel's external/status interrupt pending (RR3 bit 3
//     A, bit 0 B; vector codes 101 and 001) until WR0 Reset Ext/Status
//     Interrupts. They do not set the serial rate, and RR0's zero count
//     bit reads 0. OS16 uses channel B's as its clock tick.
//
// Not emulated: synchronous modes, the other external/status interrupts, the
// interrupt-under-service chain (Reset Highest IUS is accepted and does
// nothing), DMA requests, and the modem lines -- RR0 reports DCD and CTS
// asserted. Nor is the real part's recovery time between accesses, so this
// cannot catch software that goes too fast; the bridge will enforce it.
//============================================================================
`default_nettype none

module scc_85c30 #(
    parameter integer DIVISOR = 234        // clk cycles per bit
) (
    input  wire       clk,
    input  wire       rst_n,
    // register interface
    input  wire [1:0] addr,
    input  wire [7:0] wdata,
    output reg  [7:0] rdata,
    input  wire       cs,                  // access this cycle
    input  wire       we,
    output wire       int_n,
    // channel A serial pins
    input  wire       rxd,
    output wire       txd
);
    localparam A = 1, B = 0;

    wire dc = addr[0];                     // 1 = data port
    wire ch = addr[1];                     // 1 = channel A

    // Per channel
    reg [3:0] ptr   [0:1];
    reg [7:0] wr1   [0:1];
    reg [7:0] wr3   [0:1];
    reg [7:0] wr4   [0:1];
    reg [7:0] wr5   [0:1];
    reg [7:0] wr10  [0:1];
    reg [7:0] wr11  [0:1];
    reg [7:0] wr12  [0:1];
    reg [7:0] wr13  [0:1];
    reg [7:0] wr14  [0:1];
    reg [7:0] wr15  [0:1];
    reg       tx_ip [0:1];
    reg       ext_ip [0:1];                // external/status: a zero count
    reg [15:0] brg  [0:1];                 // baud-rate generator counter
    reg       brg_reload [0:1];
    // Shared
    reg [7:0] wr2;
    reg [7:0] wr9;

    //------------------------------------------------------------------
    // Channel A's receiver and transmitter
    //------------------------------------------------------------------
    wire [7:0] rx_bits;
    wire       rx_strobe, rx_frame_err;
    wire       tx_busy;
    reg        tx_load;
    reg  [7:0] tx_shift_data;

    uart_rx #(.DIVISOR(DIVISOR)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .rxd(rxd), .data(rx_bits), .strobe(rx_strobe), .frame_err(rx_frame_err)
    );

    uart_tx #(.DIVISOR(DIVISOR)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .data(tx_shift_data), .load(tx_load), .busy(tx_busy), .txd(txd)
    );

    // Receive FIFO, three deep like the real part. Each entry carries its own
    // framing error, which RR1 shows for the character at the head.
    reg [8:0] fifo [0:2];
    reg [1:0] count;
    reg       overrun;
    wire      rx_avail = (count != 2'd0);

    // Transmit buffer: one byte ahead of the shift register.
    reg [7:0] tx_buf;
    reg       tx_full;

    //------------------------------------------------------------------
    // Status
    //------------------------------------------------------------------
    // RR0: 7 break, 6 Tx underrun/EOM, 5 CTS, 4 sync/hunt, 3 DCD,
    //      2 Tx buffer empty, 1 zero count, 0 Rx character available
    wire [7:0] rr0_a = {1'b0, 1'b1, 1'b1, 1'b0, 1'b1, ~tx_full, 1'b0, rx_avail};
    wire [7:0] rr0_b = {1'b0, 1'b1, 1'b1, 1'b0, 1'b1, 1'b1,     1'b0, 1'b0};

    // RR1: 6 framing error, 5 Rx overrun, 3-1 residue code (011 in async),
    //      0 all sent
    wire [7:0] rr1_a = {1'b0, rx_avail & fifo[0][8], overrun, 1'b0,
                        3'b011, ~tx_full & ~tx_busy};
    wire [7:0] rr1_b = {1'b0, 1'b0, 1'b0, 1'b0, 3'b011, 1'b1};

    // Interrupt pending bits
    wire rx_mode_a = (wr1[A][4:3] == 2'b01) | (wr1[A][4:3] == 2'b10);
    wire rx_ip_a   = rx_mode_a & rx_avail;
    wire tx_ip_a   = tx_ip[A];
    wire tx_ip_b   = tx_ip[B];
    wire ext_ip_a  = ext_ip[A];
    wire ext_ip_b  = ext_ip[B];

    // RR3, readable from channel A only:
    //   5 A Rx, 4 A Tx, 3 A Ext/Status, 2 B Rx, 1 B Tx, 0 B Ext/Status
    wire [7:0] rr3 = {2'b00, rx_ip_a, tx_ip_a, ext_ip_a, 1'b0, tx_ip_b, ext_ip_b};

    assign int_n = ~(wr9[3] & (rx_ip_a | tx_ip_a | ext_ip_a | tx_ip_b | ext_ip_b));

    // RR2 from channel B: the vector with the highest pending source in it.
    // V3-V1 with status low (WR9 bit 4 = 0), V4-V6 reversed with status high.
    wire [2:0] vcode = rx_ip_a  ? 3'b110 :
                       tx_ip_a  ? 3'b100 :
                       ext_ip_a ? 3'b101 :
                       tx_ip_b  ? 3'b000 :
                       ext_ip_b ? 3'b001 : 3'b011;
    wire [7:0] rr2_b = ~wr9[0] ? wr2 :
                       wr9[4]  ? {wr2[7], vcode[0], vcode[1], vcode[2], wr2[3:0]}
                               : {wr2[7:4], vcode, wr2[0]};

    function [7:0] rreg(input c, input [3:0] n);
        case (n)
        4'd0, 4'd4:  rreg = c ? rr0_a : rr0_b;
        4'd1, 4'd5:  rreg = c ? rr1_a : rr1_b;
        4'd2, 4'd6:  rreg = c ? wr2 : rr2_b;
        4'd3, 4'd7:  rreg = c ? rr3 : 8'h00;
        4'd8:        rreg = c ? fifo[0][7:0] : 8'h00;
        4'd9, 4'd13: rreg = wr13[c];
        4'd10, 4'd14: rreg = 8'h00;
        4'd12:       rreg = wr12[c];
        default:     rreg = wr15[c] & 8'hFA;     // RR11, RR15
        endcase
    endfunction

    //------------------------------------------------------------------
    // Registers
    //------------------------------------------------------------------
    wire write = cs & we;
    wire read  = cs & ~we;

    // Reading the data, from the data port or as RR8, takes the head of the
    // FIFO.
    wire pop = read & ch & (dc | (ptr[A] == 4'd8));

    integer i;

    task reset_channel(input c);
        begin
            ptr[c]   <= 4'd0;
            wr1[c]   <= 8'h00;
            wr3[c]   <= wr3[c] & 8'hFE;          // receiver off
            wr5[c]   <= wr5[c] & 8'h61;          // transmitter, RTS, DTR off
            wr10[c]  <= 8'h00;
            wr14[c]  <= (wr14[c] & 8'hC3) | 8'h20;
            wr15[c]  <= 8'hF8;
            tx_ip[c] <= 1'b0;
            ext_ip[c] <= 1'b0;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 2; i = i + 1) begin
                ptr[i]  <= 4'd0;  wr1[i]  <= 8'h00; wr3[i]  <= 8'h00;
                wr4[i]  <= 8'h04; wr5[i]  <= 8'h00; wr10[i] <= 8'h00;
                wr11[i] <= 8'h08; wr12[i] <= 8'h00; wr13[i] <= 8'h00;
                wr14[i] <= 8'h30; wr15[i] <= 8'hF8; tx_ip[i] <= 1'b0;
                ext_ip[i] <= 1'b0; brg[i] <= 16'd0; brg_reload[i] <= 1'b0;
            end
            wr2      <= 8'h00;
            wr9      <= 8'h00;
            count    <= 2'd0;
            overrun  <= 1'b0;
            fifo[0]  <= 9'd0; fifo[1] <= 9'd0; fifo[2] <= 9'd0;
            tx_buf   <= 8'h00;
            tx_full  <= 1'b0;
            tx_load  <= 1'b0;
            tx_shift_data <= 8'h00;
            rdata    <= 8'h00;
        end else begin
            tx_load <= 1'b0;

            //----------------------------------------------------------
            // Baud-rate generators: TC, TC-1, ... 0, a clock to reload.
            //----------------------------------------------------------
            for (i = 0; i < 2; i = i + 1) begin
                if (wr14[i][1:0] != 2'b11) begin
                    brg[i] <= {wr13[i], wr12[i]};
                    brg_reload[i] <= 1'b0;
                end else if (brg_reload[i]) begin
                    brg[i] <= {wr13[i], wr12[i]};
                    brg_reload[i] <= 1'b0;
                end else if (brg[i] == 16'd0) begin
                    brg_reload[i] <= 1'b1;
                    if (wr15[i][1] & wr1[i][0]) ext_ip[i] <= 1'b1;
                end else
                    brg[i] <= brg[i] - 16'd1;
            end

            //----------------------------------------------------------
            // Transmitter: move the buffer to the shift register.
            //----------------------------------------------------------
            if (tx_full & ~tx_busy & ~tx_load & wr5[A][3]) begin
                tx_shift_data <= tx_buf;
                tx_load       <= 1'b1;
                tx_full       <= 1'b0;
                if (wr1[A][1]) tx_ip[A] <= 1'b1;
            end

            //----------------------------------------------------------
            // Receive FIFO: a pop and an arrival can happen together.
            //----------------------------------------------------------
            begin : rxfifo
                reg [1:0] n;
                n = count;
                if (pop & rx_avail) begin
                    fifo[0] <= fifo[1];
                    fifo[1] <= fifo[2];
                    n = n - 2'd1;
                end
                if (rx_strobe & wr3[A][0]) begin
                    if (n == 2'd3) begin
                        // Full: the newest character is lost, as when the
                        // real part's shift register overruns the FIFO.
                        overrun <= 1'b1;
                    end else begin
                        // After a pop the entries have moved down one.
                        case (n)
                        2'd0: fifo[0] <= {rx_frame_err, rx_bits};
                        2'd1: fifo[1] <= {rx_frame_err, rx_bits};
                        default: fifo[2] <= {rx_frame_err, rx_bits};
                        endcase
                        n = n + 2'd1;
                    end
                end
                count <= n;
            end

            //----------------------------------------------------------
            // CPU reads
            //----------------------------------------------------------
            if (read) begin
                if (dc) rdata <= ch ? fifo[0][7:0] : 8'h00;
                else begin
                    rdata   <= rreg(ch, ptr[ch]);
                    ptr[ch] <= 4'd0;
                end
            end

            //----------------------------------------------------------
            // CPU writes
            //----------------------------------------------------------
            if (write) begin
                if (dc) begin
                    // WR8, transmit data. Channel B's goes nowhere.
                    if (ch) begin
                        tx_buf  <= wdata;
                        tx_full <= 1'b1;
                    end else if (wr1[B][1]) begin
                        tx_ip[B] <= 1'b1;
                    end
                    if (ch == 1'b1) tx_ip[A] <= 1'b0;
                end else if (ptr[ch] == 4'd0) begin
                    // WR0: pointer and command
                    ptr[ch] <= {wdata[5:3] == 3'b001, wdata[2:0]};
                    case (wdata[5:3])
                    3'b010: ext_ip[ch] <= 1'b0;  // reset ext/status interrupts
                    3'b101: tx_ip[ch] <= 1'b0;   // reset Tx int pending
                    3'b110: if (ch) overrun <= 1'b0;   // error reset
                    default: ;                   // the rest have no effect here
                    endcase
                end else begin
                    ptr[ch] <= 4'd0;
                    case (ptr[ch])
                    4'd1:  wr1[ch]  <= wdata;
                    4'd2:  wr2      <= wdata;
                    4'd3:  wr3[ch]  <= wdata;
                    4'd4:  wr4[ch]  <= wdata;
                    4'd5:  wr5[ch]  <= wdata;
                    4'd8:  if (ch) begin tx_buf <= wdata; tx_full <= 1'b1;
                                         tx_ip[A] <= 1'b0; end
                    4'd9: begin
                        case (wdata[7:6])
                        2'b01: reset_channel(B);
                        2'b10: begin
                            reset_channel(A);
                            count <= 2'd0; overrun <= 1'b0; tx_full <= 1'b0;
                        end
                        2'b11: begin
                            reset_channel(A);
                            reset_channel(B);
                            count <= 2'd0; overrun <= 1'b0; tx_full <= 1'b0;
                        end
                        default: ;
                        endcase
                        // A hardware reset also clears WR9 itself, MIE with it.
                        wr9 <= (wdata[7:6] == 2'b11) ? 8'h00 : {2'b00, wdata[5:0]};
                    end
                    4'd10: wr10[ch] <= wdata;
                    4'd11: wr11[ch] <= wdata;
                    4'd12: wr12[ch] <= wdata;
                    4'd13: wr13[ch] <= wdata;
                    4'd14: wr14[ch] <= wdata;
                    4'd15: wr15[ch] <= wdata;
                    default: ;                   // WR6, WR7: sync characters
                    endcase
                end
            end

            // Turning the transmit interrupt off drops anything pending.
            if (~wr1[A][1]) tx_ip[A] <= 1'b0;
            if (~wr1[B][1]) tx_ip[B] <= 1'b0;
            if (~wr1[A][0]) ext_ip[A] <= 1'b0;
            if (~wr1[B][0]) ext_ip[B] <= 1'b0;
        end
    end
endmodule

`default_nettype wire
