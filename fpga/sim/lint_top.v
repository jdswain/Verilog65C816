// Elaboration root for `make lint`.
//
// The Gowin primitive models reference a global set/reset by absolute
// hierarchical name (GSR.GSRO), so an instance literally called GSR must exist
// at the top of the design. Synthesis inserts one automatically; outside the
// Gowin tools we have to supply it, which is what this wrapper is for.
`default_nettype none

module lint_top;
    GSR GSR (.GSRI(1'b1));

    wire       led;
    wire       uart_tx;
    wire [31:0] dq;
    wire [10:0] sa; wire [1:0] sba; wire [3:0] sdqm;
    wire sclk, scke, scs, scas, sras, swen;
    wire tclkp, tclkn; wire [2:0] tdp, tdn;
    wire adb_drive;
    wire [3:0] ext_a;
    wire [2:0] ext_sel;
    wire [7:0] ext_d;
    wire ext_sel_en_n, ext_rd_n, ext_wr_n, ext_res_n;

    top_tang20k dut (
        .clk(1'b0), .rst(1'b1), .led(led),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .O_sdram_clk(sclk), .O_sdram_cke(scke), .O_sdram_cs_n(scs),
        .O_sdram_cas_n(scas), .O_sdram_ras_n(sras), .O_sdram_wen_n(swen),
        .IO_sdram_dq(dq), .O_sdram_addr(sa), .O_sdram_ba(sba),
        .O_sdram_dqm(sdqm),
        .tmds_clk_p(tclkp), .tmds_clk_n(tclkn),
        .tmds_d_p(tdp), .tmds_d_n(tdn),
        .adb_drive(adb_drive), .adb_sense(1'b1),
        .ext_a(ext_a), .ext_d(ext_d), .ext_sel(ext_sel),
        .ext_sel_en_n(ext_sel_en_n), .ext_rd_n(ext_rd_n), .ext_wr_n(ext_wr_n),
        .ext_res_n(ext_res_n), .ext_irq_n(1'b1)
    );
endmodule

`default_nettype wire
