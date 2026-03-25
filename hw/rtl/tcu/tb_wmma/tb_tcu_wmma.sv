// =============================================================================
// tb_tcu_wmma.sv — VX_tcu_unit full-WMMA K-accumulation testbench
// =============================================================================
// Level 5: tests VX_tcu_unit with a complete WMMA computation (all UOPS).
//
// Phase 10: INT path FEDP outputs FP32 (INT8 MAC → FP32 via exp_total scale).
//
// Test cases:
//   TC_int_k_accum      — INT8 path K-accumulation regression (FP32 output)
//   TC_MX9_mexp0        — MX9 WMMA, mexp=0 (identity) → same result as INT8
//   TC_MX9_mexp_a1      — MX9 WMMA, mexp_a=1 (A×2 before MAC)
//   TC_int_exp_pos2     — exp_total=+2 (scale_a=128, scale_b=128): fp32_exp_scale +2
//   TC_int_exp_neg1     — exp_total=-1 (scale_a=127, scale_b=126): fp32_exp_scale -1
//   TC_MX9_mexp_mixed   — pair1_mexp=1, pair0_mexp=0: pair-indexed flatten
//   TC_nonzero_C        — C=-8.0 starting accumulator: fp32_add with mixed sign
//   TC_neg_A            — A=0xFF (INT8=-1): negative dot product → neg FP32 output
//   TC_MX9_sat_pos      — A=0x40+mexp=1 → saturation 0x7F (overflow_pos path)
//   TC_FLAT_full_ident  — FLAT full sequence, mexp=0 → passthrough (regression)
//   TC_FLAT_full_double — FLAT A-tile ×2 + B-tile passthrough (isolation check)
//   TC_FLAT_full_mixed  — FLAT A-tile pair-mixed shift (pair1≠pair0)
//   TC_FLAT_then_WMMA   — FLAT output → WMMA input (pipeline integration)
//
// Safe (serial) mode: fire one uop → wait commit → update D_mat → next uop.
// =============================================================================
`timescale 1ns/1ps

`ifndef XLEN
  `define XLEN 32
`endif

