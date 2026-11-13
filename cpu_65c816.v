//============================================================================
// cpu_65c816.v -- WDC 65C832 (and so 65C816) compatible CPU core
//
// A 65C832 (docs/65C832.md): the 65C816, and a native mode with a 32-bit
// accumulator and 32-bit index registers, chosen by the hidden bits E16 and
// E8 (E8 is the 65C816's E). XCE exchanges C and E8 as on the 65C816; XFE
// ($42 $FB) exchanges C and E8, V and E16. WDM ($42) is a prefix: with the
// byte after it, one instruction of the extension (MUL, UML, DIV, UDV, the
// multi-bit shifts and rotates, BSW). Parameters: C832 = 0 leaves E16 at 1
// (a 65C816), XOPS = 0 leaves the extension out.
//
// Goals: functional compatibility, NOT cycle accuracy. Every bus cycle does
// useful work: there are no dummy/phantom reads or writes (unlike the real
// chip / 6502). Most instructions complete in fewer cycles than the real
// part. Implied register ops (TAX, INX, CLC, XCE, ...) take a single cycle:
// latched at their fetch, executed during the next opcode's.
//
// Nothing computes on the read data in the cycle it arrives, and the bus
// address is a mux of registers. A read's operand is latched and its execute
// runs in the next cycle (xp), overlapped with the next opcode fetch, as is an
// implied opcode's (lp); an RMW's result is formed in its write cycle. Only a
// pull fetched behind such an execute, and an interrupt, wait a cycle for it.
//
// Instruction bytes come from an 8-byte queue, never straight off the bus.
// The queue fills a 32-bit word at a time (rdata32) in cycles the core does
// not use the bus. An instruction takes two cycles from its head, the opcode
// and then all its operand bytes at once (S_OPS); a jump empties it. A store
// to bytes already queued (at most the 8 after the current instruction) does
// not change them: code written by stores needs a taken jump before it runs
// (the rule software relies on, kept across changes to the core), or, with
// this queue only, must lie 8 bytes or more past the store.
//
// Bus protocol (simple synchronous SRAM-style):
//   - When `vld` is high a bus cycle is in progress at `addr`.
//   - Read  (we=0): memory must drive `rdata` combinationally in the same
//     cycle (async read); the core samples it on the rising clock edge when
//     rdy=1. For synchronous memories, hold `rdy` low for one cycle. A
//     memory that can also drive the whole aligned word on `rdata32` raises
//     `r32`; the instruction queue then takes all of it (else one byte).
//     Queue fills are flagged VPA=1, VDA=0.
//   - Write (we=1): `addr`/`wdata` are valid; the system commits the write
//     on the rising edge when rdy=1.
//   - `rdy` low holds the bus cycle (wait states). A state that does not
//     use the bus keeps running while a queue fill waits.
//
// Interrupts: RES (rst_n), NMI (falling edge), IRQ (level). ABORT is not
// implemented.
//
// Known simplifications (documented deviations from the real chip):
//   - No cycle accuracy; bus traffic differs from the real part.
//   - Emulation-mode page-wrap quirks are not modeled: direct-page pointer
//     fetches use full 16-bit wrap in bank 0 (not page wrap when DL=0).
//   - Indexed data accesses always use 24-bit address arithmetic (they can
//     cross banks even in emulation mode).
//   - The V flag in decimal mode is computed as for binary arithmetic.
//   - VPA/VDA/VPB/MLB status outputs and ABORT are not provided.
//
// Extension: banked direct page and stack (docs/BankedDP.md). WDM $B1 sets
// the mode, WDM $B0 clears it (reset clears it; a WDM with a byte the
// extension does not use is a 2-byte no-op). In native mode with the mode
// set, D is a page number: the direct page is at {D, $00} and the stack at
// {DH, S}, so both leave bank 0 together.
//============================================================================

