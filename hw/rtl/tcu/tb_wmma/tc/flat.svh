// =============================================================================
// tc/flat.svh — FLAT instruction test cases
// =============================================================================
// Instruction: tcu_op = TCU_OP_FLAT, tcu_args.tile_type[0]: 0=A tile, 1=B tile
// Setup: LDMICRO required (micro_ctx[wid] holds mexp_a, mexp_b)
// Operation: flatten_int8_byte(byte, mexp) applied to each byte of rs1_data
//            Result written back to tile register (format=I8, routed to INT path bypass)
//
// Coverage:
//   [V2] TC_flat_identity  — mexp=0 → all bytes passthrough (regression)
//   [V3] TC_flat_sign      — saturation boundary: mexp=1, sign overflow → sat to ±127/−128
//   [V4] TC_flat_double    — mexp_a=11 → A×2, mexp_b=00 → B passthrough (A/B isolation)
//   [V8] TC_flat_mixed     — pair0_mexp≠pair1_mexp → per-pair differential shift
//   [V7] TC_flat_then_wmma — FLAT output → WMMA input (pipeline integration)
// =============================================================================

// [V2] TC_flat_identity: mexp=0 for all → passthrough (no shift applied)
//   A=0x01020304, B=0x05060708 → unchanged
run_wmma_flat("TC_flat_identity",
    2'b00, 2'b00,
    32'h01020304, 32'h05060708,
    32'h01020304, 32'h05060708);

// [V3] TC_flat_sign: mexp=1 with bytes at saturation boundary
//   0x40 (+64): msb=0, bit6=1 → overflow_pos → sat 0x7F (+127)
//   0x80 (-128): msb=1, bit6=0 → overflow_neg → sat 0x80 (-128, no change)
//   0x01 (+1): no overflow → shift → 0x02
//   0xFE (-2): msb=1, bit6=1 → no overflow → shift → 0xFC (-4)
//   word = {0xFE, 0x80, 0x40, 0x01}
//   exp_a_flat = {sat(0xFE<<1), sat(0x80<<1), sat(0x40<<1), sat(0x01<<1)}
//             = {0xFC,         0x80,          0x7F,         0x02}
//             = 32'hFC807F02
run_wmma_flat("TC_flat_sign",
    2'b11, 2'b11,
    32'hFE804001, 32'hFE804001,
    32'hFC807F02, 32'hFC807F02);

// [V4] TC_flat_double: mexp_a=11 → A×2, mexp_b=00 → B passthrough
//   Verifies A and B tile OT flatten isolation (mexp_a must not affect B-tile)
//   A=0x01010101 → 0x02020202 (all bytes ×2, no overflow)
//   B=0x01010101 → 0x01010101 (mexp_b=00, no shift)
run_wmma_flat("TC_flat_double",
    2'b11, 2'b00,
    32'h01010101, 32'h01010101,
    32'h02020202, 32'h01010101);

// [V8] TC_flat_mixed: mexp_a=2'b10 (pair1=1, pair0=0) → per-pair differential shift
//   pair0 bytes (indices 0,1): mexp=0 → no shift
//   pair1 bytes (indices 2,3): mexp=1 → ×2
//   A=0x01020304 (bytes: b0=0x04, b1=0x03, b2=0x02, b3=0x01)
//   flat_a: b0→0x04(×1), b1→0x03(×1), b2→0x04(×2), b3→0x02(×2)
//         = 0x02040304
run_wmma_flat("TC_flat_mixed",
    2'b10, 2'b00,
    32'h01020304, 32'h01020304,
    32'h02040304, 32'h01020304);

// [V7] TC_flat_then_wmma: FLAT output → WMMA input (end-to-end integration)
//   Step 1: FLAT A-tile (mexp_a=11, A=0x01010101 → 0x02020202)
//   Step 2: reset micro_ctx (mexp=00) so WMMA INT path does not re-flatten
//   Step 3: INT8 WMMA with captured A=0x02020202, B=0x01010101, D=0
//   Expected per k-step: dot = TC_K×4 × 2×1 = 16 → FP32 16.0
//   NT=4 (K_STEPS=2): 32.0 = 0x42000000
//   NT=8 (K_STEPS=4): 64.0 = 0x42800000
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
    run_wmma("TC_flat_then_wmma", 8'd127, 8'd127);
end
