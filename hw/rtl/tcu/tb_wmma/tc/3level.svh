// =============================================================================
// tc/3level.svh — TCU_3LEVEL_ID hypothetical 3-level hierarchical scale test cases
// =============================================================================
// Format: fmt_s = TCU_3LEVEL_ID (3), fmt_d = TCU_FP32_ID
// Pipeline: OT flatten_int8_word → fmt_s patch to I8_ID → pe_sel=1 → VX_tcu_int
//
// 3-level hierarchy:
//   Level 1 (L1): E8M0 global block scale → exp_total via LDSCALE (shared by all elements)
//   Level 2 (L2): word-level scale, 1 bit shared by ALL 4 bytes in the 32-bit word
//   Level 3 (L3): pair-level scale, 1 bit shared by each 2-byte pair
//
// SW pre-computes combined shift per pair before LDMICRO:
//   combined_shift_pair0 = L2 + L3_pair0  (0-2, stored as 2-bit value)
//   combined_shift_pair1 = L2 + L3_pair1
//
// Key design intent for test cases:
//   To verify L2 "4-element sharing": pair0_shift and pair1_shift must share the
//   same L2 base and differ only in L3. Input data must differ between pairs so
//   the effect is visible in the waveform.
//   To verify L3 "2-element sharing": pair0 and pair1 get different shifts.
//
// Word byte layout: [31:24]=pair1_b1, [23:16]=pair1_b0, [15:8]=pair0_b1, [7:0]=pair0_b0
//
// Coverage:
//   [V2] TC_3level_passthrough — L1 only (L2=0, L3=0), identity baseline
//   [V8] TC_3level_l2_shared  — L2=1, L3=0: all 4 bytes uniformly shifted (×2),
//                                different pair data shows 4-element sharing in waveform
//   [V8] TC_3level_l3_diff    — L2=0, L3={pair0=0, pair1=1}: only pair1 shifted (×2),
//                                different pair data shows 2-element sharing boundary
//   [V8] TC_3level_hierarchy  — L2=1, L3={pair0=0, pair1=1}: combined effect,
//                                pair0_shift=1, pair1_shift=2 with different pair data
//                                (KEY TC: demonstrates 4-element L2 sharing AND
//                                 2-element L3 differentiation simultaneously)
//   [V6] TC_3level_saturation — L2=1, L3=1 (both pairs): A pair1=0x40 → shift=2 → sat 0x7F
// =============================================================================

