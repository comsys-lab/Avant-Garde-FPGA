// Level 9 Testbench: Full Pipeline
//   DUT: VX_fetch → VX_decode → VX_issue → VX_execute → VX_commit
//
// TC1: pipeline_trace (INT path)
//   LDSCALE: scale_a=129 (0x81), scale_b=127 (0x7F) → exp_total=2
//   WMMA   : A=B=0x01010101 (INT8 1×4), C=0  → D[m][n]=64 (all 8 tiles)
//   Encoding: LDSCALE=0x0C02808B, WMMA=0x0404840B, x5=0x00007F81
//   Expected: 16 commits, k0=32, kfinal=64
//
// TC2: fp_path (FP path)
//   WMMA FP: A=B=0x3F803F80 (BF16 1.0×2/word), C=0.0
//   Encoding: WMMA_FP=0x0401000B (fmt_d=FP32=0, fmt_s=BF16=2)
//   Per uop: TC_K=2 words × 2 BF16/word × 1.0×1.0 = 4.0
//   Expected: 16 commits, k0=4.0(0x40800000), kfinal=8.0(0x41000000)
//
//   NT=4 파라미터:
//     TC_M=2, TC_N=2, TC_K=2
//     M_STEPS=4, N_STEPS=2, K_STEPS=2  →  UOPS=16

