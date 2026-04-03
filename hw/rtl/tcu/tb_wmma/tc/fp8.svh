// =============================================================================
// tc/fp8.svh — FP8 path test cases  (requires EXT_AG_TCU_ENABLE + TCU_BHF)
// =============================================================================
// Formats: fmt_s = TCU_FP8E4M3_ID or TCU_FP8E5M2_ID, fmt_d = TCU_FP32_ID
// Pipeline: fmt_s[3]=0, not MX9 → pe_sel=0 → VX_tcu_fp (BHF FP path)
// Element packing per word: [15:8]=FP8[0], [31:24]=FP8[1], unused bytes=0
//   NT=4, TCU_TC_K=2: 2 words × 2 FP8/word = 4 elements per single-step dot product
// Note: LDSCALE exp_total is unused on FP path (no fedp_int_scaled).
//
// Coverage:
//   [V2] TC_fp8e4m3_identity  — E4M3 A=B=1.0, C=0 → 4.0  (single-step baseline)
//   [V3] TC_fp8e4m3_sign      — E4M3 A=-1.0, B=1.0 → -4.0
//   [V7] TC_fp8e4m3_kaccum    — E4M3 A=B=1.0, K_STEPS accumulation
//   [V8] TC_fp8e4m3_subnormal — E4M3 e=0 input → HW flush-to-zero (FTZ), output=0
//   [V2] TC_fp8e5m2_identity  — E5M2 A=B=1.0, C=0 → 4.0
//   [V3] TC_fp8e5m2_sign      — E5M2 A=-1.0, B=1.0 → -4.0
//   [V7] TC_fp8e5m2_kaccum    — E5M2 A=B=1.0, K_STEPS accumulation
//   [V6b] TC_fp8e5m2_inf      — E5M2 A=+Inf, B=1.0 → FP32 +Inf output
// =============================================================================
`ifdef TCU_BHF
begin : tc_fp8
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
    // [V2] TC_fp8e4m3_identity: A=B=1.0 E4M3, C=0 → dot=4.0 (single-step)
    //   4 elements × 1.0×1.0 = 4.0 = 0x40800000
    // ------------------------------------------------------------------
    fire_ldscale(8'd127, 8'd127);
    fill_A(e4m3_pos1); fill_B(e4m3_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_fp8e4m3_identity", 4'(TCU_FP8E4M3_ID), 8'd127, 8'd127);

    // ------------------------------------------------------------------
    // [V3] TC_fp8e4m3_sign: A=-1.0, B=1.0 → dot=-4.0
    //   4 elements × (-1.0)×1.0 = -4.0 = 0xC0800000
    // ------------------------------------------------------------------
    fill_A(e4m3_neg1); fill_B(e4m3_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_fp8e4m3_sign", 4'(TCU_FP8E4M3_ID), 8'd127, 8'd127);

    // ------------------------------------------------------------------
    // [V7] TC_fp8e4m3_kaccum: A=B=1.0, C starts at 0 → K-accumulation
    //   per UOP: dot = 4.0; D accumulates across K_STEPS
    //   NT=4 (K_STEPS=2): 4.0×2 = 8.0 = 0x41000000
    //   NT=8 (K_STEPS=4): 4.0×4 = 16.0 = 0x41800000
    // ------------------------------------------------------------------
    fill_A(e4m3_pos1); fill_B(e4m3_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_fp8e4m3_kaccum", 4'(TCU_FP8E4M3_ID), 8'd127, 8'd127);

    // ------------------------------------------------------------------
    // [V8] TC_fp8e4m3_subnormal: A=B=0x04 (E4M3 subnormal: e=0, m=100)
    //   verifies HW flush-to-zero (FTZ) for E4M3 subnormals (e=0 → ±0)
    //   HW explicitly flushes all e=0 inputs to ±0 (VX_tcu_fedp_bhf.sv)
    //   dot product = 4 × 0.0 × 0.0 = 0.0 → expected output = 0x00000000
    //   (ref_fp8e4m3_to_real returns 0.0 for e=0, matching FTZ behavior)
    // ------------------------------------------------------------------
    fill_A(e4m3_subnorm); fill_B(e4m3_subnorm); fill_D(32'h00000000);
    run_wmma_fp8("TC_fp8e4m3_subnormal", 4'(TCU_FP8E4M3_ID), 8'd127, 8'd127);

    // ------------------------------------------------------------------
    // [V2] TC_fp8e5m2_identity: A=B=1.0 E5M2, C=0 → 4.0
    // ------------------------------------------------------------------
    fill_A(e5m2_pos1); fill_B(e5m2_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_fp8e5m2_identity", 4'(TCU_FP8E5M2_ID), 8'd127, 8'd127);

    // ------------------------------------------------------------------
    // [V3] TC_fp8e5m2_sign: A=-1.0, B=1.0 → -4.0
    // ------------------------------------------------------------------
    fill_A(e5m2_neg1); fill_B(e5m2_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_fp8e5m2_sign", 4'(TCU_FP8E5M2_ID), 8'd127, 8'd127);

    // ------------------------------------------------------------------
    // [V7] TC_fp8e5m2_kaccum: A=B=1.0 E5M2, K-accumulation
    //   NT=4: 8.0=0x41000000; NT=8: 16.0=0x41800000
    // ------------------------------------------------------------------
    fill_A(e5m2_pos1); fill_B(e5m2_pos1); fill_D(32'h00000000);
    run_wmma_fp8("TC_fp8e5m2_kaccum", 4'(TCU_FP8E5M2_ID), 8'd127, 8'd127);

    // ------------------------------------------------------------------
    // [V6b] TC_fp8e5m2_inf: A=+Inf E5M2 (0x7C), B=1.0 E5M2 (0x3C)
    //   E5M2 supports Inf: {s=0, e=11111, m=00} = 0x7C
    //   dot = 4 × (+Inf)×(1.0) = +Inf → FP32 +Inf = 0x7F800000
    //   (single-step hardcoded; Inf propagation verified directly)
    // ------------------------------------------------------------------
    fire_ldscale(8'd127, 8'd127);
    pkt_fp8 = '0;
    pkt_fp8.uuid = UUID_WIDTH'(1); pkt_fp8.wis = '0; pkt_fp8.sid = '0;
    pkt_fp8.tmask = '1; pkt_fp8.sop = 1'b1; pkt_fp8.eop = 1'b1; pkt_fp8.wb = 1'b1;
    pkt_fp8.op_type = INST_ALU_BITS'(INST_TCU_WMMA);
    for (int t = 0; t < `SIMD_WIDTH; t++) begin
        pkt_fp8.rs1_data[t] = e5m2_inf;
        pkt_fp8.rs2_data[t] = e5m2_pos1;
        pkt_fp8.rs3_data[t] = 32'h00000000;
    end
    pkt_fp8.op_args.tcu.fmt_s  = 4'(TCU_FP8E5M2_ID);
    pkt_fp8.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
    pkt_fp8.op_args.tcu.tcu_op = TCU_OP_WMMA;
    pkt_fp8.op_args.tcu.step_m = '0; pkt_fp8.op_args.tcu.step_n = '0;
    fire_dispatch(pkt_fp8);
    wait_commit(res_fp8);
    begin
        bit ok; ok = 1;
        for (int ii=0; ii<TCU_TC_M; ii++)
            for (int jj=0; jj<TCU_TC_N; jj++)
                // FP32 +Inf = {s=0, exp=0xFF, mant=0} = 0x7F800000
                if (res_fp8.data[ii*TCU_TC_N+jj] !== 32'h7F800000) ok = 0;
        if (ok) begin
            $display("[PASS] %-28s +Inf = 0x7F800000", "TC_fp8e5m2_inf");
            pass_cnt++;
        end else begin
            $display("[FAIL] %-28s got=0x%08X exp=0x7F800000",
                     "TC_fp8e5m2_inf", res_fp8.data[0]);
            fail_cnt++;
        end
    end

end : tc_fp8
`endif // TCU_BHF
