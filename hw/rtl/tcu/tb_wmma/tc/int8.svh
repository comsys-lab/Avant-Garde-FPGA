// =============================================================================
// tc/int8.svh — INT8 path test cases
// =============================================================================
// Format: fmt_s = TCU_I8_ID, fmt_d = TCU_FP32_ID
// Pipeline: fmt_s[3]=1 → pe_sel=1 → VX_tcu_int (INT path)
// Output: FP32 = dot(A,B) × 2^exp_total + C
//
// Coverage:
//   [V2][V7] TC_int8_identity  — neutral input K-accumulation baseline
//   [V3]     TC_int8_sign      — negative A → negative FP32 output
//   [V4]     TC_int8_scale_pos — exp_total=+2 → ×4 scale
//   [V5]     TC_int8_scale_neg — exp_total=-1 → ×0.5 scale
//   [V7]     TC_int8_nonzero_C — non-zero initial C (mixed-sign fp32_add)
// =============================================================================

// [V2][V7] TC_int8_identity: A=B=1, exp_total=0, C=0 → K-accumulation baseline
//   per k-step: dot = TC_TC_K×4 × 1×1 = 8 → FP32 8.0
//   NT=4 (K_STEPS=2): 16.0 = 0x41800000
//   NT=8 (K_STEPS=4): 32.0 = 0x42000000
fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'h00000000);
run_wmma("TC_int8_identity", 8'd127, 8'd127);

// [V3] TC_int8_sign: A=0xFF (INT8=-1), B=1, exp_total=0 → negative FP32 output
//   per k-step: dot = TC_K×4 × (-1)×1 = -8 → FP32 -8.0
//   NT=4 (K_STEPS=2): -16.0 = 0xC1800000
//   NT=8 (K_STEPS=4): -32.0 = 0xC2000000
fill_A(32'hFFFFFFFF); fill_B(32'h01010101); fill_D(32'h00000000);
run_wmma("TC_int8_sign", 8'd127, 8'd127);

// [V4] TC_int8_scale_pos: A=B=1, exp_total=+2 (scale_a=128, scale_b=128)
//   per k-step: dot=8 → FP32 8.0 × 2^2 = 32.0
//   NT=4 (K_STEPS=2): 64.0 = 0x42800000
//   NT=8 (K_STEPS=4): 128.0 = 0x43000000
//   NOTE: run before any MX9 test that sets mexp≠0 (micro_ctx at reset=0 = passthrough)
fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'h00000000);
run_wmma("TC_int8_scale_pos", 8'd128, 8'd128);

// [V5] TC_int8_scale_neg: A=B=2, exp_total=-1 (scale_a=127, scale_b=126)
//   per k-step: dot = TC_K×4 × 2×2 = 32 → FP32 32.0 × 2^(-1) = 16.0
//   NT=4 (K_STEPS=2): 32.0 = 0x42000000
//   NT=8 (K_STEPS=4): 64.0 = 0x42800000
fill_A(32'h02020202); fill_B(32'h02020202); fill_D(32'h00000000);
run_wmma("TC_int8_scale_neg", 8'd127, 8'd126);

// [V7] TC_int8_nonzero_C: non-zero initial C → mixed-sign fp32_add
//   A=B=1, exp_total=0, D starts at FP32(-8.0) = 0xC1000000
//   sk=0: dot=8, 8.0+(-8.0)=0.0; sk=1: 8.0+0.0=8.0
//   NT=4 (K_STEPS=2): 8.0 = 0x41000000
//   NT=8 (K_STEPS=4): sk0→0, sk1→8, sk2→16, sk3→24 → 24.0 = 0x41C00000
fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'hC1000000);
run_wmma("TC_int8_nonzero_C", 8'd127, 8'd127);