begin : tc_3level

    // ------------------------------------------------------------------
    // [V2] TC_3level_passthrough: L2=0, L3=0 → identity (regression baseline)
    //   A=B=0x01010101, C=0; flat = passthrough
    //   dot/word = 4×1×1=4; per uop (TC_K=2): 8
    //   NT=4 (K_STEPS=2): 16.0=0x41800000
    //   NT=8 (K_STEPS=4): 32.0=0x42000000
    // ------------------------------------------------------------------
    fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'h00000000);
    run_wmma_3level("TC_3level_passthrough",
        8'd127, 8'd127,
        2'd0, 2'd0,   // pair0_shift_a=0, pair1_shift_a=0
        2'd0, 2'd0);  // pair0_shift_b=0, pair1_shift_b=0

    // ------------------------------------------------------------------
    // [V8] TC_3level_l2_shared: L2=1, L3=0 → pair0_shift=pair1_shift=1
    //   Verifies L2 as a word-level (4-element shared) factor:
    //   A = {0x02, 0x02, 0x01, 0x01} = 0x02020101  (pair1≠pair0)
    //   B = 0x01010101
    //   OT flat_A: pair0 bytes sat(0x01<<1)=0x02, pair1 bytes sat(0x02<<1)=0x04
    //   → flat_A = 0x04040202  (waveform: same shift applied to both pairs)
    //   dot/word = (0x01×0x02 + 0x01×0x02) + (0x02×0x04 + 0x02×0x04) -- wait, B is flat too
    //   flat_B: all 0x01<<1 = 0x02; flat_B = 0x02020202
    //   dot/word = 2×(0x02×0x02) + 2×(0x04×0x02) = 8 + 16 = 24; per uop: 48
    //   NT=4: 96.0=0x42C00000; NT=8: 192.0=0x43400000
    // ------------------------------------------------------------------
    fill_A(32'h02020101); fill_B(32'h01010101); fill_D(32'h00000000);
    run_wmma_3level("TC_3level_l2_shared",
        8'd127, 8'd127,
        2'd1, 2'd1,   // L2=1, L3_pair0=0, L3_pair1=0 → both pairs shift=1
        2'd1, 2'd1);

    // ------------------------------------------------------------------
    // [V8] TC_3level_l3_diff: L2=0, L3={pair0=0, pair1=1} → pair0_shift=0, pair1_shift=1
    //   Verifies L3 as a pair-level (2-element) factor:
    //   A = {0x02, 0x02, 0x01, 0x01} = 0x02020101
    //   B = 0x01010101
    //   OT flat_A: pair0=passthrough→0x01, pair1=sat(0x02<<1)=0x04
    //   → flat_A = 0x04040101  (waveform: L3 boundary visible at pair1/pair0 split)
    //   flat_B: pair0=0x01, pair1=sat(0x01<<1)=0x02 → flat_B=0x02020101
    //   dot/word = 2×(0x01×0x01) + 2×(0x04×0x02) = 2 + 16 = 18; per uop: 36
    //   NT=4: 72.0=0x42900000; NT=8: 144.0=0x43100000
    // ------------------------------------------------------------------
    fill_A(32'h02020101); fill_B(32'h01010101); fill_D(32'h00000000);
    run_wmma_3level("TC_3level_l3_diff",
        8'd127, 8'd127,
        2'd0, 2'd1,   // L2=0: pair0_shift=0+0=0, pair1_shift=0+1=1
        2'd0, 2'd1);

    // ------------------------------------------------------------------
    // [V8] TC_3level_hierarchy: L2=1, L3={pair0=0, pair1=1}
    //   KEY TC: demonstrates L2 4-element sharing AND L3 2-element differentiation.
    //   pair0_shift = L2 + L3_pair0 = 1+0 = 1
    //   pair1_shift = L2 + L3_pair1 = 1+1 = 2
    //   A = {0x02, 0x02, 0x01, 0x01} = 0x02020101
    //   B = 0x01010101
    //   OT flat_A: pair0=sat(0x01<<1)=0x02, pair1=sat(0x02<<2)=0x08
    //   → flat_A = 0x08080202  (waveform: L2 base visible in both, L3 extra in pair1)
    //   flat_B: pair0=sat(0x01<<1)=0x02, pair1=sat(0x01<<2)=0x04
    //   → flat_B = 0x04040202
    //   dot/word = 2×(0x02×0x02) + 2×(0x08×0x04) = 8 + 64 = 72; per uop: 144
    //   NT=4: 288.0=0x44100000; NT=8: 576.0=0x44100000 → 576=0x44100000
    //   NT=4: 288.0=0x43900000; NT=8: 576.0=0x44100000
    // ------------------------------------------------------------------
    fill_A(32'h02020101); fill_B(32'h01010101); fill_D(32'h00000000);
    run_wmma_3level("TC_3level_hierarchy",
        8'd127, 8'd127,
        2'd1, 2'd2,   // pair0_shift=1+0=1, pair1_shift=1+1=2
        2'd1, 2'd2);

    // ------------------------------------------------------------------
    // [V6] TC_3level_saturation: L2=1, L3=1 (both pairs) → shift=2 for all bytes
    //   A pair1 = 0x40 (+64): sat(0x40<<2) = sat(256) → 0x7F (overflow, saturate)
    //   A pair0 = 0x01 (+1):  sat(0x01<<2) = 0x04     (no overflow)
    //   A = {0x40, 0x40, 0x01, 0x01} = 0x40400101
    //   B = 0x01010101; flat_B: all sat(0x01<<2)=0x04
    //   flat_A = {0x7F,0x7F,0x04,0x04} = 0x7F7F0404
    //   dot/word = 2×(0x04×0x04) + 2×(0x7F×0x04) = 32 + 1016 = 1048; per uop: 2096
    //   NT=4: 4192.0=0x45830000; NT=8: 8384.0=0x46030000
    // ------------------------------------------------------------------
    fill_A(32'h40400101); fill_B(32'h01010101); fill_D(32'h00000000);
    run_wmma_3level("TC_3level_saturation",
        8'd127, 8'd127,
        2'd2, 2'd2,   // pair0_shift=2, pair1_shift=2
        2'd2, 2'd2);

end : tc_3level
