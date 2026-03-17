// Level 8 Testbench: VX_decode + VX_issue + VX_execute + VX_commit
//
// DUT boundary extended from L7 to include VX_decode, which takes raw 32-bit
// RISC-V instruction words and produces decode_t.
//
// RTL fix verified: VX_decode no longer references removed exp_a/exp_b fields;
// LDSCALE decode path now correctly sets tcu_op=TCU_OP_LDSCALE.
//
// Instruction encoding:
//   WMMA:    {7'h02, rs2, rs1, 3'h0, rd, 7'h0B}  funct7=7'h02
//   LDSCALE: {7'h06, rs2, rs1, 3'h0, rd, 7'h0B}  funct7=7'h06  funct7[2:0]=3'b110
//
// Test groups:
//   TC1: decode WMMA binary → verify decode_t fields (ex_type, tcu_op, fmt_s/d, used_rs)
//   TC2: decode LDSCALE binary → verify decode_t fields (tcu_op=LDSCALE, used_rs)
//   TC3: LDSCALE single-uop check (not expanded to 16, RTL fix verification)
//   TC4: WMMA → 16 commits, all data=0 (uop count)
//   TC5: LDSCALE(0,0)+WMMA (A=B=0, C=42) → all outputs=42
//   TC6: LDSCALE(scale_a=2)+WMMA (A=B=ones, C=0) → scale accumulation
//   TC7: LDSCALE(0,0)+WMMA (A=B=ones, C=-200) → negative accumulation

`include "VX_define.vh"

`timescale 1ns/1ps

import VX_gpu_pkg::*;
import VX_tcu_pkg::*;

