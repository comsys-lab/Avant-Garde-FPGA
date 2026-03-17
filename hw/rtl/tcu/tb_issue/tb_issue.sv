// Level 7 Testbench: VX_issue + VX_execute + VX_commit
//
// DUT: VX_issue (ibuffer → uop_sequencer → scoreboard → operands → dispatch)
//      + VX_execute + VX_commit
//
// New vs Level 6:
//   1. RTL fix: VX_uop_sequencer excludes LDSCALE from uop expansion (TC1 verifies)
//   2. WMMA decode_t flows through full issue pipeline (TC2 verifies uop count)
//   3. GPR register file preloaded via writeback_if before execution
//   4. K-accumulation via scoreboard serialization (TC3-TC5 verify functional results)
//
// Writeback mux:
//   preload_phase=1 → TB drives issue_wb (seeds register file)
//   preload_phase=0 → VX_commit drives issue_wb (K-accumulation feedback)
//
// Test groups:
//   TC1: LDSCALE → 1 commit (not UOPS; RTL fix verification)
//   TC2: WMMA → UOPS=16 commits, all data=0 (A=B=C=0)
//   TC3: LDSCALE(0,0)+WMMA (A=B=0, C=42) → all UOPS outputs = 42
//   TC4: LDSCALE(scale_a=2)+WMMA (A=B=ones, C=0) → accumulated tiles correct
//   TC5: LDSCALE(0,0)+WMMA (A=B=ones, C=-200) → k0=-192, kfinal=-184

`include "VX_define.vh"

`timescale 1ns/1ps

import VX_gpu_pkg::*;
import VX_tcu_pkg::*;