`default_nettype none

module cpu_65c816 #(
    parameter C832 = 1,         // the 65C832 native mode (E16)
    parameter XOPS = 1          // MUL/UML/DIV/UDV, shifts by n, BSW
) (
    input  wire        clk,
    input  wire        rst_n,
    // bus
    output reg  [23:0] addr,
    output reg  [7:0]  wdata,
    input  wire [7:0]  rdata,
    input  wire [31:0] rdata32, // the aligned word holding addr, when r32
    input  wire        r32,     // this read returns the whole word (rdata32)
    output reg         we,      // 1 = write cycle
    output reg         vld,     // bus cycle valid
    input  wire        rdy,     // memory ready (wait-state when low)
    // interrupts
    input  wire        irq_n,
    input  wire        nmi_n,
    input  wire        abort_n, // abort current instruction (active low)
    // bus-cycle classification (like the W65C816 status pins)
    output reg         vpa,     // valid program address (opcode/operand fetch)
    output reg         vda,     // valid data address (data read/write)
    output reg         vpb_n,   // vector pull, active low
    output reg         mlb_n,   // memory lock (RMW), active low
    // status
    output wire        e_flag,  // emulation mode
    output wire        m_flag,
    output wire        x_flag,
    output wire        stopped  // STP executed (until reset)
);

    //------------------------------------------------------------------
    // Architectural registers
    //------------------------------------------------------------------
    reg [31:0] A;        // accumulator (B = A[15:8]; bits above its width kept)
    reg [31:0] X, Y;     // index registers (0 above their width)
    reg [15:0] S;        // stack pointer (high byte forced 01 when E=1)
    reg [15:0] D;        // direct page register
    reg [15:0] PC;
    reg [7:0]  DBR, PBR;
    reg fC, fZ, fI, fD, fX, fM, fV, fN, fE;
    reg fE16;            // E16: 0 = 65C832 native (fE is E8)
    reg xb;              // banked direct page and stack (WDM $B1 / $B0)

    // the mode, and the registers' widths (W8, W16, W32)
    localparam [1:0] W8 = 2'd0, W16 = 2'd1, W32 = 2'd2;
    wire emu  = fE & fE16;                  // 6502 emulation
    wire n832 = (C832 != 0) & ~fE16;        // 65C832 native
    wire a32  = n832 & fE & ~fM;            // 32-bit accumulator/memory
    wire m16  = ~emu & ~fM & ~a32;          // 16-bit accumulator/memory
    wire x32  = n832 & ~fX;                 // 32-bit index registers
    wire x16  = fE16 & ~fE & ~fX;           // 16-bit (65C816 native only)
    wire [1:0] aw = a32 ? W32 : (m16 ? W16 : W8);
    wire [1:0] xw = x32 ? W32 : (x16 ? W16 : W8);
    wire cw32 = n832 & fE;                  // A's wide width is 32 (MVN's count)

    function [31:0] wmask(input [1:0] w);
        wmask = (w == W32) ? 32'hFFFFFFFF : (w == W16) ? 32'h0000FFFF : 32'h000000FF;
    endfunction
    function topb(input [31:0] v, input [1:0] w);     // the sign bit
        topb = (w == W32) ? v[31] : (w == W16) ? v[15] : v[7];
    endfunction
    function nextb(input [31:0] v, input [1:0] w);    // the one below it
        nextb = (w == W32) ? v[30] : (w == W16) ? v[14] : v[6];
    endfunction
    function zerow(input [31:0] v, input [1:0] w);
        zerow = ((v & wmask(w)) == 32'h0);
    endfunction

    assign e_flag  = emu;
    assign m_flag  = fM;
    assign x_flag  = fX;

    //------------------------------------------------------------------
    // FSM state
    //------------------------------------------------------------------
    localparam [4:0]
        S_FETCH = 5'd0,   // opcode fetch (+ folded implied execute)
        S_OPS   = 5'd1,   // the operand bytes, all at once
        S_PTRL  = 5'd4,   // indirect pointer low
        S_PTRH  = 5'd5,   // indirect pointer high
        S_PTRB  = 5'd6,   // indirect pointer bank
        S_RDL   = 5'd7,   // data read, the low byte
        S_RDH   = 5'd8,   // data read, the next bytes (rb)
        S_WRL   = 5'd9,   // store write low
        S_WRH   = 5'd10,  // store write, the next bytes (rb)
        S_WBL   = 5'd11,  // RMW write-back low
        S_WBH   = 5'd12,  // RMW write-back, the next bytes (rb)
        S_PUSH  = 5'd13,  // stack push (multi-byte)
        S_PULL  = 5'd14,  // stack pull (multi-byte)
        S_VECL  = 5'd15,  // vector fetch low
        S_VECH  = 5'd16,  // vector fetch high
        S_MVR   = 5'd17,  // block move read
        S_MVW   = 5'd18,  // block move write
        S_WAI   = 5'd19,  // waiting for interrupt
        S_STP   = 5'd20,  // stopped
        S_IMP   = 5'd21,  // push / WAI / STP setup
        S_XOP   = 5'd22,  // the opcode after a WDM prefix
        S_MD    = 5'd23;  // multiply / divide (md_ph)

    reg [4:0] state;
    assign stopped = (state == S_STP);

    //------------------------------------------------------------------
    // Addressing modes / classes / operations (from decode)
    //------------------------------------------------------------------
    localparam [4:0]
        MD_NON=5'd0,  MD_IMM=5'd1,  MD_DP =5'd2,  MD_DPX=5'd3,  MD_DPY=5'd4,
        MD_ABS=5'd5,  MD_ABX=5'd6,  MD_ABY=5'd7,  MD_ABL=5'd8,  MD_ALX=5'd9,
        MD_IDX=5'd10, MD_IDP=5'd11, MD_IDY=5'd12, MD_IDL=5'd13, MD_ILY=5'd14,
        MD_SR =5'd15, MD_SRY=5'd16, MD_REL=5'd17, MD_RLL=5'd18,
        MD_IAB=5'd19, MD_IAX=5'd20, MD_IAL=5'd21;

    localparam [2:0]
        CL_SPC=3'd0, CL_RD=3'd1, CL_WR=3'd2, CL_MW=3'd3, CL_JMP=3'd4,
        CL_JSR=3'd5;

    localparam [4:0]
        OP_ORA=5'd0,  OP_AND=5'd1,  OP_EOR=5'd2,  OP_ADC=5'd3,  OP_SBC=5'd4,
        OP_CMP=5'd5,  OP_LDA=5'd6,  OP_BIT=5'd7,  OP_LDX=5'd8,  OP_LDY=5'd9,
        OP_CPX=5'd10, OP_CPY=5'd11, OP_STA=5'd12, OP_STX=5'd13, OP_STY=5'd14,
        OP_STZ=5'd15, OP_ASL=5'd16, OP_ROL=5'd17, OP_LSR=5'd18, OP_ROR=5'd19,
        OP_INC=5'd20, OP_DEC=5'd21, OP_TSB=5'd22, OP_TRB=5'd23, OP_REP=5'd24,
        OP_SEP=5'd25, OP_NOP=5'd26,
        // the extension's, after the WDM prefix
        OP_MUL=5'd27, OP_UML=5'd28, OP_DIV=5'd29, OP_UDV=5'd30, OP_SHF=5'd31;

    //------------------------------------------------------------------
    // Working registers
    //------------------------------------------------------------------
    reg [7:0]  IR;
    reg        IRx;           // IR followed a WDM prefix
    reg [7:0]  tlo, tmid;     // operand / pointer byte accumulators
    reg [15:0] tptr;          // indirect pointer address
    reg [7:0]  ptr_bank;      // bank for pointer fetches
    reg [23:0] taddr;         // effective data address
    reg        wrap16;        // effective addr +1 wraps within bank (dp/stack)
    reg [31:0] tdata;         // RMW result / block-move byte / pulled bytes
    reg [31:0] push_q;        // push queue, MSB first
    reg [2:0]  push_n;
    reg        stk16;         // new 16-bit stack op (PEA/PEI/PER/PHD/PLD):
                              // S crosses pages in emulation, SH restored after
    reg [1:0]  post_push;     // routing after the last push
    reg [1:0]  pull_idx;
    reg [15:0] vec;           // interrupt vector address (bank 0)
    reg [23:0] taddr_alt;     // a wide access's first address (RMW write-back)
    reg [1:0]  rb;            // the byte of a wide access (S_RDH/S_WRH/S_WBH)
    reg [23:0] mv_s, mv_d;    // a block move's source and destination
    reg [23:0] pa;            // the next pull's address
    // Deferred execute: a read-class instruction's operand is latched as it
    // arrives (xm) and executed in the next cycle, the following opcode fetch,
    // so no ALU sits behind the read data. An opcode that is itself executed
    // in the fetch cycle, or an interrupt, waits a cycle for it.
    reg        xp;            // an execute is pending, of xm
    reg        lp;            // an implied opcode's execute is pending (IR)
    reg [31:0] xm;
    reg        snap_late;     // the ABORT snapshot's registers, a cycle late

    // The multiply / divide unit (S_MD): a shift-and-add multiply and a
    // restoring divide of A by the operand (xm), a bit a cycle, sharing one
    // adder. Signed operands: MUL corrects the high half after an unsigned
    // multiply; DIV divides the magnitudes and then rounds the quotient down.
    localparam [3:0] P_INIT = 4'd0, P_NEGA = 4'd1, P_NEGB = 4'd2, P_LOOP = 4'd3,
                     P_FIX1 = 4'd4, P_FIX2 = 4'd5, P_FIXQ = 4'd6, P_FIXR = 4'd7,
                     P_DONE = 4'd8;
    reg [3:0]  md_ph;
    reg [32:0] md_h;          // the product's high half / the remainder
    reg [31:0] md_l;          // the multiplier, then the low half / the quotient
    reg [31:0] md_a, md_b;    // A's operand and the memory's, at A's width
    reg [5:0]  md_n;          // steps to go
    reg        md_sx, md_sy;  // their signs (signed operations)
    reg        md_sg, md_dv;  // signed; a divide
    reg        md_ov;         // DIV: the most negative number by -1

    // Instruction queue. Opcode and operand bytes come from here, never
    // from the bus: a fetcher fills it a word at a time in the cycles the
    // core does not use the bus, and the core takes bytes from its head.
    // q[7:0] is the byte at PC; fa = PC + qn is the next byte to fetch.
    // A jump empties it (and drops a fetch in flight). Bytes already queued
    // are not refetched when a store changes them.
    reg [63:0] q;
    reg [3:0]  qn;            // bytes queued, 0-8
    reg [15:0] fa;            // offset in PBR of the next byte to fetch
    reg [23:0] faddr;         // the fetch in flight's address
    reg        fbusy;         // a fetch holds the bus until rdy
    reg        fdrop;         // ... and its bytes are stale (a jump since)
    // per-cycle flags from the state machine to the queue logic
    reg [2:0]  take;          // bytes taken from the head
    reg        jmp;           // PC written out of sequence: empty the queue
    reg [15:0] jpc;
    reg [7:0]  jbank;         // and the bank to fetch from
    wire [7:0] qb = q[7:0];

    localparam [1:0] PP_FETCH=2'd0, PP_VEC=2'd1, PP_PTR=2'd2;

    // interrupt synchronizers / NMI edge detect. irq2 and nmi_pend change
    // only as a bus cycle ends (step): S_FETCH drops vld for an interrupt,
    // and an opcode fetch that is waiting for rdy must not be abandoned --
    // the memory may finish it anyway and its rdy would end the next access.
    reg  irq1, irq2, nmi1, nmi2, nmi_pend, nmi_seen;
    reg  ab;                      // synchronized ABORT input
    wire intr = nmi_pend | (~irq2 & ~fI);

    //------------------------------------------------------------------
    // ABORT support. The aborted instruction must commit nothing: a
    // snapshot of the architectural state taken at the opcode fetch is
    // restored, all writes during the instruction are suppressed, and the
    // core then vectors through the ABORT vector with the *opcode* address
    // pushed (so RTI retries the instruction).
    //------------------------------------------------------------------
    reg        abort_pend;       // an abort is pending for the running instr
    reg [31:0] sA, sX, sY;
    reg [15:0] sS, sD, sPC;
    reg [7:0]  sDBR, sPBR;
    reg        sxb;
    reg        sfN, sfV, sfM, sfX, sfD, sfI, sfZ, sfC, sfE, sfE16;

    // ABORT may be recognized during any instruction-execution state, but not
    // during an interrupt/abort entry (push + vector fetch) or while halted.
    wire abortable = ~(((state == S_PUSH) & (post_push == PP_VEC)) |
                       (state == S_VECL) | (state == S_VECH) |
                       (state == S_STP)  | (state == S_WAI));
    wire abrt = ~ab & abortable;   // abort recognized this cycle

    //------------------------------------------------------------------
    // Decode (combinational, from IR)
    //------------------------------------------------------------------
    // Instruction decode.
    //
    // This is a REGISTERED decode: the 256-way case is a function applied to
    // the opcode as it arrives, and the result is latched alongside IR. Left
    // combinational off IR it sat between the instruction register and the
    // execute logic, adding a 256-way decode to every execute path.
    reg [4:0] d_mode;
    reg [2:0] d_cls;
    reg [4:0] d_op;
    reg [1:0] d_len;          // operand bytes (an immediate's, 8-bit)

    function [12:0] dec(input [7:0] op);
        reg [4:0] dm;
        reg [2:0] dc;
        reg [4:0] dp;
        begin
        dm = MD_NON; dc = CL_SPC; dp = OP_NOP;
        case (op)
        // 0x
        8'h00: ;                                                       // BRK (S_OPS special)
        8'h01: begin dm=MD_IDX; dc=CL_RD; dp=OP_ORA; end
        8'h02: ;                                                       // COP (S_OPS special)
        8'h03: begin dm=MD_SR;  dc=CL_RD; dp=OP_ORA; end
        8'h04: begin dm=MD_DP;  dc=CL_MW; dp=OP_TSB; end
        8'h05: begin dm=MD_DP;  dc=CL_RD; dp=OP_ORA; end
        8'h06: begin dm=MD_DP;  dc=CL_MW; dp=OP_ASL; end
        8'h07: begin dm=MD_IDL; dc=CL_RD; dp=OP_ORA; end
        8'h09: begin dm=MD_IMM; dc=CL_RD; dp=OP_ORA; end
        8'h0C: begin dm=MD_ABS; dc=CL_MW; dp=OP_TSB; end
        8'h0D: begin dm=MD_ABS; dc=CL_RD; dp=OP_ORA; end
        8'h0E: begin dm=MD_ABS; dc=CL_MW; dp=OP_ASL; end
        8'h0F: begin dm=MD_ABL; dc=CL_RD; dp=OP_ORA; end
        // 1x
        8'h10: dm=MD_REL;                                          // BPL
        8'h11: begin dm=MD_IDY; dc=CL_RD; dp=OP_ORA; end
        8'h12: begin dm=MD_IDP; dc=CL_RD; dp=OP_ORA; end
        8'h13: begin dm=MD_SRY; dc=CL_RD; dp=OP_ORA; end
        8'h14: begin dm=MD_DP;  dc=CL_MW; dp=OP_TRB; end
        8'h15: begin dm=MD_DPX; dc=CL_RD; dp=OP_ORA; end
        8'h16: begin dm=MD_DPX; dc=CL_MW; dp=OP_ASL; end
        8'h17: begin dm=MD_ILY; dc=CL_RD; dp=OP_ORA; end
        8'h19: begin dm=MD_ABY; dc=CL_RD; dp=OP_ORA; end
        8'h1C: begin dm=MD_ABS; dc=CL_MW; dp=OP_TRB; end
        8'h1D: begin dm=MD_ABX; dc=CL_RD; dp=OP_ORA; end
        8'h1E: begin dm=MD_ABX; dc=CL_MW; dp=OP_ASL; end
        8'h1F: begin dm=MD_ALX; dc=CL_RD; dp=OP_ORA; end
        // 2x
        8'h20: begin dm=MD_ABS; dc=CL_JSR; end                  // JSR abs
        8'h21: begin dm=MD_IDX; dc=CL_RD; dp=OP_AND; end
        8'h22: begin dm=MD_ABL; dc=CL_JSR; end                  // JSL long
        8'h23: begin dm=MD_SR;  dc=CL_RD; dp=OP_AND; end
        8'h24: begin dm=MD_DP;  dc=CL_RD; dp=OP_BIT; end
        8'h25: begin dm=MD_DP;  dc=CL_RD; dp=OP_AND; end
        8'h26: begin dm=MD_DP;  dc=CL_MW; dp=OP_ROL; end
        8'h27: begin dm=MD_IDL; dc=CL_RD; dp=OP_AND; end
        8'h29: begin dm=MD_IMM; dc=CL_RD; dp=OP_AND; end
        8'h2C: begin dm=MD_ABS; dc=CL_RD; dp=OP_BIT; end
        8'h2D: begin dm=MD_ABS; dc=CL_RD; dp=OP_AND; end
        8'h2E: begin dm=MD_ABS; dc=CL_MW; dp=OP_ROL; end
        8'h2F: begin dm=MD_ABL; dc=CL_RD; dp=OP_AND; end
        // 3x
        8'h30: dm=MD_REL;                                          // BMI
        8'h31: begin dm=MD_IDY; dc=CL_RD; dp=OP_AND; end
        8'h32: begin dm=MD_IDP; dc=CL_RD; dp=OP_AND; end
        8'h33: begin dm=MD_SRY; dc=CL_RD; dp=OP_AND; end
        8'h34: begin dm=MD_DPX; dc=CL_RD; dp=OP_BIT; end
        8'h35: begin dm=MD_DPX; dc=CL_RD; dp=OP_AND; end
        8'h36: begin dm=MD_DPX; dc=CL_MW; dp=OP_ROL; end
        8'h37: begin dm=MD_ILY; dc=CL_RD; dp=OP_AND; end
        8'h39: begin dm=MD_ABY; dc=CL_RD; dp=OP_AND; end
        8'h3C: begin dm=MD_ABX; dc=CL_RD; dp=OP_BIT; end
        8'h3D: begin dm=MD_ABX; dc=CL_RD; dp=OP_AND; end
        8'h3E: begin dm=MD_ABX; dc=CL_MW; dp=OP_ROL; end
        8'h3F: begin dm=MD_ALX; dc=CL_RD; dp=OP_AND; end
        // 4x
        8'h41: begin dm=MD_IDX; dc=CL_RD; dp=OP_EOR; end
        8'h42: begin dm=MD_IMM; dc=CL_RD; dp=OP_NOP; end      // WDM
        8'h43: begin dm=MD_SR;  dc=CL_RD; dp=OP_EOR; end
        8'h44: ;                                                       // MVP (special)
        8'h45: begin dm=MD_DP;  dc=CL_RD; dp=OP_EOR; end
        8'h46: begin dm=MD_DP;  dc=CL_MW; dp=OP_LSR; end
        8'h47: begin dm=MD_IDL; dc=CL_RD; dp=OP_EOR; end
        8'h49: begin dm=MD_IMM; dc=CL_RD; dp=OP_EOR; end
        8'h4C: begin dm=MD_ABS; dc=CL_JMP; end                  // JMP abs
        8'h4D: begin dm=MD_ABS; dc=CL_RD; dp=OP_EOR; end
        8'h4E: begin dm=MD_ABS; dc=CL_MW; dp=OP_LSR; end
        8'h4F: begin dm=MD_ABL; dc=CL_RD; dp=OP_EOR; end
        // 5x
        8'h50: dm=MD_REL;                                          // BVC
        8'h51: begin dm=MD_IDY; dc=CL_RD; dp=OP_EOR; end
        8'h52: begin dm=MD_IDP; dc=CL_RD; dp=OP_EOR; end
        8'h53: begin dm=MD_SRY; dc=CL_RD; dp=OP_EOR; end
        8'h54: ;                                                       // MVN (special)
        8'h55: begin dm=MD_DPX; dc=CL_RD; dp=OP_EOR; end
        8'h56: begin dm=MD_DPX; dc=CL_MW; dp=OP_LSR; end
        8'h57: begin dm=MD_ILY; dc=CL_RD; dp=OP_EOR; end
        8'h59: begin dm=MD_ABY; dc=CL_RD; dp=OP_EOR; end
        8'h5C: begin dm=MD_ABL; dc=CL_JMP; end                  // JML long
        8'h5D: begin dm=MD_ABX; dc=CL_RD; dp=OP_EOR; end
        8'h5E: begin dm=MD_ABX; dc=CL_MW; dp=OP_LSR; end
        8'h5F: begin dm=MD_ALX; dc=CL_RD; dp=OP_EOR; end
        // 6x
        8'h61: begin dm=MD_IDX; dc=CL_RD; dp=OP_ADC; end
        8'h62: dm=MD_RLL;                                          // PER (special)
        8'h63: begin dm=MD_SR;  dc=CL_RD; dp=OP_ADC; end
        8'h64: begin dm=MD_DP;  dc=CL_WR; dp=OP_STZ; end
        8'h65: begin dm=MD_DP;  dc=CL_RD; dp=OP_ADC; end
        8'h66: begin dm=MD_DP;  dc=CL_MW; dp=OP_ROR; end
        8'h67: begin dm=MD_IDL; dc=CL_RD; dp=OP_ADC; end
        8'h69: begin dm=MD_IMM; dc=CL_RD; dp=OP_ADC; end
        8'h6C: begin dm=MD_IAB; dc=CL_JMP; end                  // JMP (abs)
        8'h6D: begin dm=MD_ABS; dc=CL_RD; dp=OP_ADC; end
        8'h6E: begin dm=MD_ABS; dc=CL_MW; dp=OP_ROR; end
        8'h6F: begin dm=MD_ABL; dc=CL_RD; dp=OP_ADC; end
        // 7x
        8'h70: dm=MD_REL;                                          // BVS
        8'h71: begin dm=MD_IDY; dc=CL_RD; dp=OP_ADC; end
        8'h72: begin dm=MD_IDP; dc=CL_RD; dp=OP_ADC; end
        8'h73: begin dm=MD_SRY; dc=CL_RD; dp=OP_ADC; end
        8'h74: begin dm=MD_DPX; dc=CL_WR; dp=OP_STZ; end
        8'h75: begin dm=MD_DPX; dc=CL_RD; dp=OP_ADC; end
        8'h76: begin dm=MD_DPX; dc=CL_MW; dp=OP_ROR; end
        8'h77: begin dm=MD_ILY; dc=CL_RD; dp=OP_ADC; end
        8'h79: begin dm=MD_ABY; dc=CL_RD; dp=OP_ADC; end
        8'h7C: begin dm=MD_IAX; dc=CL_JMP; end                  // JMP (abs,X)
        8'h7D: begin dm=MD_ABX; dc=CL_RD; dp=OP_ADC; end
        8'h7E: begin dm=MD_ABX; dc=CL_MW; dp=OP_ROR; end
        8'h7F: begin dm=MD_ALX; dc=CL_RD; dp=OP_ADC; end
        // 8x
        8'h80: dm=MD_REL;                                          // BRA
        8'h81: begin dm=MD_IDX; dc=CL_WR; dp=OP_STA; end
        8'h82: dm=MD_RLL;                                          // BRL
        8'h83: begin dm=MD_SR;  dc=CL_WR; dp=OP_STA; end
        8'h84: begin dm=MD_DP;  dc=CL_WR; dp=OP_STY; end
        8'h85: begin dm=MD_DP;  dc=CL_WR; dp=OP_STA; end
        8'h86: begin dm=MD_DP;  dc=CL_WR; dp=OP_STX; end
        8'h87: begin dm=MD_IDL; dc=CL_WR; dp=OP_STA; end
        8'h89: begin dm=MD_IMM; dc=CL_RD; dp=OP_BIT; end      // BIT # (Z only)
        8'h8C: begin dm=MD_ABS; dc=CL_WR; dp=OP_STY; end
        8'h8D: begin dm=MD_ABS; dc=CL_WR; dp=OP_STA; end
        8'h8E: begin dm=MD_ABS; dc=CL_WR; dp=OP_STX; end
        8'h8F: begin dm=MD_ABL; dc=CL_WR; dp=OP_STA; end
        // 9x
        8'h90: dm=MD_REL;                                          // BCC
        8'h91: begin dm=MD_IDY; dc=CL_WR; dp=OP_STA; end
        8'h92: begin dm=MD_IDP; dc=CL_WR; dp=OP_STA; end
        8'h93: begin dm=MD_SRY; dc=CL_WR; dp=OP_STA; end
        8'h94: begin dm=MD_DPX; dc=CL_WR; dp=OP_STY; end
        8'h95: begin dm=MD_DPX; dc=CL_WR; dp=OP_STA; end
        8'h96: begin dm=MD_DPY; dc=CL_WR; dp=OP_STX; end
        8'h97: begin dm=MD_ILY; dc=CL_WR; dp=OP_STA; end
        8'h99: begin dm=MD_ABY; dc=CL_WR; dp=OP_STA; end
        8'h9C: begin dm=MD_ABS; dc=CL_WR; dp=OP_STZ; end
        8'h9D: begin dm=MD_ABX; dc=CL_WR; dp=OP_STA; end
        8'h9E: begin dm=MD_ABX; dc=CL_WR; dp=OP_STZ; end
        8'h9F: begin dm=MD_ALX; dc=CL_WR; dp=OP_STA; end
        // Ax
        8'hA0: begin dm=MD_IMM; dc=CL_RD; dp=OP_LDY; end
        8'hA1: begin dm=MD_IDX; dc=CL_RD; dp=OP_LDA; end
        8'hA2: begin dm=MD_IMM; dc=CL_RD; dp=OP_LDX; end
        8'hA3: begin dm=MD_SR;  dc=CL_RD; dp=OP_LDA; end
        8'hA4: begin dm=MD_DP;  dc=CL_RD; dp=OP_LDY; end
        8'hA5: begin dm=MD_DP;  dc=CL_RD; dp=OP_LDA; end
        8'hA6: begin dm=MD_DP;  dc=CL_RD; dp=OP_LDX; end
        8'hA7: begin dm=MD_IDL; dc=CL_RD; dp=OP_LDA; end
        8'hA9: begin dm=MD_IMM; dc=CL_RD; dp=OP_LDA; end
        8'hAC: begin dm=MD_ABS; dc=CL_RD; dp=OP_LDY; end
        8'hAD: begin dm=MD_ABS; dc=CL_RD; dp=OP_LDA; end
        8'hAE: begin dm=MD_ABS; dc=CL_RD; dp=OP_LDX; end
        8'hAF: begin dm=MD_ABL; dc=CL_RD; dp=OP_LDA; end
        // Bx
        8'hB0: dm=MD_REL;                                          // BCS
        8'hB1: begin dm=MD_IDY; dc=CL_RD; dp=OP_LDA; end
        8'hB2: begin dm=MD_IDP; dc=CL_RD; dp=OP_LDA; end
        8'hB3: begin dm=MD_SRY; dc=CL_RD; dp=OP_LDA; end
        8'hB4: begin dm=MD_DPX; dc=CL_RD; dp=OP_LDY; end
        8'hB5: begin dm=MD_DPX; dc=CL_RD; dp=OP_LDA; end
        8'hB6: begin dm=MD_DPY; dc=CL_RD; dp=OP_LDX; end
        8'hB7: begin dm=MD_ILY; dc=CL_RD; dp=OP_LDA; end
        8'hB9: begin dm=MD_ABY; dc=CL_RD; dp=OP_LDA; end
        8'hBC: begin dm=MD_ABX; dc=CL_RD; dp=OP_LDY; end
        8'hBD: begin dm=MD_ABX; dc=CL_RD; dp=OP_LDA; end
        8'hBE: begin dm=MD_ABY; dc=CL_RD; dp=OP_LDX; end
        8'hBF: begin dm=MD_ALX; dc=CL_RD; dp=OP_LDA; end
        // Cx
        8'hC0: begin dm=MD_IMM; dc=CL_RD; dp=OP_CPY; end
        8'hC1: begin dm=MD_IDX; dc=CL_RD; dp=OP_CMP; end
        8'hC2: begin dm=MD_IMM; dc=CL_RD; dp=OP_REP; end
        8'hC3: begin dm=MD_SR;  dc=CL_RD; dp=OP_CMP; end
        8'hC4: begin dm=MD_DP;  dc=CL_RD; dp=OP_CPY; end
        8'hC5: begin dm=MD_DP;  dc=CL_RD; dp=OP_CMP; end
        8'hC6: begin dm=MD_DP;  dc=CL_MW; dp=OP_DEC; end
        8'hC7: begin dm=MD_IDL; dc=CL_RD; dp=OP_CMP; end
        8'hC9: begin dm=MD_IMM; dc=CL_RD; dp=OP_CMP; end
        8'hCC: begin dm=MD_ABS; dc=CL_RD; dp=OP_CPY; end
        8'hCD: begin dm=MD_ABS; dc=CL_RD; dp=OP_CMP; end
        8'hCE: begin dm=MD_ABS; dc=CL_MW; dp=OP_DEC; end
        8'hCF: begin dm=MD_ABL; dc=CL_RD; dp=OP_CMP; end
        // Dx
        8'hD0: dm=MD_REL;                                          // BNE
        8'hD1: begin dm=MD_IDY; dc=CL_RD; dp=OP_CMP; end
        8'hD2: begin dm=MD_IDP; dc=CL_RD; dp=OP_CMP; end
        8'hD3: begin dm=MD_SRY; dc=CL_RD; dp=OP_CMP; end
        8'hD4: ;                                                       // PEI (special)
        8'hD5: begin dm=MD_DPX; dc=CL_RD; dp=OP_CMP; end
        8'hD6: begin dm=MD_DPX; dc=CL_MW; dp=OP_DEC; end
        8'hD7: begin dm=MD_ILY; dc=CL_RD; dp=OP_CMP; end
        8'hD9: begin dm=MD_ABY; dc=CL_RD; dp=OP_CMP; end
        8'hDC: begin dm=MD_IAL; dc=CL_JMP; end                  // JML [abs]
        8'hDD: begin dm=MD_ABX; dc=CL_RD; dp=OP_CMP; end
        8'hDE: begin dm=MD_ABX; dc=CL_MW; dp=OP_DEC; end
        8'hDF: begin dm=MD_ALX; dc=CL_RD; dp=OP_CMP; end
        // Ex
        8'hE0: begin dm=MD_IMM; dc=CL_RD; dp=OP_CPX; end
        8'hE1: begin dm=MD_IDX; dc=CL_RD; dp=OP_SBC; end
        8'hE2: begin dm=MD_IMM; dc=CL_RD; dp=OP_SEP; end
        8'hE3: begin dm=MD_SR;  dc=CL_RD; dp=OP_SBC; end
        8'hE4: begin dm=MD_DP;  dc=CL_RD; dp=OP_CPX; end
        8'hE5: begin dm=MD_DP;  dc=CL_RD; dp=OP_SBC; end
        8'hE6: begin dm=MD_DP;  dc=CL_MW; dp=OP_INC; end
        8'hE7: begin dm=MD_IDL; dc=CL_RD; dp=OP_SBC; end
        8'hE9: begin dm=MD_IMM; dc=CL_RD; dp=OP_SBC; end
        8'hEC: begin dm=MD_ABS; dc=CL_RD; dp=OP_CPX; end
        8'hED: begin dm=MD_ABS; dc=CL_RD; dp=OP_SBC; end
        8'hEE: begin dm=MD_ABS; dc=CL_MW; dp=OP_INC; end
        8'hEF: begin dm=MD_ABL; dc=CL_RD; dp=OP_SBC; end
        // Fx
        8'hF0: dm=MD_REL;                                          // BEQ
        8'hF1: begin dm=MD_IDY; dc=CL_RD; dp=OP_SBC; end
        8'hF2: begin dm=MD_IDP; dc=CL_RD; dp=OP_SBC; end
        8'hF3: begin dm=MD_SRY; dc=CL_RD; dp=OP_SBC; end
        8'hF4: ;                                                       // PEA (special)
        8'hF5: begin dm=MD_DPX; dc=CL_RD; dp=OP_SBC; end
        8'hF6: begin dm=MD_DPX; dc=CL_MW; dp=OP_INC; end
        8'hF7: begin dm=MD_ILY; dc=CL_RD; dp=OP_SBC; end
        8'hF9: begin dm=MD_ABY; dc=CL_RD; dp=OP_SBC; end
        8'hFC: begin dm=MD_IAX; dc=CL_JSR; end                  // JSR (abs,X)
        8'hFD: begin dm=MD_ABX; dc=CL_RD; dp=OP_SBC; end
        8'hFE: begin dm=MD_ABX; dc=CL_MW; dp=OP_INC; end
        8'hFF: begin dm=MD_ALX; dc=CL_RD; dp=OP_SBC; end
        default: ;   // remaining opcodes are handled entirely in S_FETCH
        endcase
        dec = {dm, dc, dp};
        end
    endfunction

    // Decode the byte arriving on the bus, ONCE. A Verilog function is inlined
    // at every call site, so calling dec(rdata) from each place that loads IR
    // would build a separate 256-way decoder each time.
    wire [12:0] dec_in = dec(qb);

    // The operand bytes the opcode being fetched takes (an immediate's
    // second byte, which hangs on m or x, is added in S_OPS).
    reg [1:0] len_in;
    always @* begin
        case (qb)
        8'h44, 8'h54, 8'hF4: len_in = 2'd2;             // MVP/MVN, PEA
        8'h00, 8'h02, 8'hD4: len_in = 2'd1;             // BRK, COP, PEI
        default: case (dec_in[12:8])
            MD_ABS, MD_ABX, MD_ABY, MD_RLL,
            MD_IAB, MD_IAX, MD_IAL: len_in = 2'd2;
            MD_ABL, MD_ALX:         len_in = 2'd3;
            default:                len_in = 2'd1;
            endcase
        endcase
    end

    // The opcode after a WDM prefix (S_XOP). An ADC, AND, CMP or EOR opcode
    // is MUL, UML, DIV or UDV in that addressing mode; $0A, $2A, $4A, $6A
    // and $8A take a count (ASL, ROL, LSR, ROR, ASR #n); anything else is
    // implied (lp): XFE, BSW, the banked mode's $B0/$B1, or a no-op.
    reg [12:0] xdec_in;
    reg [1:0]  xlen_in;
    reg        ximp;
    always @* begin
        xdec_in = {MD_NON, CL_SPC, OP_NOP}; xlen_in = len_in; ximp = 1'b1;
        if (XOPS != 0) begin
            if (dec_in[7:5] == CL_RD)
                case (dec_in[4:0])
                OP_ADC: begin xdec_in = {dec_in[12:5], OP_MUL}; ximp = 1'b0; end
                OP_AND: begin xdec_in = {dec_in[12:5], OP_UML}; ximp = 1'b0; end
                OP_CMP: begin xdec_in = {dec_in[12:5], OP_DIV}; ximp = 1'b0; end
                OP_EOR: begin xdec_in = {dec_in[12:5], OP_UDV}; ximp = 1'b0; end
                default: ;
                endcase
            case (qb)
            8'h0A, 8'h2A, 8'h4A, 8'h6A, 8'h8A: begin
                xdec_in = {MD_IMM, CL_RD, OP_SHF}; xlen_in = 2'd1; ximp = 1'b0;
            end
            default: ;
            endcase
        end
    end

    // The opcode being fetched: implied (executed in the next cycle, lp),
    // a push, WAI or STP (S_IMP), or a pull (S_PULL).
    reg fetch_local, fetch_setup;
    always @* begin
        fetch_local = 1'b0; fetch_setup = 1'b0;
        case (qb)
        8'h18, 8'h38, 8'h58, 8'h78, 8'hB8, 8'hD8, 8'hF8, 8'hEA,
        8'h0A, 8'h2A, 8'h4A, 8'h6A, 8'h1A, 8'h3A,
        8'hAA, 8'hA8, 8'h8A, 8'h98, 8'hBA, 8'h9A, 8'h9B, 8'hBB,
        8'h1B, 8'h3B, 8'h5B, 8'h7B, 8'hE8, 8'hCA, 8'hC8, 8'h88,
        8'hEB, 8'hFB: fetch_local = 1'b1;
        8'h08, 8'h0B, 8'h48, 8'h4B, 8'h5A, 8'h8B, 8'hDA,
        8'hCB, 8'hDB: fetch_setup = 1'b1;
        default: ;
        endcase
    end
    wire fetch_pull = (qb == 8'h28) | (qb == 8'h2B) | (qb == 8'h68) |
                      (qb == 8'h7A) | (qb == 8'hAB) | (qb == 8'hFA) |
                      (qb == 8'h40) | (qb == 8'h60) | (qb == 8'h6B);

    // PLB, PLD and RTL use the 16-bit stack in emulation mode
    wire pull16 = (qb == 8'h2B) | (qb == 8'h6B) | (qb == 8'hAB);

    // operand width for reads/RMW; stores have their own
    wire op_xwide = (d_op==OP_LDX)||(d_op==OP_LDY)||(d_op==OP_CPX)||
                    (d_op==OP_CPY)||(d_op==OP_STX)||(d_op==OP_STY);
    wire op_8bit  = (d_op==OP_REP)||(d_op==OP_SEP)||(d_op==OP_NOP)||(d_op==OP_SHF);
    wire [1:0] rw = op_8bit ? W8 : (op_xwide ? xw : aw);   // read / RMW width
    wire [1:0] sw = op_xwide ? xw : aw;                    // store width
    // the last byte of a wide access (rb)
    wire [1:0] rlast = (rw == W32) ? 2'd3 : {1'b0, rw == W16};
    wire [1:0] slast = (sw == W32) ? 2'd3 : {1'b0, sw == W16};
    wire d_md = (d_op == OP_MUL) | (d_op == OP_UML) | (d_op == OP_DIV) | (d_op == OP_UDV);

    // store value
    reg [31:0] stval;
    always @* begin
        case (d_op)
        OP_STA:  stval = A;
        OP_STX:  stval = X;
        OP_STY:  stval = Y;
        default: stval = 32'h0;      // STZ
        endcase
    end

    // A at its width (X and Y hold nothing above theirs)
    wire [31:0] av = A & wmask(aw);

    // direct-page page-wrap active: emulation mode with DL = $00. Only the
    // base offset (dp + index) wraps within the page; the +1/+2 used to fetch
    // the upper bytes of a word/pointer are plain 16-bit increments and may
    // cross the page boundary.
    wire dpw = emu & (D[7:0] == 8'h00);

    // banked mode (native only): the direct page is at {D, $00} and the
    // stack at {DH, S}. dbase is the direct page's offset in its bank,
    // dbank the bank of the direct page, the stack and their pointers.
    wire        bk    = xb & ~emu;
    wire [15:0] dbase = bk ? {D[7:0], 8'h00} : D;
    wire [7:0]  dbank = bk ? D[15:8] : 8'h00;

    // common address helpers. The bus address is a mux of registers only:
    // the second byte's address of a word (taddr1), a pointer's next byte,
    // the next pull and the vector's high byte are all stepped into their
    // registers a cycle ahead, so no adder sits in front of the memory.
    wire [23:0] taddr1   = wrap16 ? {taddr[23:16], taddr[15:0] + 16'd1}
                                  : taddr + 24'd1;
    wire [23:0] sp_push  = (emu & ~stk16) ? {16'h0001, S[7:0]} : {dbank, S};
    wire [15:0] pcn      = PC + 16'd1;
    // S_OPS: the operand bytes and the address past the instruction (an
    // immediate is as wide as its register: 1, 2 or 4 bytes)
    wire [2:0]  olen     = {1'b0, d_len} + ((d_mode != MD_IMM) ? 3'd0 :
                           (rw == W32) ? 3'd3 : (rw == W16) ? 3'd1 : 3'd0);
    wire [15:0] pce      = PC + {13'd0, olen};
    wire [7:0]  b1 = q[7:0], b2 = q[15:8], b3 = q[23:16], b4 = q[31:24];

    // P register byte (brkbit: value of bit4 in emulation mode)
    function [7:0] pbyte(input brkbit);
        pbyte = {fN, fV, emu ? 1'b1 : fM, emu ? brkbit : fX, fD, fI, fZ, fC};
    endfunction

    //------------------------------------------------------------------
    // Arithmetic helpers
    //------------------------------------------------------------------
    // decimal add: a BCD chain of 2, 4 or 8 digits. Returns {top, carry,
    // sum[31:0]} where `top` is the result's top bit BEFORE the final
    // high-nibble correction -- the 65C816 derives V from that point.
    function [33:0] dadd(input [31:0] a, input [31:0] b, input cin, input [1:0] w);
        reg [4:0] n;
        reg [31:0] s;
        reg c, cw, top;
        integer i;
        begin
            c = cin; cw = 1'b0; top = 1'b0; s = 32'h0;
            for (i = 0; i < 8; i = i + 1) begin
                n = {1'b0, a[4*i +: 4]} + {1'b0, b[4*i +: 4]} + {4'd0, c};
                if ((i == 1 && w == W8) || (i == 3 && w == W16) || (i == 7 && w == W32))
                    top = n[3];
                c = (n > 5'd9); if (c) n = n + 5'd6;
                s[4*i +: 4] = n[3:0];
                if ((i == 1 && w == W8) || (i == 3 && w == W16) || (i == 7 && w == W32))
                    cw = c;
            end
            dadd = {top, cw, s & wmask(w)};
        end
    endfunction

    // decimal subtract: a - b, cin = inverted borrow; {carry, diff[31:0]}
    function [32:0] dsub(input [31:0] a, input [31:0] b, input cin, input [1:0] w);
        reg [4:0] n;
        reg [31:0] s;
        reg c, cw;
        integer i;
        begin
            c = cin; cw = 1'b0; s = 32'h0;
            for (i = 0; i < 8; i = i + 1) begin
                n = {1'b0, a[4*i +: 4]} + {1'b0, ~b[4*i +: 4]} + {4'd0, c};
                c = n[4]; if (!c) n = n - 5'd6;
                s[4*i +: 4] = n[3:0];
                if ((i == 1 && w == W8) || (i == 3 && w == W16) || (i == 7 && w == W32))
                    cw = c;
            end
            dsub = {cw, s & wmask(w)};
        end
    endfunction

    // a 33-bit sum's carry out of the width
    function carryw(input [32:0] t, input [1:0] w);
        carryw = (w == W32) ? t[32] : (w == W16) ? t[16] : t[8];
    endfunction

    //------------------------------------------------------------------
    // Register write helpers (set NZ per current width)
    //------------------------------------------------------------------
    // A: the bits above its width kept
    task ld_a(input [31:0] v);
        begin
            case (aw)
            W32:     A <= v;
            W16:     A[15:0] <= v[15:0];
            default: A[7:0] <= v[7:0];
            endcase
            fN <= topb(v, aw); fZ <= zerow(v, aw);
        end
    endtask

    // X, Y: nothing above their width
    task ld_x(input [31:0] v);
        begin
            X <= v & wmask(xw); fN <= topb(v, xw); fZ <= zerow(v, xw);
        end
    endtask

    task ld_y(input [31:0] v);
        begin
            Y <= v & wmask(xw); fN <= topb(v, xw); fZ <= zerow(v, xw);
        end
    endtask

    // write a value into P (PLP / RTI / REP / SEP)
    task set_p(input [7:0] v);
        begin
            fN <= v[7]; fV <= v[6]; fD <= v[3]; fI <= v[2];
            fZ <= v[1]; fC <= v[0];
            if (!emu) begin
                fM <= v[5]; fX <= v[4];
                if (v[4]) begin X[31:8] <= 24'h0; Y[31:8] <= 24'h0; end
            end
        end
    endtask

    // compare: reg - mem, sets NZC (both already at width w)
    task cmp_flags(input [31:0] r, input [31:0] m, input [1:0] w);
        reg [32:0] t;
        begin
            t = {1'b0, r} + {1'b0, ~m & wmask(w)} + 33'd1;
            fC <= carryw(t, w); fN <= topb(t[31:0], w); fZ <= zerow(t[31:0], w);
        end
    endtask

    // ADC / SBC of m (at A's width); decimal at 2, 4 or 8 digits
    task do_adc(input [31:0] m);
        reg [32:0] t;
        reg [33:0] da;
        begin
            if (fD) begin
                // Decimal: V comes from the pre-correction top bit (da[33]);
                // N and Z come from the corrected result; C from the decimal
                // carry.
                da = dadd(av, m, fC, aw);
                fV <= ~(topb(av, aw) ^ topb(m, aw)) & (topb(av, aw) ^ da[33]);
                fC <= da[32];
                ld_a(da[31:0]);
            end else begin
                t = {1'b0, av} + {1'b0, m} + {32'd0, fC};
                fV <= ~(topb(av, aw) ^ topb(m, aw)) & (topb(av, aw) ^ topb(t[31:0], aw));
                fC <= carryw(t, aw);
                ld_a(t[31:0]);
            end
        end
    endtask

    task do_sbc(input [31:0] m);
        reg [32:0] t;
        reg [32:0] ds;
        begin
            // Decimal: N and Z come from the BCD-corrected result and C
            // from the (shared) borrow, but V is the binary overflow.
            t = {1'b0, av} + {1'b0, ~m & wmask(aw)} + {32'd0, fC};
            fV <= (topb(av, aw) ^ topb(m, aw)) & (topb(av, aw) ^ topb(t[31:0], aw));
            if (fD) begin
                ds = dsub(av, m, fC, aw);
                fC <= ds[32];
                ld_a(ds[31:0]);
            end else begin
                fC <= carryw(t, aw);
                ld_a(t[31:0]);
            end
        end
    endtask

    // ASL/ROL/LSR/ROR/ASR #n (IR $0A/$2A/$4A/$6A/$8A) of A, the count k
    // modulo the width. One rotator, right by kr, on A repeated to fill 32
    // bits (a left rotation by k is a right one by w - k); the shifts mask
    // what came round. C: the last bit out, or carried round.
    task do_shf(input [7:0] m);
        reg [31:0] rin, rot, lo, hi, res;
        reg [4:0] k, kr;
        reg left;
        begin
            case (aw)
            W32:     begin rin = A;              k = m[4:0];         end
            W16:     begin rin = {2{A[15:0]}};   k = {1'b0, m[3:0]}; end
            default: begin rin = {4{A[7:0]}};    k = {2'b0, m[2:0]}; end
            endcase
            left = (IR == 8'h0A) | (IR == 8'h2A);
            kr   = left ? ((aw == W32) ? 5'd0 : (aw == W16) ? 5'd16 : 5'd8) - k : k;
            rot  = (rin >> kr) | (rin << (6'd32 - {1'b0, kr}));
            lo   = (32'h1 << k) - 32'h1;                               // the low k bits
            hi   = lo << ((aw == W32) ? 6'd32 - {1'b0, k} :
                          (aw == W16) ? 6'd16 - {1'b0, k} : 6'd8 - {1'b0, k});  // the top k
            case (IR)
            8'h0A:   res = rot & ~lo;                                  // ASL
            8'h4A:   res = rot & ~hi;                                  // LSR
            8'h8A:   res = topb(A, aw) ? (rot | hi) : (rot & ~hi);    // ASR
            default: res = rot;                                        // ROL, ROR
            endcase
            if (k != 5'd0) fC <= left ? rot[0] : topb(rot, aw);
            ld_a(res);
        end
    endtask

    // read-class execute (called with the full operand at its width)
    task exec_rd(input [31:0] m);
        begin
            case (d_op)
            OP_ORA: ld_a(av | m);
            OP_AND: ld_a(av & m);
            OP_EOR: ld_a(av ^ m);
            OP_ADC: do_adc(m);
            OP_SBC: do_sbc(m);
            OP_CMP: cmp_flags(av, m, aw);
            OP_LDA: ld_a(m);
            OP_LDX: ld_x(m);
            OP_LDY: ld_y(m);
            OP_CPX: cmp_flags(X, m, xw);
            OP_CPY: cmp_flags(Y, m, xw);
            OP_BIT: begin
                fZ <= ((av & m) == 32'h0);
                if (IR != 8'h89) begin           // BIT # affects Z only
                    fN <= topb(m, aw);
                    fV <= nextb(m, aw);
                end
            end
            OP_REP: set_p(pbyte(fX) & ~m[7:0]);
            OP_SEP: set_p(pbyte(fX) |  m[7:0]);
            OP_SHF: if (XOPS != 0) do_shf(m[7:0]);
            default: ;
            endcase
        end
    endtask

    // RMW / accumulator shift-and-step core. op given explicitly so the
    // accumulator forms can run during S_FETCH (before IR is loaded).
    // to_a=1: result goes to A; else to tdata for write-back.
    // Everything it reads is an argument: a function called from a
    // continuous assignment is re-evaluated only when its arguments change.
    // m and a are at width w (0 above it).
    function [31:0] rmw_val(input [4:0] op, input [31:0] m, input [31:0] a,
                            input c, input [1:0] w);
        case (op)
        OP_ASL: rmw_val = {m[30:0], 1'b0};
        OP_ROL: rmw_val = {m[30:0], c};
        OP_LSR: rmw_val = {1'b0, m[31:1]};
        OP_ROR: rmw_val = {1'b0, m[31:1]} | ({31'd0, c} << ((w == W32) ? 5'd31 : (w == W16) ? 5'd15 : 5'd7));
        OP_INC: rmw_val = m + 32'd1;
        OP_DEC: rmw_val = m - 32'd1;
        OP_TSB: rmw_val = m | a;
        OP_TRB: rmw_val = m & ~a;
        default: rmw_val = m;
        endcase
    endfunction

    // A memory RMW's result, from its latched operand: written in S_WBL.
    wire [31:0] rmw_r = rmw_val(d_op, xm, av, fC, aw);

    task rmw_core(input [4:0] op, input [31:0] m, input to_a);
        reg [31:0] r;
        reg c, setc;
        begin
            r = rmw_val(op, m, av, fC, aw);
            c = fC; setc = 1'b0;
            case (op)
            OP_ASL, OP_ROL: begin c = topb(m, aw); setc = 1'b1; end
            OP_LSR, OP_ROR: begin c = m[0];        setc = 1'b1; end
            default: ;
            endcase
            if (setc) fC <= c;
            if (op == OP_TSB || op == OP_TRB) begin
                fZ <= ((av & m) == 32'h0);
            end else begin
                fN <= topb(r, aw);
                fZ <= zerow(r, aw);
            end
            if (to_a) begin
                case (aw)
                W32:     A <= r;
                W16:     A[15:0] <= r[15:0];
                default: A[7:0] <= r[7:0];
                endcase
            end else begin
                tdata <= r;
            end
        end
    endtask

    // the high half or remainder into X (MUL/DIV): as much as X holds
    task wr_x(input [31:0] v);
        X <= v & wmask(xw);
    endtask

    // a pull of width w's value, its last byte arriving on the bus now and
    // the others already in tdata
    function [31:0] pulled(input [1:0] w);
        pulled = (w == W32) ? {rdata, tdata[23:0]} :
                 (w == W16) ? {16'h0, rdata, tdata[7:0]} : {24'h0, rdata};
    endfunction

    // an index register stepped by MVN (+1) / MVP (-1) at its width
    function [31:0] mvstep(input [31:0] v, input up, input [1:0] w);
        mvstep = (up ? v + 32'd1 : v - 32'd1) & wmask(w);
    endfunction

    // An implied opcode, latched in IR at its fetch and executed in the next
    // cycle (lp), overlapped with the following opcode's fetch.
    task exec_imp;
        begin
            case ({IRx, IR})
            // ---- flag ops (1 cycle) ----
            9'h018: fC <= 1'b0;                      // CLC
            9'h038: fC <= 1'b1;                      // SEC
            9'h058: fI <= 1'b0;                      // CLI
            9'h078: fI <= 1'b1;                      // SEI
            9'h0B8: fV <= 1'b0;                      // CLV
            9'h0D8: fD <= 1'b0;                      // CLD
            9'h0F8: fD <= 1'b1;                      // SED
            9'h0EA: ;                                // NOP
            // ---- accumulator shifts / inc / dec (1 cycle) ----
            9'h00A: rmw_core(OP_ASL, av, 1'b1);
            9'h02A: rmw_core(OP_ROL, av, 1'b1);
            9'h04A: rmw_core(OP_LSR, av, 1'b1);
            9'h06A: rmw_core(OP_ROR, av, 1'b1);
            9'h01A: rmw_core(OP_INC, av, 1'b1);
            9'h03A: rmw_core(OP_DEC, av, 1'b1);
            // ---- transfers (1 cycle): the whole source, as much as the
            // destination holds; TCS/TCD/TSC/TDC always 16 bits ----
            9'h0AA: ld_x(A);                         // TAX
            9'h0A8: ld_y(A);                         // TAY
            9'h08A: ld_a(X);                         // TXA
            9'h098: ld_a(Y);                         // TYA
            9'h0BA: ld_x({16'h0, S});                // TSX
            9'h09A: S <= emu ? {8'h01, X[7:0]} : X[15:0];    // TXS
            9'h09B: ld_y(X);                         // TXY
            9'h0BB: ld_x(Y);                         // TYX
            9'h01B: S <= emu ? {8'h01, A[7:0]} : A[15:0];    // TCS
            9'h03B: begin                            // TSC
                A[15:0] <= S; fN <= S[15]; fZ <= (S == 16'h0000);
            end
            9'h05B: begin                            // TCD
                D <= A[15:0]; fN <= A[15]; fZ <= (A[15:0] == 16'h0000);
            end
            9'h07B: begin                            // TDC
                A[15:0] <= D; fN <= D[15]; fZ <= (D == 16'h0000);
            end
            // ---- index inc/dec (1 cycle) ----
            9'h0E8: ld_x(X + 32'd1);                 // INX
            9'h0CA: ld_x(X - 32'd1);                 // DEX
            9'h0C8: ld_y(Y + 32'd1);                 // INY
            9'h088: ld_y(Y - 32'd1);                 // DEY
            // ---- XBA / XCE (1 cycle) ----
            9'h0EB: begin                            // XBA
                A[15:0] <= {A[7:0], A[15:8]};
                fN <= A[15]; fZ <= (A[15:8] == 8'h00);
            end
            9'h0FB: begin                            // XCE: C and E8
                fC <= fE; fE <= fC;
                if (fE16 & fC) begin                 // entering emulation
                    fM <= 1'b1; fX <= 1'b1;
                    X[31:8] <= 24'h0; Y[31:8] <= 24'h0;
                    S[15:8] <= 8'h01;
                end
            end
            // ---- after the WDM prefix ----
            9'h1FB: if (C832 != 0) begin             // XFE: C and E8, V and E16
                fC <= fE; fE <= fC; fV <= fE16; fE16 <= fV;
                if (fV & fC) begin                   // entering emulation
                    fM <= 1'b1; fX <= 1'b1;
                    X[31:8] <= 24'h0; Y[31:8] <= 24'h0;
                    S[15:8] <= 8'h01;
                end else if (fV) begin               // 65C816 native
                    X[31:16] <= 16'h0; Y[31:16] <= 16'h0;
                end
            end
            9'h1EB: if (XOPS != 0)                   // BSW: A's bytes reversed
                case (aw)
                W32:     ld_a({A[7:0], A[15:8], A[23:16], A[31:24]});
                W16:     ld_a({16'h0, A[7:0], A[15:8]});
                default: ld_a(A);
                endcase
            9'h1B0: xb <= 1'b0;                      // banked mode off
            9'h1B1: xb <= 1'b1;                      // banked mode on
            default: ;
            endcase
        end
    endtask

    // PC out of sequence: the queue empties (see the queue logic)
    task jump(input [15:0] v);
        begin
            PC <= v; jmp = 1'b1; jpc = v; jbank = PBR;
        end
    endtask

    // ... and PBR with it (JML, JSL)
    task jumpl(input [7:0] b, input [15:0] v);
        begin
            PBR <= b; PC <= v; jmp = 1'b1; jpc = v; jbank = b;
        end
    endtask

    // queue a push, shortest path to S_PUSH
    task push8(input [7:0] v);
        begin
            push_q <= {v, 24'h0}; push_n <= 3'd1; stk16 <= 1'b0;
            post_push <= PP_FETCH; state <= S_PUSH;
        end
    endtask

    // 16-bit push. The only push16 callers reachable in emulation mode are
    // the new stack ops (PEA/PEI/PER/PHD) -- PHA/PHX/PHY use push8 when 8-bit
    // -- so the 16-bit-stack quirk applies whenever this runs in emulation.
    task push16(input [15:0] v);
        begin
            push_q <= {v, 16'h0}; push_n <= 3'd2; stk16 <= 1'b1;
            post_push <= PP_FETCH; state <= S_PUSH;
        end
    endtask

    // 32-bit push (PHA/PHX/PHY in 65C832 native mode)
    task push32(input [31:0] v);
        begin
            push_q <= v; push_n <= 3'd4; stk16 <= 1'b0;
            post_push <= PP_FETCH; state <= S_PUSH;
        end
    endtask

    // stack pointer step (keeps page 1 in emulation mode, except for the
    // new 16-bit stack ops which step the full 16-bit S)
    task s_dec; S <= (emu & ~stk16) ? {8'h01, S[7:0] - 8'd1} : S - 16'd1; endtask
    task s_inc; S <= (emu & ~stk16) ? {8'h01, S[7:0] + 8'd1} : S + 16'd1; endtask

    // interrupt entry (hardware IRQ/NMI and BRK/COP).
    // pushed_pc: the PC value to push; brkbit: B for the pushed P byte.
    task int_entry(input [15:0] pushed_pc, input brkbit, input [15:0] v);
        begin
            if (emu) begin
                push_q <= {pushed_pc, pbyte(brkbit), 8'h00};
                push_n <= 3'd3;
            end else begin
                push_q <= {PBR, pushed_pc, pbyte(brkbit)};
                push_n <= 3'd4;
            end
            fI <= 1'b1; fD <= 1'b0; PBR <= 8'h00;
            vec <= v;
            post_push <= PP_VEC; stk16 <= 1'b0;
            state <= S_PUSH;
        end
    endtask

    // abort entry: restore the pre-instruction snapshot, then push the
    // snapshotted PBR/PC/P (opcode address, B=0) and vector through the ABORT
    // vector (native $FFE8 / emulation $FFF8 / 65C832 native $FFD8).
    task abort_entry;
        reg [7:0] pb;
        reg       e, w;
        begin
            // With snap_late set the snapshot of what an execute changes is
            // still being taken: those registers are right as they are.
            if (snap_late) begin
                e  = emu; w = n832;
                pb = {fN, fV, e ? 1'b1 : fM, e ? 1'b0 : fX, fD, fI, fZ, fC};
            end else begin
                e  = sfE & sfE16; w = (C832 != 0) & ~sfE16;
                pb = {sfN, sfV, e ? 1'b1 : sfM, e ? 1'b0 : sfX,
                      sfD, sfI, sfZ, sfC};
                A <= sA; X <= sX; Y <= sY; xb <= sxb; S <= sS; D <= sD;
                fN <= sfN; fV <= sfV; fM <= sfM; fX <= sfX;
                fZ <= sfZ; fC <= sfC; fE <= sfE; fE16 <= sfE16;
            end
            DBR <= sDBR;
            if (e) begin push_q <= {sPC, pb, 8'h00}; push_n <= 3'd3; end
            else   begin push_q <= {sPBR, sPC, pb};  push_n <= 3'd4; end
            fI <= 1'b1; fD <= 1'b0; PBR <= 8'h00;
            vec <= e ? 16'hFFF8 : (w ? 16'hFFD8 : 16'hFFE8);
            post_push <= PP_VEC; stk16 <= 1'b0;
            abort_pend <= 1'b0;
            state <= S_PUSH;
        end
    endtask

    //------------------------------------------------------------------
    // Bus outputs (combinational)
    //------------------------------------------------------------------
    always @* begin
        vld = 1'b0; we = 1'b0; addr = faddr; wdata = 8'h00;
        // status pins: VPA/VDA classify the cycle (00=internal, 10=program,
        // 01=data, 11=opcode fetch); VPB low on vector pulls; MLB low on the
        // read+write of a read-modify-write.
        vpa = 1'b0; vda = 1'b0; vpb_n = 1'b1; mlb_n = 1'b1;
        if (fbusy) begin
            vld = 1'b1; vpa = 1'b1;           // an instruction-queue fill
        end else case (state)
        S_FETCH, S_OPS: ;                    // from the queue: no bus
        S_PTRL, S_PTRH, S_PTRB:
                 begin vld = 1'b1; addr = {ptr_bank, tptr};  vda = 1'b1; end
        S_RDL, S_RDH:
                 begin vld = 1'b1; addr = taddr;  vda = 1'b1; mlb_n = (d_cls != CL_MW); end
        S_WRL:   begin vld = 1'b1; addr = taddr;  we = 1'b1; wdata = stval[7:0];  vda = 1'b1; end
        S_WRH:   begin vld = 1'b1; addr = taddr;  we = 1'b1; wdata = stval[8*rb +: 8]; vda = 1'b1; end
        S_WBL:   begin vld = 1'b1; addr = taddr;  we = 1'b1; wdata = rmw_r[7:0];  vda = 1'b1; mlb_n = 1'b0; end
        S_WBH:   begin vld = 1'b1; addr = taddr;  we = 1'b1; wdata = tdata[8*rb +: 8]; vda = 1'b1; mlb_n = 1'b0; end
        S_PUSH:  begin vld = 1'b1; addr = sp_push; we = 1'b1; wdata = push_q[31:24]; vda = 1'b1; end
        S_PULL:  begin vld = 1'b1; addr = pa; vda = 1'b1; end
        S_VECL, S_VECH:
                 begin vld = 1'b1; addr = {8'h00, vec}; vda = 1'b1; vpb_n = 1'b0; end
        S_MVR:   begin vld = 1'b1; addr = mv_s;                 vda = 1'b1; end
        S_MVW:   begin vld = 1'b1; addr = mv_d; we = 1'b1; wdata = tdata[7:0]; vda = 1'b1; end
        default: ;
        endcase
        // suppress every write of an instruction being aborted (the abort
        // sequence itself runs with abort_pend cleared and abrt deasserted).
        // `abrt` is included so the very cycle abort is recognized -- which
        // may coincide with the store cycle -- is also suppressed.
        if (abort_pend | abrt) we = 1'b0;
    end

    wire step = rdy | ~vld;                  // a bus cycle ends (or none)

    // The core's states that use the bus. One waits while a queue fill
    // holds the bus, then for its own rdy; every other state advances each
    // cycle, a fill in flight or not.
    wire needs_bus = (state == S_PTRL) | (state == S_PTRH) | (state == S_PTRB) |
                     (state == S_RDL)  | (state == S_RDH)  | (state == S_WRL)  |
                     (state == S_WRH)  | (state == S_WBL)  | (state == S_WBH)  |
                     (state == S_PUSH) | (state == S_PULL) | (state == S_VECL) |
                     (state == S_VECH) | (state == S_MVR)  | (state == S_MVW);
    wire cstep = ~needs_bus | (~fbusy & rdy);
    wire dstate_wr = (d_cls == CL_WR);
    wire [15:0] int_vec = nmi_pend ? (emu ? 16'hFFFA : n832 ? 16'hFFDA : 16'hFFEA)
                                   : (emu ? 16'hFFFE : n832 ? 16'hFFDE : 16'hFFEE);

    // The multiply / divide unit's one adder: x + y, or x - y (md_s).
    reg [33:0] md_x, md_y;
    reg        md_s;
    always @* begin
        md_x = {1'b0, md_h}; md_y = {2'b0, md_b}; md_s = 1'b0;   // MUL: h + b
        case (md_ph)
        P_LOOP:  if (md_dv) begin                                // DIV: 2h + bit - b
                     md_x = {1'b0, md_h[31:0], md_l[31]}; md_s = 1'b1;
                 end
        P_NEGA:  begin md_x = 34'd0; md_y = {2'b0, md_a}; md_s = 1'b1; end
        P_NEGB:  begin md_x = 34'd0; md_s = 1'b1; end
        P_FIX1:  md_s = 1'b1;                                    // h - b
        P_FIX2:  begin md_y = {2'b0, md_a}; md_s = 1'b1; end     // h - a
        P_FIXQ:  begin md_x = 34'd0; md_y = {2'b0, md_l}; md_s = 1'b1; end
        P_FIXR:  if (md_sx == md_sy) begin                       // -r
                     md_x = 34'd0; md_y = {1'b0, md_h}; md_s = 1'b1;
                 end else if (md_sy) md_s = 1'b1;                // r - b
                 else begin                                      // b - r
                     md_x = {2'b0, md_b}; md_y = {1'b0, md_h}; md_s = 1'b1;
                 end
        default: ;
        endcase
    end
    wire [33:0] md_sum = md_x + (md_y ^ {34{md_s}}) + {33'd0, md_s};
    wire [31:0] md_sw  = md_sum[31:0] & wmask(aw);               // at A's width

    // branch condition
    reg btake;
    always @* begin
        case (IR[7:6])
        2'b00: btake = (fN == IR[5]);
        2'b01: btake = (fV == IR[5]);
        2'b10: btake = (fC == IR[5]) | (IR == 8'h80);   // BRA
        2'b11: btake = (fZ == IR[5]);
        endcase
    end

    //------------------------------------------------------------------
    // Main state machine
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_VECL; vec <= 16'hFFFC;
            fE <= 1'b1; fE16 <= 1'b1; fM <= 1'b1; fX <= 1'b1; fI <= 1'b1; fD <= 1'b0;
            fC <= 1'b0; fZ <= 1'b0; fV <= 1'b0; fN <= 1'b0;
            A <= 32'h0; X <= 32'h0; Y <= 32'h0;
            S <= 16'h01FF; D <= 16'h0000; DBR <= 8'h00; PBR <= 8'h00;
            PC <= 16'h0000; IR <= 8'h00; IRx <= 1'b0; xb <= 1'b0; sxb <= 1'b0;
            {d_mode, d_cls, d_op} <= dec(8'h00); d_len <= 2'd1;
            tlo <= 8'h00; tmid <= 8'h00; tptr <= 16'h0000;
            ptr_bank <= 8'h00; taddr <= 24'h0; wrap16 <= 1'b0;
            tdata <= 32'h0; push_q <= 32'h0; push_n <= 3'd0; stk16 <= 1'b0;
            post_push <= PP_FETCH; pull_idx <= 2'd0;
            taddr_alt <= 24'h0; pa <= 24'h0; rb <= 2'd0;
            mv_s <= 24'h0; mv_d <= 24'h0;
            md_ph <= P_INIT; md_h <= 33'h0; md_l <= 32'h0; md_a <= 32'h0;
            md_b <= 32'h0; md_n <= 6'd0; md_sx <= 1'b0; md_sy <= 1'b0;
            md_sg <= 1'b0; md_dv <= 1'b0; md_ov <= 1'b0;
            q <= 64'h0; qn <= 4'd0; fa <= 16'h0000; faddr <= 24'h0;
            fbusy <= 1'b0; fdrop <= 1'b0;
            xp <= 1'b0; xm <= 32'h0; snap_late <= 1'b0; lp <= 1'b0;
            irq1 <= 1'b1; irq2 <= 1'b1; nmi1 <= 1'b1; nmi2 <= 1'b1;
            nmi_pend <= 1'b0;
            ab <= 1'b1; abort_pend <= 1'b0;
            sA <= 32'h0; sX <= 32'h0; sY <= 32'h0; sS <= 16'h0;
            sD <= 16'h0; sPC <= 16'h0; sDBR <= 8'h0; sPBR <= 8'h0;
            sfN<=1'b0; sfV<=1'b0; sfM<=1'b1; sfX<=1'b1;
            sfD<=1'b0; sfI<=1'b1; sfZ<=1'b0; sfC<=1'b0; sfE<=1'b1; sfE16<=1'b1;
        end else begin
            // interrupt input synchronizers / NMI edge detect
            irq1 <= irq_n;
            if (step) irq2 <= irq1;
            nmi1 <= nmi_n; nmi2 <= nmi1;
            if (step & nmi_seen) begin nmi_pend <= 1'b1; nmi_seen <= 1'b0; end
            if (nmi2 & ~nmi1) nmi_seen <= 1'b1;
            // abort synchronizer
            ab <= abort_n;

            take = 3'd0; jmp = 1'b0; jpc = PC; jbank = PBR;

            if (cstep) begin
                // Latch a recognized abort; the abort sequence in S_FETCH
                // clears it (that clear is later in source order, so it wins
                // if both fire on the same cycle).
                if (abrt) abort_pend <= 1'b1;

                // The registers an execute changes, for the ABORT snapshot,
                // after a fetch cycle that ran the previous one's execute.
                if (snap_late) begin
                    sA <= A; sX <= X; sY <= Y; sxb <= xb; sS <= S; sD <= D; sfE <= fE; sfE16 <= fE16;
                    sfN<=fN; sfV<=fV; sfM<=fM; sfX<=fX;
                    sfD<=fD; sfI<=fI; sfZ<=fZ; sfC<=fC;
                    snap_late <= 1'b0;
                end

                case (state)

                //----------------------------------------------------------
                S_FETCH: begin
                    if (abort_pend) begin
                        // the previous instruction was aborted: restore its
                        // snapshot and vector through the ABORT handler (its
                        // execute, if one is pending, never happens)
                        xp <= 1'b0;
                        abort_entry;
                    end else if ((xp | lp) & (intr | fetch_pull | (qn == 4'd0))) begin
                        // The pending execute first: an interrupt pushes P,
                        // and a pull's address comes from S, D and E, which
                        // an implied opcode may change. Fetch again.
                        if (xp) exec_rd(xm);
                        if (lp) exec_imp;
                        xp <= 1'b0; lp <= 1'b0;
                    end else if (intr) begin
                        if (nmi_pend) nmi_pend <= 1'b0;
                        int_entry(PC, 1'b0, int_vec);
                    end else if (qn != 4'd0) begin
                        // The pending execute runs as this opcode is latched:
                        // nothing here reads what it changes.
                        if (xp) exec_rd(xm);
                        if (lp) exec_imp;
                        xp <= 1'b0; lp <= 1'b0;
                        if (xp | lp) snap_late <= 1'b1;
                        // snapshot the pre-instruction state for ABORT
                        sPC <= PC; sPBR <= PBR;
                        sA <= A; sX <= X; sY <= Y; sS <= S; sD <= D; sDBR <= DBR; sxb <= xb;
                        sfN<=fN; sfV<=fV; sfM<=fM; sfX<=fX;
                        sfD<=fD; sfI<=fI; sfZ<=fZ; sfC<=fC; sfE<=fE; sfE16<=fE16;
                        PC <= PC + 16'd1; take = 3'd1;
                        case (qb)
                        // ---- pulls / returns ----
                        8'h28, 8'h2B, 8'h68, 8'h7A, 8'hAB, 8'hFA,
                        8'h40, 8'h60, 8'h6B: begin
                            IR <= qb; IRx <= 1'b0; {d_mode, d_cls, d_op} <= dec_in;
                            pull_idx <= 2'd0; state <= S_PULL;
                            // The "new" pull instructions PLB/PLD/RTL use the
                            // 16-bit stack in emulation mode
                            stk16 <= pull16;
                            pa <= (emu & ~pull16) ? {16'h0001, S[7:0] + 8'd1}
                                                  : {dbank, S + 16'd1};
                        end
                        // ---- the WDM prefix: the next byte is the opcode ----
                        8'h42: state <= S_XOP;
                        default: begin
                            IR <= qb; IRx <= 1'b0; {d_mode, d_cls, d_op} <= dec_in;
                            d_len <= len_in;
                            if (fetch_local) lp <= 1'b1;         // implied
                            else if (fetch_setup) state <= S_IMP; // push, WAI, STP
                            else state <= S_OPS;                  // operands
                        end
                        endcase
                    end
                end

                //----------------------------------------------------------
                // A push, WAI or STP, a cycle after its fetch: what it pushes
                // is then up to date.
                S_IMP: begin
                    case (IR)
                    // ---- pushes ----
                    8'h08: push8(pbyte(1'b1));               // PHP
                    8'h0B: push16(D);                        // PHD
                    8'h48: if (a32) push32(A);               // PHA
                           else if (m16) push16(A[15:0]); else push8(A[7:0]);
                    8'h4B: push8(PBR);                       // PHK
                    8'h5A: if (x32) push32(Y);               // PHY
                           else if (x16) push16(Y[15:0]); else push8(Y[7:0]);
                    8'h8B: push8(DBR);                       // PHB
                    8'hDA: if (x32) push32(X);               // PHX
                           else if (x16) push16(X[15:0]); else push8(X[7:0]);
                    8'hCB: state <= S_WAI;
                    8'hDB: state <= S_STP;
                    default: state <= S_FETCH;
                    endcase
                end

                //----------------------------------------------------------
                // The opcode after a WDM prefix, from the queue: one of the
                // extension's (xdec_in), or implied (XFE, BSW, the banked
                // mode, or a no-op). Not an instruction boundary: no
                // interrupt here, and the ABORT snapshot is the prefix's.
                S_XOP: if (qn != 4'd0) begin
                    PC <= PC + 16'd1; take = 3'd1;
                    IR <= qb; IRx <= 1'b1; {d_mode, d_cls, d_op} <= xdec_in;
                    d_len <= xlen_in;
                    if (ximp) begin lp <= 1'b1; state <= S_FETCH; end
                    else state <= S_OPS;
                end

                //----------------------------------------------------------
                // The operand bytes, taken together once all are queued: b1-b3
                // from the head, PC at b1, pce past the instruction.
                S_OPS: if (qn >= {1'b0, olen}) begin
                    PC <= pce; take = olen;
                    // (an opcode after the prefix is never one of these)
                    case (IRx ? 8'h01 : IR)
                    8'h00: int_entry(pce, 1'b1, emu ? 16'hFFFE : n832 ? 16'hFFD6 : 16'hFFE6); // BRK
                    8'h02: int_entry(pce, 1'b1, emu ? 16'hFFF4 : n832 ? 16'hFFD4 : 16'hFFE4); // COP
                    8'h44, 8'h54: begin                                    // MVP/MVN
                        DBR <= b1; tmid <= b2; state <= S_MVR;             // dest, src bank
                        mv_s <= {b2, 16'h0} + {8'h0, X[23:0]};             // bank:0000 + X
                        mv_d <= {b1, 16'h0} + {8'h0, Y[23:0]};
                    end
                    8'h62: push16(pce + {b2, b1});                         // PER
                    8'hF4: push16({b2, b1});                               // PEA
                    8'h82: begin jump(pce + {b2, b1}); state <= S_FETCH; end // BRL
                    8'hD4: begin                                           // PEI
                        tptr <= dpw ? {D[15:8], b1} : dbase + {8'h00, b1};
                        ptr_bank <= dbank;
                        state <= S_PTRL;
                    end
                    8'h20: begin                                           // JSR abs
                        push_q <= {pcn, 16'h0}; push_n <= 3'd2; stk16 <= 1'b0;
                        post_push <= PP_FETCH;
                        jump({b2, b1});
                        state <= S_PUSH;
                    end
                    8'hFC: begin                                           // JSR (abs,X)
                        push_q <= {pcn, 16'h0}; push_n <= 3'd2; stk16 <= 1'b0;
                        post_push <= PP_PTR;
                        tptr <= {b2, b1} + X[15:0]; ptr_bank <= PBR;
                        state <= S_PUSH;
                    end
                    8'h4C: begin jump({b2, b1}); state <= S_FETCH; end     // JMP abs
                    8'h6C, 8'hDC: begin                                    // JMP (abs) / JML [abs]
                        tptr <= {b2, b1}; ptr_bank <= 8'h00;
                        state <= S_PTRL;
                    end
                    8'h7C: begin                                           // JMP (abs,X)
                        tptr <= {b2, b1} + X[15:0]; ptr_bank <= PBR;
                        state <= S_PTRL;
                    end
                    8'h5C: begin jumpl(b3, {b2, b1}); state <= S_FETCH; end // JML long
                    8'h22: begin                                           // JSL long
                        push_q <= {PBR, pce - 16'd1, 8'h00}; push_n <= 3'd3; stk16 <= 1'b1;
                        post_push <= PP_FETCH;
                        jumpl(b3, {b2, b1});
                        state <= S_PUSH;
                    end
                    default: case (d_mode)
                    MD_REL: begin
                        if (btake) jump(pce + {{8{b1[7]}}, b1});
                        state <= S_FETCH;
                    end
                    MD_IMM: begin
                        xm <= (rw == W32) ? {b4, b3, b2, b1} :
                              (rw == W16) ? {16'h0, b2, b1} : {24'h0, b1};
                        if (d_md) begin md_ph <= P_INIT; state <= S_MD; end
                        else begin xp <= 1'b1; state <= S_FETCH; end
                    end
                    // Direct-page modes: when E=1 and DL=0 the base offset
                    // (dp + index) wraps within page 0 with high byte = DH;
                    // otherwise it is a 16-bit add in bank 0 (from dbase in
                    // dbank, in banked mode). The word/pointer upper bytes
                    // are always fetched at base+1 (16-bit).
                    MD_DP: begin
                        taddr <= dpw ? {8'h00, D[15:8], b1}
                                     : {dbank, dbase + {8'h00, b1}};
                        wrap16 <= 1'b1;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_DPX: begin
                        taddr <= dpw ? {8'h00, D[15:8], b1 + X[7:0]}
                                     : {dbank, dbase + {8'h00, b1} + X[15:0]};
                        wrap16 <= 1'b1;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_DPY: begin
                        taddr <= dpw ? {8'h00, D[15:8], b1 + Y[7:0]}
                                     : {dbank, dbase + {8'h00, b1} + Y[15:0]};
                        wrap16 <= 1'b1;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_SR: begin
                        taddr <= {dbank, S + {8'h00, b1}};
                        wrap16 <= 1'b1;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_IDX: begin
                        tptr <= dpw ? {D[15:8], b1 + X[7:0]}
                                    : dbase + {8'h00, b1} + X[15:0];
                        ptr_bank <= dbank;
                        state <= S_PTRL;
                    end
                    MD_IDP, MD_IDY, MD_IDL, MD_ILY: begin
                        tptr <= dpw ? {D[15:8], b1}
                                    : dbase + {8'h00, b1};
                        ptr_bank <= dbank;
                        state <= S_PTRL;
                    end
                    MD_SRY: begin
                        tptr <= S + {8'h00, b1}; ptr_bank <= dbank;
                        state <= S_PTRL;
                    end
                    MD_ABS: begin
                        taddr <= {DBR, b2, b1}; wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_ABX: begin
                        taddr <= {DBR, b2, b1} + X[23:0]; wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    MD_ABY: begin
                        taddr <= {DBR, b2, b1} + Y[23:0]; wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    default: begin                                         // ABL / ALX
                        taddr <= (d_mode == MD_ALX)
                                 ? {b3, b2, b1} + X[23:0]
                                 : {b3, b2, b1};
                        wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    endcase
                    endcase
                end

                //----------------------------------------------------------
                S_PTRL: begin
                    tlo <= rdata; tptr <= tptr + 16'd1;
                    state <= S_PTRH;
                end

                S_PTRH: begin
                    tptr <= tptr + 16'd1;
                    case (IRx ? 8'h01 : IR)
                    8'h6C, 8'h7C, 8'hFC:                                   // jumps via pointer
                        begin jump({rdata, tlo}); state <= S_FETCH; end
                    8'hD4: push16({rdata, tlo});                           // PEI
                    8'hDC: begin tmid <= rdata; state <= S_PTRB; end       // JML [abs]
                    default: case (d_mode)
                    MD_IDL, MD_ILY: begin tmid <= rdata; state <= S_PTRB; end
                    MD_IDY, MD_SRY: begin
                        taddr <= {DBR, rdata, tlo} + Y[23:0]; wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    default: begin                                         // IDX / IDP
                        taddr <= {DBR, rdata, tlo}; wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    endcase
                    endcase
                end

                S_PTRB: begin
                    case (IRx ? 8'h01 : IR)
                    8'hDC: begin                                           // JML [abs]
                        jump({tmid, tlo}); PBR <= rdata; state <= S_FETCH;
                    end
                    default: begin                                         // IDL / ILY
                        taddr <= (d_mode == MD_ILY)
                                 ? {rdata, tmid, tlo} + Y[23:0]
                                 : {rdata, tmid, tlo};
                        wrap16 <= 1'b0;
                        state <= dstate_wr ? S_WRL : S_RDL;
                    end
                    endcase
                end

                //----------------------------------------------------------
                // The data is latched (xm), not used: a read's execute runs
                // in the next fetch cycle, an RMW's in S_WBL, a multiply's
                // or divide's in S_MD. A wide operand's bytes follow in
                // S_RDH (rb), low byte first.
                S_RDL: begin
                    xm <= {24'h0, rdata};
                    if (rw != W8) begin
                        taddr <= taddr1; taddr_alt <= taddr; rb <= 2'd1;
                        state <= S_RDH;
                    end else if (d_cls == CL_MW) state <= S_WBL;
                    else if (d_md) begin md_ph <= P_INIT; state <= S_MD; end
                    else begin xp <= 1'b1; state <= S_FETCH; end
                end

                S_RDH: begin
                    xm[8*rb +: 8] <= rdata;
                    if (rb != rlast) begin
                        taddr <= taddr1; rb <= rb + 2'd1;
                    end else if (d_cls == CL_MW) begin
                        taddr <= taddr_alt; state <= S_WBL;
                    end else if (d_md) begin md_ph <= P_INIT; state <= S_MD; end
                    else begin xp <= 1'b1; state <= S_FETCH; end
                end

                // An RMW writes back low byte first, from its first address
                S_WBL: begin
                    rmw_core(d_op, xm, 1'b0);
                    if (rw != W8) begin taddr <= taddr1; rb <= 2'd1; state <= S_WBH; end
                    else state <= S_FETCH;
                end
                S_WBH: begin
                    if (rb != rlast) begin taddr <= taddr1; rb <= rb + 2'd1; end
                    else state <= S_FETCH;
                end
                S_WRL: begin
                    if (sw != W8) begin taddr <= taddr1; rb <= 2'd1; state <= S_WRH; end
                    else state <= S_FETCH;
                end
                S_WRH: begin
                    if (rb != slast) begin taddr <= taddr1; rb <= rb + 2'd1; end
                    else state <= S_FETCH;
                end

                //----------------------------------------------------------
                S_PUSH: begin
                    s_dec;
                    push_q <= push_q << 8;
                    push_n <= push_n - 3'd1;
                    if (push_n == 3'd1) begin
                        if (emu & stk16) S[15:8] <= 8'h01;  // restore page 1
                        case (post_push)
                        PP_VEC:  state <= S_VECL;
                        PP_PTR:  state <= S_PTRL;
                        default: state <= S_FETCH;
                        endcase
                    end
                end

                S_PULL: begin
                    s_inc;
                    pa <= (emu & ~stk16) ? {16'h0001, pa[7:0] + 8'd1}
                                         : {pa[23:16], pa[15:0] + 16'd1};
                    pull_idx <= pull_idx + 2'd1;
                    tdata[8*pull_idx +: 8] <= rdata;                       // a wide pull's bytes
                    case (IR)
                    8'h28: begin set_p(rdata); state <= S_FETCH; end       // PLP
                    8'hAB: begin                                           // PLB
                        DBR <= rdata;
                        fN <= rdata[7]; fZ <= (rdata == 8'h00);
                        if (emu) S[15:8] <= 8'h01;          // restore page 1
                        state <= S_FETCH;
                    end
                    8'h2B:                                                 // PLD
                        if (pull_idx == 2'd0) tlo <= rdata;
                        else begin
                            D <= {rdata, tlo};
                            fN <= rdata[7]; fZ <= ({rdata, tlo} == 16'h0000);
                            if (emu) S[15:8] <= 8'h01;      // restore page 1
                            state <= S_FETCH;
                        end
                    // PLA, PLY, PLX: 1, 2 or 4 bytes, the last from the bus
                    8'h68:                                                 // PLA
                        if (pull_idx == ((aw == W32) ? 2'd3 : {1'b0, aw == W16})) begin
                            ld_a(pulled(aw)); state <= S_FETCH;
                        end
                    8'h7A:                                                 // PLY
                        if (pull_idx == ((xw == W32) ? 2'd3 : {1'b0, xw == W16})) begin
                            ld_y(pulled(xw)); state <= S_FETCH;
                        end
                    8'hFA:                                                 // PLX
                        if (pull_idx == ((xw == W32) ? 2'd3 : {1'b0, xw == W16})) begin
                            ld_x(pulled(xw)); state <= S_FETCH;
                        end
                    8'h60:                                                 // RTS
                        if (pull_idx == 2'd0) tlo <= rdata;
                        else begin
                            jump({rdata, tlo} + 16'd1); state <= S_FETCH;
                        end
                    8'h6B:                                                 // RTL
                        case (pull_idx)
                        2'd0: tlo <= rdata;
                        2'd1: jump({rdata, tlo} + 16'd1);
                        default: begin
                            PBR <= rdata;
                            if (emu) S[15:8] <= 8'h01;      // restore page 1
                            state <= S_FETCH;
                        end
                        endcase
                    default:                                               // RTI (0x40)
                        case (pull_idx)
                        2'd0: set_p(rdata);
                        2'd1: tlo <= rdata;
                        2'd2: begin
                            jump({rdata, tlo});
                            if (emu) state <= S_FETCH;
                        end
                        default: begin PBR <= rdata; state <= S_FETCH; end
                        endcase
                    endcase
                end

                //----------------------------------------------------------
                S_VECL: begin tlo <= rdata; vec <= vec + 16'd1; state <= S_VECH; end
                S_VECH: begin jump({rdata, tlo}); state <= S_FETCH; end

                //----------------------------------------------------------
                S_MVR: begin
                    tdata[7:0] <= rdata;
                    state <= S_MVW;
                end

                // Internal block-move loop: after FETCH/OPS set up the
                // banks, spin MVR/MVW at 2 cycles/byte without re-fetching the
                // instruction. PC already points past the MVN/MVP.
                //   - count exhausted (C wrapped to $FFFF): fall through to the
                //     next instruction.
                //   - interrupt pending: rewind PC by 3 onto the opcode so the
                //     pushed PC re-enters the move, then let S_FETCH take it.
                //   - otherwise: loop back to MVR for the next byte.
                // X and Y step at their width and the addresses follow them
                // (bank:0000 + X); the count is A at its wide width, 16 bits
                // or 32 (cw32).
                S_MVW: begin : mvw
                    reg [31:0] xn, yn;
                    xn = mvstep(X, IR == 8'h54, xw);
                    yn = mvstep(Y, IR == 8'h54, xw);
                    X <= xn; Y <= yn;
                    mv_s <= {tmid, 16'h0} + {8'h0, xn[23:0]};
                    mv_d <= {DBR, 16'h0} + {8'h0, yn[23:0]};
                    if (cw32) A <= A - 32'd1; else A[15:0] <= A[15:0] - 16'd1;
                    if (cw32 ? (A == 32'h0) : (A[15:0] == 16'h0000))
                        state <= S_FETCH;
                    else if (intr) begin
                        jump(PC - 16'd3);
                        state <= S_FETCH;
                    end else
                        state <= S_MVR;
                end

                //----------------------------------------------------------
                // MUL/UML/DIV/UDV of A (at its width) by the operand (xm),
                // a bit a cycle. The product's low half or the quotient
                // goes to A, the high half or the remainder to X.
                S_MD: begin : md
                    reg [32:0] t;
                    reg [31:0] lo, hi;
                    reg        nn;
                    case (md_ph)
                    P_INIT: begin
                        md_sg <= (d_op == OP_MUL) | (d_op == OP_DIV);
                        md_dv <= (d_op == OP_DIV) | (d_op == OP_UDV);
                        md_sx <= ((d_op == OP_MUL) | (d_op == OP_DIV)) & topb(av, aw);
                        md_sy <= ((d_op == OP_MUL) | (d_op == OP_DIV)) & topb(xm, aw);
                        md_a <= av; md_b <= xm; md_h <= 33'h0; md_l <= av;
                        md_n <= (aw == W32) ? 6'd32 : (aw == W16) ? 6'd16 : 6'd8;
                        md_ov <= (d_op == OP_DIV) & (av == (wmask(aw) ^ (wmask(aw) >> 1)))
                                                  & (xm == wmask(aw));
                        if ((d_op == OP_MUL) | (d_op == OP_UML)) md_ph <= P_LOOP;
                        else if (xm == 32'h0) begin                // by zero: V
                            fV <= 1'b1; state <= S_FETCH;
                        end else md_ph <= P_NEGA;
                    end
                    // DIV: the magnitudes, the dividend into md_l's top
                    P_NEGA: begin
                        if (md_sx) md_a <= md_sw;
                        md_ph <= P_NEGB;
                    end
                    P_NEGB: begin
                        if (md_sy) md_b <= md_sw;
                        md_l <= md_a << ((aw == W32) ? 6'd0 : (aw == W16) ? 6'd16 : 6'd24);
                        md_ph <= P_LOOP;
                    end
                    P_LOOP: begin
                        if (md_dv) begin                         // restoring divide
                            nn = ~md_sum[33];                    // 2h + bit >= b
                            md_h <= nn ? md_sum[32:0] : {md_h[31:0], md_l[31]};
                            md_l <= {md_l[30:0], nn};
                        end else begin                           // shift and add
                            t = md_l[0] ? md_sum[32:0] : md_h;
                            md_h <= {1'b0, t[32:1]};
                            md_l <= {t[0], md_l[31:1]};
                        end
                        md_n <= md_n - 6'd1;
                        if (md_n == 6'd1)
                            md_ph <= md_dv ? (md_sg ? P_FIXQ : P_DONE)
                                           : (md_sg ? P_FIX1 : P_DONE);
                    end
                    // MUL: the high half less b if a < 0, and less a if b < 0
                    P_FIX1: begin
                        if (md_sx) md_h <= {1'b0, md_sw};
                        md_ph <= P_FIX2;
                    end
                    P_FIX2: begin
                        if (md_sy) md_h <= {1'b0, md_sw};
                        md_ph <= P_DONE;
                    end
                    // DIV: rounded down. Signs alike: q, and r with the
                    // dividend's sign. Unlike: -q if r = 0, else -q - 1 and
                    // b - r, with the divisor's sign.
                    P_FIXQ: begin
                        if (md_sx != md_sy)
                            md_l <= (md_h == 33'h0) ? md_sw : (~md_l & wmask(aw));
                        md_ph <= P_FIXR;
                    end
                    P_FIXR: begin
                        if ((md_sx == md_sy) ? md_sx : (md_h != 33'h0)) md_h <= {1'b0, md_sw};
                        md_ph <= P_DONE;
                    end
                    default: begin                               // P_DONE
                        if (md_dv) begin
                            ld_a(md_l); wr_x(md_h[31:0]); fV <= md_ov;
                        end else begin
                            lo = (aw == W32) ? md_l : (aw == W16) ? {16'h0, md_l[31:16]}
                                                                  : {24'h0, md_l[31:24]};
                            hi = md_h[31:0] & wmask(aw);
                            ld_a(lo); wr_x(hi);
                            fV <= (hi != ((md_sg & topb(lo, aw)) ? wmask(aw) : 32'h0));
                        end
                        state <= S_FETCH;
                    end
                    endcase
                end

                //----------------------------------------------------------
                S_WAI: begin
                    if (nmi_pend | ~irq2) begin
                        if (nmi_pend | ~fI) begin
                            if (nmi_pend) nmi_pend <= 1'b0;
                            int_entry(PC, 1'b0, int_vec);
                        end else
                            state <= S_FETCH;
                    end
                end

                S_STP: ;                       // only reset leaves this state

                default: state <= S_FETCH;
                endcase
            end

            //--------------------------------------------------------------
            // The instruction queue: the byte taken this cycle, the fill
            // landing this cycle, a jump, and the next fill. A fill starts
            // only in a cycle the core is off the bus, when a whole word
            // will fit, and its address is latched: the bus holds it to rdy.
            begin : queue_logic
                // Both outcomes are worked out without rdy -- the fill
                // landing this cycle or not -- and rdy, which arrives late
                // (through the cache's compare), only picks one.
                reg [63:0] qq, qf;
                reg [3:0]  qc, qcf;
                reg [2:0]  nf;
                reg [31:0] fw;
                reg        land, st_n, st_f;
                qq = q >> {take, 3'b000};
                qc = qn - {1'b0, take};
                if (r32) begin
                    fw = rdata32 >> {faddr[1:0], 3'b000};
                    nf = 3'd4 - {1'b0, faddr[1:0]};
                end else begin
                    fw = {24'h0, rdata};
                    nf = 3'd1;
                end
                qf  = qq | ({32'h0, fw} << {qc, 3'b000});
                qcf = qc + {1'b0, nf};
                land = fbusy & rdy & ~fdrop & ~jmp;  // a fill lands now
                if (jmp) begin
                    q <= 64'h0; qn <= 4'd0; fa <= jpc;
                end else if (land) begin
                    q <= qf; qn <= qcf; fa <= fa + {13'd0, nf};
                end else begin
                    q <= qq; qn <= qc;
                end
                if (fbusy & rdy) begin
                    fbusy <= 1'b0; fdrop <= 1'b0;
                end else if (fbusy & jmp)
                    fdrop <= 1'b1;
                // The next fill: once the bus is free (no fill, or this one
                // ending), in a cycle the core is off it, when a word will
                // fit. (A jump out of a bus state -- a return, a vector, a
                // pointer -- may change PBR a cycle later, but the next state
                // then starts no fill until it is off the bus.)
                st_n = ~needs_bus & ~((state == S_FETCH) & (intr | abort_pend));
                st_f = st_n & (jmp | (qcf <= 4'd4));   // after a fill lands
                st_n = st_n & (jmp | (qc  <= 4'd4));   // with none landing
                if (fbusy ? (rdy & (fdrop | jmp ? st_n : st_f)) : st_n) begin
                    fbusy <= 1'b1; fdrop <= 1'b0;
                    if (jmp) begin
                        faddr <= {jbank, jpc}; fa <= jpc;
                    end else if (fbusy & ~fdrop)
                        faddr <= {PBR, fa + {13'd0, nf}};
                    else
                        faddr <= {PBR, fa};
                end
            end

            // A parameter of 0 holds its registers constant (these, the
            // last assignments, win), so that synthesis drops them: the
            // 65C832's upper halves, and the multiply/divide unit.
            if (C832 == 0) begin
                A[31:16] <= 16'h0; X[31:16] <= 16'h0; Y[31:16] <= 16'h0;
                sA[31:16] <= 16'h0; sX[31:16] <= 16'h0; sY[31:16] <= 16'h0;
                xm[31:16] <= 16'h0; tdata[31:16] <= 16'h0;
                fE16 <= 1'b1; sfE16 <= 1'b1;
            end
            if (XOPS == 0) begin
                md_ph <= P_INIT; md_h <= 33'h0; md_l <= 32'h0; md_a <= 32'h0;
                md_b <= 32'h0; md_n <= 6'd0; md_sx <= 1'b0; md_sy <= 1'b0;
                md_sg <= 1'b0; md_dv <= 1'b0; md_ov <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
