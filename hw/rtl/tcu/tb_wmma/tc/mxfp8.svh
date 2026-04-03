// =============================================================================
// tc/mxfp8.svh — MXFP8 path test cases  (requires EXT_AG_TCU_ENABLE + TCU_BHF)
// =============================================================================
// Formats: fmt_s = TCU_FP8E4M3_ID or TCU_FP8E5M2_ID, fmt_d = TCU_FP32_ID
// Pipeline: fmt_s[3]=0, not MX9 → pe_sel=0 → VX_tcu_fp (BHF FP path)
// Note: This MXFP8 test explicitly applies non-zero block exponents via LDSCALE
//       to verify the exp_total exponent shift scaling applied to the final FP result.
//
// Coverage:
//   [V2] TC_mxfp8e4m3_identity   — E4M3 A=B=1.0, C=0, scale=0 → 4.0
//   [V3] TC_mxfp8e4m3_sign       — E4M3 A=-1.0, B=1.0, scale=0 → -4.0
//   [V4] TC_mxfp8e4m3_scale_pos  — E4M3 A=B=1.0, scale=exp_total>0 (+2) → 16.0
//   [V5] TC_mxfp8e4m3_scale_neg  — E4M3 A=B=1.0, scale=exp_total<0 (-2) → 1.0
//   [V8] TC_mxfp8e4m3_subnormal  — E4M3 e=0 input → HW flush-to-zero (FTZ), output=0
//   [V2] TC_mxfp8e5m2_identity   — E5M2 A=B=1.0, C=0, scale=0 → 4.0
//   [V4] TC_mxfp8e5m2_scale_pos  — E5M2 A=B=1.0, scale=exp_total>0 (+3) → 32.0
//   [V5] TC_mxfp8e5m2_scale_neg  — E5M2 A=B=1.0, scale=exp_total<0 (-1) → 2.0
// =============================================================================
`ifdef TCU_BHF
begin : tc_mxfp8
    dispatch_t pkt_fp8; commit_t res_fp8;

    // FP8 bit patterns (word-packed: [15:8]=elem0, [31:24]=elem1)
    logic [31:0] e4m3_pos1;    //  1.0 E4M3: {s=0,e=0111,m=000}=0x38
    logic [31:0] e4m3_neg1;    // -1.0 E4M3: 0xB8
    logic [31:0] e4m3_subnorm; //  subnormal E4M3: {s=0,e=0000,m=100}=0x04 → 2^(-7)
    logic [31:0] e5m2_pos1;    //  1.0 E5M2: {s=0,e=01111,m=00}=0x3C
    logic [31:0] e5m2_neg1;    // -1.0 E5M2: 0xBC
    logic [31:0] e5m2_inf;     // +Inf E5M2: {s=0,e=11111,m=00}=0x7C

    e4m3_pos1    = {8'h38, 8'h00, 8'h38, 8'h00};
    e4m3_neg1    = {8'hB8, 8'h00, 8'hB8, 8'h00};
    e4m3_subnorm = {8'h04, 8'h00, 8'h04, 8'h00};  // 2^(-7) per element
    e5m2_pos1    = {8'h3C, 8'h00, 8'h3C, 8'h00};
    e5m2_neg1    = {8'hBC, 8'h00, 8'hBC, 8'h00};
    e5m2_inf     = {8'h7C, 8'h00, 8'h7C, 8'h00};

    // ------------------------------------------------------------------
    // [V2] TC_mxfp8e4m3_identity: A=B=1.0 E4M3, scale=0 → dot=4.0
    // ------------------------------------------------------------------
    fire_ldscale(8'd127, 8'd127);
    fill_A(e4m3_pos1); fill_B(e4m3_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_mxfp8e4m3_identity", 4'(TCU_FP8E4M3_ID), 8'd127, 8'd127);

    // ------------------------------------------------------------------
    // [V3] TC_mxfp8e4m3_sign: A=-1.0, B=1.0, scale=0 → dot=-4.0
    // ------------------------------------------------------------------
    fill_A(e4m3_neg1); fill_B(e4m3_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_mxfp8e4m3_sign", 4'(TCU_FP8E4M3_ID), 8'd127, 8'd127);

    // ------------------------------------------------------------------
    // [V4] TC_mxfp8e4m3_scale_pos: scale = +2 (128 + 128 - 127 = 129 -> exp_total=+2)
    //   4 elements × 1.0×1.0 = 4.0; * 2^2 = 16.0
    // ------------------------------------------------------------------
    fire_ldscale(8'd128, 8'd128);
    fill_A(e4m3_pos1); fill_B(e4m3_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_mxfp8e4m3_scale_pos", 4'(TCU_FP8E4M3_ID), 8'd128, 8'd128);

    // ------------------------------------------------------------------
    // [V5] TC_mxfp8e4m3_scale_neg: scale = -2 (126 + 126 - 127 = 125 -> exp_total=-2)
    //   4.0 * 2^(-2) = 1.0
    // ------------------------------------------------------------------
    fire_ldscale(8'd126, 8'd126);
    fill_A(e4m3_pos1); fill_B(e4m3_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_mxfp8e4m3_scale_neg", 4'(TCU_FP8E4M3_ID), 8'd126, 8'd126);

    // ------------------------------------------------------------------
    // [V8] TC_mxfp8e4m3_subnormal: HW FTZ handling
    // ------------------------------------------------------------------
    fire_ldscale(8'd127, 8'd127);
    fill_A(e4m3_subnorm); fill_B(e4m3_subnorm); fill_D(32'h00000000);
    run_wmma_fp8("TC_mxfp8e4m3_subnormal", 4'(TCU_FP8E4M3_ID), 8'd127, 8'd127);

    // ------------------------------------------------------------------
    // [V2] TC_mxfp8e5m2_identity: A=B=1.0 E5M2, scale=0 → 4.0
    // ------------------------------------------------------------------
    fill_A(e5m2_pos1); fill_B(e5m2_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_mxfp8e5m2_identity", 4'(TCU_FP8E5M2_ID), 8'd127, 8'd127);

    // ------------------------------------------------------------------
    // [V4] TC_mxfp8e5m2_scale_pos: scale = +3 (129 + 128 - 127 = +3)
    //   4.0 * 2^3 = 32.0
    // ------------------------------------------------------------------
    fire_ldscale(8'd129, 8'd128);
    fill_A(e5m2_pos1); fill_B(e5m2_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_mxfp8e5m2_scale_pos", 4'(TCU_FP8E5M2_ID), 8'd129, 8'd128);

    // ------------------------------------------------------------------
    // [V5] TC_mxfp8e5m2_scale_neg: scale = -1 (126 + 127 - 127 = -1)
    //   4.0 * 2^(-1) = 2.0
    // ------------------------------------------------------------------
    fire_ldscale(8'd126, 8'd127);
    fill_A(e5m2_pos1); fill_B(e5m2_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_mxfp8e5m2_scale_neg", 4'(TCU_FP8E5M2_ID), 8'd126, 8'd127);

end : tc_mxfp8
`endif // TCU_BHF
