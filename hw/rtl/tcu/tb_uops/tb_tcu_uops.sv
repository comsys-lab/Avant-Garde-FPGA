// =============================================================================
// tb_tcu_uops.sv — VX_tcu_uops register-address sequencer testbench
// =============================================================================
// Verifies for every counter 0..UOPS-1:
//   (1) rs1 = make_reg_num(F, RA + (m >> LG_A_SB) << LG_K | k)
//   (2) rs2 = make_reg_num(F, RB + ((k << LG_N) | n) >> LG_B_SB)
//          AG-TCU specific: LG_B_SB=1 → n=0,1 share same reg; n=2,3 share same reg
//   (3) rs3 = make_reg_num(F, RC + (m << LG_N) | n)
//   (4) rd  == rs3
//   (5) step_m == m_index, step_n == n_index
//   (6) wb == 1
//   (7) done == 1 exactly at last uop (counter == UOPS-1)
//   (8) tcu_op passthrough (EXT_AG_TCU_ENABLE only)
//
// Timing note: uses #1 AFTER @(posedge clk) to read counter's new value
// (counter is registered; its NBA commits with the current posedge,
//  so reading with #1 sees the updated value - opposite of stream_buffer case).
//
// Compile configurations:
//   NT=4 (default): UOPS=16, LG_B_SB=0 — standard TCU
//   NT=8          : UOPS=32, LG_B_SB=1 — tests rs2 shared-packing path
//   +EXT_AG_TCU_ENABLE: adds exp_a/exp_b passthrough check
// =============================================================================

`timescale 1ns/1ps
`ifndef XLEN
  `define XLEN 32
`endif

module tb_tcu_uops;

    import VX_gpu_pkg::*;