`include "VX_define.vh"

module tb_tcu_wmma;

    import VX_gpu_pkg::*;
    import VX_tcu_pkg::*;

    localparam LG_N = $clog2(TCU_N_STEPS);
    localparam LG_M = $clog2(TCU_M_STEPS);

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
    // DUT
    // =========================================================================
    VX_tcu_unit #(.INSTANCE_ID("tb_tcu_wmma")) dut (
        .clk(clk), .reset(reset),
        .dispatch_if(dispatch_if), .commit_if(commit_if)
    );

    genvar g;
    generate
        for (g = 0; g < 1; g++) begin : g_commit_ready
            assign commit_if[g].ready = 1'b1;
        end
    endgenerate

    // =========================================================================
    // Pass/Fail counters
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;

    // =========================================================================
    // Reference model helpers
    // =========================================================================

    // Power-of-2 helper (used for real arithmetic in ref models)
    function automatic real ref_pow2(input int e);
        real r;
        r = 1.0;
        if (e >= 0) begin
            for (int i = 0; i < e; i++) r *= 2.0;
        end else begin
            for (int i = 0; i < -e; i++) r /= 2.0;
        end
        return r;
    endfunction

    // FP32 bit pattern → real (normal numbers; returns 0 for zero/denorm/inf/nan)
    function automatic real ref_fp32_to_real(input logic [31:0] fp32);
        logic        s;
        logic [7:0]  exp;
        logic [22:0] mant;
        real         val;
        s    = fp32[31];
        exp  = fp32[30:23];
        mant = fp32[22:0];
        if (exp == 8'h00 || exp == 8'hFF) return 0.0;
        val = (1.0 + real'({9'b0, mant}) / 8388608.0) * ref_pow2(int'(exp) - 127);
        return s ? -val : val;
    endfunction

    // real → FP32 bit pattern (exact for normal numbers in FP32 range)
    function automatic logic [31:0] ref_real_to_fp32(input real r);
        logic       sign;
        real        abs_r;
        integer     exp_unbiased;
        real        sig;
        logic [7:0] biased_exp;
        logic [22:0] mant;
        if (r == 0.0) return 32'h00000000;
        sign = (r < 0.0) ? 1'b1 : 1'b0;
        abs_r = sign ? -r : r;
        exp_unbiased = 0;
        sig = abs_r;
        while (sig >= 2.0) begin sig /= 2.0; exp_unbiased++; end
        while (sig < 1.0)  begin sig *= 2.0; exp_unbiased--; end
        if (exp_unbiased + 127 >= 255) return {sign, 8'hFF, 23'h0};
        if (exp_unbiased + 127 <= 0)   return {sign, 8'h00, 23'h0};
        biased_exp = 8'(exp_unbiased + 127);
        mant = 23'(integer'((sig - 1.0) * 8388608.0));
        return {sign, biased_exp, mant};
    endfunction

    // INT8 flatten with saturation
    function automatic logic [7:0] ref_flatten_byte(
        input logic [7:0] b, input logic mexp);
        if (!mexp) return b;
        if ((b[7] == 1'b0) && (b[6] == 1'b1)) return 8'h7F;
        if ((b[7] == 1'b1) && (b[6] == 1'b0)) return 8'h80;
        return {b[6:0], 1'b0};
    endfunction

    function automatic logic [31:0] ref_flatten_word(
        input logic [31:0] w, input logic [1:0] mexp);
        return {ref_flatten_byte(w[31:24], mexp[1]),
                ref_flatten_byte(w[23:16], mexp[1]),
                ref_flatten_byte(w[15:8],  mexp[0]),
                ref_flatten_byte(w[7:0],   mexp[0])};
    endfunction

    // Integer dot product
    function automatic logic signed [31:0] ref_dot(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2,
        input int i, j, b_off
    );
        logic signed [31:0] d;
        d = '0;
        for (int k = 0; k < TCU_TC_K; k++)
            for (int b = 0; b < 4; b++)
                d += $signed(rs1[i*TCU_TC_K + k][8*b+7 -: 8])
                   * $signed(rs2[b_off + j*TCU_TC_K + k][8*b+7 -: 8]);
        return d;
    endfunction

    // FP32 reference: dot × 2^exp_total + C(FP32)
    // Uses real arithmetic — exact for integer dot products × power-of-2 scale.
    function automatic logic [31:0] ref_d_fp32(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic signed [9:0] exp_total,
        input int i, j, b_off
    );
        logic signed [31:0] d;
        real fp_d, c_r, result_r;
        d = ref_dot(rs1, rs2, i, j, b_off);
        fp_d     = real'($signed(d)) * ref_pow2(int'($signed(exp_total)));
        c_r      = ref_fp32_to_real(rs3[i * TCU_TC_N + j]);
        result_r = fp_d + c_r;
        return ref_real_to_fp32(result_r);
    endfunction

    // =========================================================================
    // Dispatch / Commit helpers
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

    task automatic wait_commit(output commit_t res);
        @(posedge clk);
        while (!commit_if[0].valid) @(posedge clk);
        res = commit_if[0].data;
    endtask

`ifdef EXT_AG_TCU_ENABLE
    task automatic fire_ldscale(input logic [7:0] scale_a, scale_b);
        dispatch_t pkt; commit_t dummy;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'('hDEAD);
        pkt.wis = '0; pkt.sid = '0; pkt.tmask = '1;
        pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data[0]        = {16'b0, scale_b, scale_a};
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_LDSCALE;
        fire_dispatch(pkt);
        wait_commit(dummy);
    endtask

    // fire_ldmicro: sets pair-shared micro_exp bits (uniform across all threads)
    //   mexp_a[1:0] = {pair1_mexp_a, pair0_mexp_a}
    //   mexp_b[1:0] = {pair1_mexp_b, pair0_mexp_b}
    task automatic fire_ldmicro(input logic [1:0] mexp_a, mexp_b);
        dispatch_t pkt; commit_t dummy;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'('hDEAD);
        pkt.wis = '0; pkt.sid = '0; pkt.tmask = '1;
        pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        for (int t = 0; t < `SIMD_WIDTH; t++) begin
            pkt.rs1_data[t] = {30'b0, mexp_a};
            pkt.rs2_data[t] = {30'b0, mexp_b};
        end
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_LDMICRO;
        fire_dispatch(pkt);
        wait_commit(dummy);
    endtask
`endif

    // Build INT8 dispatch packet (Phase 10: fmt_d=FP32 since output is FP32)
    function automatic dispatch_t build_dispatch_int(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [3:0] step_m, step_n
    );
        dispatch_t pkt;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'(1);
        pkt.wis = '0; pkt.sid = '0; pkt.tmask = '1;
        pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data = rs1; pkt.rs2_data = rs2; pkt.rs3_data = rs3;
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);   // Phase 10: INT path → FP32 output
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
`ifdef EXT_AG_TCU_ENABLE
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
`endif
        return pkt;
    endfunction

