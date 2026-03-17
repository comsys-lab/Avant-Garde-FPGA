// =============================================================================
// tb_tcu_wmma.sv — VX_tcu_unit full-WMMA K-accumulation testbench
// =============================================================================
// Level 5: tests VX_tcu_unit with a complete WMMA computation (all UOPS).
//
// K-accumulation model (safe / serial mode):
//   For each uop in counter order (n inner → m middle → k outer):
//     1. Pack A_mat[sm][sk] / B_mat[sk][sn] / D_mat[sm][sn] into rs1/rs2/rs3.
//     2. Fire one dispatch_t → wait for one commit_t.
//     3. Verify DUT output against SW golden model (64-bit intermediate).
//     4. Write DUT output back to D_mat[sm][sn] (register-file feedback).
//
// Counter decode (matches VX_tcu_uops bit layout):
//   ctr = k << (LG_N + LG_M) | m << LG_N | n
//   → n innermost, m middle, k outermost
//
// SW saturation model (64-bit intermediate, per user requirement):
//   shifted = int64(dot) << exp_total
//   sat     = clip(shifted, INT32_MIN, INT32_MAX)
//   d[i][j] = sat + c[i][j]
//
// Config (NT=4 default):
//   TC_M=2, TC_N=2, TC_K=2
//   M_STEPS=4, N_STEPS=2, K_STEPS=2  → UOPS=16
//   SIMD_WIDTH=4, one dispatch_if lane
// =============================================================================
`timescale 1ns/1ps

`ifndef XLEN
  `define XLEN 32
`endif

`include "VX_define.vh"

module tb_tcu_wmma;

    import VX_gpu_pkg::*;
    import VX_tcu_pkg::*;

    // =========================================================================
    // Compile-time dimensions (derived from TCU package)
    // =========================================================================
    localparam LG_N      = $clog2(TCU_N_STEPS);   // log2(2) = 1  for NT=4
    localparam LG_M      = $clog2(TCU_M_STEPS);   // log2(4) = 2  for NT=4
    // localparam LG_K not needed directly; k = ctr >> (LG_N + LG_M)

    // Uops per k-group: all (sm,sn) combinations for one fixed k
    // NT=4 → 4×2 = 8   NT=8 → 4×4 = 16
    localparam K_GRP_SIZE = TCU_M_STEPS * TCU_N_STEPS;

    // =========================================================================
    // Clock & Reset
    // =========================================================================
    logic clk, reset;
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Interfaces
    // =========================================================================
    VX_dispatch_if dispatch_if[1]();
    VX_commit_if   commit_if  [1]();

    // =========================================================================
    // DUT: VX_tcu_unit
    // =========================================================================
    VX_tcu_unit #(
        .INSTANCE_ID ("tb_tcu_wmma")
    ) dut (
        .clk        (clk),
        .reset      (reset),
        .dispatch_if(dispatch_if),
        .commit_if  (commit_if)
    );

    // TB always accepts commits immediately
    genvar g;
    generate
        for (g = 0; g < 1; g++) begin : g_commit_ready
            assign commit_if[g].ready = 1'b1;
        end
    endgenerate

    // =========================================================================
    // Pass / Fail counters
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;

    // =========================================================================
    // SW reference model — one FEDP output element
    //
    //   dot   = Σ_{k=0}^{TC_K-1} Σ_{b=0}^{3} int8(rs1[i*TC_K+k][8b+7:8b])
    //                                         * int8(rs2[j*TC_K+k][8b+7:8b])
    //   sat   = clip(int64(dot) << exp_total, INT32_MIN, INT32_MAX)
    //   d     = sat + int32(rs3[i*TC_N+j])
    //
    // 64-bit intermediate prevents overflow in the shift comparison.
    // =========================================================================
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
            for (int b = 0; b < 4; b++)
                dot += $signed(rs1[i*TCU_TC_K + k][8*b+7 -: 8])
                     * $signed(rs2[b_off + j*TCU_TC_K + k][8*b+7 -: 8]);

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

`ifdef EXT_AG_TCU_ENABLE
    // =========================================================================
    // OT redesign: MX9 flatten reference model
    //   byte_in = {micro_exp[1b], INT7_mantissa[7b]}
    //   element_value = m7 × 2^mexp → flat = mexp ? m8<<1 : m8
    //   OT always applies this for INT WMMA — no mode flag needed.
    // =========================================================================
    function automatic logic [7:0] ref_flatten_mx9_byte(input logic [7:0] byte_in);
        logic              mexp;
        logic signed [7:0] m8;
        mexp = byte_in[7];
        m8   = $signed({byte_in[6], byte_in[6:0]});  // sign_ext7 → INT8
        return mexp ? m8 <<< 1 : m8;
    endfunction

    function automatic logic [31:0] ref_flatten_mx9_word(input logic [31:0] w);
        logic [31:0] res;
        res[ 7: 0] = ref_flatten_mx9_byte(w[ 7: 0]);
        res[15: 8] = ref_flatten_mx9_byte(w[15: 8]);
        res[23:16] = ref_flatten_mx9_byte(w[23:16]);
        res[31:24] = ref_flatten_mx9_byte(w[31:24]);
        return res;
    endfunction
