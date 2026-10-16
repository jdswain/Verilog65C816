// Diagnostic wrapper: run the real SoC, but instead of trusting the serial port,
// stream the CPU's address bus out of the transmitter that is known to work
// on this board. Tells us whether the CPU runs at all and, if it is stuck,
// exactly where.
//
// Emits "AAAAAA S\r\n" a few times a second: 24-bit address, then a flag
// character ('.' running, 'S' stopped after STP).
`default_nettype none

`include "rom_path.vh"

module socdbg (
    input  wire       clk,
    output wire       uart_tx,
    output wire [5:0] led
);
    localparam integer DIVISOR = 234;

    reg [7:0] por = 8'd0;
    wire      rst_n = por[7];
    always @(posedge clk) if (!rst_n) por <= por + 1'b1;

    wire [23:0] dbg_addr;
    wire        dbg_vld, dbg_we, dbg_stopped;
    wire        soc_txd;
    wire [5:0]  soc_led;

    soc #(.ROM_HEX(`ROM_HEX_PATH), .FONT_HEX(`FONT_HEX_PATH), .DIVISOR(DIVISOR),
          .MAP(`ROM_MAP), .ROM_BITS(`ROM_BITS_DEF), .ROM_BASE(`ROM_BASE_DEF)) u_soc (
        .clk(clk), .rst_n(rst_n), .rxd(1'b1), .txd(soc_txd), .led(soc_led),
        .dbg_addr(dbg_addr), .dbg_vld(dbg_vld), .dbg_we(dbg_we),
        .dbg_stopped(dbg_stopped)
    );

    // Sample the address a few times a second and shift it out as hex.
    reg [22:0] tick = 23'd0;
    reg [23:0] snap = 24'd0;
    reg [3:0]  idx  = 4'd10;        // 10 = idle
    reg        load = 1'b0;
    wire       busy;

    function [7:0] hex(input [3:0] n);
        hex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
    endfunction

    reg [7:0] ch;
    always @* begin
        case (idx)
        4'd0: ch = hex(snap[23:20]);
        4'd1: ch = hex(snap[19:16]);
        4'd2: ch = hex(snap[15:12]);
        4'd3: ch = hex(snap[11:8]);
        4'd4: ch = hex(snap[7:4]);
        4'd5: ch = hex(snap[3:0]);
        4'd6: ch = 8'h20;                       // space
        4'd7: ch = dbg_stopped ? 8'h53 : 8'h2E; // 'S' or '.'
        4'd8: ch = 8'h0D;
        4'd9: ch = 8'h0A;
        default: ch = 8'h2E;
        endcase
    end

    always @(posedge clk) begin
        load <= 1'b0;
        if (!rst_n) begin
            tick <= 23'd0;
            idx  <= 4'd10;
        end else if (idx == 4'd10) begin
            tick <= tick + 1'b1;
            if (tick == 23'h7FFFFF) begin
                snap <= dbg_addr;               // latch what the CPU is doing
                idx  <= 4'd0;
            end
        end else if (!busy && !load) begin
            load <= 1'b1;
            idx  <= (idx == 4'd9) ? 4'd10 : idx + 1'b1;
        end
    end

    uart_tx #(.DIVISOR(DIVISOR)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .data(ch), .load(load), .busy(busy), .txd(uart_tx)
    );

    reg [25:0] cnt = 26'd0;
    always @(posedge clk) cnt <= cnt + 1'b1;
    assign led = ~{cnt[24], dbg_stopped, soc_led[3], soc_txd, dbg_vld, busy};
endmodule

`default_nettype wire