`ifdef EXT_AG_TCU_ENABLE
    // Build MX9 dispatch packet (fmt_s=TCU_MX9_ID → OT flattens + routes INT)
    function automatic dispatch_t build_dispatch_mx9(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [3:0] step_m, step_n
    );
        dispatch_t pkt;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'(1);
        pkt.wis = '0; pkt.sid = '0; pkt.tmask = '1;
        pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data = rs1; pkt.rs2_data = rs2; pkt.rs3_data = rs3;
        pkt.op_args.tcu.fmt_s  = 4'(TCU_MX9_ID);    // OT: flatten → patch to I8_ID
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
        return pkt;
    endfunction
`endif

    // =========================================================================
    // Tile matrices (indexed by step coordinates)
    // =========================================================================
    logic [TCU_M_STEPS-1:0][TCU_K_STEPS-1:0]
          [TCU_TC_M-1:0][TCU_TC_K-1:0][`XLEN-1:0] A_mat;
    logic [TCU_K_STEPS-1:0][TCU_N_STEPS-1:0]
          [TCU_TC_N-1:0][TCU_TC_K-1:0][`XLEN-1:0] B_mat;
    logic [TCU_M_STEPS-1:0][TCU_N_STEPS-1:0]
          [TCU_TC_M-1:0][TCU_TC_N-1:0][`XLEN-1:0] D_mat;

    task automatic fill_A(input logic [`XLEN-1:0] w);
        for (int sm=0; sm<TCU_M_STEPS; sm++)
            for (int sk=0; sk<TCU_K_STEPS; sk++)
                for (int ii=0; ii<TCU_TC_M; ii++)
                    for (int kk=0; kk<TCU_TC_K; kk++)
                        A_mat[sm][sk][ii][kk] = w;
    endtask
    task automatic fill_B(input logic [`XLEN-1:0] w);
        for (int sk=0; sk<TCU_K_STEPS; sk++)
            for (int sn=0; sn<TCU_N_STEPS; sn++)
                for (int jj=0; jj<TCU_TC_N; jj++)
                    for (int kk=0; kk<TCU_TC_K; kk++)
                        B_mat[sk][sn][jj][kk] = w;
    endtask
    task automatic fill_D(input logic [`XLEN-1:0] w);
        for (int sm=0; sm<TCU_M_STEPS; sm++)
            for (int sn=0; sn<TCU_N_STEPS; sn++)
                for (int ii=0; ii<TCU_TC_M; ii++)
                    for (int jj=0; jj<TCU_TC_N; jj++)
                        D_mat[sm][sn][ii][jj] = w;
    endtask

    // =========================================================================
    // run_wmma: INT8 path, safe (serial) mode — all TCU_UOPS dispatches
    // Output: FP32 bit pattern (Phase 10: INT FEDP outputs FP32)
    // =========================================================================
    task automatic run_wmma(
        input string name,
        input logic [7:0] exp_a, exp_b
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_in, rs2_in, rs3_in;
        dispatch_t pkt; commit_t res;
        logic signed [9:0] exp_total;
        bit test_pass;
        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;
        test_pass = 1;
`ifdef EXT_AG_TCU_ENABLE
        fire_ldscale(exp_a, exp_b);
`endif
        for (int ctr = 0; ctr < TCU_UOPS; ctr++) begin
            int n, m, sm, sn, sk, a_off, b_off;
            n     = (LG_N > 0) ? (ctr & ((1 << LG_N) - 1))           : 0;
            m     = (LG_M > 0) ? ((ctr >> LG_N) & ((1 << LG_M) - 1)) : 0;
            sm    = m; sn = n; sk = ctr >> (LG_N + LG_M);
            a_off = (sm & (TCU_A_SUB_BLOCKS - 1)) * TCU_A_BLOCK_SIZE;
            b_off = (sn & (TCU_B_SUB_BLOCKS - 1)) * TCU_B_BLOCK_SIZE;

            rs1_in = '0;
            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int kk=0; kk<TCU_TC_K; kk++)
                    rs1_in[a_off + ii*TCU_TC_K + kk] = A_mat[sm][sk][ii][kk];
            rs2_in = '0;
            for (int jj=0; jj<TCU_TC_N; jj++)
                for (int kk=0; kk<TCU_TC_K; kk++)
                    rs2_in[b_off + jj*TCU_TC_K + kk] = B_mat[sk][sn][jj][kk];
            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++)
                    rs3_in[ii*TCU_TC_N + jj] = D_mat[sm][sn][ii][jj];

            pkt = build_dispatch_int(rs1_in, rs2_in, rs3_in, 4'(sm), 4'(sn));
            fire_dispatch(pkt);
            wait_commit(res);

            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++) begin
                    logic [31:0] got, exp_v;
                    got   = res.data[ii*TCU_TC_N + jj];
                    exp_v = ref_d_fp32(rs1_in, rs2_in, rs3_in, exp_total, ii, jj, b_off);
                    D_mat[sm][sn][ii][jj] = res.data[ii*TCU_TC_N + jj];
                    if (got !== exp_v) begin
                        $display("[FAIL] %-28s ctr=%0d [%0d][%0d] got=0x%08X exp=0x%08X",
                                 name, ctr, ii, jj, got, exp_v);
                        test_pass = 0;
                    end
                end
        end
        if (test_pass) begin
            $display("[PASS] %-28s all %0d uops × %0d outputs",
                     name, TCU_UOPS, TCU_TC_M * TCU_TC_N);
            pass_cnt++;
        end else
            fail_cnt++;
    endtask