`endif

    // =========================================================================
    // fire_dispatch: drive one dispatch handshake
    // =========================================================================
    task automatic fire_dispatch(input dispatch_t pkt);
        @(posedge clk); #1;
        dispatch_if[0].valid = 1'b1;
        dispatch_if[0].data  = pkt;

        @(posedge clk);
        while (!dispatch_if[0].ready) @(posedge clk);

        #1;
        dispatch_if[0].valid = 1'b0;
    endtask

    // =========================================================================
    // wait_commit: wait for commit pulse; sample in active region (pre-NBA)
    // VX_stream_buffer OUT_REG=1: data_out_r is overwritten by NBA in same
    // cycle → must read before #1.
    // =========================================================================
    task automatic wait_commit(output commit_t res);
        @(posedge clk);
        while (!commit_if[0].valid) @(posedge clk);
        res = commit_if[0].data;   // active region, before NBA
    endtask

    // =========================================================================
    // fire_ldscale: issue LDSCALE to write per-warp scale context
    //   rs1_data[0][3:0]  = scale_a, [7:4] = scale_b
    //   Fires one dispatch, drains the dummy commit (FEDP result = 0).
    // =========================================================================
`ifdef EXT_AG_TCU_ENABLE
    task automatic fire_ldscale(input logic [7:0] scale_a, scale_b);
        dispatch_t pkt;
        commit_t   dummy;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'(0);
        pkt.wis                = '0;
        pkt.sid                = '0;
        pkt.tmask              = '1;
        pkt.PC                 = '0;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.wb                 = 1'b1;
        pkt.rd                 = '0;
        pkt.sop                = 1'b1;
        pkt.eop                = 1'b1;
        // Scale packed into rs1_data[0]: [15:8]=scale_b, [7:0]=scale_a
        pkt.rs1_data[0]        = {16'b0, scale_b, scale_a};
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_LDSCALE;
        fire_dispatch(pkt);
        wait_commit(dummy);  // drain dummy result (d=0, harmless)
    endtask
`endif

    // =========================================================================
    // build_dispatch: assemble a dispatch_t for one (step_m, step_n) uop
    // =========================================================================
    function automatic dispatch_t build_dispatch(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [3:0] step_m, step_n
    );
        dispatch_t pkt;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'(1);
        pkt.wis                = '0;
        pkt.sid                = '0;
        pkt.tmask              = '1;
        pkt.PC                 = '0;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.wb                 = 1'b1;
        pkt.rd                 = '0;
        pkt.sop                = 1'b1;
        pkt.eop                = 1'b1;
        pkt.rs1_data           = rs1;
        pkt.rs2_data           = rs2;
        pkt.rs3_data           = rs3;
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
`ifdef EXT_AG_TCU_ENABLE
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
`endif
        return pkt;
    endfunction

    // =========================================================================
    // Global tile matrices (indexed by tile-step coordinates):
    //
    //   A_mat[sm][sk][i][kk]  — rs1 word for FEDP row i, k-word kk
    //   B_mat[sk][sn][j][kk]  — rs2 word for FEDP col j, k-word kk
    //   D_mat[sm][sn][i][j]   — accumulator (C input / rd output)
    //
    // Thread flattening (generalised for any A/B_SUB_BLOCKS):
    //   a_off = (sm & (A_SUB_BLOCKS-1)) * A_BLOCK_SIZE
    //   b_off = (sn & (B_SUB_BLOCKS-1)) * B_BLOCK_SIZE
    //   rs1[a_off + i*TC_K + kk] = A_mat[sm][sk][i][kk]
    //   rs2[b_off + j*TC_K + kk] = B_mat[sk][sn][j][kk]
    //   rs3[i*TC_N + j]          = D_mat[sm][sn][i][j]
    // =========================================================================
    logic [TCU_M_STEPS-1:0][TCU_K_STEPS-1:0]
          [TCU_TC_M-1:0][TCU_TC_K-1:0][`XLEN-1:0]       A_mat;

    logic [TCU_K_STEPS-1:0][TCU_N_STEPS-1:0]
          [TCU_TC_N-1:0][TCU_TC_K-1:0][`XLEN-1:0]       B_mat;

    logic [TCU_M_STEPS-1:0][TCU_N_STEPS-1:0]
          [TCU_TC_M-1:0][TCU_TC_N-1:0][`XLEN-1:0]       D_mat;

    logic [TCU_M_STEPS-1:0][TCU_N_STEPS-1:0]
          [TCU_TC_M-1:0][TCU_TC_N-1:0][`XLEN-1:0]       D_mat_save;

    // =========================================================================
    // Matrix fill helpers
    // =========================================================================
    task automatic fill_A(input logic [`XLEN-1:0] w);
        for (int sm = 0; sm < TCU_M_STEPS; sm++)
            for (int sk = 0; sk < TCU_K_STEPS; sk++)
                for (int ii = 0; ii < TCU_TC_M; ii++)
                    for (int kk = 0; kk < TCU_TC_K; kk++)
                        A_mat[sm][sk][ii][kk] = w;
    endtask

    task automatic fill_B(input logic [`XLEN-1:0] w);
        for (int sk = 0; sk < TCU_K_STEPS; sk++)
            for (int sn = 0; sn < TCU_N_STEPS; sn++)
                for (int jj = 0; jj < TCU_TC_N; jj++)
                    for (int kk = 0; kk < TCU_TC_K; kk++)
                        B_mat[sk][sn][jj][kk] = w;
    endtask

    task automatic fill_D(input logic [`XLEN-1:0] w);
        for (int sm = 0; sm < TCU_M_STEPS; sm++)
            for (int sn = 0; sn < TCU_N_STEPS; sn++)
                for (int ii = 0; ii < TCU_TC_M; ii++)
                    for (int jj = 0; jj < TCU_TC_N; jj++)
                        D_mat[sm][sn][ii][jj] = w;
    endtask

    // =========================================================================
    // run_wmma: issue all TCU_UOPS dispatches for one full WMMA
    //
    //   Counter order (matches VX_tcu_uops):  n inner → m → k outer
    //   Safe mode: fire → wait_commit → update D_mat before next dispatch.
    //
    //   Per-uop checks: d[i][j] == ref_d(rs1, rs2, rs3, exp_total, i, j)
    //   exp_total stability: asserts exp_a+exp_b is constant across all uops.
    // =========================================================================
    task automatic run_wmma(
        input string name,
        input logic [7:0] exp_a,
        input logic [7:0] exp_b
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_in, rs2_in, rs3_in;
        dispatch_t  pkt;
        commit_t    res;
        logic signed [9:0] exp_total;
        bit         test_pass;
        int         sm, sn, sk;
        int         n, m, k;

        exp_total  = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;
        test_pass  = 1;

`ifdef EXT_AG_TCU_ENABLE
        // Write scale context before WMMA K-loop (Avant-Garde flatten)
        fire_ldscale(exp_a, exp_b);
`endif

        for (int ctr = 0; ctr < TCU_UOPS; ctr++) begin
            // --- Decode counter (n innermost, m middle, k outermost) ----------
            n = (LG_N > 0) ? (ctr & ((1 << LG_N) - 1))          : 0;
            m = (LG_M > 0) ? ((ctr >> LG_N) & ((1 << LG_M) - 1)) : 0;
            k = ctr >> (LG_N + LG_M);
            sm = m; sn = n; sk = k;

            // --- Sub-block offsets (match RTL a_off/b_off) --------------------
            begin
                int a_off, b_off;
                a_off = (sm & (TCU_A_SUB_BLOCKS - 1)) * TCU_A_BLOCK_SIZE;
                b_off = (sn & (TCU_B_SUB_BLOCKS - 1)) * TCU_B_BLOCK_SIZE;

            // --- Flatten A_mat[sm][sk] → rs1 ---------------------------------
            rs1_in = '0;
            for (int ii = 0; ii < TCU_TC_M; ii++)
                for (int kk = 0; kk < TCU_TC_K; kk++)
                    rs1_in[a_off + ii * TCU_TC_K + kk] = A_mat[sm][sk][ii][kk];

            // --- Flatten B_mat[sk][sn] → rs2 ---------------------------------
            rs2_in = '0;
            for (int jj = 0; jj < TCU_TC_N; jj++)
                for (int kk = 0; kk < TCU_TC_K; kk++)
                    rs2_in[b_off + jj * TCU_TC_K + kk] = B_mat[sk][sn][jj][kk];

            // --- Flatten D_mat[sm][sn] → rs3 (t = i*TC_N + j) ----------------
            for (int ii = 0; ii < TCU_TC_M; ii++)
                for (int jj = 0; jj < TCU_TC_N; jj++)
                    rs3_in[ii * TCU_TC_N + jj] = D_mat[sm][sn][ii][jj];

            // --- Build and fire dispatch ---------------------------------------
            pkt = build_dispatch(rs1_in, rs2_in, rs3_in,
                                 4'(sm), 4'(sn));
            fire_dispatch(pkt);

            // --- Collect commit ------------------------------------------------
            wait_commit(res);

            // --- Per-element verify & D_mat update ----------------------------
            begin
                logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_ref, rs2_ref;
`ifdef EXT_AG_TCU_ENABLE
                // OT always flattens INT WMMA: apply same flatten to reference
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    rs1_ref[t] = ref_flatten_mx9_word(rs1_in[t]);
                    rs2_ref[t] = ref_flatten_mx9_word(rs2_in[t]);
                end
`else
                rs1_ref = rs1_in;
                rs2_ref = rs2_in;
`endif
                for (int ii = 0; ii < TCU_TC_M; ii++) begin
                    for (int jj = 0; jj < TCU_TC_N; jj++) begin
                        logic signed [31:0] got, exp_val;
                        got     = $signed(res.data[ii * TCU_TC_N + jj]);
                        exp_val = ref_d(rs1_ref, rs2_ref, rs3_in, exp_total, ii, jj, b_off);

                        // Write DUT output back to D_mat (register-file feedback)
                        D_mat[sm][sn][ii][jj] = res.data[ii * TCU_TC_N + jj];

                        if (got !== exp_val) begin
                            $display("[FAIL] %-28s ctr=%2d (m=%0d,n=%0d,k=%0d) [%0d][%0d] got=%0d exp=%0d",
                                     name, ctr, sm, sn, sk, ii, jj, got, exp_val);
                            test_pass = 0;
                        end
                    end
                end
            end
            end // begin (a_off/b_off scope)
        end // for ctr

        if (test_pass) begin
            $display("[PASS] %-28s all %0d uops × %0d outputs",
                     name, TCU_UOPS, TCU_TC_M * TCU_TC_N);
            pass_cnt++;
        end else begin
            fail_cnt++;
        end
    endtask

    // =========================================================================
    // run_wmma_stream: full WMMA with k-group streaming dispatch.
    //
    // Within each k-group (K_GRP_SIZE uops), dispatch_if.valid stays high
    // across consecutive cycles (back-to-back). Commits are collected
    // concurrently in the same while loop.
    //
    // Timing model:
    //   - Build all K_GRP_SIZE packets before issuing (no intra-group RAW).
    //   - Prime: set up grp_pkts[0] then enter the while loop.
    //   - Each loop iteration: @(posedge clk) → collect commit, advance
    //     dispatch if ready → #1 → set up next packet (or deassert valid).
    //   - After all commits collected, update D_mat and check vs ref_d.
    //   - Cross-group: D_mat is updated between k-groups → no inter-group RAW.
    // =========================================================================
    task automatic run_wmma_stream(
        input string name,
        input logic [7:0] exp_a,
        input logic [7:0] exp_b
    );
        dispatch_t                           grp_pkts [K_GRP_SIZE];
        commit_t                             grp_res  [K_GRP_SIZE];
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0]  rs1_t, rs2_t, rs3_t;
        logic signed [9:0] exp_total;
        int         issued, collected;
        int         n, m, sm, sn, sk;
        bit         test_pass;

        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;
        test_pass = 1;

`ifdef EXT_AG_TCU_ENABLE
        // Write scale context once before all k-groups (Avant-Garde flatten)
        fire_ldscale(exp_a, exp_b);
`endif

        for (int kg = 0; kg < TCU_K_STEPS; kg++) begin

            // --- Build packets for this k-group ----------------------------
            for (int kgi = 0; kgi < K_GRP_SIZE; kgi++) begin
                n  = (LG_N > 0) ? (kgi & ((1 << LG_N) - 1)) : 0;
                m  = kgi >> LG_N;
                sm = m; sn = n; sk = kg;
                begin
                    int a_off, b_off;
                    a_off = (sm & (TCU_A_SUB_BLOCKS - 1)) * TCU_A_BLOCK_SIZE;
                    b_off = (sn & (TCU_B_SUB_BLOCKS - 1)) * TCU_B_BLOCK_SIZE;

                    rs1_t = '0;
                    for (int ii = 0; ii < TCU_TC_M; ii++)
                        for (int kk = 0; kk < TCU_TC_K; kk++)
                            rs1_t[a_off + ii * TCU_TC_K + kk] = A_mat[sm][sk][ii][kk];
                    rs2_t = '0;
                    for (int jj = 0; jj < TCU_TC_N; jj++)
                        for (int kk = 0; kk < TCU_TC_K; kk++)
                            rs2_t[b_off + jj * TCU_TC_K + kk] = B_mat[sk][sn][jj][kk];
                    for (int ii = 0; ii < TCU_TC_M; ii++)
                        for (int jj = 0; jj < TCU_TC_N; jj++)
                            rs3_t[ii * TCU_TC_N + jj] = D_mat[sm][sn][ii][jj];

                    grp_pkts[kgi] = build_dispatch(rs1_t, rs2_t, rs3_t,
                                                   4'(sm), 4'(sn));
                end
            end

            // --- Issue k-group with valid=1 sustained -----------------------
            issued    = 0;
            collected = 0;

            @(posedge clk); #1;
            dispatch_if[0].valid = 1'b1;
            dispatch_if[0].data  = grp_pkts[0];

            while (issued < K_GRP_SIZE || collected < K_GRP_SIZE) begin
                @(posedge clk);

                // Collect commit in active region
                if (commit_if[0].valid && collected < K_GRP_SIZE) begin
                    grp_res[collected] = commit_if[0].data;
                    collected++;
                end

                // Advance dispatch if handshake fired
                if (issued < K_GRP_SIZE && dispatch_if[0].ready)
                    issued++;

                // Set up next cycle's dispatch
                #1;
                if (issued < K_GRP_SIZE) begin
                    dispatch_if[0].valid = 1'b1;
                    dispatch_if[0].data  = grp_pkts[issued];
                end else
                    dispatch_if[0].valid = 1'b0;
            end

            // --- Verify results and update D_mat ---------------------------
            for (int kgi = 0; kgi < K_GRP_SIZE; kgi++) begin
                n  = (LG_N > 0) ? (kgi & ((1 << LG_N) - 1)) : 0;
                m  = kgi >> LG_N;
                sm = m; sn = n; sk = kg;
                begin
                    int a_off, b_off;
                    a_off = (sm & (TCU_A_SUB_BLOCKS - 1)) * TCU_A_BLOCK_SIZE;
                    b_off = (sn & (TCU_B_SUB_BLOCKS - 1)) * TCU_B_BLOCK_SIZE;

                    // Rebuild rs1/rs2/rs3 using pre-update D_mat
                    rs1_t = '0;
                    for (int ii = 0; ii < TCU_TC_M; ii++)
                        for (int kk = 0; kk < TCU_TC_K; kk++)
                            rs1_t[a_off + ii * TCU_TC_K + kk] = A_mat[sm][sk][ii][kk];
                    rs2_t = '0;
                    for (int jj = 0; jj < TCU_TC_N; jj++)
                        for (int kk = 0; kk < TCU_TC_K; kk++)
                            rs2_t[b_off + jj * TCU_TC_K + kk] = B_mat[sk][sn][jj][kk];
                    for (int ii = 0; ii < TCU_TC_M; ii++)
                        for (int jj = 0; jj < TCU_TC_N; jj++)
                            rs3_t[ii * TCU_TC_N + jj] = D_mat[sm][sn][ii][jj];

                    begin
                        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_ref2, rs2_ref2;
`ifdef EXT_AG_TCU_ENABLE
                        for (int t = 0; t < `SIMD_WIDTH; t++) begin
                            rs1_ref2[t] = ref_flatten_mx9_word(rs1_t[t]);
                            rs2_ref2[t] = ref_flatten_mx9_word(rs2_t[t]);
                        end
`else
                        rs1_ref2 = rs1_t;
                        rs2_ref2 = rs2_t;
`endif
                        for (int ii = 0; ii < TCU_TC_M; ii++) begin
                            for (int jj = 0; jj < TCU_TC_N; jj++) begin
                                logic signed [31:0] got_s, exp_s;
                                got_s = $signed(grp_res[kgi].data[ii * TCU_TC_N + jj]);
                                exp_s = ref_d(rs1_ref2, rs2_ref2, rs3_t, exp_total, ii, jj, b_off);
                                // Update D_mat AFTER computing expected (for next k-group)
                                D_mat[sm][sn][ii][jj] = grp_res[kgi].data[ii * TCU_TC_N + jj];
                                if (got_s !== exp_s) begin
                                    $display("[FAIL] %-28s k=%0d kgi=%0d [%0d][%0d] got=%0d exp=%0d",
                                             name, kg, kgi, ii, jj, got_s, exp_s);
                                    test_pass = 0;
                                end
                            end
                        end
                    end
                end
            end

        end // for kg

        if (test_pass) begin
            $display("[PASS] %-28s all %0d uops × %0d outputs (stream)",
                     name, TCU_UOPS, TCU_TC_M * TCU_TC_N);
            pass_cnt++;
        end else
            fail_cnt++;
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin
        // ---- Reset ----------------------------------------------------------
        reset                = 1'b1;
        dispatch_if[0].valid = 1'b0;
        dispatch_if[0].data  = '0;
        repeat(4) @(posedge clk);
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;

        $display("=== tb_tcu_wmma ===");
        $display("  TCU_TC_M=%0d  TCU_TC_N=%0d  TCU_TC_K=%0d",
                 TCU_TC_M, TCU_TC_N, TCU_TC_K);
        $display("  M_STEPS=%0d  N_STEPS=%0d  K_STEPS=%0d  UOPS=%0d",
                 TCU_M_STEPS, TCU_N_STEPS, TCU_K_STEPS, TCU_UOPS);
        $display("------------------------------------------------------------");

`ifdef TESTS_SAFE
        // ====================================================================
        // TC1: All-ones A & B, zero C, exp=0
        //   Per FEDP per k-step: dot = TC_K*4*1 = 8
        //   D after k=0: 8+0=8 ;  D after k=1: 8+8=16
        //   Expected final D[i][j] = 16 for all (i,j)
        // ====================================================================
        fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'd0);
        run_wmma("TC1_ones_k_accum", 8'd127, 8'd127);

        // ====================================================================
        // TC2: Ones, exp_total=4 (exp_a=2, exp_b=2)
        //   Per k-step: 8<<4=128 ; k=0→128, k=1→128+128=256
        // ====================================================================
        fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'd0);
        run_wmma("TC2_ones_exp4", 8'd129, 8'd129);

        // ====================================================================
        // TC3: Non-zero initial C → verify C passthrough in accumulation
        //   fill_D(100): D start = 100 for every tile position
        //   k=0: 8+100=108 ; k=1: 8+108=116
        // ====================================================================
        fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'd100);
        run_wmma("TC3_nonzero_C", 8'd127, 8'd127);

        // ====================================================================
        // TC4: Asymmetric rows / columns (same pattern as tb_tcu_unit TC4)
        //   A row 0 = 2s, A row 1 = 3s  (all k-steps and m-steps)
        //   B col 0 = 1s, B col 1 = 4s  (all k-steps and n-steps)
        //   Per k-step:
        //     d[0][0]=16, d[0][1]=64, d[1][0]=24, d[1][1]=96
        //   After K_STEPS=2:
        //     d[0][0]=32, d[0][1]=128, d[1][0]=48, d[1][1]=192
        // ====================================================================
        begin
            for (int sm_g = 0; sm_g < TCU_M_STEPS; sm_g++)
                for (int sk_g = 0; sk_g < TCU_K_STEPS; sk_g++)
                    for (int ii = 0; ii < TCU_TC_M; ii++)
                        for (int kk = 0; kk < TCU_TC_K; kk++)
                            A_mat[sm_g][sk_g][ii][kk] =
                                (ii == 0) ? 32'h02020202 : 32'h03030303;
            for (int sk_g = 0; sk_g < TCU_K_STEPS; sk_g++)
                for (int sn_g = 0; sn_g < TCU_N_STEPS; sn_g++)
                    for (int jj = 0; jj < TCU_TC_N; jj++)
                        for (int kk = 0; kk < TCU_TC_K; kk++)
                            B_mat[sk_g][sn_g][jj][kk] =
                                (jj == 0) ? 32'h01010101 : 32'h04040404;
            fill_D(32'd0);
            run_wmma("TC4_asymmetric", 8'd127, 8'd127);
        end

        // ====================================================================
        // TC5: Negative × Positive, exp=0
        //   MX9: A byte=0x7F={mexp=0, m7=7'b1111111=-1} → flat=-1
        //        B byte=0x01={mexp=0, m7=+1} → flat=+1
        //   dot per k-step = TC_K*4*(-1)*(+1) = -8
        //   After K_STEPS=2: d[i][j] = -16
        // ====================================================================
        fill_A(32'h7F7F7F7F); fill_B(32'h01010101); fill_D(32'd0);
        run_wmma("TC5_neg_dot", 8'd127, 8'd127);

        // ====================================================================
        // TC6: Positive saturation path — flat=-128, exp_total=+14 (max)
        //   MX9: byte=0xC0={mexp=1, m7=-64} → flat=-64<<1=-128
        //   dot = TC_K*4*128^2 = 131072 per k
        //   131072 << 14 = 2147483648 > INT32_MAX → saturate to INT32_MAX
        //   After k=0: INT32_MAX + 0 = INT32_MAX
        //   After k=1: INT32_MAX + INT32_MAX = -2 (32-bit wrap, no final sat)
        // ====================================================================
        fill_A(32'hC0C0C0C0); fill_B(32'hC0C0C0C0); fill_D(32'd0);
        run_wmma("TC6_pos_saturation", 8'd134, 8'd134);

        // ====================================================================
        // TC7: Right-shift with negative dot — Phase 4② coverage
        //   MX9: A byte=0x7F={mexp=0,m7=-1}→flat=-1; B byte=0x01→flat=+1
        //   exp_a=-2, exp_b=0 → exp_total=-2
        //   dot = TC_K*4*(-1)*(+1) = -8 per k
        //   -8 >>> 2 = -2 per k
        //   After k=0: D=-2  After k=1: D=-4
        // ====================================================================
        fill_A(32'h7F7F7F7F); fill_B(32'h01010101); fill_D(32'd0);
        run_wmma("TC7_rshift_neg_dot", 8'd125, 8'd127);

        // ====================================================================
        // TC8: MX-style block exponents
        //   A=[1,2,3,4]*4 per word, B=[1]*4 per word, exp_total=6
        //   dot per k-step = (1+2+3+4)*2*4=80 ; 80<<6=5120 per k
        //   K_STEPS=2 → 10240
        // ====================================================================
        fill_A(32'h04030201); fill_B(32'h01010101); fill_D(32'd0);
        run_wmma("TC8_MX_style", 8'd130, 8'd130);

        // ====================================================================
        // TC9: Random data — statistical end-to-end confidence
        //   XorShift32 PRNG seeded with 0xDEAD_BEEF
        // ====================================================================
        begin
            logic [31:0] seed;
            seed = 32'hDEAD_BEEF;
            for (int sm_g = 0; sm_g < TCU_M_STEPS; sm_g++)
                for (int sk_g = 0; sk_g < TCU_K_STEPS; sk_g++)
                    for (int ii = 0; ii < TCU_TC_M; ii++)
                        for (int kk = 0; kk < TCU_TC_K; kk++) begin
                            seed = seed ^ (seed << 13);
                            seed = seed ^ (seed >> 17);
                            seed = seed ^ (seed << 5);
                            A_mat[sm_g][sk_g][ii][kk] = seed;
                        end
            for (int sk_g = 0; sk_g < TCU_K_STEPS; sk_g++)
                for (int sn_g = 0; sn_g < TCU_N_STEPS; sn_g++)
                    for (int jj = 0; jj < TCU_TC_N; jj++)
                        for (int kk = 0; kk < TCU_TC_K; kk++) begin
                            seed = seed ^ (seed << 13);
                            seed = seed ^ (seed >> 17);
                            seed = seed ^ (seed << 5);
                            B_mat[sk_g][sn_g][jj][kk] = seed;
                        end
            fill_D(32'd42);
            run_wmma("TC9_random", 8'd128, 8'd129);
        end
`endif // TESTS_SAFE

`ifdef TESTS_STREAM
        // ====================================================================
        // TC10: Streaming cross-check — ones×ones, exp=0
        //   Safe mode first (reference), then streaming mode.
        //   Both must produce D[i][j]=16 for all (i,j).
        //   After run, D_mat (stream) must equal D_mat_save (safe).
        // ====================================================================
        begin
            fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'd0);
            run_wmma("TC10_safe_ref", 8'd127, 8'd127);
            D_mat_save = D_mat;

            fill_D(32'd0);
            run_wmma_stream("TC10_stream", 8'd127, 8'd127);

            begin
                bit cross_ok;
                cross_ok = 1;
                for (int sm_c = 0; sm_c < TCU_M_STEPS; sm_c++)
                    for (int sn_c = 0; sn_c < TCU_N_STEPS; sn_c++)
                        for (int ii = 0; ii < TCU_TC_M; ii++)
                            for (int jj = 0; jj < TCU_TC_N; jj++)
                                if (D_mat[sm_c][sn_c][ii][jj] !==
                                    D_mat_save[sm_c][sn_c][ii][jj]) begin
                                    $display("[FAIL] TC10_cross sm=%0d sn=%0d [%0d][%0d] stream=%0d safe=%0d",
                                             sm_c, sn_c, ii, jj,
                                             $signed(D_mat[sm_c][sn_c][ii][jj]),
                                             $signed(D_mat_save[sm_c][sn_c][ii][jj]));
                                    cross_ok = 0;
                                end
                if (cross_ok) begin
                    $display("[PASS] TC10_cross             safe vs stream match");
                    pass_cnt++;
                end else
                    fail_cnt++;
            end
        end

        // ====================================================================
        // TC11: Streaming, exponents (exp_a=2, exp_b=2 → exp_total=4)
        //   ones×ones: dot=8 per k-step → 8<<4=128
        //   After K_STEPS=2: D[i][j]=256
        // ====================================================================
        fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'd0);
        run_wmma_stream("TC11_stream_exp4", 8'd129, 8'd129);

        // ====================================================================
        // TC12: Streaming with random data — same seed as TC9
        //   End-to-end confidence for streaming path with varied inputs.
        // ====================================================================
        begin
            logic [31:0] seed;
            seed = 32'hDEAD_BEEF;
            for (int sm_g = 0; sm_g < TCU_M_STEPS; sm_g++)
                for (int sk_g = 0; sk_g < TCU_K_STEPS; sk_g++)
                    for (int ii = 0; ii < TCU_TC_M; ii++)
                        for (int kk = 0; kk < TCU_TC_K; kk++) begin
                            seed = seed ^ (seed << 13);
                            seed = seed ^ (seed >> 17);
                            seed = seed ^ (seed << 5);
                            A_mat[sm_g][sk_g][ii][kk] = seed;
                        end
            for (int sk_g = 0; sk_g < TCU_K_STEPS; sk_g++)
                for (int sn_g = 0; sn_g < TCU_N_STEPS; sn_g++)
                    for (int jj = 0; jj < TCU_TC_N; jj++)
                        for (int kk = 0; kk < TCU_TC_K; kk++) begin
                            seed = seed ^ (seed << 13);
                            seed = seed ^ (seed >> 17);
                            seed = seed ^ (seed << 5);
                            B_mat[sk_g][sn_g][jj][kk] = seed;
                        end
            fill_D(32'd42);
            run_wmma_stream("TC12_stream_random", 8'd128, 8'd129);
        end
`endif // TESTS_STREAM

`ifdef TESTS_SAT
        // ====================================================================
        // TC13: Max positive exponent (exp_total=+14)
        //   MX9: byte=0xC0={mexp=1,m7=-64}→flat=-128
        //   dot = TC_K*4*128^2 = 131072 per k
        //   131072 << 14 = 2147483648 > INT32_MAX → sat = INT32_MAX each k-step
        //   After k=0: INT32_MAX + 0 = INT32_MAX
        //   After k=1: INT32_MAX + INT32_MAX = -2 (wrapping 32-bit add)
        // ====================================================================
        fill_A(32'hC0C0C0C0); fill_B(32'hC0C0C0C0); fill_D(32'd0);
        run_wmma("TC13_exp14_sat", 8'd134, 8'd134);

        // ====================================================================
        // TC14: Asymmetric saturation — row 0 saturates, row 1 does not
        //   A_mat[*][*][0][*]=-128 (0x80), A_mat[*][*][1][*]=+1 (0x01)
        //   MX9: 0xC0={mexp=1,m7=-64}→flat=-128; 0x01→flat=+1
        //   dot[0][j] = TC_K*4*(-128)*(-128) = 131072 → <<14 > INT32_MAX → +sat
        //   dot[1][j] = TC_K*4*(+1)*(-128) = -1024 → -1024<<14 = -16777216 (no sat)
        //   After k=0: D[0][j]=INT32_MAX,  D[1][j]=-16777216
        //   After k=1: D[0][j]=-2 (wrap),  D[1][j]=-33554432
        // ====================================================================
        begin
            for (int sm_g = 0; sm_g < TCU_M_STEPS; sm_g++)
                for (int sk_g = 0; sk_g < TCU_K_STEPS; sk_g++)
                    for (int ii = 0; ii < TCU_TC_M; ii++)
                        for (int kk = 0; kk < TCU_TC_K; kk++)
                            A_mat[sm_g][sk_g][ii][kk] =
                                (ii == 0) ? 32'hC0C0C0C0 : 32'h01010101;
            fill_B(32'hC0C0C0C0);
            fill_D(32'd0);
            run_wmma("TC14_asymm_sat", 8'd134, 8'd134);
        end

        // ====================================================================
        // TC15: Non-zero C + saturation → wrapping in opposite direction
        //   MX9: byte=0xC0={mexp=1,m7=-64}→flat=-128; A=B flat=-128, C=1
        //   sat = INT32_MAX each k-step (131072<<14 = INT32_MAX+1 → clamp)
        //   After k=0: INT32_MAX + 1 = INT32_MIN  (positive wraps to negative!)
        //   After k=1: INT32_MAX + INT32_MIN = -1
        // ====================================================================
        fill_A(32'hC0C0C0C0); fill_B(32'hC0C0C0C0); fill_D(32'd1);
        run_wmma("TC15_nonzero_C_sat", 8'd134, 8'd134);

        // ====================================================================
        // TC16: Streaming + saturation cross-check (TC15 data)
        //   Safe mode as reference → D_mat_save → streaming → compare
        // ====================================================================
        begin
            fill_A(32'hC0C0C0C0); fill_B(32'hC0C0C0C0); fill_D(32'd1);
            run_wmma("TC16_safe_sat_ref", 8'd134, 8'd134);
            D_mat_save = D_mat;

            fill_D(32'd1);
            run_wmma_stream("TC16_stream_sat", 8'd134, 8'd134);

            begin
                bit cross_ok;
                cross_ok = 1;
                for (int sm_c = 0; sm_c < TCU_M_STEPS; sm_c++)
                    for (int sn_c = 0; sn_c < TCU_N_STEPS; sn_c++)
                        for (int ii = 0; ii < TCU_TC_M; ii++)
                            for (int jj = 0; jj < TCU_TC_N; jj++)
                                if (D_mat[sm_c][sn_c][ii][jj] !==
                                    D_mat_save[sm_c][sn_c][ii][jj]) begin
                                    $display("[FAIL] TC16_cross sm=%0d sn=%0d [%0d][%0d] stream=%0d safe=%0d",
                                             sm_c, sn_c, ii, jj,
                                             $signed(D_mat[sm_c][sn_c][ii][jj]),
                                             $signed(D_mat_save[sm_c][sn_c][ii][jj]));
                                    cross_ok = 0;
                                end
                if (cross_ok) begin
                    $display("[PASS] TC16_cross             safe vs stream match");
                    pass_cnt++;
                end else
                    fail_cnt++;
            end
        end
`endif // TESTS_SAT

        // ====================================================================
        // Summary
        // ====================================================================
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
