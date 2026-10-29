//============================================================================
// sd_spi.v -- the microSD slot in SPI mode, $02C0
//
// The Tang Nano's microSD slot, driven as an SPI device: CLK is SCLK (pin
// 83), CMD is MOSI (82), D0 is MISO (84) and D3 is chip select (81). D1 and
// D2 are not used in SPI mode (their pins carry DMA's TC and DRQ1), so 4-bit
// SD mode is not available. The controller only moves bytes: commands,
// responses and data tokens are the software's.
//
// An exchange sends a byte, most significant bit first, and receives one at
// the same time, in SPI mode 0: SCLK idles low, MOSI changes on the falling
// edge and MISO is sampled on the rising one. MOSI idles high. SCLK is the
// system clock / (2 * (DIVIDER + 1)): 0 is 12.6 MHz at 25.2 MHz, and the
// reset value keeps it under the 400 kHz a card needs until it is
// initialised (31: 393.75 kHz).
//
// Registers (reg_addr[1:0], mirrored through the slot):
//   +0  DATA     write: send the byte. read: the byte last received.
//   +1  NEXT     read: the byte last received, and send $FF to receive the
//                next one, so a block is read with one load a byte. Writes
//                are ignored.
//   +2  STATUS   read: bit 7 BUSY (an exchange is running), bit 0 SELECT.
//       CONTROL  write: bit 0 SELECT (1 drives chip select low).
//   +3  DIVIDER  read and write.
//
// NO POLLING. An access to DATA or NEXT while an exchange is running waits
// for it to finish: the access is latched here, `stall` holds the CPU's I/O
// cycle open (soc.v), and when the exchange ends the access is carried out
// and the CPU released. So a write then a read of DATA returns the reply to
// the byte written, and a loop of NEXT reads goes as fast as the card. An
// exchange takes 16 * (DIVIDER + 1) + 1 clocks.
//============================================================================
`default_nettype none

module sd_spi #(
    parameter integer SYS_HZ = 25_200_000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [1:0]  reg_addr,
    input  wire [7:0]  wdata,
    output reg  [7:0]  rdata,            // STATUS and DIVIDER, from reg_addr
    output reg  [7:0]  rx,               // DATA and NEXT: a register
    input  wire        cs,               // one-cycle strobe
    input  wire        we,
    output wire        stall,            // hold the access: it waits

    output reg         sd_clk,
    output wire        sd_mosi,
    output wire        sd_cs_n,
    input  wire        sd_miso
);
    // The slowest SCLK under 400 kHz: half a period of DIVIDER + 1 clocks.
    localparam integer DIV_SLOW = (SYS_HZ + 799_999) / 800_000 - 1;

    localparam [1:0] P_NONE = 2'd0, P_READ = 2'd1, P_SEND = 2'd2, P_NEXT = 2'd3;

    reg [7:0] sr;                        // out at the top, in at the bottom
    reg [7:0] div;
    reg [7:0] cnt;                       // clocks left in this half period
    reg [2:0] bits;                      // bits done
    reg       busy, sel, inbit;
    reg [1:0] pend;                      // the access waiting for the exchange
    reg [7:0] pend_byte;

    assign sd_mosi = busy ? sr[7] : 1'b1;
    assign sd_cs_n = ~sel;
    assign stall   = (pend != P_NONE);

    // This cycle's access to DATA or NEXT, if any.
    wire [1:0] op = ~cs                     ? P_NONE :
                    (reg_addr == 2'd0) & we ? P_SEND :
                    (reg_addr == 2'd0)      ? P_READ :
                    (reg_addr == 2'd1) & ~we ? P_NEXT : P_NONE;

    wire last = busy & (cnt == 8'd0) & sd_clk & (bits == 3'd7);
    wire [7:0] got = {sr[6:0], inbit};

    // Start an exchange of byte b.
    task start(input [7:0] b);
        begin
            sr   <= b;
            busy <= 1'b1;
            bits <= 3'd0;
            cnt  <= div;                 // MOSI is set up for a half period
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr        <= 8'hFF;
            rx        <= 8'hFF;
            div       <= DIV_SLOW[7:0];
            cnt       <= 8'd0;
            bits      <= 3'd0;
            busy      <= 1'b0;
            sel       <= 1'b0;
            inbit     <= 1'b1;
            sd_clk    <= 1'b0;
            pend      <= P_NONE;
            pend_byte <= 8'hFF;
        end else begin
            if (cs & we & (reg_addr == 2'd2)) sel <= wdata[0];
            if (cs & we & (reg_addr == 2'd3)) div <= wdata;

            if (busy) begin
                // An access while busy waits; the CPU is held, so there is
                // never more than one.
                if (op != P_NONE) begin
                    pend      <= op;
                    pend_byte <= wdata;
                end

                if (cnt != 8'd0)
                    cnt <= cnt - 8'd1;
                else if (!sd_clk) begin  // rising edge: sample
                    cnt    <= div;
                    sd_clk <= 1'b1;
                    inbit  <= sd_miso;
                end else begin           // falling edge: shift
                    cnt    <= div;
                    sd_clk <= 1'b0;
                    sr     <= got;
                    bits   <= bits + 3'd1;
                end

                // The end of the exchange: the byte is in, and the waiting
                // access is carried out.
                // An access arriving in this very cycle is carried out with
                // it, as one that had waited.
                if (last) begin
                    rx   <= got;
                    busy <= 1'b0;
                    pend <= P_NONE;
                    case (op != P_NONE ? op : pend)
                        P_SEND:  start(op != P_NONE ? wdata : pend_byte);
                        P_NEXT:  start(8'hFF);
                        default: ;
                    endcase
                end
            end else begin
                case (op)
                    P_SEND:  start(wdata);
                    P_NEXT:  start(8'hFF);
                    default: ;
                endcase
            end
        end
    end

    always @* begin
        case (reg_addr)
            2'd2:    rdata = {busy, 6'd0, sel};
            2'd3:    rdata = div;
            default: rdata = rx;
        endcase
    end
endmodule

`default_nettype wire
