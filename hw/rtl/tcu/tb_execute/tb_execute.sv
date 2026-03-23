// Level 6 Testbench: VX_execute + VX_commit
//
// DUT: VX_execute (all execution units) + VX_commit (priority arbiter)
// Output monitored: VX_commit.writeback_if
//
// Phase 10 essential test cases:
//   Group A (TC1,TC3-TC5): WMMA regression — INT8 → FP32 output (ref_d_fp32 model)
//   Group B (TC6-TC7): ALU ADD standalone (format-agnostic)
//   Group C (TC8-TC10): Concurrent ALU+TCU, priority arbitration, metadata passthrough
//
// TC2 (pos_sat with Phase 8A MX9 flatten) removed — behavior changed in Phase 10.

`include "VX_define.vh"

import VX_gpu_pkg::*;
import VX_tcu_pkg::*;

module tb_execute;

    // =========================================================================
    // Clock / reset
    // =========================================================================
    logic clk = 0;
    logic reset;
    always #5 clk = ~clk;

    // =========================================================================
    // Interface instances
    // =========================================================================
    VX_dispatch_if     dispatch_if [NUM_EX_UNITS * `ISSUE_WIDTH]();
    VX_commit_if       commit_mid  [NUM_EX_UNITS * `ISSUE_WIDTH]();
    VX_writeback_if    writeback_if[`ISSUE_WIDTH]();
    VX_branch_ctl_if   branch_ctl_if[`NUM_ALU_BLOCKS]();
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
    // DUT: VX_execute
    // =========================================================================
    base_dcrs_t base_dcrs_tie;
    assign base_dcrs_tie = '0;

    VX_execute #(
        .INSTANCE_ID ("tb_execute"),
        .CORE_ID     (0)
    ) execute (
        .clk            (clk),
        .reset          (reset),
        .base_dcrs      (base_dcrs_tie),
        .lsu_mem_if     (lsu_mem_if),
        .dispatch_if    (dispatch_if),
        .commit_if      (commit_mid),
        .sched_csr_if   (sched_csr_if),
        .branch_ctl_if  (branch_ctl_if),
        .warp_ctl_if    (warp_ctl_if),
        .commit_csr_if  (commit_csr_if)
    );

    // =========================================================================
    // DUT: VX_commit
    // =========================================================================
    VX_commit #(
        .INSTANCE_ID ("tb_commit")
    ) commit (
        .clk              (clk),
        .reset            (reset),
        .commit_if        (commit_mid),
        .writeback_if     (writeback_if),
        .commit_csr_if    (commit_csr_if),
        .commit_sched_if  (commit_sched_if)
    );

    // =========================================================================
    // Tie-offs: unused dispatch slots (LSU, SFU never dispatched)
    // =========================================================================
    for (genvar i = 0; i < NUM_EX_UNITS * `ISSUE_WIDTH; i++) begin : g_tie_dispatch
        if (i != EX_ALU * `ISSUE_WIDTH && i != EX_TCU * `ISSUE_WIDTH) begin
            assign dispatch_if[i].valid = 1'b0;
            assign dispatch_if[i].data  = '0;
        end
    end

    // =========================================================================
    // Tie-offs: LSU memory interface (req.ready=0, rsp.valid=0)
    // LSU dispatch never fires, so no memory requests are generated.
    // =========================================================================
    for (genvar i = 0; i < `NUM_LSU_BLOCKS; i++) begin : g_tie_lsu
        assign lsu_mem_if[i].req_ready = 1'b0;
        assign lsu_mem_if[i].rsp_valid = 1'b0;
        assign lsu_mem_if[i].rsp_data  = '0;
    end

    // =========================================================================
    // Tie-offs: branch control (ALU output, no ready; just consume)
    // =========================================================================
    // branch_ctl_if is push-only (no ready), driven by VX_alu_unit.
    // Nothing to tie off — just ignore the outputs.

    // =========================================================================
    // Tie-offs: warp control (SFU output)
    //   dvstack_ptr is the one field our "TB-as-scheduler" must drive.
    //   SFU reads dvstack_ptr when it processes warp control ops (never fired).
    // =========================================================================
    assign warp_ctl_if.dvstack_ptr = '0;

    // =========================================================================
    // Tie-offs: sched_csr_if (SFU reads CSR counters from scheduler)
    //   All fields driven to 0 — SFU CSR reads return 0 (SFU never dispatched).
    // =========================================================================
    assign sched_csr_if.cycles       = '0;
    assign sched_csr_if.active_warps = '0;
    assign sched_csr_if.thread_masks = '0;
    assign sched_csr_if.alm_empty    = '0;

    // =========================================================================
    // Tie-off: commit_sched_if (VX_commit output → scheduler, just consume)
    // =========================================================================
    // commit_sched_if.committed_warps is driven by VX_commit; we ignore it.

    // =========================================================================
    // Counters
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;

    // =========================================================================
    // FP32 bit ↔ real conversion helpers (avoids shortreal/Verilator issues)
    // =========================================================================
    // Convert IEEE 754 single-precision 32-bit pattern to real (double).
    function automatic real fp32_to_real (input logic [31:0] bits);
        logic        sign;
        int          exp;
        logic [22:0] mant;
        real         r;
        sign = bits[31];
        exp  = int'(bits[30:23]) - 127;
        mant = bits[22:0];
        r = 1.0;
        for (int b = 22; b >= 0; b--)
            if (mant[b]) r += 2.0 ** (b - 23);  // bit 22 = 2^-1, bit 0 = 2^-23
        r = r * (2.0 ** exp);
        return sign ? -r : r;
    endfunction

    // Convert real to IEEE 754 single-precision 32-bit pattern (normalized only).
    function automatic logic [31:0] real_to_fp32 (input real r);
        logic        sign;
        real         r_abs;
        int          exp;
        real         mant;
        logic [22:0] mant_bits;
        if (r == 0.0) return 32'h0;
        sign  = (r < 0.0) ? 1'b1 : 1'b0;
        r_abs = sign ? -r : r;
        exp   = 0;
        while (r_abs >= 2.0) begin r_abs /= 2.0; exp++; end
        while (r_abs <  1.0) begin r_abs *= 2.0; exp--; end
        mant = r_abs - 1.0;
        mant_bits = '0;
        for (int b = 22; b >= 0; b--) begin
            mant *= 2.0;
            if (mant >= 1.0) begin mant_bits[b] = 1'b1; mant -= 1.0; end
        end
        return {sign, 8'(exp + 127), mant_bits};
    endfunction

    // =========================================================================
    // Reference model — Phase 10: INT8 → INT32 dot → FP32 output
    //   Matches VX_tcu_fedp_int_scaled: int32_to_fp32 + fp32_exp_scale + fp32_add(C)
    //   C (rs3) is stored as raw FP32 bits and interpreted as FP32.
    // =========================================================================
    function automatic logic [31:0] ref_d_fp32 (
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic signed [9:0] exp_total,
        input int i, j, b_off
    );
        int  dot;
        real dot_f, scale_f, c_f, result_f;
        int  exp_int;

        dot = '0;
        for (int k = 0; k < TCU_TC_K; k++)
            for (int b = 0; b < 4; b++) begin
                logic signed [7:0] a8 = rs1[i * TCU_TC_K + k][8*b+7 -: 8];
                logic signed [7:0] b8 = rs2[b_off + j * TCU_TC_K + k][8*b+7 -: 8];
                dot += int'(a8) * int'(b8);
            end

        exp_int  = int'($signed(exp_total));
        dot_f    = real'(dot);
        scale_f  = 2.0 ** exp_int;
        c_f      = fp32_to_real(rs3[i * TCU_TC_N + j]);
        result_f = dot_f * scale_f + c_f;
        return real_to_fp32(result_f);
    endfunction

    // =========================================================================
    // Helper: all-same fill
    // =========================================================================
    function automatic logic [`SIMD_WIDTH-1:0][`XLEN-1:0] fill (
        input logic [`XLEN-1:0] w
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] r;
        for (int i = 0; i < `SIMD_WIDTH; i++) r[i] = w;
        return r;
    endfunction

    // =========================================================================
    // Handshake tasks
    // =========================================================================
    logic [UUID_WIDTH-1:0] next_uuid = UUID_WIDTH'(1);

    task automatic fire_tcu (input dispatch_t pkt);
        @(posedge clk); #1;
        dispatch_if[EX_TCU * `ISSUE_WIDTH].valid = 1'b1;
        dispatch_if[EX_TCU * `ISSUE_WIDTH].data  = pkt;
        @(posedge clk);
        while (!dispatch_if[EX_TCU * `ISSUE_WIDTH].ready) @(posedge clk);
        #1;
        dispatch_if[EX_TCU * `ISSUE_WIDTH].valid = 1'b0;
    endtask

    task automatic fire_alu (input dispatch_t pkt);
        @(posedge clk); #1;
        dispatch_if[EX_ALU * `ISSUE_WIDTH].valid = 1'b1;
        dispatch_if[EX_ALU * `ISSUE_WIDTH].data  = pkt;
        @(posedge clk);
        while (!dispatch_if[EX_ALU * `ISSUE_WIDTH].ready) @(posedge clk);
        #1;
        dispatch_if[EX_ALU * `ISSUE_WIDTH].valid = 1'b0;
    endtask

    // =========================================================================
    // fire_ldscale_tcu: issue LDSCALE through VX_execute → VX_commit path,
    //   drain the dummy writeback. Must be called before each WMMA in AG-TCU.
    // =========================================================================
`ifdef EXT_AG_TCU_ENABLE
    task automatic fire_ldscale_tcu(input logic [7:0] scale_a, scale_b);
        dispatch_t  pkt;
        writeback_t dummy;
        logic [UUID_WIDTH-1:0] ld_uuid;
        ld_uuid                = next_uuid++;
        pkt                    = build_base_pkt(ld_uuid, '0);
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_LDSCALE;
        // Scale packed into rs1_data[0]: [15:8]=scale_b, [7:0]=scale_a
        pkt.rs1_data[0]        = {16'b0, scale_b, scale_a};
        fire_tcu(pkt);
        wait_writeback_uuid(ld_uuid, dummy);
    endtask

    // fire_ldmicro_tcu: sends LDMICRO to VX_tcu_operand_transformer via execute.
    //   mexp_a[1:0] = {pair1_a, pair0_a}, mexp_b[1:0] = {pair1_b, pair0_b}
    //   wb=0: no GPR writeback → wait_writeback_uuid NOT called.
    task automatic fire_ldmicro_tcu(
        input logic [1:0] mexp_a, mexp_b);
        dispatch_t pkt;
        logic [UUID_WIDTH-1:0] ld_uuid;
        ld_uuid                    = next_uuid++;
        pkt                        = build_base_pkt(ld_uuid, '0);
        pkt.wb                     = 1'b0;  // no GPR writeback
        pkt.op_type                = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.op_args.tcu.fmt_s      = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d      = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.tcu_op     = TCU_OP_LDMICRO;
        for (int t = 0; t < `SIMD_WIDTH; t++) begin
            pkt.rs1_data[t] = {30'b0, mexp_a};
            pkt.rs2_data[t] = {30'b0, mexp_b};
        end
        fire_tcu(pkt);
        // LDMICRO has wb=0: OT stores micro_exp into micro_ctx register.
        // It still passes through execute pipeline; allow 2 cycles for OT latch.
        repeat(2) @(posedge clk);
    endtask
`endif

    // Wait for writeback with matching UUID; collect up to 2 pending results
    logic [UUID_WIDTH-1:0] saved_uuid;
    writeback_t            saved_wb;
    logic                  have_saved = 0;

    task automatic wait_writeback_uuid (
        input  logic [UUID_WIDTH-1:0] target_uuid,
        output writeback_t            res
    );
        // Check if we already collected this UUID during a previous wait
        if (have_saved && saved_uuid == target_uuid) begin
            res        = saved_wb;
            have_saved = 0;
            return;
        end
        // Wait for writeback_if to fire
        forever begin
            @(posedge clk);
            if (writeback_if[0].valid) begin
                if (writeback_if[0].data.uuid == target_uuid) begin
                    res = writeback_if[0].data;
                    return;
                end else begin
                    // Save it for another caller
                    saved_uuid = writeback_if[0].data.uuid;
                    saved_wb   = writeback_if[0].data;
                    have_saved = 1;
                end
            end
        end
    endtask

    // Build a base dispatch packet (fields common to TCU and ALU)
    function automatic dispatch_t build_base_pkt (
        input logic [UUID_WIDTH-1:0] uuid,
        input logic [NUM_REGS_BITS-1:0] rd
    );
        dispatch_t p;
        p           = '0;
        p.uuid      = uuid;
        p.wis       = '0;
        p.sid       = '0;
        p.tmask     = '1;
        p.PC        = '0;
        p.wb        = 1'b1;
        p.rd        = rd;
        p.sop       = 1'b1;
        p.eop       = 1'b1;
        return p;
    endfunction

    // =========================================================================
    // run_tcu_test
    //   Fires one WMMA dispatch, waits for writeback, compares via ref_d.
    // =========================================================================
    task automatic run_tcu_test (
        input string name,
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [7:0] exp_a, exp_b,
        input logic [3:0] step_m = 4'd0,
        input logic [3:0] step_n = 4'd0
    );
        dispatch_t  pkt;
        writeback_t res;
        logic signed [9:0] exp_total;
        int         b_off;
        bit         test_pass;
        logic [UUID_WIDTH-1:0] my_uuid;

        my_uuid   = next_uuid++;
        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;
        b_off     = (int'(step_n) & (TCU_B_SUB_BLOCKS - 1)) * TCU_B_BLOCK_SIZE;

        pkt                    = build_base_pkt(my_uuid, NUM_REGS_BITS'(2));
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);  // Phase 10: INT FEDP outputs FP32
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
`ifdef EXT_AG_TCU_ENABLE
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
`endif
        pkt.rs1_data = rs1;
        pkt.rs2_data = rs2;
        pkt.rs3_data = rs3;

`ifdef EXT_AG_TCU_ENABLE
        fire_ldscale_tcu(exp_a, exp_b);
`endif
        fire_tcu(pkt);
        wait_writeback_uuid(my_uuid, res);

        test_pass = 1;
        for (int i = 0; i < TCU_TC_M; i++) begin
            for (int j = 0; j < TCU_TC_N; j++) begin
                logic [31:0] got, exp_val;
                got     = res.data[i * TCU_TC_N + j];
                exp_val = ref_d_fp32(rs1, rs2, rs3, exp_total, i, j, b_off);
                if (got !== exp_val) begin
                    $display("[FAIL] %-30s [%0d][%0d] got=0x%08h exp=0x%08h",
                             name, i, j, got, exp_val);
                    test_pass = 0;
                end
            end
        end
        if (test_pass) begin
            $display("[PASS] %-30s all %0d outputs correct",
                     name, TCU_TC_M * TCU_TC_N);
            pass_cnt++;
        end else begin
            fail_cnt++;
        end
    // =========================================================================
    // run_mx9_test (Phase 10)
    //   Fires LDSCALE + LDMICRO + MX9 WMMA dispatch.
    //   Reference model applies flatten before dot: rs1_flat = flatten(rs1, mexp_a).
    // =========================================================================

    // Phase 10 flatten: shift left by mexp (1-bit), saturate at INT8 bounds.
    function automatic logic [7:0] ref_flatten_byte(
        input logic [7:0] b, input logic mexp);
        if (!mexp) return b;
        // mexp=1: result = b << 1 with saturation
        if (b[7] == 1'b0 && b[6] == 1'b1) return 8'h7F;  // +127 sat
        if (b[7] == 1'b1 && b[6] == 1'b0) return 8'h80;  // -128 sat
        return {b[6:0], 1'b0};
    endfunction

    function automatic logic [31:0] ref_flatten_word(
        input logic [31:0] w, input logic [1:0] mexp);
        return {ref_flatten_byte(w[31:24], mexp[1]),
                ref_flatten_byte(w[23:16], mexp[1]),
                ref_flatten_byte(w[15:8],  mexp[0]),
                ref_flatten_byte(w[7:0],   mexp[0])};
    endfunction

`ifdef EXT_AG_TCU_ENABLE
    task automatic run_mx9_test (
        input string name,
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [7:0] exp_a, exp_b,
        input logic [1:0] mexp_a, mexp_b  // uniform across all threads
    );
        dispatch_t  pkt;
        writeback_t res;
        logic signed [9:0] exp_total;
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_flat, rs2_flat;
        int         b_off;
        bit         test_pass;
        logic [UUID_WIDTH-1:0] my_uuid;

        my_uuid   = next_uuid++;
        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;
        b_off     = 0;

        // Apply flatten to match OT behaviour
        for (int t = 0; t < `SIMD_WIDTH; t++) begin
            rs1_flat[t] = ref_flatten_word(rs1[t], mexp_a);
            rs2_flat[t] = ref_flatten_word(rs2[t], mexp_b);
        end

        pkt                    = build_base_pkt(my_uuid, NUM_REGS_BITS'(2));
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.op_args.tcu.fmt_s  = 4'(TCU_MX9_ID);    // OT: flatten + patch to I8
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.step_m = 4'd0;
        pkt.op_args.tcu.step_n = 4'd0;
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
        pkt.rs1_data           = rs1;
        pkt.rs2_data           = rs2;
        pkt.rs3_data           = rs3;

        fire_ldscale_tcu(exp_a, exp_b);
        fire_ldmicro_tcu(mexp_a, mexp_b);
        fire_tcu(pkt);
        wait_writeback_uuid(my_uuid, res);

        test_pass = 1;
        for (int i = 0; i < TCU_TC_M; i++) begin
            for (int j = 0; j < TCU_TC_N; j++) begin
                logic [31:0] got, exp_val;
                got     = res.data[i * TCU_TC_N + j];
                // Reference uses FLATTENED rs1/rs2
                exp_val = ref_d_fp32(rs1_flat, rs2_flat, rs3, exp_total, i, j, b_off);
                if (got !== exp_val) begin
                    $display("[FAIL] %-30s [%0d][%0d] got=0x%08h exp=0x%08h",
                             name, i, j, got, exp_val);
                    test_pass = 0;
                end
            end
        end
        if (test_pass) begin
            $display("[PASS] %-30s all %0d outputs correct",
                     name, TCU_TC_M * TCU_TC_N);
            pass_cnt++;
        end else begin
            fail_cnt++;
        end
    endtask
`endif // EXT_AG_TCU_ENABLE

    // =========================================================================
    // run_alu_test
    //   Fires one ALU ADD dispatch, waits for writeback, verifies rs1+rs2.
    // =========================================================================
    task automatic run_alu_test (
        input string name,
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2
    );
        dispatch_t  pkt;
        writeback_t res;
        bit         test_pass;
        logic [UUID_WIDTH-1:0] my_uuid;

        my_uuid = next_uuid++;

        pkt             = build_base_pkt(my_uuid, NUM_REGS_BITS'(1));
        pkt.op_type     = INST_ALU_BITS'(INST_ALU_ADD);
        pkt.op_args.alu = '0;    // use_PC=0, use_imm=0, is_w=0, xtype=0, imm=0
        pkt.rs1_data    = rs1;
        pkt.rs2_data    = rs2;

        fire_alu(pkt);
        wait_writeback_uuid(my_uuid, res);

        test_pass = 1;
        for (int i = 0; i < `SIMD_WIDTH; i++) begin
            logic signed [31:0] got, exp_val;
            got     = $signed(res.data[i]);
            exp_val = $signed(rs1[i]) + $signed(rs2[i]);
            if (got !== exp_val) begin
                $display("[FAIL] %-30s [%0d] got=%0d exp=%0d",
                         name, i, got, exp_val);
                test_pass = 0;
            end
        end
        if (test_pass) begin
            $display("[PASS] %-30s all %0d outputs correct",
                     name, `SIMD_WIDTH);
            pass_cnt++;
        end else begin
            fail_cnt++;
        end
    endtask

    // =========================================================================
    // run_concurrent_test
    //   Fires ALU then TCU back-to-back (no wait between).
    //   Collects both writebacks (order may differ due to arbitration).
    //   Verifies both results independently.
    // =========================================================================
    task automatic run_concurrent_test (
        input string name,
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] alu_rs1, alu_rs2,
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] tcu_rs1, tcu_rs2, tcu_rs3,
        input logic [7:0] exp_a, exp_b
    );
        dispatch_t  alu_pkt, tcu_pkt;
        writeback_t alu_res, tcu_res;
        logic signed [9:0] exp_total;
        bit         test_pass;
        logic [UUID_WIDTH-1:0] alu_uuid, tcu_uuid;

        alu_uuid  = next_uuid++;
        tcu_uuid  = next_uuid++;
        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;

        // Build ALU packet
        alu_pkt             = build_base_pkt(alu_uuid, NUM_REGS_BITS'(1));
        alu_pkt.op_type     = INST_ALU_BITS'(INST_ALU_ADD);
        alu_pkt.op_args.alu = '0;
        alu_pkt.rs1_data    = alu_rs1;
        alu_pkt.rs2_data    = alu_rs2;

        // Build TCU packet
        tcu_pkt                    = build_base_pkt(tcu_uuid, NUM_REGS_BITS'(2));
        tcu_pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        tcu_pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        tcu_pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);  // Phase 10
        tcu_pkt.op_args.tcu.step_m = 4'd0;
        tcu_pkt.op_args.tcu.step_n = 4'd0;
`ifdef EXT_AG_TCU_ENABLE
        tcu_pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
`endif
        tcu_pkt.rs1_data = tcu_rs1;
        tcu_pkt.rs2_data = tcu_rs2;
        tcu_pkt.rs3_data = tcu_rs3;

`ifdef EXT_AG_TCU_ENABLE
        // Write scale context before the concurrent fire (must complete first)
        fire_ldscale_tcu(exp_a, exp_b);
`endif

        // Fire ALU and TCU simultaneously (both valids asserted same cycle)
        @(posedge clk); #1;
        dispatch_if[EX_ALU * `ISSUE_WIDTH].valid = 1'b1;
        dispatch_if[EX_ALU * `ISSUE_WIDTH].data  = alu_pkt;
        dispatch_if[EX_TCU * `ISSUE_WIDTH].valid = 1'b1;
        dispatch_if[EX_TCU * `ISSUE_WIDTH].data  = tcu_pkt;

        // Wait for ALU to be accepted (1-cycle unit)
        @(posedge clk);
        while (!dispatch_if[EX_ALU * `ISSUE_WIDTH].ready) @(posedge clk);
        #1; dispatch_if[EX_ALU * `ISSUE_WIDTH].valid = 1'b0;

        // Wait for TCU to be accepted
        @(posedge clk);
        while (!dispatch_if[EX_TCU * `ISSUE_WIDTH].ready) @(posedge clk);
        #1; dispatch_if[EX_TCU * `ISSUE_WIDTH].valid = 1'b0;

        // Collect both results
        wait_writeback_uuid(alu_uuid, alu_res);
        wait_writeback_uuid(tcu_uuid, tcu_res);

        test_pass = 1;

        // Verify ALU result
        for (int i = 0; i < `SIMD_WIDTH; i++) begin
            logic signed [31:0] got, exp_val;
            got     = $signed(alu_res.data[i]);
            exp_val = $signed(alu_rs1[i]) + $signed(alu_rs2[i]);
            if (got !== exp_val) begin
                $display("[FAIL] %-30s ALU[%0d] got=%0d exp=%0d",
                         name, i, got, exp_val);
                test_pass = 0;
            end
        end

        // Verify TCU result
        for (int i = 0; i < TCU_TC_M; i++) begin
            for (int j = 0; j < TCU_TC_N; j++) begin
                logic [31:0] got, exp_val;
                got     = tcu_res.data[i * TCU_TC_N + j];
                exp_val = ref_d_fp32(tcu_rs1, tcu_rs2, tcu_rs3, exp_total, i, j, 0);
                if (got !== exp_val) begin
                    $display("[FAIL] %-30s TCU[%0d][%0d] got=0x%08h exp=0x%08h",
                             name, i, j, got, exp_val);
                    test_pass = 0;
                end
            end
        end

        if (test_pass) begin
            $display("[PASS] %-30s ALU+TCU both correct", name);
            pass_cnt++;
        end else begin
            fail_cnt++;
        end
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin
        // ---- Reset ----------------------------------------------------------
        reset = 1'b1;
        dispatch_if[EX_ALU * `ISSUE_WIDTH].valid = 1'b0;
        dispatch_if[EX_ALU * `ISSUE_WIDTH].data  = '0;
        dispatch_if[EX_TCU * `ISSUE_WIDTH].valid = 1'b0;
        dispatch_if[EX_TCU * `ISSUE_WIDTH].data  = '0;
        repeat(4) @(posedge clk);
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;

        $display("=== Level 6: VX_execute + VX_commit Testbench ===");
        $display("  EX_ALU=%0d  EX_LSU=%0d  EX_SFU=%0d  EX_TCU=%0d  NUM_EX_UNITS=%0d",
                 EX_ALU, EX_LSU, EX_SFU, EX_TCU, NUM_EX_UNITS);
        $display("  TCU_TC_M=%0d  TCU_TC_N=%0d  TCU_TC_K=%0d",
                 TCU_TC_M, TCU_TC_N, TCU_TC_K);
        $display("  ISSUE_WIDTH=%0d  SIMD_WIDTH=%0d",
                 `ISSUE_WIDTH, `SIMD_WIDTH);
        $display("--------------------------------------------------");

        // ====================================================================
        // Group A: TCU regression (key cases from Level 4)
        // ====================================================================

        // TC1: ones × ones, exp=0 → dot=8 → FP32(8.0)=0x41000000
        run_tcu_test("TC1_wmma_ones_exp0",
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd127, 8'd127);

        // TC3: right-shift — exp_total=-2, dot=8 → FP32(8*0.25)=FP32(2.0)=0x40000000
        run_tcu_test("TC3_rshift_ones",
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd125, 8'd127);

        // TC4: mixed bytes, exp_total=6 → dot=20 → FP32(20*64)=FP32(1280.0)=0x44A00000
        run_tcu_test("TC4_wmma_mx_style",
            fill(32'h04030201), fill(32'h01010101), fill(32'd0),
            8'd130, 8'd130);

        // TC5: FP32 negative C — FP32(8.0) + FP32(-200.0) = FP32(-192.0)
        //   C preloaded as FP32(-200.0)=0xC3480000; expected = FP32(-192.0)=0xC3400000
        run_tcu_test("TC5_wmma_neg_accum",
            fill(32'h01010101), fill(32'h01010101), fill(32'hC3480000),
            8'd127, 8'd127);

        // ====================================================================
        // Group B: ALU ADD standalone (new at Level 6)
        // ====================================================================

        // TC6: simple add → 42 + 58 = 100 per lane
        run_alu_test("TC6_alu_add_basic",
            fill(32'd42), fill(32'd58));

        // TC7: wrapping add → -1 + 1 = 0 per lane
        run_alu_test("TC7_alu_add_wrap",
            fill(32'hFFFFFFFF), fill(32'd1));

        // ====================================================================
        // Group C: Concurrent + Arbitration (core value of Level 6)
        // ====================================================================

        // TC8: Concurrent ALU (10+20=30) and WMMA (ones, d=8)
        //   Both fire together; ALU completes in ~1 cycle, WMMA in ~6+ cycles.
        //   VX_commit delivers ALU first (priority 0 < 3), then WMMA.
        run_concurrent_test("TC8_concurrent_alu_tcu",
            fill(32'd10), fill(32'd20),          // ALU: 10+20=30
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),  // WMMA: d=8
            8'd127, 8'd127);

        // TC9: Concurrent with exponent scaling
        //   ALU: 100 + 100 = 200
        //   WMMA: ones, exp_total=4 → 8<<4=128
        run_concurrent_test("TC9_concurrent_with_exp",
            fill(32'd100), fill(32'd100),
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd129, 8'd129);

        // TC10: Metadata passthrough
        //   Verify uuid and rd survive VX_execute → VX_commit → writeback_if
        begin
            dispatch_t  pkt;
            writeback_t res;
            logic [UUID_WIDTH-1:0] test_uuid = UUID_WIDTH'(42);
            logic [NUM_REGS_BITS-1:0] test_rd = NUM_REGS_BITS'(7);
            bit ok = 1;

            pkt                    = build_base_pkt(test_uuid, test_rd);
            pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
            pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
            pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);  // Phase 10
            pkt.op_args.tcu.step_m = 4'd0;
            pkt.op_args.tcu.step_n = 4'd0;
            pkt.rs1_data           = fill(32'h01010101);
            pkt.rs2_data           = fill(32'h01010101);
            pkt.rs3_data           = fill(32'd0);
`ifdef EXT_AG_TCU_ENABLE
            pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
`endif

`ifdef EXT_AG_TCU_ENABLE
            fire_ldscale_tcu(8'd127, 8'd127);
`endif
            fire_tcu(pkt);
            wait_writeback_uuid(test_uuid, res);

            if (res.uuid !== test_uuid) begin
                $display("[FAIL] TC10_metadata_passthrough  uuid got=%0h exp=%0h",
                         res.uuid, test_uuid);
                ok = 0;
            end
            if (res.rd !== test_rd) begin
                $display("[FAIL] TC10_metadata_passthrough  rd got=%0d exp=%0d",
                         res.rd, test_rd);
                ok = 0;
            end
            if (ok) begin
                $display("[PASS] TC10_metadata_passthrough  uuid=%0h rd=%0d (correct)",
                         res.uuid, res.rd);
                pass_cnt++;
            end else begin
                fail_cnt++;
            end
        end

`ifdef EXT_AG_TCU_ENABLE
        // ====================================================================
        // Group D: MX9 + LDMICRO [Phase 10]
        // ====================================================================

        // TC11: MX9 with mexp_a=1 (all pairs), mexp_b=0, exp_total=0
        //   A=0x01010101 → flatten → A_flat=0x02020202
        //   B=0x01010101 → identity → B_flat=0x01010101
        //   dot = TC_K * 4 bytes * 2*1 = 8*2 = 16
        //   FP32(16.0) + C(0.0) = FP32(16.0) = 0x41800000
        run_mx9_test("TC11_mx9_mexp_a1",
            fill(32'h01010101), fill(32'h01010101), fill(32'h00000000),
            8'd127, 8'd127,
            2'b11, 2'b00);   // mexp_a: pair0=1, pair1=1; mexp_b: all 0

        // TC12: MX9 with mexp_a=1, exp_total=+2 (OT flatten × global exp scale)
        //   A_flat=0x02020202, B_flat=0x01010101
        //   dot=16, exp_total=2 → FP32(16 * 4) = FP32(64.0) = 0x42800000
        run_mx9_test("TC12_mx9_mexp_a1_exp2",
            fill(32'h01010101), fill(32'h01010101), fill(32'h00000000),
            8'd129, 8'd127,   // exp_total = 129+127-254 = +2
            2'b11, 2'b00);
`endif

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
