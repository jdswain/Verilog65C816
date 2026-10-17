//============================================================================
// adb_host.v -- Apple Desktop Bus host controller
//
// ADB is a single open-collector line, pulled up, driven low by whichever end
// is talking. Here that is split into two unidirectional signals: `adb_drive`
// pulls the bus low, `adb_sense` reads it back. Level shifting between the
// bus's 5V and the FPGA's 3.3V lives outside this module.
//
// `adb_drive` feeds a transistor that INVERTS: driving it high pulls the bus
// low. `adb_sense` is not inverted -- high means the bus is idle.
//
// The sense input is synchronised and then DEGLITCHED in logic rather than
// relying on an I/O hysteresis attribute: two flops for metastability, then a
// change is only accepted once it has held for US_GLITCH microseconds. A bit
// cell is ~2500 clocks here, so a couple of microseconds of filtering costs
// nothing and buys a lot of noise immunity. Both edges are delayed equally, so
// measured low times -- and therefore decoded bit values -- are unaffected.
//
// The bus is SENSED, never assumed. Whenever the host has released the line
// but reads it low, something else is driving: during the command stop bit
// that is a service request, and anywhere else in a bit cell it is a collision
// (two devices answering at once, or a stuck bus).
//
// Signalling (Microchip AN591 / Apple's ADB spec):
//
//   bit cell   100 us    '1' = 35 us low then 65 us high
//                        '0' = 65 us low then 35 us high
//   attention  800 us low
//   sync        70 us high
//   command    8 bits MSB first, then a '0' stop bit
//   Tlt        stop-to-start; the device answers inside this window
//   data       '1' start bit, 2..8 bytes, '0' stop bit
//   SRQ        a device keeps the line low past the command stop bit
//   reset      3 ms low
//   idle       at least US_IDLE between transactions (see below)
//
// Every duration is a parameter, deliberately: the published figures disagree
// with each other (AN591 gives Tlt as both 65-160 us and 160-240 us in
// different paragraphs) and devices are allowed +/-30% tolerance, so they need
// tuning against real hardware rather than baking in.
//
// A new command waits until the bus has been idle for US_IDLE. Apple's
// figures give no minimum gap, but a real keyboard (tested on the breadboard
// in October 2026) loses about half its keys when Talks follow each other
// back to back: it answers cleanly, but some key events are never sent. A
// 0.5 ms gap still lost one key in seven; 2 ms lost none in a hundred. The
// gap is enforced here rather than in software, so every poller gets it; a
// command written early is held, with busy set, until the bus has rested.
//
// Transmit is timed open-loop; receive is edge-driven, decoding each bit from
// how long the line stayed low (a '0' holds low nearly twice as long as a '1').
//
// A command byte is AAAA CCRR -- address, command, register. CC = 11 Talk,
// 10 Listen; Flush is lower nibble 0001 and SendReset is $00, neither of which
// has a data phase.
//============================================================================
`default_nettype none

module adb_host #(
    parameter integer CLK_HZ = 25_200_000,
    parameter integer US_BIT       = 100,
    parameter integer US_LOW_1     = 35,
    parameter integer US_LOW_0     = 65,
    parameter integer US_ATTN      = 800,
    parameter integer US_SYNC      = 70,
    parameter integer US_TLT_MAX   = 300,   // give up waiting for a response
    parameter integer US_RESET     = 3000,
    parameter integer US_IDLE      = 3000,  // bus rest before each command
    parameter integer US_RX_THRESH = 50,    // low longer than this reads as '0'
    parameter integer US_RX_END    = 150,   // no new bit by now: packet over
    parameter integer US_GLITCH    = 2      // reject transitions shorter than this
) (
    input  wire       clk,
    input  wire       rst_n,

    // register interface (one-cycle strobe, byte wide)
    input  wire [3:0] reg_addr,
    input  wire [7:0] wdata,
    output reg  [7:0] rdata,
    input  wire       cs,
    input  wire       we,

    // ADB bus, split into drive and sense
    output reg        adb_drive,      // 1 = pull the bus low
    input  wire       adb_sense       // bus level, 1 = idle high
);
    localparam integer PER_US      = CLK_HZ / 1000000;
    localparam integer TICK_BIT    = PER_US * US_BIT;
    localparam integer TICK_LOW1   = PER_US * US_LOW_1;
    localparam integer TICK_LOW0   = PER_US * US_LOW_0;
    localparam integer TICK_ATTN   = PER_US * US_ATTN;
    localparam integer TICK_SYNC   = PER_US * US_SYNC;
    localparam integer TICK_TLT    = PER_US * US_TLT_MAX;
    localparam integer TICK_RESET  = PER_US * US_RESET;
    localparam integer TICK_THRESH = PER_US * US_RX_THRESH;
    localparam integer TICK_RXEND  = PER_US * US_RX_END;
    localparam integer TICK_GLITCH = PER_US * US_GLITCH;
    localparam integer TICK_IDLE   = PER_US * US_IDLE;

    localparam integer CW = 20;                  // covers the 3 ms reset

    //------------------------------------------------------------------
    // Registers
    //------------------------------------------------------------------
    localparam [3:0] R_CMD = 4'h0, R_STATUS = 4'h1, R_LEN = 4'h2, R_CTRL = 4'h3;

    reg [7:0] cmd_r, len_r;
    reg [7:0] data_r [0:7];

    reg       st_busy, st_done, st_timeout, st_srq;
    reg [3:0] st_count;
    reg       st_collision;

    wire [7:0] status = {st_busy, st_done, st_timeout, st_srq, st_count};

    wire is_talk   = (cmd_r[3:2] == 2'b11);
    wire is_listen = (cmd_r[3:2] == 2'b10);

    //------------------------------------------------------------------
    // Synchronise, then deglitch. A change is only believed once it has held
    // for TICK_GLITCH cycles.
    //------------------------------------------------------------------
    reg [1:0]  sense_sync;
    reg        bus_filt, bus_filt_d;
    reg [15:0] glitch_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sense_sync <= 2'b11;
            bus_filt   <= 1'b1;
            bus_filt_d <= 1'b1;
            glitch_cnt <= 16'd0;
        end else begin
            sense_sync <= {sense_sync[0], adb_sense};
            bus_filt_d <= bus_filt;
            if (sense_sync[1] == bus_filt) begin
                glitch_cnt <= 16'd0;                 // agrees: nothing to do
            end else if (glitch_cnt >= TICK_GLITCH[15:0]) begin
                bus_filt   <= sense_sync[1];         // held long enough: believe it
                glitch_cnt <= 16'd0;
            end else begin
                glitch_cnt <= glitch_cnt + 1'b1;
            end
        end
    end

    wire bus_level = bus_filt;
    wire bus_fall  = bus_filt_d & ~bus_filt;
    wire bus_rise  = ~bus_filt_d & bus_filt;

    // We have released the line but it is still low: someone else is driving.
    // Extended status, read at register 3:
    //   bit 0  collision: the bus was low while we had released it, outside
    //          the service-request window
    //   bit 1  the bus as sensed now (synchronised, not deglitched); 1 = high
    //   bit 2  what we are driving now; 1 = pulling the bus low
    // Bits 1 and 2 are for bringing up the external circuit: with nothing in
    // progress, bit 1 should read 1 and bit 2 0.
    wire [7:0] status2 = {5'd0, adb_drive, sense_sync[1], st_collision};

    wire bus_contended = ~adb_drive & ~bus_level;

    //------------------------------------------------------------------
    // FSM
    //------------------------------------------------------------------
    localparam [3:0]
        S_IDLE  = 4'd0, S_ATTN  = 4'd1, S_SYNC  = 4'd2,
        S_TX_LO = 4'd3, S_TX_HI = 4'd4,
        S_TLT   = 4'd5, S_RX_LO = 4'd6, S_RX_HI = 4'd7,
        S_RESET = 4'd8, S_FINISH= 4'd9, S_HOLD  = 4'd10;

    // what the bit currently being sent belongs to
    localparam [1:0] PH_CMD = 2'd0, PH_CMDSTOP = 2'd1,
                     PH_DATA = 2'd2, PH_DATASTOP = 2'd3;

    reg [3:0]    state;
    reg [1:0]    phase;
    reg [CW-1:0] timer;
    reg [CW-1:0] low_len;
    reg [3:0]    bit_idx;
    reg [3:0]    byte_idx;
    reg [7:0]    shifter;
    reg          cur_bit;
    reg          got_start;
    reg [2:0]    rx_bit;
    reg [7:0]    rx_shift;
    reg [CW-1:0] idle_cnt;              // how long the bus has rested

    integer i;

    // Start transmitting bit `b`: pull low for its low time.
    task tx_bit(input b, input [1:0] ph);
        begin
            cur_bit   <= b;
            phase     <= ph;
            adb_drive <= 1'b1;
            timer     <= b ? TICK_LOW1[CW-1:0] : TICK_LOW0[CW-1:0];
            state     <= S_TX_LO;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            phase      <= PH_CMD;
            adb_drive  <= 1'b0;
            cmd_r      <= 8'h00;
            len_r      <= 8'd0;
            st_busy    <= 1'b0;
            st_done    <= 1'b0;
            st_timeout <= 1'b0;
            st_srq     <= 1'b0;
            st_count   <= 4'd0;
            st_collision <= 1'b0;
            timer      <= {CW{1'b0}};
            low_len    <= {CW{1'b0}};
            bit_idx    <= 4'd0;
            byte_idx   <= 4'd0;
            shifter    <= 8'd0;
            cur_bit    <= 1'b0;
            got_start  <= 1'b0;
            rx_bit     <= 3'd0;
            rx_shift   <= 8'd0;
            idle_cnt   <= {CW{1'b0}};
            for (i = 0; i < 8; i = i + 1) data_r[i] <= 8'd0;
        end else begin
            //----------------------------------------------------------
            // Register writes. Writing the command starts a transaction;
            // length and data must be set up beforehand.
            //----------------------------------------------------------
            if (cs && we && !st_busy) begin
                case (reg_addr)
                R_CMD: begin
                    cmd_r      <= wdata;
                    st_busy    <= 1'b1;
                    st_done    <= 1'b0;
                    st_timeout <= 1'b0;
                    st_srq     <= 1'b0;
                    st_count   <= 4'd0;
                    st_collision <= 1'b0;
                    shifter    <= {wdata[6:0], 1'b0};
                    bit_idx    <= 4'd7;             // 7 bits after this one
                    byte_idx   <= 4'd0;
                    got_start  <= 1'b0;
                    timer      <= {CW{1'b0}};
                    state      <= S_HOLD;           // attention once rested
                    cur_bit    <= wdata[7];
                    phase      <= PH_CMD;
                end
                R_LEN:  len_r <= wdata;
                R_CTRL: if (wdata[0]) begin
                    st_busy   <= 1'b1;
                    st_done   <= 1'b0;
                    adb_drive <= 1'b1;
                    timer     <= TICK_RESET[CW-1:0];
                    state     <= S_RESET;
                end
                default: if (reg_addr[3]) data_r[reg_addr[2:0]] <= wdata;
                endcase
            end

            //----------------------------------------------------------
            // Timed states
            //----------------------------------------------------------
            if (timer != {CW{1'b0}}) begin
                timer <= timer - 1'b1;
            end else begin
                case (state)
                S_IDLE: ;

                S_HOLD: if (idle_cnt >= TICK_IDLE[CW-1:0]) begin
                    adb_drive <= 1'b1;              // attention
                    timer     <= TICK_ATTN[CW-1:0];
                    state     <= S_ATTN;
                end

                S_ATTN: begin
                    adb_drive <= 1'b0;
                    timer     <= TICK_SYNC[CW-1:0];
                    state     <= S_SYNC;
                end

                // First command bit follows the sync period.
                S_SYNC: tx_bit(cur_bit, PH_CMD);

                S_TX_LO: begin
                    adb_drive <= 1'b0;
                    timer     <= cur_bit ? (TICK_BIT[CW-1:0] - TICK_LOW1[CW-1:0])
                                         : (TICK_BIT[CW-1:0] - TICK_LOW0[CW-1:0]);
                    state     <= S_TX_HI;
                end

                S_TX_HI: begin
                    // The line should have come back up while we were not
                    // driving. If it has not, and this is not the stop bit
                    // where a service request is legitimate, someone else is
                    // holding the bus down.
                    if (bus_contended && phase != PH_CMDSTOP)
                        st_collision <= 1'b1;
                    case (phase)
                    PH_CMD:
                        if (bit_idx != 4'd0) begin
                            bit_idx <= bit_idx - 1'b1;
                            shifter <= {shifter[6:0], 1'b0};
                            tx_bit(shifter[7], PH_CMD);
                        end else begin
                            tx_bit(1'b0, PH_CMDSTOP);   // command stop bit
                        end

                    PH_CMDSTOP: begin
                        // A device that wants service holds the line low past
                        // our release at the end of the stop bit.
                        if (!bus_level) st_srq <= 1'b1;
                        if (is_talk) begin
                            timer   <= TICK_TLT[CW-1:0];
                            low_len <= {CW{1'b0}};
                            state   <= S_TLT;
                        end else if (is_listen && len_r != 8'd0) begin
                            got_start <= 1'b0;
                            tx_bit(1'b1, PH_DATA);      // data start bit
                        end else begin
                            state <= S_FINISH;          // Flush / SendReset
                        end
                    end

                    PH_DATA:
                        if (!got_start) begin
                            got_start <= 1'b1;
                            shifter   <= {data_r[0][6:0], 1'b0};
                            bit_idx   <= 4'd7;
                            byte_idx  <= 4'd0;
                            tx_bit(data_r[0][7], PH_DATA);
                        end else if (bit_idx != 4'd0) begin
                            bit_idx <= bit_idx - 1'b1;
                            shifter <= {shifter[6:0], 1'b0};
                            tx_bit(shifter[7], PH_DATA);
                        end else if ({4'd0, byte_idx} + 8'd1 < len_r) begin
                            byte_idx <= byte_idx + 1'b1;
                            shifter  <= {data_r[byte_idx + 1'b1][6:0], 1'b0};
                            bit_idx  <= 4'd7;
                            tx_bit(data_r[byte_idx + 1'b1][7], PH_DATA);
                        end else begin
                            tx_bit(1'b0, PH_DATASTOP);  // data stop bit
                        end

                    PH_DATASTOP: state <= S_FINISH;
                    endcase
                end

                // Receive states are driven by bus edges below, not by the
                // timer; they must still be listed here or the default clause
                // would drag them back to idle.
                S_RX_LO, S_RX_HI: ;

                // Nothing answered inside the window.
                S_TLT: begin
                    st_timeout <= 1'b1;
                    state      <= S_FINISH;
                end

                S_RESET: begin
                    adb_drive <= 1'b0;
                    state     <= S_FINISH;
                end

                S_FINISH: begin
                    adb_drive <= 1'b0;
                    st_busy   <= 1'b0;
                    st_done   <= 1'b1;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
                endcase
            end

            // The bus rests from the end of one transaction to the start of
            // the next. The line level is deliberately not consulted: a bus
            // held down would otherwise keep a command waiting forever, where
            // sending it reports the fault as a collision.
            if (state != S_IDLE && state != S_HOLD)
                idle_cnt <= {CW{1'b0}};
            else if (idle_cnt < TICK_IDLE[CW-1:0])
                idle_cnt <= idle_cnt + 1'b1;

            //----------------------------------------------------------
            // Receive: edge driven, so it runs outside the timer gating.
            //----------------------------------------------------------
            if (state == S_TLT && bus_fall) begin
                low_len <= {CW{1'b0}};
                timer   <= {CW{1'b0}};
                state   <= S_RX_LO;
            end else if (state == S_RX_LO) begin
                if (bus_rise) begin
                    // Decide the bit from how long the line was held low.
                    if (!got_start) begin
                        got_start <= 1'b1;          // that was the start bit
                        rx_bit    <= 3'd0;
                        st_count  <= 4'd0;
                    end else begin
                        rx_shift <= {rx_shift[6:0],
                                     (low_len > TICK_THRESH[CW-1:0]) ? 1'b0 : 1'b1};
                        if (rx_bit == 3'd7) begin
                            rx_bit <= 3'd0;
                            if (st_count < 4'd8) begin
                                data_r[st_count[2:0]] <=
                                    {rx_shift[6:0],
                                     (low_len > TICK_THRESH[CW-1:0]) ? 1'b0 : 1'b1};
                                st_count <= st_count + 1'b1;
                            end
                        end else begin
                            rx_bit <= rx_bit + 1'b1;
                        end
                    end
                    timer <= {CW{1'b0}};
                    low_len <= {CW{1'b0}};
                    state <= S_RX_HI;
                end else begin
                    low_len <= low_len + 1'b1;
                end
            end else if (state == S_RX_HI) begin
                if (bus_fall) begin
                    low_len <= {CW{1'b0}};
                    state   <= S_RX_LO;
                end else if (low_len > TICK_RXEND[CW-1:0]) begin
                    // No further bit: the last one was the stop bit, which was
                    // shifted in as if it were data, so drop it.
                    if (rx_bit == 3'd1) st_count <= st_count;
                    state <= S_FINISH;
                end else begin
                    low_len <= low_len + 1'b1;
                end
            end
        end
    end

    always @* begin
        case (reg_addr)
        R_CMD:    rdata = cmd_r;
        R_STATUS: rdata = status;
        R_LEN:    rdata = len_r;
        R_CTRL:   rdata = status2;
        default:  rdata = reg_addr[3] ? data_r[reg_addr[2:0]] : 8'hFF;
        endcase
    end
endmodule

`default_nettype wire