`ifdef EXT_AG_TCU_ENABLE
    // =========================================================================
    // run_wmma_mx9: MX9 path with LDMICRO, safe (serial) mode
    //   OT: flatten INT8 using micro_ctx, patch fmt_s → I8, route to INT path
    //   Reference: apply ref_flatten_word before ref_d_fp32
    // =========================================================================
    task automatic run_wmma_mx9(
        input string name,
        input logic [7:0] exp_a, exp_b,
        input logic [1:0] mexp_a, mexp_b   // uniform across all threads
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_in, rs2_in, rs3_in;
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_flat, rs2_flat;
        dispatch_t pkt; commit_t res;
        logic signed [9:0] exp_total;
        bit test_pass;
        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;
        test_pass = 1;

        fire_ldscale(exp_a, exp_b);
        fire_ldmicro(mexp_a, mexp_b);

        for (int ctr = 0; ctr < TCU_UOPS; ctr++) begin
            int n, m, sm, sn, sk, a_off, b_off;
            n     = (LG_N > 0) ? (ctr & ((1 << LG_N) - 1))           : 0;
            m     = (LG_M > 0) ? ((ctr >> LG_N) & ((1 << LG_M) - 1)) : 0;
            sm    = m; sn = n; sk = ctr >> (LG_N + LG_M);
            a_off = (sm & (TCU_A_SUB_BLOCKS - 1)) * TCU_A_BLOCK_SIZE;
            b_off = (sn & (TCU_B_SUB_BLOCKS - 1)) * TCU_B_BLOCK_SIZE;

            rs1_in = '0;
            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int kk=0; kk<TCU_TC_K; kk++)
                    rs1_in[a_off + ii*TCU_TC_K + kk] = A_mat[sm][sk][ii][kk];
            rs2_in = '0;
            for (int jj=0; jj<TCU_TC_N; jj++)
                for (int kk=0; kk<TCU_TC_K; kk++)
                    rs2_in[b_off + jj*TCU_TC_K + kk] = B_mat[sk][sn][jj][kk];
            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++)
                    rs3_in[ii*TCU_TC_N + jj] = D_mat[sm][sn][ii][jj];

            // Apply Phase 10 flatten (matches OT behaviour)
            for (int t = 0; t < `SIMD_WIDTH; t++) begin
                rs1_flat[t] = ref_flatten_word(rs1_in[t], mexp_a);
                rs2_flat[t] = ref_flatten_word(rs2_in[t], mexp_b);
            end

            pkt = build_dispatch_mx9(rs1_in, rs2_in, rs3_in, 4'(sm), 4'(sn));
            fire_dispatch(pkt);
            wait_commit(res);

            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++) begin
                    logic [31:0] got, exp_v;
                    got   = res.data[ii*TCU_TC_N + jj];
                    exp_v = ref_d_fp32(rs1_flat, rs2_flat, rs3_in,
                                       exp_total, ii, jj, b_off);
                    D_mat[sm][sn][ii][jj] = res.data[ii*TCU_TC_N + jj];
                    if (got !== exp_v) begin
                        $display("[FAIL] %-28s ctr=%0d [%0d][%0d] got=0x%08X exp=0x%08X",
                                 name, ctr, ii, jj, got, exp_v);
                        test_pass = 0;
                    end
                end
        end
        if (test_pass) begin
            $display("[PASS] %-28s all %0d uops × %0d outputs",
                     name, TCU_UOPS, TCU_TC_M * TCU_TC_N);
            pass_cnt++;
        end else
            fail_cnt++;
    endtask