`ifdef EXT_TCU_ENABLE
    import VX_tcu_pkg::*;
`endif

    // -----------------------------------------------------------------------
    // Mirror VX_tcu_uops compile-time constants (for golden model)
    // -----------------------------------------------------------------------
    localparam UOPS    = TCU_UOPS;
    localparam LG_N    = $clog2(TCU_N_STEPS);   // 0 when N_STEPS==1
    localparam LG_M    = $clog2(TCU_M_STEPS);
    localparam LG_K    = $clog2(TCU_K_STEPS);
    localparam LG_A_SB = $clog2(TCU_A_SUB_BLOCKS);
    localparam LG_B_SB = $clog2(TCU_B_SUB_BLOCKS);

    // -----------------------------------------------------------------------
    // DUT I/O
    // -----------------------------------------------------------------------
    logic      clk, reset;
    ibuffer_t  ibuf_in, ibuf_out;
    logic      start, next, done;

    VX_tcu_uops dut (
        .clk     (clk),
        .reset   (reset),
        .ibuf_in (ibuf_in),
        .ibuf_out(ibuf_out),
        .start   (start),
        .next    (next),
        .done    (done)
    );

    // -----------------------------------------------------------------------
    // Clock (10 ns period)
    // -----------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // Counters
    // -----------------------------------------------------------------------
    int pass_cnt = 0;
    int fail_cnt = 0;

    // -----------------------------------------------------------------------
    // Golden model: index extraction from linear counter
    // -----------------------------------------------------------------------
    function automatic int n_of(int ctr);
        return (LG_N > 0) ? (ctr & ((1 << LG_N) - 1)) : 0;
    endfunction

    function automatic int m_of(int ctr);
        return (LG_M > 0) ? ((ctr >> LG_N) & ((1 << LG_M) - 1)) : 0;
    endfunction

    function automatic int k_of(int ctr);
        return (LG_K > 0) ? ((ctr >> (LG_N + LG_M)) & ((1 << LG_K) - 1)) : 0;
    endfunction

    // Golden register numbers (6-bit: bit[5]=float type, bits[4:0]=reg index)
    function automatic logic [NUM_REGS_BITS-1:0] exp_rs1(int ctr);
        int m = m_of(ctr), k = k_of(ctr);
        int off = ((m >> LG_A_SB) << LG_K) | k;
        return make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RA) + RV_REGS_BITS'(off));
    endfunction

    function automatic logic [NUM_REGS_BITS-1:0] exp_rs2(int ctr);
        int n = n_of(ctr), k = k_of(ctr);
        int off = ((k << LG_N) | n) >> LG_B_SB;
        return make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RB) + RV_REGS_BITS'(off));
    endfunction

    function automatic logic [NUM_REGS_BITS-1:0] exp_rs3(int ctr);
        int n = n_of(ctr), m = m_of(ctr);
        int off = (m << LG_N) | n;
        return make_reg_num(REG_TYPE_F, RV_REGS_BITS'(TCU_RC) + RV_REGS_BITS'(off));
    endfunction

    // -----------------------------------------------------------------------
    // Assertion helpers
    // -----------------------------------------------------------------------
    task automatic assert_eq(
        input string  field,
        input int     ctr,
        input logic [NUM_REGS_BITS-1:0] got, exp
    );
        if (got !== exp) begin
            fail_cnt++;
            $display("  FAIL uop[%0d] %s: got f%0d(=%0d), exp f%0d(=%0d)",
                ctr, field,
                get_reg_idx(got), got,
                get_reg_idx(exp), exp);
        end else begin
            pass_cnt++;
        end
    endtask

    // -----------------------------------------------------------------------
    // Per-uop check task
    // -----------------------------------------------------------------------
    task automatic check_uop(int ctr);
        logic [NUM_REGS_BITS-1:0] e1, e2, e3;
        logic exp_done_val;

        e1 = exp_rs1(ctr);
        e2 = exp_rs2(ctr);
        e3 = exp_rs3(ctr);
        exp_done_val = (ctr == UOPS - 1);

        // (1) rs1
        assert_eq("rs1", ctr, ibuf_out.rs1, e1);
        // (2) rs2
        assert_eq("rs2", ctr, ibuf_out.rs2, e2);
        // (3) rs3
        assert_eq("rs3", ctr, ibuf_out.rs3, e3);
        // (4) rd == rs3
        if (ibuf_out.rd !== e3) begin
            fail_cnt++;
            $display("  FAIL uop[%0d] rd!=rs3: rd=%0d rs3=%0d", ctr, ibuf_out.rd, e3);
        end else begin
            pass_cnt++;
        end
        // (5) step_m, step_n
        if (ibuf_out.op_args.tcu.step_m !== 4'(m_of(ctr))) begin
            fail_cnt++;
            $display("  FAIL uop[%0d] step_m: got %0d exp %0d",
                ctr, ibuf_out.op_args.tcu.step_m, m_of(ctr));
        end else pass_cnt++;
        if (ibuf_out.op_args.tcu.step_n !== 4'(n_of(ctr))) begin
            fail_cnt++;
            $display("  FAIL uop[%0d] step_n: got %0d exp %0d",
                ctr, ibuf_out.op_args.tcu.step_n, n_of(ctr));
        end else pass_cnt++;
        // (6) wb == 1
        if (ibuf_out.wb !== 1'b1) begin
            fail_cnt++;
            $display("  FAIL uop[%0d] wb=%0d exp 1", ctr, ibuf_out.wb);
        end else pass_cnt++;
        // (7) done flag
        if (done !== exp_done_val) begin
            fail_cnt++;
            $display("  FAIL uop[%0d] done=%0d exp %0d", ctr, done, exp_done_val);
        end else pass_cnt++;
    endtask

    // -----------------------------------------------------------------------
    // rs2 sharing structural checks (golden model only, before DUT run)
    // -----------------------------------------------------------------------
    task automatic golden_rs2_sharing_check();
        if (LG_B_SB == 0) begin
            $display("--- rs2 sharing: LG_B_SB=0, no sharing (standard TCU) ---");
            pass_cnt++;
            return;
        end

        $display("--- rs2 sharing checks (LG_B_SB=%0d) ---", LG_B_SB);

        // Check every pair (n=2i, n=2i+1) for the same k,m shares the same B reg
        begin
            int errors = 0;
            for (int k = 0; k < TCU_K_STEPS; k++) begin
                for (int m = 0; m < TCU_M_STEPS; m++) begin
                    for (int n = 0; n < TCU_N_STEPS; n += (1 << LG_B_SB)) begin
                        // All n in [n .. n+(1<<LG_B_SB)-1] must share same rs2
                        logic [NUM_REGS_BITS-1:0] base_reg;
                        int base_ctr;
                        base_ctr = (k << (LG_N + LG_M)) | (m << LG_N) | n;
                        base_reg = exp_rs2(base_ctr);
                        for (int dn = 1; dn < (1 << LG_B_SB); dn++) begin
                            int ctr2 = (k << (LG_N + LG_M)) | (m << LG_N) | (n + dn);
                            if (exp_rs2(ctr2) !== base_reg) begin
                                errors++;
                                $display("  FAIL sharing: k=%0d m=%0d n=%0d vs n=%0d: rs2=%0d vs %0d",
                                    k, m, n, n+dn, get_reg_idx(base_reg), get_reg_idx(exp_rs2(ctr2)));
                            end
                        end
                    end
                end
            end
            if (errors == 0) begin
                pass_cnt++;
                $display("  PASS: all n-pairs share same rs2 (LG_B_SB=%0d)", LG_B_SB);
            end else fail_cnt++;
        end

        // k stride check: rs2(k+1, n=0, m=0) - rs2(k=0, n=0, m=0) == 2^(LG_N - LG_B_SB)
        begin
            int ctr_k0 = 0;  // k=0, m=0, n=0
            int ctr_k1 = (1 << (LG_N + LG_M));  // k=1, m=0, n=0
            int r0 = get_reg_idx(exp_rs2(ctr_k0));
            int r1 = get_reg_idx(exp_rs2(ctr_k1));
            int exp_stride = (1 << (LG_N - LG_B_SB));
            if ((r1 - r0) != exp_stride) begin
                fail_cnt++;
                $display("  FAIL k_stride: rs2(k=0)=f%0d rs2(k=1)=f%0d delta=%0d exp=%0d",
                    r0, r1, r1-r0, exp_stride);
            end else begin
                pass_cnt++;
                $display("  PASS k_stride: delta=%0d (exp %0d)", r1-r0, exp_stride);
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin
        // Init
        reset   = 1;
        start   = 0;
        next    = 0;
        ibuf_in = '0;

`ifdef EXT_AG_TCU_ENABLE
        // Set recognizable value for tcu_op passthrough check
        ibuf_in.op_args.tcu.tcu_op = TCU_OP_LDSCALE;
`endif

        // Print config
        $display("=== tb_tcu_uops ===");
        $display("    NUM_THREADS=%0d  UOPS=%0d", `NUM_THREADS, UOPS);
        $display("    N_STEPS=%0d  M_STEPS=%0d  K_STEPS=%0d",
            TCU_N_STEPS, TCU_M_STEPS, TCU_K_STEPS);
        $display("    TC_M=%0d  TC_N=%0d  TC_K=%0d",
            TCU_TC_M, TCU_TC_N, TCU_TC_K);
        $display("    LG_N=%0d  LG_M=%0d  LG_K=%0d  LG_A_SB=%0d  LG_B_SB=%0d",
            LG_N, LG_M, LG_K, LG_A_SB, LG_B_SB);
        $display("    RA=%0d  RB=%0d  RC=%0d  NRB=%0d",
            TCU_RA, TCU_RB, TCU_RC, TCU_NRB);

        // Reset for 2 cycles
        @(posedge clk); @(posedge clk);
        reset = 0;

        // ---------------------------------------------------------------
        // Pre-flight: rs2 sharing structural check (golden model only)
        // ---------------------------------------------------------------
        golden_rs2_sharing_check();

        // ---------------------------------------------------------------
        // Uop sequencer test
        // ---------------------------------------------------------------
        $display("--- sequencer: %0d uops ---", UOPS);

        // Fire start.
        // TIMING: do NOT deassert start/next in the same active region as
        // @(posedge clk).  The coroutine is resumed before always_ff evaluates
        // in Verilator's active-region ordering, so driving a signal to 0 there
        // causes always_ff to see 0 instead of 1.  Deassert AFTER #1 (post-NBA).
        start = 1;
        @(posedge clk);
        // Posedge: always_ff sees start=1, busy=0 → busy<=1 (NBA).
        #1;        // After NBA: busy=1, counter=0
        start = 0; // Safe to deassert now
        check_uop(0);

`ifdef EXT_AG_TCU_ENABLE
        // tcu_op passthrough check (constant across all uops)
        if (ibuf_out.op_args.tcu.tcu_op !== TCU_OP_LDSCALE) begin
            fail_cnt++;
            $display("  FAIL tcu_op passthrough: got %0d exp %0d (TCU_OP_LDSCALE)",
                     ibuf_out.op_args.tcu.tcu_op, TCU_OP_LDSCALE);
        end else pass_cnt++;
`endif

        // Iterate remaining uops.
        // Same timing rule: deassert next AFTER #1, not in active region.
        for (int i = 1; i < UOPS; i++) begin
            next = 1;
            @(posedge clk);
            // Posedge: always_ff sees next=1, busy=1 → counter<=i, done<=(NBA).
            #1;        // After NBA: counter=i, done=(i==UOPS-1)
            next = 0;  // Safe to deassert now
            check_uop(i);
        end

        // ---------------------------------------------------------------
        // Result
        // ---------------------------------------------------------------
        $display("=== Results: %0d PASS / %0d FAIL ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("FAIL: %0d test(s) failed", fail_cnt);

        $finish;
    end

endmodule