`include "VX_define.vh"

module tb_pipeline;

    import VX_gpu_pkg::*;
    import VX_tcu_pkg::*;

    // =========================================================================
    // Clock / reset
    // =========================================================================
    logic clk   = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    // =========================================================================
    // Constants
    // =========================================================================
    localparam IC_DATA_SIZE = ICACHE_WORD_SIZE;   // 4 bytes (32-bit instruction)
    localparam IC_TAG_WIDTH = ICACHE_TAG_WIDTH;   // UUID_WIDTH + NW_WIDTH

    localparam [NUM_REGS_BITS-1:0] SCALE_REG = 5; // x5 holds {scale_b, scale_a}
    localparam logic [6:0] TCU_OPCODE = 7'h0B;

    // TC1 — INT path values
    localparam logic [31:0] INSTR_LDSCALE = 32'h0C02_808B;
    localparam logic [31:0] INSTR_WMMA    = 32'h0404_840B; // fmt_d=I32=8, fmt_s=I8=9
    localparam logic [31:0] SCALE_VAL     = 32'h0000_7F81; // scale_b=127, scale_a=129
    localparam logic [31:0] A_VAL         = 32'h0101_0101;
    localparam logic [31:0] B_VAL         = 32'h0101_0101;
    localparam logic [31:0] C_VAL         = 32'h0000_0000;

    // TC2 — FP path values
    // encode_wmma(fmt_d=FP32_ID=0, fmt_s=BF16_ID=2) = 0x0401_000B
    localparam logic [31:0] INSTR_WMMA_FP = 32'h0401_000B; // fmt_d=FP32=0, fmt_s=BF16=2
    localparam logic [31:0] A_VAL_FP      = 32'h3F80_3F80; // {BF16 1.0, BF16 1.0}
    localparam logic [31:0] B_VAL_FP      = 32'h3F80_3F80;
    localparam logic [31:0] C_VAL_FP      = 32'h0000_0000; // FP32 0.0

    // =========================================================================
    // Interfaces
    // =========================================================================
    VX_schedule_if schedule_if();

    VX_mem_bus_if #(
        .DATA_SIZE (IC_DATA_SIZE),
        .TAG_WIDTH (IC_TAG_WIDTH)
    ) icache_bus_if();

    VX_fetch_if        fetch_if();
    VX_decode_sched_if decode_sched_if();
    VX_decode_if       decode_if();

    VX_writeback_if   issue_wb       [`ISSUE_WIDTH]();
    VX_writeback_if   commit_wb      [`ISSUE_WIDTH]();
    VX_dispatch_if    issue_dispatch [NUM_EX_UNITS * `ISSUE_WIDTH]();
    VX_commit_if      commit_mid     [NUM_EX_UNITS * `ISSUE_WIDTH]();
    VX_issue_sched_if issue_sched_if [`ISSUE_WIDTH]();
    VX_branch_ctl_if  branch_ctl_if  [`NUM_ALU_BLOCKS]();
    VX_warp_ctl_if    warp_ctl_if();
    VX_commit_csr_if  commit_csr_if();
    VX_commit_sched_if commit_sched_if();
    VX_sched_csr_if   sched_csr_if();
    VX_lsu_mem_if #(
        .NUM_LANES (`NUM_LSU_LANES),
        .DATA_SIZE (4),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) lsu_mem_if[`NUM_LSU_BLOCKS]();

    // =========================================================================
    // Writeback mux: preload_phase=1 → TB seeds GPR, preload_phase=0 → commit_wb
    // =========================================================================
    logic       preload_phase = 1'b1;
    logic       tb_wb_valid_r = 1'b0;
    writeback_t tb_wb_data_r;

    for (genvar i = 0; i < `ISSUE_WIDTH; i++) begin : g_wb_mux
        assign issue_wb[i].valid = preload_phase ? tb_wb_valid_r  : commit_wb[i].valid;
        assign issue_wb[i].data  = preload_phase ? tb_wb_data_r   : commit_wb[i].data;
    end

    // =========================================================================
    // TB signals — schedule_if (TB is the scheduler)
    // =========================================================================
    logic                     tb_sched_valid;
    logic [UUID_WIDTH-1:0]    tb_sched_uuid;
    logic [NW_WIDTH-1:0]      tb_sched_wid;
    logic [`NUM_THREADS-1:0]  tb_sched_tmask;
    logic [PC_BITS-1:0]       tb_sched_pc;

    assign schedule_if.valid       = tb_sched_valid;
    assign schedule_if.data.uuid   = tb_sched_uuid;
    assign schedule_if.data.wid    = tb_sched_wid;
    assign schedule_if.data.tmask  = tb_sched_tmask;
    assign schedule_if.data.PC     = tb_sched_pc;

    // =========================================================================
    // TB signals — icache_bus_if slave side (TB is the icache)
    // =========================================================================
    logic                         tb_icache_req_ready;
    logic                         tb_icache_rsp_valid;
    logic [IC_DATA_SIZE*8-1:0]    tb_icache_rsp_data;
    logic [IC_TAG_WIDTH-1:0]      tb_icache_rsp_tag_flat;

    assign icache_bus_if.req_ready     = tb_icache_req_ready;
    assign icache_bus_if.rsp_valid     = tb_icache_rsp_valid;
    assign icache_bus_if.rsp_data.data = tb_icache_rsp_data;
    assign icache_bus_if.rsp_data.tag  = tb_icache_rsp_tag_flat;

    // =========================================================================
    // DUT: VX_fetch
    // =========================================================================
    VX_fetch #(
        .INSTANCE_ID ("tb_pipeline_fetch")
    ) fetch_dut (
        .clk           (clk),
        .reset         (reset),
        .icache_bus_if (icache_bus_if),
        .schedule_if   (schedule_if),
        .fetch_if      (fetch_if)
    );

    // =========================================================================
    // DUT: VX_decode
    // =========================================================================
    VX_decode #(
        .INSTANCE_ID ("tb_pipeline_decode")
    ) decode_dut (
        .clk             (clk),
        .reset           (reset),
        .fetch_if        (fetch_if),
        .decode_if       (decode_if),
        .decode_sched_if (decode_sched_if)
    );

    // =========================================================================
    // DUT: VX_issue
    // =========================================================================
    VX_issue #(
        .INSTANCE_ID ("tb_pipeline_issue")
    ) issue_dut (
        .clk            (clk),
        .reset          (reset),
        .decode_if      (decode_if),
        .writeback_if   (issue_wb),
        .dispatch_if    (issue_dispatch),
        .issue_sched_if (issue_sched_if)
    );

    // =========================================================================
    // DUT: VX_execute
    // =========================================================================
    base_dcrs_t base_dcrs_tie;
    assign base_dcrs_tie = '0;

    VX_execute #(
        .INSTANCE_ID ("tb_pipeline_execute"),
        .CORE_ID     (0)
    ) execute_dut (
        .clk           (clk),
        .reset         (reset),
        .base_dcrs     (base_dcrs_tie),
        .lsu_mem_if    (lsu_mem_if),
        .dispatch_if   (issue_dispatch),
        .commit_if     (commit_mid),
        .sched_csr_if  (sched_csr_if),
        .branch_ctl_if (branch_ctl_if),
        .warp_ctl_if   (warp_ctl_if),
        .commit_csr_if (commit_csr_if)
    );

    // =========================================================================
    // DUT: VX_commit
    // =========================================================================
    VX_commit #(
        .INSTANCE_ID ("tb_pipeline_commit")
    ) commit_dut (
        .clk             (clk),
        .reset           (reset),
        .commit_if       (commit_mid),
        .writeback_if    (commit_wb),
        .commit_csr_if   (commit_csr_if),
        .commit_sched_if (commit_sched_if)
    );

    // =========================================================================
    // Tie-offs
    // =========================================================================
    for (genvar i = 0; i < `NUM_LSU_BLOCKS; i++) begin : g_tie_lsu
        assign lsu_mem_if[i].req_ready = 1'b0;
        assign lsu_mem_if[i].rsp_valid = 1'b0;
        assign lsu_mem_if[i].rsp_data  = '0;
    end

    assign warp_ctl_if.dvstack_ptr   = '0;
    assign sched_csr_if.cycles       = '0;
    assign sched_csr_if.active_warps = '0;
    assign sched_csr_if.thread_masks = '0;
    assign sched_csr_if.alm_empty    = '0;

    // =========================================================================
    // Helpers
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;
    logic [UUID_WIDTH-1:0] next_uuid = UUID_WIDTH'(1);

    function automatic logic [`SIMD_WIDTH-1:0][`XLEN-1:0] fill (
        input logic [`XLEN-1:0] w
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] r;
        for (int i = 0; i < `SIMD_WIDTH; i++) r[i] = w;
        return r;
    endfunction

    function automatic logic [31:0] encode_wmma (
        input logic [3:0] fmt_d,
        input logic [3:0] fmt_s
    );
        return {7'h02, 5'h0, {1'b0, fmt_s}, 3'h0, {1'b0, fmt_d}, TCU_OPCODE};
    endfunction

    function automatic logic [31:0] encode_ldscale (
        input logic [4:0] scale_rs1
    );
        return {7'h06, 5'h0, scale_rs1, 3'h0, 5'h1, TCU_OPCODE};
    endfunction

    // =========================================================================
    // preload_gpr: write one register into VX_operands via issue_wb
    //   Must be called only when preload_phase=1
    // =========================================================================
    task automatic preload_gpr (
        input logic [NUM_REGS_BITS-1:0] reg_idx,
        input logic [`XLEN-1:0]         val
    );
        writeback_t wb;
        wb        = '0;
        wb.wis    = '0;
        wb.tmask  = '1;
        wb.eop    = 1'b1;
        wb.rd     = reg_idx;
        for (int t = 0; t < `SIMD_WIDTH; t++) wb.data[t] = val;
        @(posedge clk); #1;
        tb_wb_valid_r = 1'b1;
        tb_wb_data_r  = wb;
        @(posedge clk); #1;
        tb_wb_valid_r = 1'b0;
    endtask

    // Seed A-tile (M_STEPS×K_STEPS regs), B-tile (K_STEPS×N_STEPS), C-tile (M_STEPS×N_STEPS)
    // Tile registers are float registers → use make_reg_num(REG_TYPE_F, idx)
    task automatic preload_tile_regs (
        input logic [`XLEN-1:0] a_val,
        input logic [`XLEN-1:0] b_val,
        input logic [`XLEN-1:0] c_val
    );
        for (int m = 0; m < TCU_M_STEPS; m++)
            for (int k = 0; k < TCU_K_STEPS; k++)
                preload_gpr(NUM_REGS_BITS'(make_reg_num(REG_TYPE_F, 5'(TCU_RA + m * TCU_K_STEPS + k))), a_val);
        for (int k = 0; k < TCU_K_STEPS; k++)
            for (int n = 0; n < TCU_N_STEPS; n++)
                preload_gpr(NUM_REGS_BITS'(make_reg_num(REG_TYPE_F, 5'(TCU_RB + k * TCU_N_STEPS + n))), b_val);
        for (int m = 0; m < TCU_M_STEPS; m++)
            for (int n = 0; n < TCU_N_STEPS; n++)
                preload_gpr(NUM_REGS_BITS'(make_reg_num(REG_TYPE_F, 5'(TCU_RC + m * TCU_N_STEPS + n))), c_val);
    endtask

    // =========================================================================
    // send_instr: schedule_if → VX_fetch → icache req → TB respond → VX_fetch → fetch_if
    //
    //   Timing (OUT_REG=1 elastic buffer in VX_fetch):
    //     posedge①: schedule_if fires → elastic buffer input latches
    //     #1 after ①: elastic buffer data_out_r (req_data.tag) is committed
    //     TB sends icache rsp → wait for rsp_valid && rsp_ready
    //     #1 after rsp: prev_write cleared → tag_store ram[] read correct
    // =========================================================================
    task automatic send_instr (
        input logic [PC_BITS-1:0]      pc,
        input logic [NW_WIDTH-1:0]     wid,
        input logic [`NUM_THREADS-1:0] tmask,
        input logic [31:0]             instr_word
    );
        logic [IC_TAG_WIDTH-1:0] req_tag;

        // Assert schedule
        tb_sched_valid = 1;
        tb_sched_uuid  = next_uuid;
        tb_sched_wid   = wid;
        tb_sched_tmask = tmask;
        tb_sched_pc    = pc;
        next_uuid      = next_uuid + 1;

        // Wait for schedule handshake (elastic buffer accepts req)
        // schedule_if.ready = icache_req_ready && ibuf_ready
        @(posedge clk iff (schedule_if.valid && schedule_if.ready));
        #1; // let elastic buffer NBA commit → req_data.tag is now valid
        req_tag = icache_bus_if.req_data.tag;
        #1;
        tb_sched_valid = 0;

        // Send icache response with captured tag
        tb_icache_rsp_valid    = 1;
        tb_icache_rsp_data     = instr_word; // 32-bit instruction word
        tb_icache_rsp_tag_flat = req_tag;

        // Wait for rsp_ready (= fetch_if.ready, driven by VX_decode ibuf)
        @(posedge clk iff (icache_bus_if.rsp_valid && icache_bus_if.rsp_ready));
        #1; // let NBA commit → tag_store prev_write cleared, ram[] read correct
        #1;
        tb_icache_rsp_valid = 0;
    endtask

    // =========================================================================
    // wait_commit: wait for one eop writeback from VX_commit
    // =========================================================================
    task automatic wait_commit (output writeback_t res);
        @(posedge clk);
        while (!commit_wb[0].valid) @(posedge clk);
        res = commit_wb[0].data;
        @(posedge clk);
    endtask

    // Collect `count` valid commits
    task automatic collect_wbs (
        input  int         count,
        output writeback_t results []
    );
        results = new[count];
        for (int i = 0; i < count; i++) begin
            @(posedge clk);
            while (!commit_wb[0].valid) @(posedge clk);
            results[i] = commit_wb[0].data;
        end
    endtask

    // =========================================================================
    // Main stimulus
    // =========================================================================
    initial begin
        // --- Reset ---
        reset                  = 1'b1;
        tb_sched_valid         = 0;
        tb_sched_uuid          = '0;
        tb_sched_wid           = '0;
        tb_sched_tmask         = '0;
        tb_sched_pc            = '0;
        tb_icache_req_ready    = 1;  // always accept icache requests
        tb_icache_rsp_valid    = 0;
        tb_icache_rsp_data     = '0;
        tb_icache_rsp_tag_flat = '0;
        tb_wb_valid_r          = 0;
        tb_wb_data_r           = '0;
        preload_phase          = 1'b1;

        repeat(4) @(posedge clk);
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;

        $display("=== tb_pipeline: Full Pipeline Trace (VX_fetch → VX_decode → VX_issue → VX_execute → VX_commit) ===");
        $display("  TILE %0dx%0d  TC %0dx%0d  TC_K=%0d  M/N/K_STEPS=%0d/%0d/%0d  UOPS=%0d",
                 TCU_TILE_M, TCU_TILE_N, TCU_TC_M, TCU_TC_N, TCU_TC_K,
                 TCU_M_STEPS, TCU_N_STEPS, TCU_K_STEPS, TCU_UOPS);
        $display("  LDSCALE=0x%08X  WMMA=0x%08X  x5=0x%08X",
                 INSTR_LDSCALE, INSTR_WMMA, SCALE_VAL);

        // ======================================================================
        // TC1: pipeline_trace
        //   LDSCALE(scale_a=129=0x81, scale_b=127=0x7F) → exp_total=2
        //   WMMA(A=B=0x01010101, C=0)
        //   FEDP per uop: dot=8 (TC_K*4 INT8 pairs, all 1×1), shifted = 8<<2 = 32
        //   K accumulation: k=0→ 32+0=32, k=1→ 32+32=64
        //   8 output tiles (M_STEPS×N_STEPS), each final value = 64
        // ======================================================================
        begin : tc1
            writeback_t ldscale_wb;
            writeback_t results[];
            bit ok = 1;
            // exp_total=2, dot_per_uop = TC_K*4 = 8
            int exp_k0    = (TCU_TC_K * 4) <<< 2;  // 8 << 2 = 32
            int exp_final = exp_k0 * TCU_K_STEPS;   // 32 * 2 = 64

            $display("[TC1] Preloading GPRs: A=B=0x01010101, C=0x0, x5=0x%08X", SCALE_VAL);
            preload_tile_regs(A_VAL, B_VAL, C_VAL);
            preload_gpr(SCALE_REG, SCALE_VAL);
            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            // LDSCALE: PC=0x80000000, wid=0, tmask=all-ones
            $display("[TC1] send_instr LDSCALE (PC=0x80000000)");
            send_instr(PC_BITS'(32'h8000_0000),
                       NW_WIDTH'(0),
                       {`NUM_THREADS{1'b1}},
                       INSTR_LDSCALE);
            wait_commit(ldscale_wb);
            $display("[TC1] LDSCALE committed  rd=x%0d  data[0]=%0d  (exp 0)",
                     ldscale_wb.rd, $signed(ldscale_wb.data[0]));
`endif

            // WMMA: PC=0x80000004, wid=0, tmask=all-ones
            $display("[TC1] send_instr WMMA   (PC=0x80000004)");
            send_instr(PC_BITS'(32'h8000_0004),
                       NW_WIDTH'(0),
                       {`NUM_THREADS{1'b1}},
                       INSTR_WMMA);
            collect_wbs(TCU_UOPS, results);

            $display("[TC1] Checking %0d commits  (exp: k0=%0d, kfinal=%0d):",
                     TCU_UOPS, exp_k0, exp_final);
            for (int r = 0; r < TCU_UOPS; r++) begin
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    logic signed [31:0] got = $signed(results[r].data[t]);
                    if (got !== 32'(exp_k0) && got !== 32'(exp_final)) begin
                        $display("  [FAIL] commit[%0d][t=%0d] = %0d  (exp %0d or %0d)",
                                 r, t, got, exp_k0, exp_final);
                        ok = 0;
                    end
                end
                $display("  commit[%02d]: data[0]=%3d  wis=%0d  rd=%2d  uuid=%0d  %s",
                         r, $signed(results[r].data[0]),
                         results[r].wis, results[r].rd, results[r].uuid,
                         ($signed(results[r].data[0]) === 32'(exp_final)) ? "[final]" : "[k=0]");
            end

            if (ok) begin
                $display("[PASS] TC1_pipeline_trace   k0=%0d  kfinal=%0d  (%0d×%0d tiles all correct)",
                         exp_k0, exp_final, TCU_M_STEPS, TCU_N_STEPS);
                pass_cnt++;
            end else begin
                $display("[FAIL] TC1_pipeline_trace");
                fail_cnt++;
            end

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ======================================================================
        // TC2: fp_path
        //   WMMA FP (fmt_d=FP32, fmt_s=BF16), no LDSCALE (exp_total ignored by VX_tcu_fp)
        //   A=B=0x3F803F80: each word = {BF16 1.0, BF16 1.0}
        //   Per uop: TC_K=2 words × 2 BF16/word × 1.0×1.0 = 4.0 (FP32)
        //   k0: 4.0 + 0.0 = 4.0 (0x40800000)
        //   kfinal: 4.0 + 4.0 = 8.0 (0x41000000)
        // ======================================================================
        begin : tc2
            writeback_t results[];
            bit ok = 1;
            logic [31:0] exp_k0_fp    = 32'h4080_0000;  // FP32 4.0
            logic [31:0] exp_final_fp = 32'h4100_0000;  // FP32 8.0

            $display("[TC2] Preloading FP GPRs: A=B=0x3F803F80 (BF16 1.0×2), C=FP32 0.0");
            preload_tile_regs(A_VAL_FP, B_VAL_FP, C_VAL_FP);
            preload_phase = 1'b0;
            @(posedge clk); #1;

            // WMMA FP: PC=0x80000008, wid=0, tmask=all-ones
            $display("[TC2] send_instr WMMA FP (PC=0x80000008)");
            send_instr(PC_BITS'(32'h8000_0008),
                       NW_WIDTH'(0),
                       {`NUM_THREADS{1'b1}},
                       INSTR_WMMA_FP);
            collect_wbs(TCU_UOPS, results);

            $display("[TC2] Checking %0d commits  (exp: k0=4.0(0x%08X) kfinal=8.0(0x%08X)):",
                     TCU_UOPS, exp_k0_fp, exp_final_fp);
            for (int r = 0; r < TCU_UOPS; r++) begin
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    logic [31:0] got = results[r].data[t];
                    if (got !== exp_k0_fp && got !== exp_final_fp) begin
                        $display("  [FAIL] commit[%0d][t=%0d] = 0x%08X  (exp 0x%08X or 0x%08X)",
                                 r, t, got, exp_k0_fp, exp_final_fp);
                        ok = 0;
                    end
                end
                $display("  commit[%02d]: data[0]=0x%08X  wis=%0d  rd=%2d  uuid=%0d  %s",
                         r, results[r].data[0],
                         results[r].wis, results[r].rd, results[r].uuid,
                         (results[r].data[0] === exp_final_fp) ? "[final]" : "[k=0]");
            end

            if (ok) begin
                $display("[PASS] TC2_fp_path   k0=4.0  kfinal=8.0  (%0d×%0d tiles all correct)",
                         TCU_M_STEPS, TCU_N_STEPS);
                pass_cnt++;
            end else begin
                $display("[FAIL] TC2_fp_path");
                fail_cnt++;
            end

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // --- Summary ---
        $display("=== RESULT: %0d/%0d PASS ===", pass_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0) $display("[ALL PASS]");
        $finish;
    end

endmodule
