// Level 6 Testbench: VX_execute + VX_commit
//
// DUT: VX_execute (all execution units) + VX_commit (priority arbiter)
// Output monitored: VX_commit.writeback_if
//
// New vs Level 5:
//   1. All execution units compiled together (multi-unit integration check)
//   2. EX_TCU slot indexing in VX_execute verified
//   3. VX_commit priority arbitration (EX_ALU > EX_TCU) tested
//   4. Concurrent ALU + TCU execution verified
//
// Test groups:
//   Group A (TC1-TC5): WMMA regression through VX_execute+VX_commit
//   Group B (TC6-TC7): ALU ADD standalone
//   Group C (TC8-TC10): Concurrent ALU+TCU, priority collision, metadata

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
    // Reference model (same as Level 4 tb_tcu_unit)
    // =========================================================================
    function automatic logic signed [7:0] ref_flatten_mx9_byte(input logic [7:0] byte_in);
        logic              mexp;
        logic signed [7:0] m8;
        mexp = byte_in[7];
        m8   = $signed({byte_in[6], byte_in[6:0]});  // sign_ext7
        return mexp ? m8 <<< 1 : m8;
    endfunction

    function automatic logic signed [31:0] ref_d (
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic signed [9:0] exp_total,
        input int i, j, b_off
    );
        logic signed [31:0] dot;
        logic signed [63:0] shifted;
        logic signed [31:0] sat;
        logic [4:0] rshift_amt;

        dot = '0;
        for (int k = 0; k < TCU_TC_K; k++)
            for (int b = 0; b < 4; b++) begin
                logic signed [7:0] a8 = ref_flatten_mx9_byte(rs1[i * TCU_TC_K + k][8*b+7 -: 8]);
                logic signed [7:0] b8 = ref_flatten_mx9_byte(rs2[b_off + j * TCU_TC_K + k][8*b+7 -: 8]);
                dot += a8 * b8;
            end

        if (exp_total[9]) begin // sign bit = 1 → negative exp → right shift
            rshift_amt = 5'($signed(-exp_total));
            shifted = 64'($signed(dot)) >>> rshift_amt;
        end else begin
            shifted = 64'($signed(dot)) <<< exp_total;
        end

        if      (shifted > 64'sd2147483647)  sat = 32'h7FFF_FFFF;
        else if (shifted < -64'sd2147483648) sat = 32'h8000_0000;
        else                                 sat = shifted[31:0];

        return sat + $signed(rs3[i * TCU_TC_N + j]);
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
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_LDSCALE;
        // Scale packed into rs1_data[0]: [15:8]=scale_b, [7:0]=scale_a
        pkt.rs1_data[0]        = {16'b0, scale_b, scale_a};
        fire_tcu(pkt);
        wait_writeback_uuid(ld_uuid, dummy);
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
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
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
                logic signed [31:0] got, exp_val;
                got     = $signed(res.data[i * TCU_TC_N + j]);
                exp_val = ref_d(rs1, rs2, rs3, exp_total, i, j, b_off);
                if (got !== exp_val) begin
                    $display("[FAIL] %-30s [%0d][%0d] got=%0d exp=%0d",
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
        tcu_pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
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
                logic signed [31:0] got, exp_val;
                got     = $signed(tcu_res.data[i * TCU_TC_N + j]);
                exp_val = ref_d(tcu_rs1, tcu_rs2, tcu_rs3, exp_total, i, j, 0);
                if (got !== exp_val) begin
                    $display("[FAIL] %-30s TCU[%0d][%0d] got=%0d exp=%0d",
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

        // TC1: ones × ones, exp=0 → dot = TC_K*4*1*1 = 8
        run_tcu_test("TC1_wmma_ones_exp0",
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd127, 8'd127);

        // TC2: positive saturation — (-128)×(-128), exp_total=+14 → INT32_MAX
        // 0xC0 flatten 시 -> mexp=1, m7=-64 -> -128
        run_tcu_test("TC2_wmma_pos_sat",
            fill(32'hC0C0C0C0), fill(32'hC0C0C0C0), fill(32'd0),
            8'd134, 8'd134);

        // TC3: right-shift (Phase 4② coverage) — exp_total=-2, dot=8 → 8>>>2=2
        run_tcu_test("TC3_rshift_ones",
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd125, 8'd127);

        // TC4: MX-style, exp_total=6 → dot=20, 20<<6=1280
        run_tcu_test("TC4_wmma_mx_style",
            fill(32'h04030201), fill(32'h01010101), fill(32'd0),
            8'd130, 8'd130);

        // TC5: negative C accumulator → 8 + (-200) = -192
        run_tcu_test("TC5_wmma_neg_accum",
            fill(32'h01010101), fill(32'h01010101), fill(-32'd200),
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
            pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
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