module tb_decode;

    // =========================================================================
    // Clock / reset
    // =========================================================================
    logic clk = 0;
    logic reset;
    always #5 clk = ~clk;

    // =========================================================================
    // Derived parameters
    // =========================================================================
    localparam LG_N    = $clog2(TCU_N_STEPS);
    localparam LG_M    = $clog2(TCU_M_STEPS);
    localparam LG_K    = $clog2(TCU_K_STEPS);
    localparam LG_A_SB = $clog2(TCU_A_SUB_BLOCKS);
    localparam LG_B_SB = $clog2(TCU_B_SUB_BLOCKS);
    localparam TCU_NRA = (TCU_M_STEPS / TCU_A_SUB_BLOCKS) * TCU_K_STEPS;
    localparam TCU_NRC = TCU_M_STEPS * TCU_N_STEPS;

    // Scale register: integer x5
    localparam [NUM_REGS_BITS-1:0] SCALE_REG =
        make_reg_num(REG_TYPE_I, RV_REGS_BITS'(5));

    // RISC-V TCU base opcode (custom-0)
    localparam logic [6:0] TCU_OPCODE = 7'h0B;

    // =========================================================================
    // Interface instances
    // =========================================================================
    VX_fetch_if        fetch_if();
    VX_decode_sched_if decode_sched_if();       // VX_decode drives, TB ignores
    VX_decode_if       decode_if();             // VX_decode → VX_issue (observed)

    VX_writeback_if    issue_wb  [`ISSUE_WIDTH]();
    VX_writeback_if    commit_wb [`ISSUE_WIDTH]();
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
    // Writeback mux: preload_phase ? TB → VX_issue.wb : VX_commit → VX_issue.wb
    // =========================================================================
    logic       preload_phase = 1'b1;
    logic       tb_wb_valid_r = 1'b0;
    writeback_t tb_wb_data_r;

    for (genvar i = 0; i < `ISSUE_WIDTH; i++) begin : g_wb_mux
        assign issue_wb[i].valid = preload_phase ? tb_wb_valid_r    : commit_wb[i].valid;
        assign issue_wb[i].data  = preload_phase ? tb_wb_data_r     : commit_wb[i].data;
    end

    // =========================================================================
    // DUT: VX_decode  (NEW in Level 8)
    // =========================================================================
    VX_decode #(
        .INSTANCE_ID ("tb_decode_d")
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
    // Tie-offs
    // =========================================================================
    for (genvar i = 0; i < `NUM_LSU_BLOCKS; i++) begin : g_tie_lsu
        assign lsu_mem_if[i].req_ready = 1'b0;
        assign lsu_mem_if[i].rsp_valid = 1'b0;
        assign lsu_mem_if[i].rsp_data  = '0;
    end

    assign warp_ctl_if.dvstack_ptr = '0;
    assign sched_csr_if.cycles       = '0;
    assign sched_csr_if.active_warps = '0;
    assign sched_csr_if.thread_masks = '0;
    assign sched_csr_if.alm_empty    = '0;

    // =========================================================================
    // Counters and helpers
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

    // =========================================================================
    // Instruction encoding functions
    // =========================================================================
    // WMMA: funct7=7'h02, funct3=3'h0, opcode=TCU_OPCODE
    //   fmt_d embedded in rd[3:0], fmt_s embedded in rs1[3:0]
    //   VX_tcu_uops overrides actual register indices, so rs2/rs3 bits don't matter
    function automatic logic [31:0] encode_wmma (
        input logic [3:0] fmt_d,
        input logic [3:0] fmt_s
    );
        return {7'h02, 5'h0, {1'b0, fmt_s}, 3'h0, {1'b0, fmt_d}, TCU_OPCODE};
    endfunction

    // LDSCALE: funct7=7'h06 (funct7[2:0]=3'b110), funct3=3'h0, opcode=TCU_OPCODE
    //   scale_rs1[4:0] = source integer register holding {exp_b[3:0], exp_a[3:0]}
    //   rd = x1 (non-zero so wb=1; VX_commit fires commit_wb.valid; d=0 written to x1)
    function automatic logic [31:0] encode_ldscale (
        input logic [4:0] scale_rs1
    );
        return {7'h06, 5'h0, scale_rs1, 3'h0, 5'h1, TCU_OPCODE};
    endfunction

    // =========================================================================
    // preload_gpr: seed VX_operands register file via issue_wb (preload_phase=1)
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
        for (int m = 0; m < TCU_M_STEPS; m++) begin
            for (int k = 0; k < TCU_K_STEPS; k++) begin
                int off_a = ((m >> LG_A_SB) << LG_K) | k;
                preload_gpr(
                    make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RA) + RV_REGS_BITS'(off_a)),
                    a_val);
            end
        end
        for (int k = 0; k < TCU_K_STEPS; k++) begin
            for (int n = 0; n < TCU_N_STEPS; n++) begin
                int off_b = ((k << LG_N) | n) >> LG_B_SB;
                preload_gpr(
                    make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RB) + RV_REGS_BITS'(off_b)),
                    b_val);
            end
        end
        for (int m = 0; m < TCU_M_STEPS; m++) begin
            for (int n = 0; n < TCU_N_STEPS; n++) begin
                int off_c = (m << LG_N) | n;
                preload_gpr(
                    make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RC) + RV_REGS_BITS'(off_c)),
                    c_val);
            end
        end
    endtask

    // =========================================================================
    // send_fetch_sample: drive fetch_if with instr32, wait for acceptance,
    // sample decode_if.data at the accepted posedge (combinational decode output).
    // =========================================================================
    task automatic send_fetch_sample (
        input  logic [31:0] instr,
        output decode_t     sampled
    );
        @(posedge clk); #1;
        fetch_if.valid      = 1'b1;
        fetch_if.data.uuid  = next_uuid;
        fetch_if.data.wid   = '0;
        fetch_if.data.tmask = '1;
        fetch_if.data.PC    = '0;
        fetch_if.data.instr = instr;
        next_uuid = next_uuid + 1;
        @(posedge clk);
        while (!fetch_if.ready) begin
            @(posedge clk);
        end
        // At this posedge: fetch_if.ready=1, decode_if.valid=1
        // VX_elastic_buffer #(SIZE=0) is combinational → decode_if.data is valid now
        sampled = decode_if.data;
        #1;
        fetch_if.valid = 1'b0;
    endtask

    task automatic send_fetch (input logic [31:0] instr);
        decode_t ignored;
        send_fetch_sample(instr, ignored);
    endtask

    // =========================================================================
    // wait_commit / collect_wbs
    // =========================================================================
    task automatic wait_commit (output writeback_t res);
        int timeout_ctr;
        @(posedge clk);
        timeout_ctr = 0;
        while (!commit_wb[0].valid) begin
            timeout_ctr++;
            @(posedge clk);
        end
        res = commit_wb[0].data;
        // Yield one extra cycle so VX_scoreboard's always @(posedge clk) sees
        // writeback_fire=1 before any caller modifies preload_phase/issue_wb.
        @(posedge clk);
    endtask

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
    // Stimulus
    // =========================================================================
    initial begin
        // ---- Reset -----------------------------------------------------------
        reset          = 1'b1;
        fetch_if.valid = 1'b0;
        fetch_if.data  = '0;
        tb_wb_valid_r  = 1'b0;
        tb_wb_data_r   = '0;
        preload_phase  = 1'b1;
        repeat(4) @(posedge clk);
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;

        $display("=== Level 8: VX_decode + VX_issue + VX_execute + VX_commit ===");
        $display("  UOPS=%0d  M_STEPS=%0d  N_STEPS=%0d  K_STEPS=%0d",
                 TCU_UOPS, TCU_M_STEPS, TCU_N_STEPS, TCU_K_STEPS);
        $display("  TCU_OPCODE=0x%02h  WMMA funct7=0x02  LDSCALE funct7=0x06",
                 TCU_OPCODE);
        $display("------------------------------------------------------------");

        // ==================================================================
        // TC1: decode_wmma_fields
        //   Send WMMA binary → sample decode_if.data → verify decoded fields.
        //   Also drain the resulting 16 commits (A=B=C=0, all outputs=0).
        // ==================================================================
        begin : tc1
            decode_t     sampled;
            writeback_t  wresults[];
            writeback_t  dummy;
            bit          ok = 1;
            logic [3:0]  fmt_d = 4'(TCU_I32_ID);
            logic [3:0]  fmt_s = 4'(TCU_I8_ID);

            preload_tile_regs(32'd0, 32'd0, 32'd0);
            preload_gpr(SCALE_REG, 32'h7F7F);  // E8M0 neutral: exp_total=0

            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            // LDSCALE must precede WMMA; send with rd=x0, rs1=x5
            send_fetch(encode_ldscale(5'd5));
            wait_commit(dummy);
`endif
            // Send WMMA and capture decoded fields
            send_fetch_sample(encode_wmma(fmt_d, fmt_s), sampled);

            // Check ex_type
            if (sampled.ex_type !== EX_BITS'(EX_TCU)) begin
                $display("[FAIL] TC1_decode_wmma_fields  ex_type=0x%0h (exp EX_TCU=0x%0h)",
                         sampled.ex_type, EX_BITS'(EX_TCU));
                ok = 0;
            end
            // Check op_type
            if (sampled.op_type !== INST_OP_BITS'(INST_TCU_WMMA)) begin
                $display("[FAIL] TC1_decode_wmma_fields  op_type=0x%0h (exp INST_TCU_WMMA=0x%0h)",
                         sampled.op_type, INST_OP_BITS'(INST_TCU_WMMA));
                ok = 0;
            end
`ifdef EXT_AG_TCU_ENABLE
            // Check tcu_op = TCU_OP_WMMA (RTL fix: was stale exp_a/exp_b assign)
            if (sampled.op_args.tcu.tcu_op !== TCU_OP_WMMA) begin
                $display("[FAIL] TC1_decode_wmma_fields  tcu_op=0x%0h (exp TCU_OP_WMMA=0x%0h)",
                         sampled.op_args.tcu.tcu_op, TCU_OP_WMMA);
                ok = 0;
            end
`endif
            // Check fmt_s and fmt_d (embedded in rs1[3:0] and rd[3:0])
            if (sampled.op_args.tcu.fmt_s !== fmt_s) begin
                $display("[FAIL] TC1_decode_wmma_fields  fmt_s=0x%0h (exp 0x%0h)",
                         sampled.op_args.tcu.fmt_s, fmt_s);
                ok = 0;
            end
            if (sampled.op_args.tcu.fmt_d !== fmt_d) begin
                $display("[FAIL] TC1_decode_wmma_fields  fmt_d=0x%0h (exp 0x%0h)",
                         sampled.op_args.tcu.fmt_d, fmt_d);
                ok = 0;
            end
            // Check used_rs: rs1, rs2, rs3 all used for WMMA
            if (sampled.used_rs !== 3'b111) begin
                $display("[FAIL] TC1_decode_wmma_fields  used_rs=%03b (exp 111)",
                         sampled.used_rs);
                ok = 0;
            end

            // Drain the 16 WMMA commits (A=B=C=0 → data=0, no verification needed)
            collect_wbs(TCU_UOPS, wresults);

            if (ok) begin
                $display("[PASS] TC1_decode_wmma_fields      ex_type/op_type/tcu_op/fmt/used_rs correct");
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC2: decode_ldscale_fields
        //   Send LDSCALE binary → sample decode_if.data → verify:
        //     tcu_op = TCU_OP_LDSCALE
        //     used_rs[0]=1 (rs1 used), used_rs[2:1]=00 (rs2/rs3 not used)
        //   Drain the 1 LDSCALE commit.
        // ==================================================================
        begin : tc2
            decode_t    sampled;
            writeback_t dummy;
            bit         ok = 1;

            preload_gpr(SCALE_REG, 32'h7F7F);  // E8M0 neutral: exp_total=0
            preload_phase = 1'b0;
            @(posedge clk); #1;

            // Send LDSCALE and capture decoded fields
            send_fetch_sample(encode_ldscale(5'd5), sampled);

            // Check ex_type
            if (sampled.ex_type !== EX_BITS'(EX_TCU)) begin
                $display("[FAIL] TC2_decode_ldscale_fields  ex_type=0x%0h (exp EX_TCU)",
                         sampled.ex_type);
                ok = 0;
            end
`ifdef EXT_AG_TCU_ENABLE
            // Check tcu_op = TCU_OP_LDSCALE (RTL fix: new LDSCALE decode path)
            if (sampled.op_args.tcu.tcu_op !== TCU_OP_LDSCALE) begin
                $display("[FAIL] TC2_decode_ldscale_fields  tcu_op=0x%0h (exp TCU_OP_LDSCALE=0x%0h)",
                         sampled.op_args.tcu.tcu_op, TCU_OP_LDSCALE);
                ok = 0;
            end
`endif
            // Check rs1 is used, rs2/rs3 are not
            if (!sampled.used_rs[0]) begin
                $display("[FAIL] TC2_decode_ldscale_fields  used_rs[0]=0 (rs1 should be used)");
                ok = 0;
            end
            if (sampled.used_rs[2] || sampled.used_rs[1]) begin
                $display("[FAIL] TC2_decode_ldscale_fields  used_rs[2:1]=%02b (exp 00: rs2/rs3 unused)",
                         sampled.used_rs[2:1]);
                ok = 0;
            end

            // Drain the 1 LDSCALE commit
            wait_commit(dummy);

            if (ok) begin
                $display("[PASS] TC2_decode_ldscale_fields   tcu_op=LDSCALE, rs1-only used");
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC3: LDSCALE single-uop check (RTL fix: uop_sequencer does not expand)
        //   Send LDSCALE → expect exactly 1 commit, no extra commits after.
        // ==================================================================
        begin : tc3
            writeback_t ld_res;
            bit ok = 1;

            preload_gpr(SCALE_REG, 32'h7F7F);  // E8M0 neutral: exp_total=0
            preload_phase = 1'b0;
            @(posedge clk); #1;

            send_fetch(encode_ldscale(5'd5));
            wait_commit(ld_res);
            // TC3 goal: verify uop count=1 (not 16). Data is undefined for LDSCALE
            // (rd=x1 is a TB hack to force a writeback; LDSCALE should use rd=x0).

            begin : tc3_extra
                int extra = 0;
                repeat (10) begin
                    @(posedge clk);
                    if (commit_wb[0].valid) extra++;
                end
                if (extra > 0) begin
                    $display("[FAIL] TC3_ldscale_single_uop  %0d extra commits (exp 0) — LDSCALE was expanded!",
                             extra);
                    ok = 0;
                end
            end

            if (ok) begin
                $display("[PASS] TC3_ldscale_single_uop      1 commit, no expansion (RTL fix OK)");
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC4: WMMA uop count check
        //   A=B=C=0 → all outputs=0, expect exactly TCU_UOPS commits.
        // ==================================================================
        begin : tc4
            writeback_t dummy;
            writeback_t results[];
            bit ok = 1;

            preload_tile_regs(32'd0, 32'd0, 32'd0);
            preload_gpr(SCALE_REG, 32'h7F7F);  // E8M0 neutral: exp_total=0
            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            send_fetch(encode_ldscale(5'd5));
            wait_commit(dummy);
`endif
            send_fetch(encode_wmma(4'(TCU_I32_ID), 4'(TCU_I8_ID)));
            collect_wbs(TCU_UOPS, results);

            for (int r = 0; r < TCU_UOPS; r++) begin
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    if (results[r].data[t] !== 32'd0) begin
                        $display("[FAIL] TC4_wmma_uop_count  commit[%0d][t=%0d]=0x%0h (exp 0)",
                                 r, t, results[r].data[t]);
                        ok = 0;
                    end
                end
            end

            if (ok) begin
                $display("[PASS] TC4_wmma_uop_count          %0d commits, all data=0", TCU_UOPS);
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC5: LDSCALE(0,0) + WMMA  (A=B=0, C=42)
        //   dot=0 per tile → all outputs = 42.
        // ==================================================================
        begin : tc5
            writeback_t dummy;
            writeback_t results[];
            bit ok = 1;

            preload_tile_regs(32'd0, 32'd0, 32'd42);
            preload_gpr(SCALE_REG, 32'h7F7F);  // E8M0 neutral: exp_total=0
            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            send_fetch(encode_ldscale(5'd5));
            wait_commit(dummy);
`endif
            send_fetch(encode_wmma(4'(TCU_I32_ID), 4'(TCU_I8_ID)));
            collect_wbs(TCU_UOPS, results);

            for (int r = 0; r < TCU_UOPS; r++) begin
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    if ($signed(results[r].data[t]) !== 32'sd42) begin
                        $display("[FAIL] TC5_wmma_passthrough  commit[%0d][t=%0d]=%0d (exp 42)",
                                 r, t, $signed(results[r].data[t]));
                        ok = 0;
                    end
                end
            end

            if (ok) begin
                $display("[PASS] TC5_wmma_passthrough        all %0d outputs = 42", TCU_UOPS);
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC6: LDSCALE(scale_a=2, scale_b=0) + WMMA  (A=B=ones, C=0)
        //   dot_per_uop = TC_K * 4 = 8
        //   exp_total = 2 → shifted = 8 << 2 = 32
        //   k=0: 32 + 0 = 32    k=1 (final): 32 + 32 = 64
        // ==================================================================
        begin : tc6
            writeback_t dummy;
            writeback_t results[];
            bit ok = 1;
            int dot_per_uop = TCU_TC_K * 4;
            int exp_shifted = dot_per_uop <<< 2;
            int exp_k0      = exp_shifted;
            int exp_final   = exp_shifted + exp_k0;

            preload_tile_regs(32'h01010101, 32'h01010101, 32'd0);
            preload_gpr(SCALE_REG, 32'h7F81);  // E8M0: scale_a=129(=127+2), scale_b=127 → exp_total=2
            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            send_fetch(encode_ldscale(5'd5));
            wait_commit(dummy);
`endif
            send_fetch(encode_wmma(4'(TCU_I32_ID), 4'(TCU_I8_ID)));
            collect_wbs(TCU_UOPS, results);

            begin : tc6_check
                int final_cnt = 0;
                for (int r = 0; r < TCU_UOPS; r++) begin
                    for (int t = 0; t < `SIMD_WIDTH; t++) begin
                        logic signed [31:0] got = $signed(results[r].data[t]);
                        if (got !== 32'(exp_k0) && got !== 32'(exp_final)) begin
                            $display("[FAIL] TC6_scale_accumulation  commit[%0d][t=%0d]=%0d (exp %0d or %0d)",
                                     r, t, got, exp_k0, exp_final);
                            ok = 0;
                        end
                    end
                    if ($signed(results[r].data[0]) === 32'(exp_final))
                        final_cnt++;
                end
                if (final_cnt !== TCU_NRC) begin
                    $display("[FAIL] TC6_scale_accumulation  final_cnt=%0d (exp %0d=TCU_NRC)",
                             final_cnt, TCU_NRC);
                    ok = 0;
                end
            end

            if (ok) begin
                $display("[PASS] TC6_scale_accumulation      k0=%0d kfinal=%0d, %0d tiles",
                         exp_k0, exp_final, TCU_NRC);
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC7: LDSCALE(0,0) + WMMA  (A=B=ones, C=-200)
        //   dot_per_uop=8, exp_total=0 → shifted=8
        //   k=0: 8 + (-200) = -192    k=1 (final): 8 + (-192) = -184
        // ==================================================================
        begin : tc7
            writeback_t dummy;
            writeback_t results[];
            bit ok = 1;
            int c_init      = -200;
            int dot_per_uop = TCU_TC_K * 4;
            int exp_k0      = dot_per_uop + c_init;
            int exp_final   = dot_per_uop + exp_k0;

            preload_tile_regs(32'h01010101, 32'h01010101, 32'(signed'(-200)));
            preload_gpr(SCALE_REG, 32'h7F7F);  // E8M0 neutral: exp_total=0
            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            send_fetch(encode_ldscale(5'd5));
            wait_commit(dummy);
`endif
            send_fetch(encode_wmma(4'(TCU_I32_ID), 4'(TCU_I8_ID)));
            collect_wbs(TCU_UOPS, results);

            for (int r = 0; r < TCU_UOPS; r++) begin
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    logic signed [31:0] got = $signed(results[r].data[t]);
                    if (got !== 32'(exp_k0) && got !== 32'(exp_final)) begin
                        $display("[FAIL] TC7_neg_accumulator  commit[%0d][t=%0d]=%0d (exp %0d or %0d)",
                                 r, t, got, exp_k0, exp_final);
                        ok = 0;
                    end
                end
            end

            if (ok) begin
                $display("[PASS] TC7_neg_accumulator         k0=%0d kfinal=%0d (correct)",
                         exp_k0, exp_final);
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // Summary
        // ==================================================================
        $display("------------------------------------------------------------");
        $display("Results: %0d PASS / %0d FAIL  (total %0d)",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");
        $display("============================================================");
        $finish;
    end

endmodule