module tb_issue;

    // =========================================================================
    // Clock / reset
    // =========================================================================
    logic clk = 0;
    logic reset;
    always #5 clk = ~clk;

    // =========================================================================
    // Derived parameters (mirror VX_tcu_uops counter logic for reference model)
    // =========================================================================
    localparam LG_N    = $clog2(TCU_N_STEPS);
    localparam LG_M    = $clog2(TCU_M_STEPS);
    localparam LG_K    = $clog2(TCU_K_STEPS);
    localparam LG_A_SB = $clog2(TCU_A_SUB_BLOCKS);
    localparam LG_B_SB = $clog2(TCU_B_SUB_BLOCKS);
    // Number of unique tile registers accessed by one WMMA
    localparam TCU_NRA = (TCU_M_STEPS / TCU_A_SUB_BLOCKS) * TCU_K_STEPS;
    localparam TCU_NRC = TCU_M_STEPS * TCU_N_STEPS;  // = M_STEPS * N_STEPS

    // Scale value register: integer x5 (arbitrary choice)
    localparam [NUM_REGS_BITS-1:0] SCALE_REG =
        make_reg_num(REG_TYPE_I, RV_REGS_BITS'(5));

    // =========================================================================
    // Interface instances
    // =========================================================================
    VX_decode_if       decode_if();
    VX_writeback_if    issue_wb  [`ISSUE_WIDTH]();  // → VX_issue.writeback_if
    VX_writeback_if    commit_wb [`ISSUE_WIDTH]();  // VX_commit output → here
    VX_dispatch_if     issue_dispatch [NUM_EX_UNITS * `ISSUE_WIDTH]();
    VX_commit_if       commit_mid     [NUM_EX_UNITS * `ISSUE_WIDTH]();
    VX_issue_sched_if  issue_sched_if [`ISSUE_WIDTH]();
    VX_branch_ctl_if   branch_ctl_if  [`NUM_ALU_BLOCKS]();
    VX_warp_ctl_if     warp_ctl_if();
    VX_commit_csr_if   commit_csr_if();
    VX_commit_sched_if commit_sched_if();
    VX_sched_csr_if    sched_csr_if();
    VX_lsu_mem_if #(
        .NUM_LANES (`NUM_LSU_LANES),
        .DATA_SIZE (4),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) lsu_mem_if[`NUM_LSU_BLOCKS]();

    // =========================================================================
    // Writeback mux: preload_phase ? TB_preload : VX_commit_output
    // VX_writeback_if is ack-free (valid+data only, no ready).
    // When preload_phase=1: TB's tb_wb_valid_r/tb_wb_data_r drives issue_wb.
    // When preload_phase=0: VX_commit's commit_wb drives issue_wb, enabling
    //   K-accumulation (each k=0 writeback feeds into k=1 as rs3).
    // =========================================================================
    logic       preload_phase   = 1'b1;
    logic       tb_wb_valid_r   = 1'b0;
    writeback_t tb_wb_data_r;

    for (genvar i = 0; i < `ISSUE_WIDTH; i++) begin : g_wb_mux
        assign issue_wb[i].valid = preload_phase ? tb_wb_valid_r    : commit_wb[i].valid;
        assign issue_wb[i].data  = preload_phase ? tb_wb_data_r     : commit_wb[i].data;
    end

    // =========================================================================
    // DUT: VX_issue
    // =========================================================================
    VX_issue #(
        .INSTANCE_ID ("tb_issue")
    ) issue (
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
        .INSTANCE_ID ("tb_execute"),
        .CORE_ID     (0)
    ) execute (
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
        .INSTANCE_ID ("tb_commit")
    ) commit (
        .clk             (clk),
        .reset           (reset),
        .commit_if       (commit_mid),
        .writeback_if    (commit_wb),
        .commit_csr_if   (commit_csr_if),
        .commit_sched_if (commit_sched_if)
    );

    // =========================================================================
    // Tie-offs: LSU memory interface (LSU dispatch always valid=0)
    // =========================================================================
    for (genvar i = 0; i < `NUM_LSU_BLOCKS; i++) begin : g_tie_lsu
        assign lsu_mem_if[i].req_ready = 1'b0;
        assign lsu_mem_if[i].rsp_valid = 1'b0;
        assign lsu_mem_if[i].rsp_data  = '0;
    end

    // Tie-off: warp_ctl_if (SFU output, SFU never dispatched)
    assign warp_ctl_if.dvstack_ptr = '0;

    // Tie-off: sched_csr_if (SFU CSR reads return 0)
    assign sched_csr_if.cycles       = '0;
    assign sched_csr_if.active_warps = '0;
    assign sched_csr_if.thread_masks = '0;
    assign sched_csr_if.alm_empty    = '0;

    // =========================================================================
    // Counters
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;

    // =========================================================================
    // Helper: fill all threads with same 32-bit word
    // =========================================================================
    function automatic logic [`SIMD_WIDTH-1:0][`XLEN-1:0] fill (
        input logic [`XLEN-1:0] w
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] r;
        for (int i = 0; i < `SIMD_WIDTH; i++) r[i] = w;
        return r;
    endfunction

    // =========================================================================
    // UUID counter
    // =========================================================================
    logic [UUID_WIDTH-1:0] next_uuid = UUID_WIDTH'(1);

    // =========================================================================
    // preload_gpr: seed the VX_operands register file via issue_wb (preload_phase=1).
    // writeback_if is ack-free: one-cycle pulse suffices to update the register.
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

    // =========================================================================
    // preload_tile_regs: seed A, B, C tile registers
    // =========================================================================
    task automatic preload_tile_regs (
        input logic [`XLEN-1:0] a_val,
        input logic [`XLEN-1:0] b_val,
        input logic [`XLEN-1:0] c_val
    );
        // A tile: RA + off_a for all (m,k)
        for (int m = 0; m < TCU_M_STEPS; m++) begin
            for (int k = 0; k < TCU_K_STEPS; k++) begin
                int off_a;
                off_a = ((m >> LG_A_SB) << LG_K) | k;
                preload_gpr(
                    make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RA) + RV_REGS_BITS'(off_a)),
                    a_val);
            end
        end
        // B tile: RB + off_b for all (k,n)
        for (int k = 0; k < TCU_K_STEPS; k++) begin
            for (int n = 0; n < TCU_N_STEPS; n++) begin
                int off_b;
                off_b = ((k << LG_N) | n) >> LG_B_SB;
                preload_gpr(
                    make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RB) + RV_REGS_BITS'(off_b)),
                    b_val);
            end
        end
        // C tile: RC + off_c for all (m,n)
        for (int m = 0; m < TCU_M_STEPS; m++) begin
            for (int n = 0; n < TCU_N_STEPS; n++) begin
                int off_c;
                off_c = (m << LG_N) | n;
                preload_gpr(
                    make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RC) + RV_REGS_BITS'(off_c)),
                    c_val);
            end
        end
    endtask

    // =========================================================================
    // send_decode: drive decode_if with one decode_t, wait for VX_ibuffer ready.
    // Timing follows L6 fire_tcu pattern: align to post-edge, assert, wait, deassert.
    // =========================================================================
    task automatic send_decode (input decode_t pkt);
        @(posedge clk); #1;
        decode_if.valid = 1'b1;
        decode_if.data  = pkt;
        @(posedge clk);
        while (!decode_if.ready) @(posedge clk);
        #1;
        decode_if.valid = 1'b0;
    endtask

    // =========================================================================
    // Build LDSCALE decode_t
    // rs1 = SCALE_REG (preloaded with packed {scale_b[7:0], scale_a[7:0]})
    // E8M0: neutral = 8'd127; exp_total = scale_a + scale_b - 254
    // =========================================================================
    function automatic decode_t build_ldscale (input logic [UUID_WIDTH-1:0] uuid);
        decode_t d;
        d               = '0;
        d.uuid          = uuid;
        d.wid           = '0;
        d.tmask         = '1;
        d.ex_type       = EX_BITS'(EX_TCU);
        d.op_type       = INST_OP_BITS'(INST_TCU_WMMA);
`ifdef EXT_AG_TCU_ENABLE
        d.op_args.tcu.tcu_op = TCU_OP_LDSCALE;
`endif
        d.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        d.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        d.wb            = 1'b1;
        d.used_rs       = 3'b001;    // only rs1 used
        d.rd            = '0;        // writes d=0 to rd=x0
        d.rs1           = SCALE_REG; // register holding packed scale
        d.rs2           = '0;
        d.rs3           = '0;
        return d;
    endfunction

    // =========================================================================
    // Build WMMA decode_t
    // rs1/rs2/rs3/rd will be overridden by VX_tcu_uops for each microop.
    // We set the base tile register indices as hints (not used after uop expansion).
    // =========================================================================
    function automatic decode_t build_wmma (input logic [UUID_WIDTH-1:0] uuid);
        decode_t d;
        d               = '0;
        d.uuid          = uuid;
        d.wid           = '0;
        d.tmask         = '1;
        d.ex_type       = EX_BITS'(EX_TCU);
        d.op_type       = INST_OP_BITS'(INST_TCU_WMMA);
`ifdef EXT_AG_TCU_ENABLE
        d.op_args.tcu.tcu_op = TCU_OP_WMMA;
`endif
        d.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        d.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        d.wb            = 1'b1;
        d.used_rs       = 3'b111;    // rs1,rs2,rs3 all used
        d.rd            = make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RC));
        d.rs1           = make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RA));
        d.rs2           = make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RB));
        d.rs3           = make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RC));
        return d;
    endfunction

    // =========================================================================
    // wait_commit: spin until commit_wb[0].valid rises, return data.
    // =========================================================================
    task automatic wait_commit (output writeback_t res);
        @(posedge clk);
        while (!commit_wb[0].valid) @(posedge clk);
        res = commit_wb[0].data;
    endtask

    // =========================================================================
    // collect_wbs: collect `count` consecutive valid commits from commit_wb[0].
    // =========================================================================
    task automatic collect_wbs (
        input  int           count,
        output writeback_t   results []
    );
        results = new[count];
        for (int i = 0; i < count; i++) begin
            @(posedge clk);
            while (!commit_wb[0].valid) @(posedge clk);
            results[i] = commit_wb[0].data;
        end
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin
        // ---- Reset -----------------------------------------------------------
        reset           = 1'b1;
        decode_if.valid = 1'b0;
        decode_if.data  = '0;
        tb_wb_valid_r   = 1'b0;
        tb_wb_data_r    = '0;
        preload_phase   = 1'b1;
        repeat(4) @(posedge clk);
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;

        $display("=== Level 7: VX_issue + VX_execute + VX_commit Testbench ===");
        $display("  UOPS=%0d  M_STEPS=%0d  N_STEPS=%0d  K_STEPS=%0d",
                 TCU_UOPS, TCU_M_STEPS, TCU_N_STEPS, TCU_K_STEPS);
        $display("  TC_M=%0d  TC_N=%0d  TC_K=%0d",
                 TCU_TC_M, TCU_TC_N, TCU_TC_K);
        $display("  NRA=%0d  NRB=%0d  NRC=%0d",
                 TCU_NRA, TCU_NRB, TCU_NRC);
        $display("  RA=%0d  RB=%0d  RC=%0d",
                 TCU_RA, TCU_RB, TCU_RC);
        $display("--------------------------------------------------");

        // ==================================================================
        // TC1: LDSCALE single-uop check (RTL fix verification)
        //   Send LDSCALE decode_t → expect exactly 1 commit (not UOPS=16).
        //   SCALE_REG preloaded with 0 → scale_a=0, scale_b=0, data=0.
        // ==================================================================
        begin : tc1
            writeback_t ld_res;
            bit ok = 1;

            // Preload SCALE_REG = {16'b0, 8'd127, 8'd127} (E8M0 neutral: exp_total=0)
            preload_gpr(SCALE_REG, 32'h7F7F);

            // Switch to exec phase
            preload_phase = 1'b0;
            @(posedge clk); #1;

            send_decode(build_ldscale(next_uuid++));

            // Expect exactly 1 commit with data=0
            wait_commit(ld_res);

            for (int t = 0; t < `SIMD_WIDTH; t++) begin
                if (ld_res.data[t] !== '0) begin
                    $display("[FAIL] TC1_ldscale_single_uop  [t=%0d] data=0x%0h (exp 0)",
                             t, ld_res.data[t]);
                    ok = 0;
                end
            end

            // Wait 10 more cycles and verify no extra commit arrives
            // (if uop_sequencer mistakenly expanded LDSCALE, extra commits would arrive)
            begin : tc1_extra_check
                int extra = 0;
                repeat (10) begin
                    @(posedge clk);
                    if (commit_wb[0].valid) extra++;
                end
                if (extra > 0) begin
                    $display("[FAIL] TC1_ldscale_single_uop  %0d extra commits (exp 0) — LDSCALE was expanded!",
                             extra);
                    ok = 0;
                end
            end

            if (ok) begin
                $display("[PASS] TC1_ldscale_single_uop      1 commit, data=0 (RTL fix OK)");
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC2: WMMA uop count check
        //   A=B=C=0 → all dot products = 0, all outputs = 0.
        //   Verify exactly TCU_UOPS=16 commits arrive.
        // ==================================================================
        begin : tc2
            writeback_t dummy;
            writeback_t results[];
            bit ok = 1;

            // Preload all tile regs = 0
            preload_tile_regs(32'd0, 32'd0, 32'd0);
            preload_gpr(SCALE_REG, 32'h7F7F);  // E8M0 neutral: exp_total=0

            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            // LDSCALE must precede WMMA in Avant-Garde TCU
            send_decode(build_ldscale(next_uuid++));
            wait_commit(dummy);    // drain 1 LDSCALE commit
`endif

            send_decode(build_wmma(next_uuid++));
            collect_wbs(TCU_UOPS, results);

            // Verify all UOPS outputs = 0
            for (int r = 0; r < TCU_UOPS; r++) begin
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    if (results[r].data[t] !== 32'd0) begin
                        $display("[FAIL] TC2_wmma_uop_count  commit[%0d][t=%0d] data=0x%0h (exp 0)",
                                 r, t, results[r].data[t]);
                        ok = 0;
                    end
                end
            end

            if (ok) begin
                $display("[PASS] TC2_wmma_uop_count          %0d commits, all data=0", TCU_UOPS);
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC3: LDSCALE(0,0) + WMMA  (A=B=0, C=42)
        //   dot=0 per tile, so all outputs = 42 (C passes through unchanged).
        // ==================================================================
        begin : tc3
            writeback_t dummy;
            writeback_t results[];
            bit ok = 1;

            preload_tile_regs(32'd0, 32'd0, 32'd42);
            preload_gpr(SCALE_REG, 32'h7F7F);  // E8M0 neutral: exp_total=0

            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            send_decode(build_ldscale(next_uuid++));
            wait_commit(dummy);
`endif

            send_decode(build_wmma(next_uuid++));
            collect_wbs(TCU_UOPS, results);

            for (int r = 0; r < TCU_UOPS; r++) begin
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    if ($signed(results[r].data[t]) !== 32'sd42) begin
                        $display("[FAIL] TC3_wmma_passthrough  commit[%0d][t=%0d] got=%0d (exp 42)",
                                 r, t, $signed(results[r].data[t]));
                        ok = 0;
                    end
                end
            end

            if (ok) begin
                $display("[PASS] TC3_wmma_passthrough        all %0d outputs = 42", TCU_UOPS);
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC4: LDSCALE(scale_a=2, scale_b=0) + WMMA  (A=B=ones, C=0)
        //   dot_per_uop = TC_K * 4 * 1 * 1 = 8
        //   exp_total = 2 → shifted = 8 << 2 = 32
        //   k=0 result  = shifted + 0 = 32  (C_init=0)
        //   k=1 result  = shifted + 32 = 64 (accumulated via writeback_if mux)
        //   Final per tile = K_STEPS * 32 = 64
        //   Verify each commit is 32 (k=0) or 64 (k=1),
        //   and exactly TCU_NRC commits have the final value 64.
        // ==================================================================
        begin : tc4
            writeback_t dummy;
            writeback_t results[];
            bit ok = 1;
            int dot_per_uop;
            int exp_shifted;  // dot << exp_total
            int exp_k0;       // k=0 tile result
            int exp_final;    // k=1 (final accumulated) tile result

            dot_per_uop = TCU_TC_K * 4;       // 8 for NT=4
            exp_shifted = dot_per_uop <<< 2;  // 8 << 2 = 32
            exp_k0      = exp_shifted + 0;    // = 32 (C_init=0)
            exp_final   = exp_shifted + exp_k0; // = 64 (k=1 adds another shifted)

            preload_tile_regs(32'h01010101, 32'h01010101, 32'd0);
            preload_gpr(SCALE_REG, 32'h7F81);  // E8M0: scale_a=129(=127+2), scale_b=127 → exp_total=2

            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            send_decode(build_ldscale(next_uuid++));
            wait_commit(dummy);
`endif

            send_decode(build_wmma(next_uuid++));
            collect_wbs(TCU_UOPS, results);

            begin : tc4_check
                int final_cnt = 0;
                for (int r = 0; r < TCU_UOPS; r++) begin
                    for (int t = 0; t < `SIMD_WIDTH; t++) begin
                        logic signed [31:0] got = $signed(results[r].data[t]);
                        if (got !== 32'(exp_k0) && got !== 32'(exp_final)) begin
                            $display("[FAIL] TC4_scale_accumulation  commit[%0d][t=%0d] got=%0d (exp %0d or %0d)",
                                     r, t, got, exp_k0, exp_final);
                            ok = 0;
                        end
                    end
                    // Count commits that have the final accumulated value
                    if ($signed(results[r].data[0]) === 32'(exp_final))
                        final_cnt++;
                end
                // Exactly TCU_NRC = M_STEPS*N_STEPS tiles should have the final value
                if (final_cnt !== TCU_NRC) begin
                    $display("[FAIL] TC4_scale_accumulation  final_cnt=%0d (exp %0d = TCU_NRC)",
                             final_cnt, TCU_NRC);
                    ok = 0;
                end
            end

            if (ok) begin
                $display("[PASS] TC4_scale_accumulation      k0=%0d kfinal=%0d, %0d tiles finalized",
                         exp_k0, exp_final, TCU_NRC);
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC5: LDSCALE(0,0) + WMMA  (A=B=ones, C=-200)
        //   dot_per_uop = 8, exp_total = 0 → shifted = 8
        //   k=0 result  = 8 + (-200) = -192
        //   k=1 result  = 8 + (-192) = -184  (final)
        //   Verify each commit is -192 (k=0) or -184 (k=1).
        // ==================================================================
        begin : tc5
            writeback_t dummy;
            writeback_t results[];
            bit ok = 1;
            int c_init      = -200;
            int dot_per_uop = TCU_TC_K * 4;  // 8 for NT=4
            int exp_k0      = dot_per_uop + c_init;   // 8 + (-200) = -192
            int exp_final   = dot_per_uop + exp_k0;   // 8 + (-192) = -184

            preload_tile_regs(32'h01010101, 32'h01010101, 32'(signed'(-200)));
            preload_gpr(SCALE_REG, 32'h7F7F);  // E8M0 neutral: exp_total=0

            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            send_decode(build_ldscale(next_uuid++));
            wait_commit(dummy);
`endif

            send_decode(build_wmma(next_uuid++));
            collect_wbs(TCU_UOPS, results);

            for (int r = 0; r < TCU_UOPS; r++) begin
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    logic signed [31:0] got = $signed(results[r].data[t]);
                    if (got !== 32'(exp_k0) && got !== 32'(exp_final)) begin
                        $display("[FAIL] TC5_neg_accumulator  commit[%0d][t=%0d] got=%0d (exp %0d or %0d)",
                                 r, t, got, exp_k0, exp_final);
                        ok = 0;
                    end
                end
            end

            if (ok) begin
                $display("[PASS] TC5_neg_accumulator         k0=%0d kfinal=%0d (correct)",
                         exp_k0, exp_final);
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // Summary
        // ==================================================================
        $display("--------------------------------------------------");
        $display("Results: %0d PASS / %0d FAIL  (total %0d)",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");
        $display("==================================================");
        $finish;
    end

endmodule
