// =============================================================================
// tb_tcu_wmma.sv — VX_tcu_unit full-WMMA testbench
// =============================================================================
// Level 5: tests VX_tcu_unit with complete WMMA computation (all UOPS).
//
// Test cases are organized by format in tc/ subdirectory:
//   tc/int8.svh    — INT8   path: [V2][V3][V4][V5][V7]
//   tc/mxint8.svh  — MXINT8 path: [V2][V3][V4][V5][V6][V7]
//   tc/mx9.svh     — MX9    path: [V1][V2][V3][V4][V5][V6][V7][V8]
//   tc/flat.svh    — FLAT instruction: [V2][V3][V4][V7][V8]
//   tc/fp8.svh     — FP8 E4M3/E5M2 path: [V2][V3]  (requires TCU_BHF)
//
// Validation axes:
//   V1 Routing    — OT fmt_s 라우팅 (MX9 implicit; other formats implicit)
//   V2 Identity   — neutral A,B, C=0 → expected output
//   V3 Sign       — negative element → negative output
//   V4 Scale+     — exp_total > 0 (INT path only; N/A for FP8)
//   V5 Scale-     — exp_total < 0 (INT path only; N/A for FP8)
//   V6 Boundary   — OT saturation (INT) / special float values (FP8, deferred)
//   V7 K-Accum    — multi K-step accumulation
//   V8 Format-spec — format-specific transform (MX9 pair mexp; FP8 subnormal deferred)
//
// Build modes:
//   make test-all    — all formats (default)
//   make test-int8   — INT8 only
//   make test-mxint8 — MXINT8 only
//   make test-mx9    — MX9 only
//   make test-flat   — FLAT only
//   make test-fp8    — FP8 only  (requires TCU_BHF)
//   make nt8         — all formats, NT=8
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

    // MX9 Option C re-quantization reference
    //   {s[1b],frac[6:0]} + mexp_bit → INT8 flat = Q>>(2-mexp), Q=128+frac
    function automatic logic [7:0] ref_mx9_requant_byte(
        input logic [7:0] byte_val,
        input logic       mexp_bit
    );
        logic [7:0] Q;
        logic [6:0] flat_mag;
        Q        = {1'b1, byte_val[6:0]};
        flat_mag = mexp_bit ? Q[7:1] : Q[7:2];
        if (byte_val[7] == 1'b0) return {1'b0, flat_mag};
        else                     return ~{1'b0, flat_mag} + 8'd1;
    endfunction

    // MX9 dot product with per-pair mexp
    function automatic logic signed [31:0] ref_dot_mx9(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2,
        input logic [1:0] mexp_a, mexp_b,
        input int i, j, b_off
    );
        logic signed [31:0] d;
        logic mexp_a_bit, mexp_b_bit;
        logic [7:0] a_raw, b_raw;
        logic signed [7:0] a8, b8;
        d = '0;
        for (int k = 0; k < TCU_TC_K; k++)
            for (int b = 0; b < 4; b++) begin
                mexp_a_bit = mexp_a[(b >= 2) ? 1 : 0];
                mexp_b_bit = mexp_b[(b >= 2) ? 1 : 0];
                a_raw = rs1[i*TCU_TC_K + k][8*b+7 -: 8];
                b_raw = rs2[b_off + j*TCU_TC_K + k][8*b+7 -: 8];
                a8 = $signed(ref_mx9_requant_byte(a_raw, mexp_a_bit));
                b8 = $signed(ref_mx9_requant_byte(b_raw, mexp_b_bit));
                d += a8 * b8;
            end
        return d;
    endfunction

    // MX9 FP32 reference: dot_mx9 × 2^(exp_total-10) + C
    function automatic logic [31:0] ref_d_fp32_mx9(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic signed [9:0] exp_total,
        input logic [1:0] mexp_a, mexp_b,
        input int i, j, b_off
    );
        logic signed [31:0] d;
        real fp_d, c_r, result_r;
        d        = ref_dot_mx9(rs1, rs2, mexp_a, mexp_b, i, j, b_off);
        fp_d     = real'($signed(d)) * ref_pow2(int'($signed(exp_total)) - 10);
        c_r      = ref_fp32_to_real(rs3[i * TCU_TC_N + j]);
        result_r = fp_d + c_r;
        return ref_real_to_fp32(result_r);
    endfunction

    // 3-level flatten reference: saturate_int8(int8 << shift), shift ∈ {0,1,2}
    //   Mirrors OT flatten_int8_byte with SCALE_BITS=2 (FLAT_W=11, MAX_SHIFT=3)
    function automatic logic signed [7:0] ref_3level_flatten_byte(
        input logic [7:0] b8,
        input logic [1:0] shift
    );
        logic [10:0] wide, shifted;
        logic [3:0]  upper;
        if (shift == 2'b00) return signed'(b8);
        wide    = {{3{b8[7]}}, b8};  // sign-extend to 11 bits (MAX_SHIFT=3 extra bits)
        shifted = wide << shift;
        upper   = shifted[10:7];    // bits above INT8 range
        if ((&upper) | (~|upper)) return signed'(shifted[7:0]);
        return b8[7] ? 8'sh80 : 8'sh7F;
    endfunction

    // 3-level dot product reference: flatten then INT8 MAC
    function automatic logic [31:0] ref_d_fp32_3level(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic signed [9:0] exp_total,
        input logic [1:0] p0_shift_a, p1_shift_a,
        input logic [1:0] p0_shift_b, p1_shift_b,
        input int i, j, b_off
    );
        logic signed [31:0] d;
        real fp_d, c_r, result_r;
        logic [1:0] sha, shb;
        d = '0;
        for (int k = 0; k < TCU_TC_K; k++)
            for (int b = 0; b < 4; b++) begin
                sha = (b >= 2) ? p1_shift_a : p0_shift_a;
                shb = (b >= 2) ? p1_shift_b : p0_shift_b;
                d += ref_3level_flatten_byte(rs1[i*TCU_TC_K+k][b*8+:8], sha)
                   * ref_3level_flatten_byte(rs2[b_off+j*TCU_TC_K+k][b*8+:8], shb);
            end
        fp_d     = real'($signed(d)) * ref_pow2(int'($signed(exp_total)));
        c_r      = ref_fp32_to_real(rs3[i * TCU_TC_N + j]);
        result_r = fp_d + c_r;
        return ref_real_to_fp32(result_r);
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

    // FP8 E4M3 decode: {s[1], e[3:0], m[2:0]}, bias=7
    //   HW flush-to-zero (FTZ): e=0 → ±0 (both zero AND subnormal flushed)
    //   NaN: e=0xF, m=0x7 → return 0.0 (undefined; ref treats as 0)
    function automatic real ref_fp8e4m3_to_real(input logic [7:0] fp8);
        logic s; logic [3:0] e; logic [2:0] m; real val;
        s = fp8[7]; e = fp8[6:3]; m = fp8[2:0];
        if (e == 4'hF && m == 3'h7) return 0.0;  // NaN
        if (e == 4'h0) return 0.0;  // zero AND subnormal → HW flush-to-zero
        val = (1.0 + real'(m) / 8.0) * ref_pow2(int'(e) - 7);  // normal
        return s ? -val : val;
    endfunction

    // FP8 E5M2 decode: {s[1], e[4:0], m[1:0]}, bias=15
    //   subnormal (e=0): 0.mant × 2^(1-15)
    //   Inf: e=0x1F, m=0 → return ±1e38 (large finite; overflow → FP32 Inf in ref_real_to_fp32)
    //   NaN: e=0x1F, m≠0 → return 0.0
    function automatic real ref_fp8e5m2_to_real(input logic [7:0] fp8);
        logic s; logic [4:0] e; logic [1:0] m; real val;
        s = fp8[7]; e = fp8[6:2]; m = fp8[1:0];
        if (e == 5'h1F) begin
            if (m == 2'h0) return s ? -1.0e39 : 1.0e39;  // Inf → overflow → FP32 Inf
            else           return 0.0;                     // NaN → 0 for ref
        end
        if (e == 5'h0)
            val = real'({1'b0, m}) / 4.0 * ref_pow2(1 - 15);  // subnormal
        else
            val = (1.0 + real'(m) / 4.0) * ref_pow2(int'(e) - 15);  // normal
        return s ? -val : val;
    endfunction

    // FP8 dot product reference: sum_k sum_{elem in word} decode(A_elem) × decode(B_elem)
    //   FP8 word packing: 2 elements per 32-bit word at [15:8] and [31:24]
    //   fp8_fmt: TCU_FP8E4M3_ID or TCU_FP8E5M2_ID
    function automatic logic [31:0] ref_d_fp32_fp8(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input int unsigned fp8_fmt,
        input logic signed [9:0] exp_total,
        input int i, j, b_off
    );
        real d, c_r, result_r;
        logic [7:0] ea0, ea1, eb0, eb1;
        d = 0.0;
        for (int k = 0; k < TCU_TC_K; k++) begin
            ea0 = rs1[i*TCU_TC_K + k][15:8];
            ea1 = rs1[i*TCU_TC_K + k][31:24];
            eb0 = rs2[b_off + j*TCU_TC_K + k][15:8];
            eb1 = rs2[b_off + j*TCU_TC_K + k][31:24];
            if (fp8_fmt == TCU_FP8E4M3_ID) begin
                d += ref_fp8e4m3_to_real(ea0) * ref_fp8e4m3_to_real(eb0);
                d += ref_fp8e4m3_to_real(ea1) * ref_fp8e4m3_to_real(eb1);
            end else begin
                d += ref_fp8e5m2_to_real(ea0) * ref_fp8e5m2_to_real(eb0);
                d += ref_fp8e5m2_to_real(ea1) * ref_fp8e5m2_to_real(eb1);
            end
        end
        // Apply MX block scaling (exp_total)
        d = d * ref_pow2(int'(exp_total));
        c_r      = ref_fp32_to_real(rs3[i * TCU_TC_N + j]);
        result_r = d + c_r;
        return ref_real_to_fp32(result_r);
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
        // Use !== 1'b1 (case comparison) instead of ! to correctly handle
        // X-state in Vivado xsim: !X = X, while(X) exits immediately.
        while (dispatch_if[0].ready !== 1'b1) @(posedge clk);
        #1;
        dispatch_if[0].valid = 1'b0;
    endtask

    task automatic wait_commit(output commit_t res);
        @(posedge clk);
        // Use !== 1'b1 (case comparison) instead of ! to correctly handle
        // X-state in Vivado xsim: !X = X, while(X) exits immediately.
        while (commit_if[0].valid !== 1'b1) @(posedge clk);
        res = commit_if[0].data;
    endtask

`ifdef EXT_AG_TCU_ENABLE
    // fire_ldscale: scalar backward-compat — duplicates scale_a across TC_M rows,
    //   scale_b across TC_N cols (uniform scale case; matches all existing TCs).
    task automatic fire_ldscale(input logic [7:0] scale_a, scale_b);
        dispatch_t pkt; commit_t dummy;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'('hDEAD);
        pkt.wis = '0; pkt.sid = '0; pkt.tmask = '1;
        pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data[0]        = {scale_b, scale_b, scale_a, scale_a};  // TC_M=TC_N=2
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_LDSCALE;
        fire_dispatch(pkt);
        wait_commit(dummy);
    endtask

    // fire_ldmicro: sets pair-shared micro_exp bits (uniform across all threads)
    //   mexp_a[1:0] = {pair1_mexp_a, pair0_mexp_a}
    //   Packing (SCALE_BITS=2, CTX_W=4): meta_arr[0]={0,pair0}, meta_arr[1]={0,pair1}
    //   rs1_data[t][3:0] = {1'b0, pair1, 1'b0, pair0} → shift 0 or 1 per pair
    task automatic fire_ldmicro(input logic [1:0] mexp_a, mexp_b);
        dispatch_t pkt; commit_t dummy;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'('hDEAD);
        pkt.wis = '0; pkt.sid = '0; pkt.tmask = '1;
        pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        for (int t = 0; t < `SIMD_WIDTH; t++) begin
            pkt.rs1_data[t] = {28'b0, 1'b0, mexp_a[1], 1'b0, mexp_a[0]};
            pkt.rs2_data[t] = {28'b0, 1'b0, mexp_b[1], 1'b0, mexp_b[0]};
        end
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_LDMICRO;
        fire_dispatch(pkt);
        wait_commit(dummy);
    endtask

    // fire_ldmicro_3level: sets 2-bit combined shifts per pair for TCU_3LEVEL_ID
    //   pair0_shift = level2 + level3_pair0 (0-2), pair1_shift = level2 + level3_pair1 (0-2)
    //   Packing: meta_arr[0]=pair0_shift[1:0], meta_arr[1]=pair1_shift[1:0]
    //   rs1_data[t][3:0] = {pair1_shift_a[1:0], pair0_shift_a[1:0]}
    task automatic fire_ldmicro_3level(
        input logic [1:0] pair0_shift_a, pair1_shift_a,
        input logic [1:0] pair0_shift_b, pair1_shift_b
    );
        dispatch_t pkt; commit_t dummy;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'('hDEAD);
        pkt.wis = '0; pkt.sid = '0; pkt.tmask = '1;
        pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        for (int t = 0; t < `SIMD_WIDTH; t++) begin
            pkt.rs1_data[t] = {28'b0, pair1_shift_a, pair0_shift_a};
            pkt.rs2_data[t] = {28'b0, pair1_shift_b, pair0_shift_b};
        end
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_LDMICRO;
        fire_dispatch(pkt);
        wait_commit(dummy);
    endtask
`endif

    // Build INT8 dispatch packet (fmt_d=FP32: INT FEDP outputs FP32)
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
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
`ifdef EXT_AG_TCU_ENABLE
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
`endif
        return pkt;
    endfunction

`ifdef EXT_AG_TCU_ENABLE
    // Build MX9 dispatch packet (fmt_s=TCU_MX9_ID; OT patches to I8_ID → INT path)
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
        pkt.op_args.tcu.fmt_s  = 4'(TCU_MX9_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
        return pkt;
    endfunction

    // Build 3LEVEL dispatch packet (fmt_s=TCU_3LEVEL_ID; OT flattens via micro_ctx → I8_ID)
    function automatic dispatch_t build_dispatch_3level(
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
        pkt.op_args.tcu.fmt_s  = 4'(TCU_3LEVEL_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
        return pkt;
    endfunction

    // Build MXINT8 dispatch packet (fmt_s[3]=1 → INT path directly)
    function automatic dispatch_t build_dispatch_mxint8(
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
        pkt.op_args.tcu.fmt_s  = 4'(TCU_MXINT8_ID);
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
    // Output: FP32 bit pattern (INT FEDP outputs FP32)
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
    // run_wmma_mxint8: MXINT8 path with LDSCALE, safe (serial) mode
    // =========================================================================
    task automatic run_wmma_mxint8(
        input string name,
        input logic [7:0] exp_a, exp_b
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_in, rs2_in, rs3_in;
        dispatch_t pkt; commit_t res;
        logic signed [9:0] exp_total;
        bit test_pass;
        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;
        test_pass = 1;

        fire_ldscale(exp_a, exp_b);

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

            pkt = build_dispatch_mxint8(rs1_in, rs2_in, rs3_in, 4'(sm), 4'(sn));
            fire_dispatch(pkt);
            wait_commit(res);

            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++) begin
                    logic [31:0] got, exp_v;
                    got   = res.data[ii*TCU_TC_N + jj];
                    exp_v = ref_d_fp32(rs1_in, rs2_in, rs3_in,
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

    // =========================================================================
    // run_wmma_mx9: MX9 Option C WMMA with LDSCALE + LDMICRO
    // =========================================================================
    task automatic run_wmma_mx9(
        input string name,
        input logic [7:0] exp_a, exp_b,
        input logic [1:0] mexp_a, mexp_b
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_in, rs2_in, rs3_in;
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

            pkt = build_dispatch_mx9(rs1_in, rs2_in, rs3_in, 4'(sm), 4'(sn));
            fire_dispatch(pkt);
            wait_commit(res);

            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++) begin
                    logic [31:0] got, exp_v;
                    got   = res.data[ii*TCU_TC_N + jj];
                    exp_v = ref_d_fp32_mx9(rs1_in, rs2_in, rs3_in,
                                           exp_total, mexp_a, mexp_b, ii, jj, b_off);
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

    // =========================================================================
    // run_wmma_3level: 3-level hierarchical scale WMMA
    //   SW pre-computes combined_shift = level2 + level3_pair (0-2) and stores via
    //   fire_ldmicro_3level.  OT calls flatten_int8_word, patches fmt_s → I8_ID.
    // =========================================================================
    task automatic run_wmma_3level(
        input string     name,
        input logic [7:0] exp_a, exp_b,
        input logic [1:0] p0_shift_a, p1_shift_a,
        input logic [1:0] p0_shift_b, p1_shift_b
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_in, rs2_in, rs3_in;
        dispatch_t pkt; commit_t res;
        logic signed [9:0] exp_total;
        bit test_pass;
        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;
        test_pass = 1;

        fire_ldscale(exp_a, exp_b);
        fire_ldmicro_3level(p0_shift_a, p1_shift_a, p0_shift_b, p1_shift_b);

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

            pkt = build_dispatch_3level(rs1_in, rs2_in, rs3_in, 4'(sm), 4'(sn));
            fire_dispatch(pkt);
            wait_commit(res);

            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++) begin
                    logic [31:0] got, exp_v;
                    got   = res.data[ii*TCU_TC_N + jj];
                    exp_v = ref_d_fp32_3level(rs1_in, rs2_in, rs3_in,
                                              exp_total, p0_shift_a, p1_shift_a,
                                              p0_shift_b, p1_shift_b, ii, jj, b_off);
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

    // =========================================================================
    // fire_flat_uop: send one FLAT UOP and wait for commit
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
    // =========================================================================
    task automatic run_wmma_flat(
        input string       name,
        input logic [1:0]  mexp_a, mexp_b,
        input logic [31:0] a_word,
        input logic [31:0] b_word,
        input logic [31:0] exp_a_flat,
        input logic [31:0] exp_b_flat
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
`ifdef TCU_BHF
    // Build FP8 dispatch packet
    function automatic dispatch_t build_dispatch_fp8(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [3:0] fmt_s,
        input logic [3:0] step_m, step_n
    );
        dispatch_t pkt;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'(1);
        pkt.wis = '0; pkt.sid = '0; pkt.tmask = '1;
        pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data = rs1; pkt.rs2_data = rs2; pkt.rs3_data = rs3;
        pkt.op_args.tcu.fmt_s  = fmt_s;
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
        return pkt;
    endfunction

    // =========================================================================
    // run_wmma_fp8: FP8 path, safe (serial) mode — all TCU_UOPS dispatches
    //   fp8_fmt: TCU_FP8E4M3_ID or TCU_FP8E5M2_ID
    //   Reference: ref_d_fp32_fp8 (real-arithmetic FP8 dot product + C)
    //   Note: LDSCALE exp_total is unused by FP path; fire_ldscale maintains warp state.
    // =========================================================================
    task automatic run_wmma_fp8(
        input string       name,
        input logic [3:0]  fp8_fmt,
        input logic [7:0]  exp_a, exp_b
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_in, rs2_in, rs3_in;
        dispatch_t pkt; commit_t res;
        bit test_pass;
        test_pass = 1;

        fire_ldscale(exp_a, exp_b);

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

            pkt = build_dispatch_fp8(rs1_in, rs2_in, rs3_in, fp8_fmt, 4'(sm), 4'(sn));
            fire_dispatch(pkt);
            wait_commit(res);

            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++) begin
                    logic [31:0] got, exp_v;
                    logic signed [9:0] exp_total;
                    exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;
                    got   = res.data[ii*TCU_TC_N + jj];
                    exp_v = ref_d_fp32_fp8(rs1_in, rs2_in, rs3_in,
                                           fp8_fmt, exp_total, ii, jj, b_off);
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
`endif // TCU_BHF
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

        $display("=== tb_tcu_wmma: V1-V8 format validation ===");
        $display("  TCU_TC_M=%0d  TCU_TC_N=%0d  TCU_TC_K=%0d",
                 TCU_TC_M, TCU_TC_N, TCU_TC_K);
        $display("  UOPS=%0d  M_STEPS=%0d  N_STEPS=%0d  K_STEPS=%0d",
                 TCU_UOPS, TCU_M_STEPS, TCU_N_STEPS, TCU_K_STEPS);
        $display("------------------------------------------------------------");

`ifdef TCU_TEST_INT8
        $display("--- INT8 ---");
        `include "tc/int8.svh"

`elsif TCU_TEST_MXINT8
        $display("--- MXINT8 ---");
`ifdef EXT_AG_TCU_ENABLE
        `include "tc/mxint8.svh"
`endif

`elsif TCU_TEST_MX9
        $display("--- MX9 ---");
`ifdef EXT_AG_TCU_ENABLE
        `include "tc/mx9.svh"
`endif

`elsif TCU_TEST_FLAT
        $display("--- FLAT ---");
`ifdef EXT_AG_TCU_ENABLE
        `include "tc/flat.svh"
`endif

`elsif TCU_TEST_FP8
        $display("--- FP8 ---");
`ifdef EXT_AG_TCU_ENABLE
        `include "tc/fp8.svh"
`endif

`elsif TCU_TEST_MXFP8
        $display("--- MXFP8 ---");
`ifdef EXT_AG_TCU_ENABLE
        `include "tc/mxfp8.svh"
`endif

`elsif TCU_TEST_3LEVEL
        $display("--- 3LEVEL ---");
`ifdef EXT_AG_TCU_ENABLE
        `include "tc/3level.svh"
`endif

`else
        // Default: run all formats
        $display("--- INT8 ---");
        `include "tc/int8.svh"

`ifdef EXT_AG_TCU_ENABLE
        $display("--- MXINT8 ---");
        `include "tc/mxint8.svh"

        $display("--- MX9 ---");
        `include "tc/mx9.svh"

        $display("--- FLAT ---");
        `include "tc/flat.svh"

        `include "tc/fp8.svh"

        $display("--- MXFP8 ---");
        `include "tc/mxfp8.svh"

        $display("--- 3LEVEL ---");
        `include "tc/3level.svh"
`endif
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
