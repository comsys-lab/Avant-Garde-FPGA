// =============================================================================
// tc/mx9.svh — MX9 path test cases
// =============================================================================
// Format: fmt_s = TCU_MX9_ID (4), fmt_d = TCU_FP32_ID
// Pipeline: OT patches fmt_s 4→TCU_I8_ID → pe_sel=1 → VX_tcu_int (INT path)
// Setup: LDSCALE + LDMICRO required
// Encoding: byte = {s[1b], frac[6:0]}; requant: Q={1,frac}, flat=Q>>(2-mexp)
// Output: FP32 = dot(flat_A, flat_B) × 2^(exp_total-10) + C
//
// Coverage:
//   [V1][V2][V7] TC_mx9_identity  — neutral input, mexp=0, exp=0 (OT routing implicit)
//   [V3]         TC_mx9_sign      — negative A byte → negative dot
//   [V4]         TC_mx9_scale_pos — exp_total=+2 with mexp=0  ← NEW
//   [V5]         TC_mx9_scale_neg — exp_total=-1 with mexp=0  ← NEW
//   [V6]         TC_mx9_boundary  — A=B=0x7F (max), mexp=1 → max flat=127, no OT saturation
//   [V8]         TC_mx9_mexp1     — mexp=1 all pairs → ×2 quantization effect
//   [V8]         TC_mx9_mexp_mixed — pair0_mexp≠pair1_mexp → per-pair differential
// =============================================================================

// [V1][V2][V7] TC_mx9_identity: A=B=0x00 (s=0,frac=0), mexp=0, exp_total=0, C=0
//   requant: Q=128, flat=128>>2=32; per k-step: dot = TC_K×4 × 32×32 = 8192
//   fp_d = 8192 × 2^(0-10) = 8.0/k-step (all K_STEPS accumulated)
//   V1 implicit: MX9 WMMA producing correct FP32 output proves OT fmt_s patch active
//   NT=4 (K_STEPS=2): 16.0 = 0x41800000
//   NT=8 (K_STEPS=4): 32.0 = 0x42000000
fill_A(32'h00000000); fill_B(32'h00000000); fill_D(32'h00000000);
run_wmma_mx9("TC_mx9_identity", 8'd127, 8'd127, 2'b00, 2'b00);

// [V3] TC_mx9_sign: A=0x80 (s=1, frac=0), B=0x00, mexp=0
//   flat_A = -32, flat_B = +32 → dot = TC_K×4 × (-32)×32 = -8192/uop
//   fp_d = -8192 × 2^(-10) = -8.0/k-step
//   NT=4 (K_STEPS=2): -16.0 = 0xC1800000
//   NT=8 (K_STEPS=4): -32.0 = 0xC2000000
fill_A(32'h80808080); fill_B(32'h00000000); fill_D(32'h00000000);
run_wmma_mx9("TC_mx9_sign", 8'd127, 8'd127, 2'b00, 2'b00);

// [V4] TC_mx9_scale_pos: A=B=0x00, mexp=0, exp_total=+2 (scale_a=128, scale_b=128)
//   flat_A=flat_B=32; per k-step: dot=8192
//   fp_d = 8192 × 2^(2-10) = 8192/256 = 32.0/k-step
//   NT=4 (K_STEPS=2): 64.0 = 0x42800000
//   NT=8 (K_STEPS=4): 128.0 = 0x43000000
fill_A(32'h00000000); fill_B(32'h00000000); fill_D(32'h00000000);
run_wmma_mx9("TC_mx9_scale_pos", 8'd128, 8'd128, 2'b00, 2'b00);

// [V5] TC_mx9_scale_neg: A=B=0x00, mexp=0, exp_total=-1 (scale_a=127, scale_b=126)
//   flat_A=flat_B=32; per k-step: dot=8192
//   fp_d = 8192 × 2^(-1-10) = 8192/2048 = 4.0/k-step
//   NT=4 (K_STEPS=2): 8.0 = 0x41000000
//   NT=8 (K_STEPS=4): 16.0 = 0x41800000
fill_A(32'h00000000); fill_B(32'h00000000); fill_D(32'h00000000);
run_wmma_mx9("TC_mx9_scale_neg", 8'd127, 8'd126, 2'b00, 2'b00);

// [V6] TC_mx9_boundary: A=B=0x7F (s=0,frac=127), mexp=1 → max flat value, no OT saturation
//   Q=255, flat=255>>1=127 (INT8 max; mexp=1 still within range, no sat8_shift needed)
//   per k-step: dot = TC_K×4 × 127×127 = 8 × 16129 = 129032
//   fp_d = 129032 × 2^(-9) per k-step
//   ref_d_fp32_mx9 computes exact expected per step
fill_A(32'h7F7F7F7F); fill_B(32'h7F7F7F7F); fill_D(32'h00000000);
run_wmma_mx9("TC_mx9_boundary", 8'd127, 8'd127, 2'b11, 2'b11);

// [V8] TC_mx9_mexp1: A=B=0x00, mexp=1 all pairs → flat=64 (vs 32 at mexp=0), ×2 effect
//   Q=128, flat=128>>1=64; per k-step: dot = TC_K×4 × 64×64 = 8 × 4096 = 32768
//   fp_d = 32768 × 2^(-9) = 64.0/k-step
//   NT=4 (K_STEPS=2): 128.0 = 0x43000000
//   NT=8 (K_STEPS=4): 256.0 = 0x43800000
fill_A(32'h00000000); fill_B(32'h00000000); fill_D(32'h00000000);
run_wmma_mx9("TC_mx9_mexp1", 8'd127, 8'd127, 2'b11, 2'b11);

// [V8] TC_mx9_mexp_mixed: A=0x40 (s=0,frac=64), mexp_a=2'b10 (pair1=1,pair0=0)
//   mexp_b=0 for both pairs; B=0x00 (flat=32 for both pairs)
//   pair0: flat_A = Q_A>>2 = (128+64)>>2 = 48; pair1: flat_A = 192>>1 = 96
//   per k-step: dot = TC_K × (2×48×32 + 2×96×32) = 2 × (1536 + 3072) = 9216
//   fp_d = 9216 × 2^(-10) = 9.0/k-step
//   NT=4 (K_STEPS=2): 18.0 = 0x41900000
//   NT=8 (K_STEPS=4): 36.0 = 0x42100000
fill_A(32'h40404040); fill_B(32'h00000000); fill_D(32'h00000000);
run_wmma_mx9("TC_mx9_mexp_mixed", 8'd127, 8'd127, 2'b10, 2'b00);
