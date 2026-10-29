//============================================================================
// sd_card_model.v -- an SDHC card in SPI mode, for simulation
//
// Enough of the SD Physical Layer spec's SPI mode for a block driver:
//   CMD0  GO_IDLE_STATE       R1; the CRC must be right ($95)
//   CMD8  SEND_IF_COND        R7, the voltage and check pattern echoed; the
//                             CRC must be right ($87 for $1AA)
//   CMD9  SEND_CSD            a version 2 CSD giving the image's size
//   CMD10 SEND_CID            a CID
//   CMD12 STOP_TRANSMISSION   R1b, ending CMD18
//   CMD13 SEND_STATUS         R2
//   CMD16 SET_BLOCKLEN        R1; only 512
//   CMD17 READ_SINGLE_BLOCK   R1, then $FE, 512 bytes and the CRC16
//   CMD18 READ_MULTIPLE_BLOCK R1, then blocks until CMD12
//   CMD24 WRITE_BLOCK         R1; then $FE and 512 bytes, answered $05 and
//                             busy for a few bytes
//   CMD25 WRITE_MULTIPLE      R1; then blocks after $FC, until $FD
//   CMD55 APP_CMD, ACMD41     idle for the first ACMD41, ready on the second
//   CMD58 READ_OCR            R3: powered up once ready, CCS set
// Anything else is answered as an illegal command. It is block addressed
// (SDHC), and CRCs other than CMD0's and CMD8's are not checked.
//
// The card answers a command after one $FF byte (NCR), and a read's data
// token after one more (NAC). It shifts MOSI in on the rising edge of SCLK
// and changes MISO on the falling edge (mode 0). Chip select going high
// abandons whatever it was sending. +sd=image.hex loads the image, a byte a
// line; without it there is no card and miso_oe stays low.
//============================================================================
`timescale 1ns/1ps

module sd_card_model #(
    parameter integer BLOCKS = 2048     // 1 MB
) (
    input  wire sclk,
    input  wire mosi,
    input  wire cs_n,
    output reg  miso = 1'b1,
    output wire miso_oe
);
    reg [7:0] mem [0:BLOCKS*512-1];
    reg present = 1'b0;
    reg [8*256-1:0] path;
    integer i;
    initial begin
        for (i = 0; i < BLOCKS*512; i = i + 1) mem[i] = 8'h00;
        if ($value$plusargs("sd=%s", path)) begin
            $readmemh(path, mem);
            present = 1'b1;
        end
    end
    assign miso_oe = present & ~cs_n;

    // What the card sends, a byte at a time.
    reg [7:0] q [0:2047];
    integer qh = 0, qt = 0;
    task push(input [7:0] b); begin q[qt] = b; qt = (qt + 1) % 2048; end endtask

    // CRC16-CCITT of a block, as a read sends it.
    function [15:0] crc16(input integer base);
        integer n, b;
        reg [15:0] c;
        begin
            c = 16'h0000;
            for (n = 0; n < 512; n = n + 1) begin
                c = c ^ {mem[base + n], 8'h00};
                for (b = 0; b < 8; b = b + 1)
                    c = c[15] ? {c[14:0], 1'b0} ^ 16'h1021 : {c[14:0], 1'b0};
            end
            crc16 = c;
        end
    endfunction

    task push_block(input integer blk);
        integer n;
        reg [15:0] c;
        begin
            push(8'hFF);                 // NAC
            push(8'hFE);                 // start block token
            for (n = 0; n < 512; n = n + 1) push(mem[blk*512 + n]);
            c = crc16(blk*512);
            push(c[15:8]); push(c[7:0]);
        end
    endtask

    // Command state
    reg [7:0]  cmd [0:5];
    integer    ncmd = 0;                 // command bytes collected
    reg        idle = 1'b1, app = 1'b0;
    integer    acmd41s = 0;
    reg        rd_multi = 1'b0;          // CMD18 running
    integer    rd_blk;
    // Writing: 0 none, 1 waiting for a token, 2 taking data
    integer    wr_state = 0, wr_blk, wr_n;
    reg        wr_multi = 1'b0;
    reg [7:0]  wr_buf [0:513];

    task r1(input [7:0] flags); begin push(8'hFF); push({7'd0, idle} | flags); end endtask

    task command;
        reg [5:0]  c;
        reg [31:0] arg;
        integer    n;
        begin
            c   = cmd[0][5:0];
            arg = {cmd[1], cmd[2], cmd[3], cmd[4]};
            if (app && c == 6'd41) begin
                app = 1'b0;
                acmd41s = acmd41s + 1;
                if (acmd41s >= 2) idle = 1'b0;
                r1(8'h00);
            end else begin
                app = 1'b0;
                case (c)
                6'd0:  if (cmd[5] != 8'h95) r1(8'h08);
                       else begin idle = 1'b1; acmd41s = 0; rd_multi = 1'b0; r1(8'h00); end
                6'd8:  if (cmd[5] != 8'h87) r1(8'h08);
                       else begin r1(8'h00); push(8'h00); push(8'h00); push(cmd[3]); push(cmd[4]); end
                6'd9:  begin
                           r1(8'h00);
                           push(8'hFF); push(8'hFE);
                           // CSD version 2: C_SIZE = blocks / 1024 - 1
                           push(8'h40); push(8'h0E); push(8'h00); push(8'h32);
                           push(8'h5B); push(8'h59); push(8'h00);
                           n = BLOCKS / 1024 - 1;
                           push({2'b00, n[21:16]}); push(n[15:8]); push(n[7:0]);
                           push(8'h7F); push(8'h80); push(8'h0A); push(8'h40);
                           push(8'h00); push(8'h01);
                           push(8'h00); push(8'h00);   // CRC16, not checked
                       end
                6'd10: begin
                           r1(8'h00);
                           push(8'hFF); push(8'hFE);
                           for (n = 0; n < 16; n = n + 1) push(8'h41 + n);
                           push(8'h00); push(8'h00);
                       end
                6'd12: begin
                           qt = qh;              // the block being sent stops
                           rd_multi = 1'b0;
                           push(8'hFF);          // the stuff byte after CMD12
                           r1(8'h00); push(8'h00); push(8'hFF);   // R1b
                       end
                6'd13: begin r1(8'h00); push(8'h00); end
                6'd16: r1(arg == 32'd512 ? 8'h00 : 8'h40);
                6'd17: if (arg >= BLOCKS) r1(8'h40);
                       else begin r1(8'h00); push_block(arg); end
                6'd18: if (arg >= BLOCKS) r1(8'h40);
                       else begin r1(8'h00); rd_multi = 1'b1; rd_blk = arg; end
                6'd24, 6'd25:
                       if (arg >= BLOCKS) r1(8'h40);
                       else begin
                           r1(8'h00);
                           wr_state = 1; wr_blk = arg; wr_multi = (c == 6'd25);
                       end
                6'd55: begin app = 1'b1; r1(8'h00); end
                6'd58: begin
                           r1(8'h00);
                           push(idle ? 8'h40 : 8'hC0); push(8'hFF); push(8'h80); push(8'h00);
                       end
                default: r1(8'h04);
                endcase
            end
        end
    endtask

    // A byte from the host.
    task take(input [7:0] b);
        integer n;
        begin
            if (wr_state == 1) begin
                if (b == 8'hFE || (wr_multi && b == 8'hFC)) begin
                    wr_state = 2; wr_n = 0;
                end else if (wr_multi && b == 8'hFD) begin
                    wr_state = 0;                    // stop tran: busy, then done
                    push(8'hFF); push(8'h00); push(8'h00); push(8'hFF);
                end
            end else if (wr_state == 2) begin
                wr_buf[wr_n] = b; wr_n = wr_n + 1;
                if (wr_n == 514) begin               // the data and its CRC
                    for (n = 0; n < 512; n = n + 1) mem[wr_blk*512 + n] = wr_buf[n];
                    push(8'h05);                     // data accepted
                    push(8'h00); push(8'h00); push(8'h00);   // busy
                    push(8'hFF);
                    if (wr_multi && wr_blk + 1 < BLOCKS) begin
                        wr_blk = wr_blk + 1; wr_state = 1;
                    end else
                        wr_state = 0;
                end
            end else if (ncmd > 0) begin
                cmd[ncmd] = b; ncmd = ncmd + 1;
                if (ncmd == 6) begin ncmd = 0; command; end
            end else if (b[7:6] == 2'b01) begin
                cmd[0] = b; ncmd = 1;
            end
        end
    endtask

    // The SPI side
    reg [7:0] in_sr = 8'hFF, out_sr = 8'hFF;
    integer bitn = 0;

    always @(negedge cs_n) begin
        bitn = 0; out_sr = 8'hFF; miso = 1'b1;
    end
    always @(posedge cs_n) begin
        qh = 0; qt = 0; ncmd = 0; rd_multi = 1'b0;
        if (wr_state == 2) wr_state = 0;
    end

    always @(posedge sclk) if (!cs_n && present) begin
        in_sr = {in_sr[6:0], mosi};
        bitn = bitn + 1;
        if (bitn == 8) begin
            bitn = 0;
            take(in_sr);
            if (qh == qt && rd_multi) begin
                push_block(rd_blk);
                rd_blk = (rd_blk + 1) % BLOCKS;
            end
            if (qh != qt) begin out_sr = q[qh]; qh = (qh + 1) % 2048; end
            else out_sr = 8'hFF;
        end
    end

    always @(negedge sclk) if (!cs_n && present) miso = out_sr[7 - bitn];
endmodule