`endif // EXT_AG_TCU_ENABLE

`ifdef EXT_AG_TCU_ENABLE
    // =========================================================================
    // fire_flat_uop: send one FLAT UOP and wait for commit
    //   tile_type: 0=A tile (uses mexp_a from micro_ctx), 1=B tile (uses mexp_b)
    //   rs1_word: uniform tile register content for all threads
    // =========================================================================
    task automatic fire_flat_uop(
        input logic        tile_type,
        input logic [31:0] rs1_word,
        output commit_t    res
    );
        dispatch_t pkt;
        pkt = '0;
        pkt.uuid = UUID_WIDTH'(2); pkt.wis = '0; pkt.sid = '0;
        pkt.tmask = '1; pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.op_type = INST_ALU_BITS'(INST_TCU_WMMA);
        for (int t = 0; t < `SIMD_WIDTH; t++)
            pkt.rs1_data[t] = rs1_word;
        pkt.op_args.tcu.fmt_s     = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d     = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op    = TCU_OP_FLAT;
        pkt.op_args.tcu.tile_type = {1'b0, tile_type};
        fire_dispatch(pkt);
        wait_commit(res);
    endtask

    // =========================================================================
    // run_wmma_flat: LDMICRO → TCU_FLAT_UOPS FLAT UOPs → verify all commits
    //   Sends NRA A-tile UOPs (tile_type=0) then NRB B-tile UOPs (tile_type=1).
    //   Each UOP verifies all TCU_TC_M×TCU_TC_N output slots match exp_*_flat.
    // =========================================================================
    task automatic run_wmma_flat(
        input string       name,
        input logic [1:0]  mexp_a, mexp_b,
        input logic [31:0] a_word,      // uniform input for each A-tile register
        input logic [31:0] b_word,      // uniform input for each B-tile register
        input logic [31:0] exp_a_flat,  // expected flattened output for A-tile
        input logic [31:0] exp_b_flat   // expected flattened output for B-tile
    );
        commit_t res;
        bit test_pass;
        test_pass = 1;

        fire_ldmicro(mexp_a, mexp_b);

        for (int ctr = 0; ctr < TCU_FLAT_UOPS; ctr++) begin
            logic        tile_type;
            logic [31:0] rs1_word, exp_word;
            tile_type = (ctr >= TCU_NRA) ? 1'b1 : 1'b0;
            rs1_word  = tile_type ? b_word : a_word;
            exp_word  = tile_type ? exp_b_flat : exp_a_flat;

            fire_flat_uop(tile_type, rs1_word, res);

            for (int t = 0; t < TCU_TC_M * TCU_TC_N; t++) begin
                if (res.data[t] !== exp_word) begin
                    $display("[FAIL] %-28s ctr=%0d t=%0d got=0x%08X exp=0x%08X",
                             name, ctr, t, res.data[t], exp_word);
                    test_pass = 0;
                end
            end
        end

        if (test_pass) begin
            $display("[PASS] %-28s all %0d UOPs (%0d A + %0d B) correct",
                     name, TCU_FLAT_UOPS, TCU_NRA, TCU_NRB);
            pass_cnt++;
        end else
            fail_cnt++;
    endtask
`endif // EXT_AG_TCU_ENABLE

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin
        reset                = 1'b1;
        dispatch_if[0].valid = 1'b0;
        dispatch_if[0].data  = '0;
        repeat(4) @(posedge clk);
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;

        $display("=== tb_tcu_wmma: Phase 10 FP32 INT path validation ===");
        $display("  TCU_TC_M=%0d  TCU_TC_N=%0d  TCU_TC_K=%0d",
                 TCU_TC_M, TCU_TC_N, TCU_TC_K);
        $display("  UOPS=%0d  M_STEPS=%0d  N_STEPS=%0d  K_STEPS=%0d",
                 TCU_UOPS, TCU_M_STEPS, TCU_N_STEPS, TCU_K_STEPS);
        $display("------------------------------------------------------------");

        // --------------------------------------------------------------------
        // TC_int_k_accum: INT8 path K-accumulation regression
        //   A=B=0x01010101 (INT8=1), exp_total=0, D starts at 0.0 (FP32)
        //   Per k-step: dot = TC_K×4×1×1 = 8 → adds FP32 8.0 each step
        //   Final D = FP32(8 × K_STEPS) per (i,j) output
        //     NT=4: K_STEPS=2 → 16.0 = 0x41800000
        //     NT=8: K_STEPS=4 → 32.0 = 0x42000000
        // --------------------------------------------------------------------
        fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'h00000000);
        run_wmma("TC_int_k_accum", 8'd127, 8'd127);

`ifdef EXT_AG_TCU_ENABLE
        // --------------------------------------------------------------------
        // TC_int_exp_pos2: exp_total=+2 (scale_a=128, scale_b=128)
        //   Must run before any MX9 test that sets mexp≠0 (do_flatten_int
        //   applies to INT8 path; mexp=0 from reset = passthrough).
        //   A=B=0x01010101 (INT8=1 each byte), D=0.0
        //   dot per k-step = TC_TC_K×4 × 1×1 = 8
        //   SCALE: FP32(8) × 2^2 = 32.0 per k-step
        //   K accumulation (sk=0→32.0, sk=1→64.0):
        //     NT=4: K_STEPS=2 → final D = 64.0 = 0x42800000
        //     NT=8: K_STEPS=4 → final D = 128.0 = 0x43000000
        // --------------------------------------------------------------------
        fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'h00000000);
        run_wmma("TC_int_exp_pos2", 8'd128, 8'd128);

        // --------------------------------------------------------------------
        // TC_int_exp_neg1: exp_total=-1 (scale_a=127, scale_b=126)
        //   A=B=0x02020202 (INT8=2 each byte), D=0.0
        //   dot per k-step = TC_TC_K×4 × 2×2 = 32
        //   SCALE: FP32(32) × 2^(-1) = 16.0 per k-step
        //   K accumulation (sk=0→16.0, sk=1→32.0):
        //     NT=4: K_STEPS=2 → final D = 32.0 = 0x42000000
        //     NT=8: K_STEPS=4 → final D = 64.0 = 0x42800000
        // --------------------------------------------------------------------
        fill_A(32'h02020202); fill_B(32'h02020202); fill_D(32'h00000000);
        run_wmma("TC_int_exp_neg1", 8'd127, 8'd126);

        // --------------------------------------------------------------------
        // TC_nonzero_C: accumulate onto non-zero C (fp32_add with mixed sign)
        //   A=B=0x01010101 (INT8=1), exp_total=0, D starts at FP32(-8.0)
        //   sk=0: dot=8, 8.0+(-8.0)=0.0 → D_mat=0.0
        //   sk=1: dot=8, 8.0+0.0=8.0    → D_mat=8.0
        //     NT=4: K_STEPS=2 → final D = 8.0 = 0x41000000
        //     NT=8: K_STEPS=4 → 0+8+16+24? No: sk0→0, sk1→8, sk2→16, sk3→24 = 24.0
        //       Final D = 24.0 = 0x41C00000
        // --------------------------------------------------------------------
        fill_A(32'h01010101); fill_B(32'h01010101);
        fill_D(32'hC1000000);   // FP32(-8.0)
        run_wmma("TC_nonzero_C", 8'd127, 8'd127);

        // --------------------------------------------------------------------
        // TC_neg_A: negative INT8 input (A=0xFF = INT8(-1))
        //   A=0xFFFFFFFF (INT8=-1 each), B=0x01010101 (INT8=+1), D=0.0
        //   dot per k-step = TC_TC_K×4 × (-1)×1 = -8
        //   FP32(-8.0) per k-step, exp_total=0
        //   K accumulation (sk=0→-8.0, sk=1→-16.0):
        //     NT=4: K_STEPS=2 → final D = -16.0 = 0xC1800000
        //     NT=8: K_STEPS=4 → final D = -32.0 = 0xC2000000
        // --------------------------------------------------------------------
        fill_A(32'hFFFFFFFF); fill_B(32'h01010101); fill_D(32'h00000000);
        run_wmma("TC_neg_A", 8'd127, 8'd127);

        // --------------------------------------------------------------------
        // TC_MX9_mexp0: MX9 with all mexp=0 (identity flatten)
        //   Expects same result as TC_int_k_accum (flatten is no-op)
        // --------------------------------------------------------------------
        fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'h00000000);
        run_wmma_mx9("TC_MX9_mexp0", 8'd127, 8'd127, 2'b00, 2'b00);

        // --------------------------------------------------------------------
        // TC_MX9_mexp_a1: MX9 with mexp_a=1 (all pairs), mexp_b=0
        //   A=0x01 (INT8=1) → flatten(1, mexp=1) = 2 (no overflow)
        //   B=0x01 (INT8=1) → flatten(1, mexp=0) = 1
        //   Per k-step: dot = TC_K×4 × 2×1 = 16 → adds FP32 16.0 each step
        //   K accumulation (sk=0→16.0, sk=1→32.0):
        //     NT=4: K_STEPS=2 → final D = 32.0 = 0x42000000
        //     NT=8: K_STEPS=4 → final D = 64.0 = 0x42800000
        // --------------------------------------------------------------------
        fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'h00000000);
        run_wmma_mx9("TC_MX9_mexp_a1", 8'd127, 8'd127, 2'b11, 2'b00);

        // --------------------------------------------------------------------
        // TC_MX9_mexp_mixed: pair1_mexp=1, pair0_mexp=0 (mixed pair-shared)
        //   mexp_a=2'b10: bit[1]=pair1=1, bit[0]=pair0=0
        //   A=0x01010101 → flatten: pair0 bytes(0,1)→0x01, pair1 bytes(2,3)→0x02
        //   flat A = 0x02020101 per thread word
        //   B=0x01010101, mexp_b=0 → unchanged
        //   dot per word: b0(1×1)=1, b1(1×1)=1, b2(2×1)=2, b3(2×1)=2 → 6
        //   dot per k-step = 6 × TC_TC_K = 12; FP32(12.0) per k-step, exp_total=0
        //   K accumulation (sk=0→12.0, sk=1→24.0):
        //     NT=4: K_STEPS=2 → final D = 24.0 = 0x41C00000
        //     NT=8: K_STEPS=4 → final D = 48.0 = 0x42400000
        // --------------------------------------------------------------------
        fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'h00000000);
        run_wmma_mx9("TC_MX9_mexp_mixed", 8'd127, 8'd127, 2'b10, 2'b00);

        // --------------------------------------------------------------------
        // TC_MX9_sat_pos: saturation overflow_pos path (0x40 + mexp=1 → 0x7F)
        //   A=0x40404040 (INT8=+64): bit7=0, bit6=1 → overflow_pos → 0x7F=127
        //   flat A = 0x7F7F7F7F per thread word
        //   B=0x01010101 (INT8=1), mexp_b=0 → unchanged
        //   dot per k-step = 4×TC_TC_K × 127×1 = 4×2×127 = 1016
        //   FP32(1016.0) per k-step, exp_total=0
        //   K accumulation (sk=0→1016.0, sk=1→2032.0):
        //     NT=4: K_STEPS=2 → final D = 2032.0 = 0x447E0000
        //     NT=8: K_STEPS=4 → final D = 4064.0 = 0x457E0000
        // --------------------------------------------------------------------
        fill_A(32'h40404040); fill_B(32'h01010101); fill_D(32'h00000000);
        run_wmma_mx9("TC_MX9_sat_pos", 8'd127, 8'd127, 2'b11, 2'b00);

        // --------------------------------------------------------------------
        // FLAT instruction tests (Phase B)
        //   run_wmma_flat: LDMICRO → NRA A-tile UOPs + NRB B-tile UOPs
        //   Verifies full FLAT sequence including A/B tile isolation.
        // --------------------------------------------------------------------

        // TC_FLAT_full_ident: mexp=0 → all passthrough (regression)
        //   A=0x01020304, B=0x05060708 → no change
        run_wmma_flat("TC_FLAT_full_ident",
            2'b00, 2'b00,
            32'h01020304, 32'h05060708,
            32'h01020304, 32'h05060708);

        // TC_FLAT_full_double: mexp_a=11 → A×2, mexp_b=00 → B passthrough
        //   Verifies A-tile flatten AND isolation (mexp_a not applied to B-tile)
        //   A=0x01010101 → 0x02020202; B=0x01010101 → 0x01010101
        run_wmma_flat("TC_FLAT_full_double",
            2'b11, 2'b00,
            32'h01010101, 32'h01010101,
            32'h02020202, 32'h01010101);

        // TC_FLAT_full_mixed: mexp_a=2'b10 (pair1=1, pair0=0)
        //   pair0 bytes (0,1): no shift → unchanged
        //   pair1 bytes (2,3): ×2
        //   A=0x01020304 → pair0(0x04,0x03)→0x04,0x03; pair1(0x02,0x01)→0x04,0x02
        //   flat_a = 0x02040304
        run_wmma_flat("TC_FLAT_full_mixed",
            2'b10, 2'b00,
            32'h01020304, 32'h01020304,
            32'h02040304, 32'h01020304);

        // TC_FLAT_then_WMMA: use FLAT output as WMMA input (integration)
        //   Step 1: FLAT A-tile (mexp_a=11, 0x01→0x02) — capture flattened data
        //   Step 2: reset micro_ctx (mexp=00) so WMMA INT path doesn't re-flatten
        //   Step 3: INT8 WMMA with captured A=0x02020202, B=0x01010101, D=0
        //   Expected: dot per k-step = TC_K×4 × 2×1 = 16 → FP32 16.0/k-step
        //     NT=4: K_STEPS=2 → 32.0 = 0x42000000
        //     NT=8: K_STEPS=4 → 64.0 = 0x42800000
        begin : tc_flat_then_wmma
            logic [31:0] captured_a;
            commit_t flat_res;
            fire_ldmicro(2'b11, 2'b00);
            for (int i = 0; i < TCU_FLAT_UOPS; i++) begin
                logic tile_type_l;
                tile_type_l = (i >= TCU_NRA) ? 1'b1 : 1'b0;
                fire_flat_uop(tile_type_l, 32'h01010101, flat_res);
                if (i == 0) captured_a = flat_res.data[0];  // expect 0x02020202
            end
            fire_ldmicro(2'b00, 2'b00);  // reset micro_ctx → WMMA passthrough
            fill_A(captured_a); fill_B(32'h01010101); fill_D(32'h00000000);
            run_wmma("TC_FLAT_then_WMMA", 8'd127, 8'd127);
        end
`endif

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
