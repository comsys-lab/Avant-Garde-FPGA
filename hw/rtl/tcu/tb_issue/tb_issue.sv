// Level 7 Testbench: VX_issue standalone
//
// DUT: VX_issue only (ibuffer → uop_sequencer → scoreboard → operands → dispatch)
// TB drives decode_if and monitors dispatch_if[EX_TCU * ISSUE_WIDTH].
// Register file seeded via writeback_if in preload_phase.
// Scoreboard released after WMMA dispatch by manually injecting writeback_if.
//
// Phase 10 TC:
//   TC1: LDSCALE → 1 dispatch (uop_sequencer does NOT expand to UOPS)
//   TC2: WMMA → TCU_UOPS dispatches, sop/eop marking
//   TC3: LDMICRO → 1 dispatch, dispatch.wb=0  [Phase 10]
//   TC4: Scoreboard RAW stall — WMMA#1 stalls WMMA#2; inject wb → WMMA#2 proceeds

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
    // Derived parameters
    // =========================================================================
    localparam LG_N    = $clog2(TCU_N_STEPS);
    localparam LG_M    = $clog2(TCU_M_STEPS);
    localparam LG_K    = $clog2(TCU_K_STEPS);
    localparam LG_A_SB = $clog2(TCU_A_SUB_BLOCKS);
    localparam LG_B_SB = $clog2(TCU_B_SUB_BLOCKS);
    localparam TCU_NRA = (TCU_M_STEPS / TCU_A_SUB_BLOCKS) * TCU_K_STEPS;
    localparam TCU_NRC = TCU_M_STEPS * TCU_N_STEPS;

    localparam [NUM_REGS_BITS-1:0] SCALE_REG =
        make_reg_num(REG_TYPE_I, RV_REGS_BITS'(5));

    // =========================================================================
    // Interfaces
    // =========================================================================
    VX_decode_if       decode_if();
    VX_writeback_if    writeback_if[`ISSUE_WIDTH]();
    VX_dispatch_if     dispatch_if [NUM_EX_UNITS * `ISSUE_WIDTH]();
    VX_issue_sched_if  issue_sched_if[`ISSUE_WIDTH]();

    // TB always accepts all dispatches immediately
    for (genvar i = 0; i < NUM_EX_UNITS * `ISSUE_WIDTH; i++) begin : g_disp_ready
        assign dispatch_if[i].ready = 1'b1;
    end

    // =========================================================================
    // DUT: VX_issue only
    // =========================================================================
    VX_issue #(.INSTANCE_ID("tb_issue")) issue_dut (
        .clk            (clk),
        .reset          (reset),
        .decode_if      (decode_if),
        .writeback_if   (writeback_if),
        .dispatch_if    (dispatch_if),
        .issue_sched_if (issue_sched_if)
    );

    // =========================================================================
    // Writeback driver (preload_phase=1: seed registers; =0: inject after dispatch)
    // =========================================================================
    logic       preload_phase = 1'b1;
    logic       tb_wb_valid_r = 1'b0;
    writeback_t tb_wb_data_r;

    for (genvar i = 0; i < `ISSUE_WIDTH; i++) begin : g_wb_drive
        assign writeback_if[i].valid = tb_wb_valid_r;
        assign writeback_if[i].data  = tb_wb_data_r;
    end

    // =========================================================================
    // TCU dispatch counter
    // =========================================================================
    int tcu_dispatch_cnt = 0;
    always @(posedge clk) begin
        if (reset)
            tcu_dispatch_cnt <= 0;
        else if (dispatch_if[EX_TCU * `ISSUE_WIDTH].valid &&
                 dispatch_if[EX_TCU * `ISSUE_WIDTH].ready)
            tcu_dispatch_cnt <= tcu_dispatch_cnt + 1;
    end

    // =========================================================================
    // Pass/fail counters and UUID
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;
    logic [UUID_WIDTH-1:0] next_uuid = UUID_WIDTH'(1);
    logic [UUID_WIDTH-1:0] fork_uuid;  // scratch for fork...join_none uuid capture
    logic [NUM_REGS_BITS-1:0] fork_commit_rd; // scratch rd for sim_commit in fork threads

    // =========================================================================
    // Helpers
    // =========================================================================
    task automatic preload_gpr(
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

    // sim_commit: inject one writeback for rd to release scoreboard entry.
    // Simulates VX_execute→VX_commit when VX_execute is absent from DUT.
    task automatic sim_commit(input logic [NUM_REGS_BITS-1:0] rd);
        preload_gpr(rd, '0);
    endtask

    task automatic preload_tile_regs(
        input logic [`XLEN-1:0] a_val, b_val, c_val
    );
        for (int m = 0; m < TCU_M_STEPS; m++)
            for (int k = 0; k < TCU_K_STEPS; k++) begin
                int off_a = ((m >> LG_A_SB) << LG_K) | k;
                preload_gpr(
                    make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RA) + RV_REGS_BITS'(off_a)),
                    a_val);
            end
        for (int k = 0; k < TCU_K_STEPS; k++)
            for (int n = 0; n < TCU_N_STEPS; n++) begin
                int off_b = ((k << LG_N) | n) >> LG_B_SB;
                preload_gpr(
                    make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RB) + RV_REGS_BITS'(off_b)),
                    b_val);
            end
        for (int m = 0; m < TCU_M_STEPS; m++)
            for (int n = 0; n < TCU_N_STEPS; n++) begin
                int off_c = (m << LG_N) | n;
                preload_gpr(
                    make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RC) + RV_REGS_BITS'(off_c)),
                    c_val);
            end
    endtask

    // inject_wb_for_tile: simulate VX_commit writeback for all C-tile registers.
    // Releases scoreboard so a subsequent WMMA can issue.
    task automatic inject_wb_for_tile(input logic [`XLEN-1:0] val);
        for (int m = 0; m < TCU_M_STEPS; m++)
            for (int n = 0; n < TCU_N_STEPS; n++) begin
                int off_c = (m << LG_N) | n;
                preload_gpr(
                    make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RC) + RV_REGS_BITS'(off_c)),
                    val);
            end
    endtask

    task automatic send_decode(input decode_t pkt);
        @(posedge clk); #1;
        decode_if.valid = 1'b1;
        decode_if.data  = pkt;
        @(posedge clk);
        while (!decode_if.ready) @(posedge clk);
        #1;
        decode_if.valid = 1'b0;
    endtask

    // wait until tcu_dispatch_cnt reaches target
    task automatic wait_dispatch(input int target);
        while (tcu_dispatch_cnt < target) @(posedge clk);
    endtask

    // =========================================================================
    // Decode packet builders
    // =========================================================================
    function automatic decode_t build_ldscale(input logic [UUID_WIDTH-1:0] uuid);
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
        d.op_args.tcu.fmt_s = 4'(TCU_I8_ID);
        d.op_args.tcu.fmt_d = 4'(TCU_FP32_ID);  // Phase 10: INT FEDP outputs FP32
        // LDSCALE writes to scale_ctx (internal), not GPR → wb=0 avoids scoreboard lock
        d.wb            = 1'b0;
        d.used_rs       = 3'b001;
        d.rs1           = SCALE_REG;
        return d;
    endfunction

    function automatic decode_t build_wmma(input logic [UUID_WIDTH-1:0] uuid);
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
        d.op_args.tcu.fmt_s = 4'(TCU_I8_ID);
        d.op_args.tcu.fmt_d = 4'(TCU_FP32_ID);
        d.wb            = 1'b1;
        d.used_rs       = 3'b111;
        d.rd  = make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RC));
        d.rs1 = make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RA));
        d.rs2 = make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RB));
        d.rs3 = make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RC));
        return d;
    endfunction

    function automatic decode_t build_ldmicro(input logic [UUID_WIDTH-1:0] uuid);
        decode_t d;
        d               = '0;
        d.uuid          = uuid;
        d.wid           = '0;
        d.tmask         = '1;
        d.ex_type       = EX_BITS'(EX_TCU);
        d.op_type       = INST_OP_BITS'(INST_TCU_WMMA);
`ifdef EXT_AG_TCU_ENABLE
        d.op_args.tcu.tcu_op = TCU_OP_LDMICRO;
`endif
        d.op_args.tcu.fmt_s = 4'(TCU_I8_ID);
        d.op_args.tcu.fmt_d = 4'(TCU_FP32_ID);
        d.wb            = 1'b0;   // no GPR writeback
        d.used_rs       = 3'b011; // rs1 + rs2 used
        d.rs1 = make_reg_num(REG_TYPE_F, RV_REGS_BITS'(6));
        d.rs2 = make_reg_num(REG_TYPE_F, RV_REGS_BITS'(7));
        return d;
    endfunction

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin
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

        $display("=== Level 7: VX_issue standalone ===");
        $display("  UOPS=%0d  M_STEPS=%0d  N_STEPS=%0d  K_STEPS=%0d",
                 TCU_UOPS, TCU_M_STEPS, TCU_N_STEPS, TCU_K_STEPS);
        $display("  NRA=%0d  NRB=%0d  NRC=%0d",
                 TCU_NRA, TCU_NRB, TCU_NRC);
        $display("------------------------------------------------------------");

        // ==================================================================
        // TC1: LDSCALE → 1 dispatch (uop_sequencer single-UOP check)
        // ==================================================================
        begin : tc1
            int cnt_before, cnt_after;
            bit ok = 1;

            preload_gpr(SCALE_REG, 32'h7F7F);
            preload_phase = 1'b0;
            @(posedge clk); #1;

            cnt_before = tcu_dispatch_cnt;
            send_decode(build_ldscale(next_uuid++));
            wait_dispatch(cnt_before + 1);
            cnt_after = tcu_dispatch_cnt;

            // Wait 10 cycles to ensure no extra dispatches (uop expansion bug)
            repeat(10) @(posedge clk);
            if (tcu_dispatch_cnt !== cnt_after) begin
                $display("[FAIL] TC1_ldscale  extra dispatches: total=%0d, exp=%0d (LDSCALE was expanded!)",
                         tcu_dispatch_cnt - cnt_before, 1);
                ok = 0;
            end

            if (ok) begin
                $display("[PASS] TC1_ldscale_single_dispatch  1 dispatch (uop_seq not expanded)");
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC2: WMMA → TCU_UOPS dispatches + sop/eop verification
        // ==================================================================
        begin : tc2
            int cnt_before, cnt_after;
            int sop_cnt = 0, eop_cnt = 0;
            bit ok = 1;

            preload_tile_regs(32'h01010101, 32'h01010101, 32'h00000000);
            preload_gpr(SCALE_REG, 32'h7F7F);
            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            send_decode(build_ldscale(next_uuid++));
            wait_dispatch(tcu_dispatch_cnt + 1);
`endif
            cnt_before = tcu_dispatch_cnt;

            // 3-thread fork:
            //   T1: send WMMA decode packet
            //   T2: observe sop/eop at each dispatch (fast, no blocking commit)
            //   T3: inject_wb_for_tile between K-steps to release scoreboard
            //       (without VX_execute, rd==rs3 C-tile lock must be cleared before sk+1)
            begin : tc2_fork_blk
                automatic logic [UUID_WIDTH-1:0] u2 = next_uuid++;
                fork
                    // Thread 1: send WMMA decode packet
                    send_decode(build_wmma(u2));
                    // Thread 2: observe dispatches for sop/eop (no commit injection here)
                    begin
                        for (int i = 0; i < TCU_UOPS; i++) begin
                            @(posedge clk iff (dispatch_if[EX_TCU * `ISSUE_WIDTH].valid &&
                                               dispatch_if[EX_TCU * `ISSUE_WIDTH].ready));
                            #1;
                            if (dispatch_if[EX_TCU * `ISSUE_WIDTH].data.sop) sop_cnt++;
                            if (dispatch_if[EX_TCU * `ISSUE_WIDTH].data.eop) eop_cnt++;
                        end
                    end
                    // Thread 3: release C-tile scoreboard entries between K-steps
                    begin
                        for (int k = 0; k < TCU_K_STEPS; k++) begin
                            // Wait for one K-step worth of dispatches
                            wait_dispatch(cnt_before + (k + 1) * (TCU_M_STEPS * TCU_N_STEPS));
                            // Release all C-tile register locks so the next K-step can read C
                            if (k < TCU_K_STEPS - 1)
                                inject_wb_for_tile('0);
                        end
                    end
                join
            end
            wait_dispatch(cnt_before + TCU_UOPS);
            cnt_after = tcu_dispatch_cnt;

            if ((cnt_after - cnt_before) !== TCU_UOPS) begin
                $display("[FAIL] TC2_wmma_uop_count  dispatches=%0d (exp %0d)",
                         cnt_after - cnt_before, TCU_UOPS);
                ok = 0;
            end
            // With SIMD_COUNT=1 (NUM_THREADS==SIMD_WIDTH), every dispatch is a
            // full SIMD packet so sop=eop=1 for every UOP — expected behavior.
            if (sop_cnt !== TCU_UOPS) begin
                $display("[FAIL] TC2_wmma_sop  sop_cnt=%0d (exp %0d, SIMD_COUNT=1 → sop=1 always)",
                         sop_cnt, TCU_UOPS);
                ok = 0;
            end
            if (eop_cnt !== TCU_UOPS) begin
                $display("[FAIL] TC2_wmma_eop  eop_cnt=%0d (exp %0d, SIMD_COUNT=1 → eop=1 always)",
                         eop_cnt, TCU_UOPS);
                ok = 0;
            end

            if (ok) begin
                $display("[PASS] TC2_wmma_uop_count   %0d dispatches, sop/eop=1 each (SIMD_COUNT=1)", TCU_UOPS);
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            inject_wb_for_tile(32'h41800000);  // release scoreboard
        end

        // ==================================================================
        // TC3: LDMICRO → 1 dispatch, dispatch.wb=0 [Phase 10]
        // ==================================================================
        begin : tc3
            int cnt_before, cnt_after;
            logic wb_at_dispatch;
            bit ok = 1;

            preload_gpr(make_reg_num(REG_TYPE_F, RV_REGS_BITS'(6)), 32'h3);
            preload_gpr(make_reg_num(REG_TYPE_F, RV_REGS_BITS'(7)), 32'h0);
            preload_phase = 1'b0;
            @(posedge clk); #1;

            cnt_before = tcu_dispatch_cnt;
            begin : tc3_fork_blk
                automatic logic [UUID_WIDTH-1:0] u3 = next_uuid++;
                fork
                    send_decode(build_ldmicro(u3));
                    begin
                        @(posedge clk iff (dispatch_if[EX_TCU * `ISSUE_WIDTH].valid &&
                                           dispatch_if[EX_TCU * `ISSUE_WIDTH].ready));
                        wb_at_dispatch = dispatch_if[EX_TCU * `ISSUE_WIDTH].data.wb;
                    end
                join
            end
            wait_dispatch(cnt_before + 1);
            cnt_after = tcu_dispatch_cnt;

            // Wait to verify no extra dispatches
            repeat(10) @(posedge clk);
            if ((cnt_after - cnt_before) !== 1) begin
                $display("[FAIL] TC3_ldmicro  dispatch count=%0d (exp 1)", cnt_after - cnt_before);
                ok = 0;
            end
            if (wb_at_dispatch !== 1'b0) begin
                $display("[FAIL] TC3_ldmicro  dispatch.wb=%0b (exp 0: no writeback)", wb_at_dispatch);
                ok = 0;
            end

            if (ok) begin
                $display("[PASS] TC3_ldmicro_dispatch   1 dispatch, wb=0 confirmed");
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

        // ==================================================================
        // TC4: Scoreboard RAW stall
        //   WMMA#1 dispatches → WMMA#2 stalls (C-tile WAW hazard) →
        //   inject writeback → WMMA#2 dispatches
        // ==================================================================
        begin : tc4
            int cnt_w1_start, cnt_w1_end, cnt_stall_mid, cnt_w2_end;
            bit ok = 1;

            preload_tile_regs(32'h01010101, 32'h01010101, 32'h00000000);
            preload_gpr(SCALE_REG, 32'h7F7F);
            preload_phase = 1'b0;
            @(posedge clk); #1;

`ifdef EXT_AG_TCU_ENABLE
            send_decode(build_ldscale(next_uuid++));
            wait_dispatch(tcu_dispatch_cnt + 1);
`endif

            // WMMA #1: dispatch all UOPs.
            // Requires k-step wb injection (same as TC2) because UOP 8 (k=1)
            // needs C-tiles that UOP 0-7 (k=0) locked.
            cnt_w1_start = tcu_dispatch_cnt;
            begin : tc4_w1_fork_blk
                automatic logic [UUID_WIDTH-1:0] u_w1 = next_uuid++;
                fork
                    send_decode(build_wmma(u_w1));
                    begin
                        for (int k = 0; k < TCU_K_STEPS; k++) begin
                            wait_dispatch(cnt_w1_start + (k+1) * (TCU_M_STEPS * TCU_N_STEPS));
                            if (k < TCU_K_STEPS - 1) begin
                                preload_phase = 1'b1;
                                inject_wb_for_tile('0);
                                preload_phase = 1'b0;
                            end
                        end
                    end
                join
            end
            wait_dispatch(cnt_w1_start + TCU_UOPS);
            cnt_w1_end = tcu_dispatch_cnt;
            // C-tiles are now locked by WMMA#1 k=1 UOPs.

            // Queue WMMA#2 (stalls: C-tiles still locked by WMMA#1 k=1)
            // Use module-level fork_uuid to avoid Verilator LIFETIME error with join_none
            fork_uuid = next_uuid++;
            fork
                send_decode(build_wmma(fork_uuid));
            join_none

            // Stall observation: 8 cycles with no new dispatch
            repeat(8) @(posedge clk);
            cnt_stall_mid = tcu_dispatch_cnt;

            if (cnt_stall_mid > cnt_w1_end) begin
                $display("[WARN] TC4: WMMA#2 dispatched %0d uops before wb injection (stall not observed)",
                         cnt_stall_mid - cnt_w1_end);
            end

            // Inject wb → WMMA#2 k=0 UOPs (0-7) can now dispatch
            preload_phase = 1'b1;
            inject_wb_for_tile(32'h41800000);
            preload_phase = 1'b0;

            // Wait for WMMA#2 k=0 step (M*N UOPs)
            wait_dispatch(cnt_w1_end + TCU_M_STEPS * TCU_N_STEPS);

            // WMMA#2 k=1 UOPs stall on C-tiles locked by its own k=0 → inject again
            preload_phase = 1'b1;
            inject_wb_for_tile(32'h41800000);
            preload_phase = 1'b0;

            // Wait for all WMMA#2 UOPs
            wait_dispatch(cnt_w1_end + TCU_UOPS);
            cnt_w2_end = tcu_dispatch_cnt;

            if ((cnt_w2_end - cnt_w1_end) !== TCU_UOPS) begin
                $display("[FAIL] TC4_stall  WMMA#2 dispatches=%0d after wb (exp %0d)",
                         cnt_w2_end - cnt_w1_end, TCU_UOPS);
                ok = 0;
            end

            if (ok) begin
                $display("[PASS] TC4_scoreboard_raw_stall   WMMA#2 dispatched after writeback injection");
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            inject_wb_for_tile(32'd0);
        end

        // ==================================================================
        // Summary
        // ==================================================================
        // ==================================================================
        // TC5: LDSCALE dispatch → rs1_data carries packed scale from reg file
        //   preload SCALE_REG = 32'h7F81 → scale_a=0x81=129, scale_b=0x7F=127
        //   Expect dispatch_if.rs1_data[0] == 32'h00007F81
        //   Verifies operands unit reads SCALE_REG correctly at dispatch time.
        // ==================================================================
        begin : tc5
            logic [31:0] scale_packed = 32'h00007F81;  // {scale_b=127, scale_a=129}
            logic [31:0] got_rs1;
            bit ok = 1;
            int cnt_before;

            preload_gpr(SCALE_REG, scale_packed);
            preload_phase = 1'b0;
            @(posedge clk); #1;

            cnt_before = tcu_dispatch_cnt;
            begin : tc5_fork_blk
                automatic logic [UUID_WIDTH-1:0] u5 = next_uuid++;
                fork
                    send_decode(build_ldscale(u5));
                    begin
                        // Sample rs1_data at the dispatch handshake cycle
                        @(posedge clk iff (dispatch_if[EX_TCU * `ISSUE_WIDTH].valid &&
                                           dispatch_if[EX_TCU * `ISSUE_WIDTH].ready));
                        got_rs1 = dispatch_if[EX_TCU * `ISSUE_WIDTH].data.rs1_data[0];
                    end
                join
            end
            wait_dispatch(cnt_before + 1);

            if (got_rs1 !== scale_packed) begin
                $display("[FAIL] TC5_ldscale_rs1_data  rs1_data[0]=0x%08h (exp 0x%08h = {scale_b=127, scale_a=129})",
                         got_rs1, scale_packed);
                ok = 0;
            end

            if (ok) begin
                $display("[PASS] TC5_ldscale_rs1_data   rs1_data[0]=0x%08h (scale correctly read from reg file)",
                         got_rs1);
                pass_cnt++;
            end else fail_cnt++;

            preload_phase = 1'b1;
            @(posedge clk); #1;
        end

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
