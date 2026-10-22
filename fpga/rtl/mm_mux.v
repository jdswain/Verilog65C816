//============================================================================
// mm_mux.v -- two memory masters on the SDRAM controller's port 2
//
// The blitter (master B) and the DMA engine (master D) share the memory-
// master port. A master is granted when it asks and nothing holds the port,
// and keeps the grant until its transaction's `done`: the controller reads
// the address and write data from the port all through a transaction, so it
// must not change master in the middle. If both ask at once, the DMA engine
// wins: it has deadlines (the floppy's FIFO) and the blitter has none, and
// it asks at most once every few bus cycles.
//
// Port 2 outranks the CPU, which is fair only because each master drops its
// request for a cycle after `done`. With two masters one could ask while the
// other drops, so the port's request is held low for the cycle after every
// `done` as well: the CPU always gets its turn between two transactions.
//
// The cache snoops port 2's writes; `done & we` with the granted master's
// address is that report.
//============================================================================
`default_nettype none

module mm_mux (
    input  wire        clk,
    input  wire        rst_n,

    // ---- master B: the blitter ----
    input  wire        b_req,
    input  wire        b_we,
    input  wire [20:0] b_addr,
    input  wire [31:0] b_wdata,
    input  wire [3:0]  b_wmask,
    output wire        b_done,
    output wire        b_rvalid,

    // ---- master D: the DMA engine ----
    input  wire        d_req,
    input  wire        d_we,
    input  wire [20:0] d_addr,
    input  wire [31:0] d_wdata,
    input  wire [3:0]  d_wmask,
    output wire        d_done,
    output wire        d_rvalid,

    // ---- port 2 ----
    output wire        p_req,
    output wire        p_we,
    output wire [20:0] p_addr,
    output wire [31:0] p_wdata,
    output wire [3:0]  p_wmask,
    input  wire        p_done,
    input  wire        p_rvalid
);
    reg held;                // a master has the port
    reg held_d;              // ...and it is D
    reg gap;                 // the cycle after a done

    // Before a grant, the master that would get it; after, the one that has it.
    wire use_d = held ? held_d : d_req;

    assign p_req   = ~gap & (use_d ? d_req : b_req);
    assign p_we    = use_d ? d_we    : b_we;
    assign p_addr  = use_d ? d_addr  : b_addr;
    assign p_wdata = use_d ? d_wdata : b_wdata;
    assign p_wmask = use_d ? d_wmask : b_wmask;

    assign d_done   = p_done   &  use_d;
    assign d_rvalid = p_rvalid &  use_d;
    assign b_done   = p_done   & ~use_d;
    assign b_rvalid = p_rvalid & ~use_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            held <= 1'b0; held_d <= 1'b0; gap <= 1'b0;
        end else begin
            gap <= p_done;
            if (p_done)
                held <= 1'b0;
            else if (!held && !gap && (d_req || b_req)) begin
                held   <= 1'b1;
                held_d <= d_req;
            end
        end
    end
endmodule

`default_nettype wire
