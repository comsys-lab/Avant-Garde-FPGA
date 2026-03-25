// =============================================================================
// tb_tcu_unit.sv — VX_tcu_unit system-level testbench (Verilator --timing)
// =============================================================================
// Phase 10: MX9 = standard INT8 (2's complement) + micro_exp via LDMICRO.
// INT path FEDP now outputs FP32:
//   INT8 MAC → INT32 dot → FP32(×2^exp_total) + FP32 C accumulation.
//
// Tests:
//   TC1:                INT8 WMMA basic regression (exp_total=0 → FP32 8.0)
//   TC_hazard:          LDSCALE hazard lock (FP32 expected values)
//   TC_MX9_mexp0:       MX9 WMMA, mexp=0 (identity flatten) → FP32 8.0
//   TC_MX9_mexp_a1:     MX9 WMMA, mexp_a=1 (A×2), mexp_b=0 → FP32 16.0
//   TC_MX9_sat_pos:     MX9 WMMA, A=0x40 (+64), mexp=1 → saturate +127 → FP32 1016.0
//   TC_MX9_sat_neg:     MX9 WMMA, A=0x80 (-128), mexp=1 → saturate -128 → FP32 -1024.0
//   TC_FLAT_identity:   FLAT, mexp=0 → passthrough
//   TC_FLAT_a_double:   FLAT A-tile, mexp_a=2'b11 → ×2
//   TC_FLAT_b_double:   FLAT B-tile, mexp_b=2'b11 → ×2
//   TC_FLAT_mixed_pairs: FLAT A-tile, pair1_mexp=1/pair0_mexp=0 → mixed shift
//   TC_FLAT_sat_pos:    FLAT A-tile, +64 + mexp=1 → overflow_pos → +127
//   TC_FLAT_sat_neg:    FLAT A-tile, -128 + mexp=1 → overflow_neg → -128
//   TC_FLAT_iso_a_notb: FLAT B-tile with mexp_a=11/mexp_b=00 → passthrough (isolation)
//   TC_FLAT_neg_no_sat: FLAT A-tile, INT8=-2 + mexp=1 → -4 (normal neg shift)
// =============================================================================
`timescale 1ns/1ps

`ifndef XLEN
  `define XLEN 32
`endif

`include "VX_define.vh"

module tb_tcu_unit;

    import VX_gpu_pkg::*;
    import VX_tcu_pkg::*;

    localparam N_ISSUES = `ISSUE_WIDTH;

    // =========================================================================
    // Clock & Reset
    // =========================================================================
    logic clk, reset;
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Interfaces
    // =========================================================================
    VX_dispatch_if dispatch_if[N_ISSUES]();
    VX_commit_if   commit_if  [N_ISSUES]();

    // =========================================================================
    // DUT
    // =========================================================================
    VX_tcu_unit #(
        .INSTANCE_ID ("tb_tcu_unit")
    ) dut (
        .clk        (clk),
        .reset      (reset),
        .dispatch_if(dispatch_if),
        .commit_if  (commit_if)
    );

    genvar g;
    generate
        for (g = 0; g < N_ISSUES; g++) begin : g_commit_ready
            assign commit_if[g].ready = 1'b1;
        end
    endgenerate

    // =========================================================================
    // Counters
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;

    // =========================================================================
    // Reference model — Phase 10 INT8 flatten with saturation
    //   OT: flat = saturate_int8(int8_val << mexp)
    //   mexp[0]: pair0 (bytes 0,1), mexp[1]: pair1 (bytes 2,3)
    // =========================================================================
    function automatic logic [7:0] ref_flatten_byte(
        input logic [7:0] b,
        input logic       mexp
    );
        if (!mexp) return b;
        if ((b[7] == 1'b0) && (b[6] == 1'b1)) return 8'h7F;  // +overflow → +127
        if ((b[7] == 1'b1) && (b[6] == 1'b0)) return 8'h80;  // -overflow → -128
        return {b[6:0], 1'b0};  // << 1
    endfunction

    function automatic logic [31:0] ref_flatten_word(
        input logic [31:0] w,
        input logic [1:0]  mexp
    );
        return {ref_flatten_byte(w[31:24], mexp[1]),
                ref_flatten_byte(w[23:16], mexp[1]),
                ref_flatten_byte(w[15:8],  mexp[0]),
                ref_flatten_byte(w[7:0],   mexp[0])};
    endfunction

    // INT32 dot product (on already-flattened operands)
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

    // INT32 × 2^exp_total → FP32 bit pattern
    // Exact for small integer values (|dot| < 2^24) typical of INT8 MACs.
    function automatic logic [31:0] ref_int_ldexp_fp32(
        input logic signed [31:0] v,
        input logic signed [9:0]  exp_total
    );
        logic        sign;
        logic [30:0] abs_v;
        integer      msb;
        integer      biased_exp_i;
        logic [7:0]  biased_exp;
        logic [22:0] mant;

        if (v == '0) return 32'h00000000;
        sign  = v[31];
        abs_v = sign ? 31'(-$signed(v)) : v[30:0];

        // Find MSB position (last-assignment = highest set bit)
        msb = 0;
        for (int k = 0; k <= 30; k++)
            if (abs_v[k]) msb = k;

        biased_exp_i = msb + $signed(exp_total) + 127;
        if (biased_exp_i >= 255) return {sign, 8'hFF, 23'h0};  // overflow → ±Inf
        if (biased_exp_i <= 0)   return {sign, 8'h00, 23'h0};  // underflow → ±0

        biased_exp = biased_exp_i[7:0];
        if (msb == 0)
            mant = 23'h0;
        else if (msb >= 23)
            mant = abs_v[(msb-1) -: 23];
        else
            mant = 23'(abs_v << (23 - msb));

        return {sign, biased_exp, mant};
    endfunction

    // Full FP32 reference (C=0 assumed for all Phase 10 TCs)
    function automatic logic [31:0] ref_d_fp32(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic signed [9:0] exp_total,
        input int i, j, b_off
    );
        logic signed [31:0] d;
        d = ref_dot(rs1, rs2, i, j, b_off);
        return ref_int_ldexp_fp32(d, exp_total);
        // Note: assumes rs3 = 0 (FP32 0.0); all Phase 10 TCs use C=0
    endfunction

    // =========================================================================
    // Helper: replicate word across all SIMD slots
    // =========================================================================
    function automatic logic [`SIMD_WIDTH-1:0][`XLEN-1:0] fill(
        input logic [`XLEN-1:0] w);
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] r;
        for (int i = 0; i < `SIMD_WIDTH; i++) r[i] = w;
        return r;
    endfunction

    // =========================================================================
    // Dispatch helpers
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
        pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1; pkt.rd = '0;
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
        pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1; pkt.rd = '0;
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
`endif // EXT_AG_TCU_ENABLE

    // =========================================================================
    // run_test: plain INT8 WMMA (fmt_s=TCU_I8_ID, micro_ctx mexp defaults to 0)
    // Output: FP32 bit pattern (Phase 10: INT FEDP outputs FP32)
    // =========================================================================
    task automatic run_test(
        input string name,
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [7:0] exp_a, exp_b
    );
        dispatch_t pkt; commit_t res;
        logic signed [9:0] exp_total;
        bit test_pass;

        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;

`ifdef EXT_AG_TCU_ENABLE
        fire_ldscale(exp_a, exp_b);
`endif

        pkt = '0;
        pkt.uuid = UUID_WIDTH'(1); pkt.wis = '0; pkt.sid = '0;
        pkt.tmask = '1; pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.op_type          = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data         = rs1; pkt.rs2_data = rs2; pkt.rs3_data = rs3;
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
`ifdef EXT_AG_TCU_ENABLE
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
`endif
        fire_dispatch(pkt);
        wait_commit(res);

        test_pass = 1;
        for (int i = 0; i < TCU_TC_M; i++)
            for (int j = 0; j < TCU_TC_N; j++) begin
                logic [31:0] got   = res.data[i*TCU_TC_N+j];
                logic [31:0] exp_v = ref_d_fp32(rs1, rs2, rs3, exp_total, i, j, 0);
                if (got !== exp_v) begin
                    $display("[FAIL] %-28s [%0d][%0d] got=0x%08X exp=0x%08X",
                             name, i, j, got, exp_v);
                    test_pass = 0;
                end
            end

        if (test_pass) begin
            $display("[PASS] %-28s all %0d outputs correct", name, TCU_TC_M*TCU_TC_N);
            pass_cnt++;
        end else fail_cnt++;
    endtask

`ifdef EXT_AG_TCU_ENABLE
    // =========================================================================
    // run_test_mx9: MX9 WMMA (fmt_s=TCU_MX9_ID) with LDMICRO + LDSCALE
    //   OT: flatten INT8 using micro_ctx, then patch fmt_s → TCU_I8_ID
    //   exp_d: expected FP32 bit pattern (all TC_M×TC_N outputs must match)
    // =========================================================================
    task automatic run_test_mx9(
        input string name,
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [7:0] scale_a, scale_b,
        input logic [1:0] mexp_a, mexp_b,   // uniform across all threads
        input logic [31:0] exp_d             // expected FP32 result for all outputs
    );
        dispatch_t pkt; commit_t res;
        bit test_pass;

        fire_ldscale(scale_a, scale_b);
        fire_ldmicro(mexp_a, mexp_b);

        pkt = '0;
        pkt.uuid = UUID_WIDTH'(1); pkt.wis = '0; pkt.sid = '0;
        pkt.tmask = '1; pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data           = rs1; pkt.rs2_data = rs2; pkt.rs3_data = rs3;
        pkt.op_args.tcu.fmt_s  = 4'(TCU_MX9_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
        fire_dispatch(pkt);
        wait_commit(res);

        test_pass = 1;
        for (int i = 0; i < TCU_TC_M; i++)
            for (int j = 0; j < TCU_TC_N; j++) begin
                logic [31:0] got = res.data[i*TCU_TC_N+j];
                if (got !== exp_d) begin
                    $display("[FAIL] %-28s [%0d][%0d] got=0x%08X exp=0x%08X",
                             name, i, j, got, exp_d);
                    test_pass = 0;
                end
            end

        if (test_pass) begin
            $display("[PASS] %-28s all %0d outputs = 0x%08X",
                     name, TCU_TC_M*TCU_TC_N, exp_d);
            pass_cnt++;
        end else fail_cnt++;
    endtask
`endif // EXT_AG_TCU_ENABLE

`ifdef EXT_AG_TCU_ENABLE
    // =========================================================================
    // fire_flat: issue one FLAT UOP for a single tile register and wait for commit
    //   tile_type: 0=A tile (uses mexp_a from micro_ctx), 1=B tile (uses mexp_b)
    //   rs1_input: tile register content for all threads (uniform)
    //   result: rd_data (flattened, all threads)
    // =========================================================================
    task automatic fire_flat(
        input logic        tile_type,
        input logic [31:0] rs1_word,   // uniform word for all threads
        output commit_t    res
    );
        dispatch_t pkt;
        pkt = '0;
        pkt.uuid = UUID_WIDTH'(2); pkt.wis = '0; pkt.sid = '0;
        pkt.tmask = '1; pkt.sop = 1'b1; pkt.eop = 1'b1; pkt.wb = 1'b1;
        pkt.rd = NUM_REGS_BITS'(tile_type ? TCU_RB : TCU_RA);
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
    // run_test_flat: LDMICRO → FLAT one register → check output
    // =========================================================================
    task automatic run_test_flat(
        input string       name,
        input logic [1:0]  mexp_a, mexp_b,
        input logic        tile_type,   // 0=A tile, 1=B tile
        input logic [31:0] rs1_word,    // tile register content (uniform)
        input logic [31:0] exp_word     // expected flattened word
    );
        commit_t res;
        fire_ldmicro(mexp_a, mexp_b);
        fire_flat(tile_type, rs1_word, res);

        begin
            bit ok;
            ok = 1;
            for (int t = 0; t < TCU_TC_M * TCU_TC_N; t++) begin
                if (res.data[t] !== exp_word) begin
                    $display("[FAIL] %-28s thread %0d: got=0x%08X exp=0x%08X",
                             name, t, res.data[t], exp_word);
                    ok = 0;
                end
            end
            if (ok) begin
                $display("[PASS] %-28s output=0x%08X", name, exp_word);
                pass_cnt++;
            end else fail_cnt++;
        end
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

        $display("=== tb_tcu_unit: Phase 10 FP32 INT path validation ===");
        $display("  TCU_TC_M=%0d  TCU_TC_N=%0d  TCU_TC_K=%0d",
                 TCU_TC_M, TCU_TC_N, TCU_TC_K);
        $display("------------------------------------------------------------");

        // ====================================================================
        // TC1: INT8 path regression
        //   A=B=0x01010101 (all INT8=1), micro_ctx mexp=0, exp_total=0, C=0
        //   dot = TCU_TC_K × 4 bytes × 1×1 = 8
        //   FP32 output: 8.0 × 2^0 + 0.0 = 8.0 = 0x41000000
        // ====================================================================
        run_test("TC1_int_regression",
            fill(32'h01010101), fill(32'h01010101), fill(32'h00000000),
            8'd127, 8'd127);

`ifdef EXT_AG_TCU_ENABLE
        // ====================================================================
        // TC_hazard: LDSCALE must stall until in-flight INT WMMA commits
        //   WMMA1 (s1, scale=134/134 → exp_total=+14):
        //     dot=8, 8.0 × 2^14 = 131072.0 = 0x48000000
        //   WMMA2 (s2, scale=127/127 → exp_total=0):
        //     dot=8, 8.0 = 0x41000000
        // ====================================================================
        begin : tc_hazard
            dispatch_t wmma_pkt, lds2_pkt;
            commit_t   r_wmma, r_dummy, r_wmma2;
            bit ok;

            fire_ldscale(8'd134, 8'd134);  // s1: exp_total = 134+134-254 = +14

            wmma_pkt = '0;
            wmma_pkt.uuid = UUID_WIDTH'(1); wmma_pkt.wis = '0; wmma_pkt.sid = '0;
            wmma_pkt.tmask = '1; wmma_pkt.sop = 1'b1; wmma_pkt.eop = 1'b1;
            wmma_pkt.wb = 1'b1;
            wmma_pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
            wmma_pkt.rs1_data           = fill(32'h01010101);
            wmma_pkt.rs2_data           = fill(32'h01010101);
            wmma_pkt.rs3_data           = fill(32'h00000000);
            wmma_pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
            wmma_pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
            wmma_pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
            fire_dispatch(wmma_pkt);

            lds2_pkt = '0;
            lds2_pkt.uuid = UUID_WIDTH'('hDEAD); lds2_pkt.wis = '0; lds2_pkt.sid = '0;
            lds2_pkt.tmask = '1; lds2_pkt.sop = 1'b1; lds2_pkt.eop = 1'b1;
            lds2_pkt.wb = 1'b1;
            lds2_pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
            lds2_pkt.rs1_data[0]        = {16'b0, 8'd127, 8'd127};  // s2: exp_total=0
            lds2_pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
            lds2_pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
            lds2_pkt.op_args.tcu.tcu_op = TCU_OP_LDSCALE;
            fire_dispatch(lds2_pkt);

            wait_commit(r_wmma);
            ok = 1;
            for (int i = 0; i < TCU_TC_M; i++)
                for (int j = 0; j < TCU_TC_N; j++)
                    if (r_wmma.data[i*TCU_TC_N+j] !== 32'h48000000) ok = 0;
            if (ok) begin
                $display("[PASS] %-28s WMMA used s1(exp=+14) → 0x48000000 (131072.0)",
                         "TC_hazard_s1");
                pass_cnt++;
            end else begin
                $display("[FAIL] %-28s got=0x%08X exp=0x48000000", "TC_hazard_s1",
                         r_wmma.data[0]);
                fail_cnt++;
            end

            wait_commit(r_dummy);  // drain LDSCALE(s2) commit

            fire_dispatch(wmma_pkt);
            wait_commit(r_wmma2);
            ok = 1;
            for (int i = 0; i < TCU_TC_M; i++)
                for (int j = 0; j < TCU_TC_N; j++)
                    if (r_wmma2.data[i*TCU_TC_N+j] !== 32'h41000000) ok = 0;
            if (ok) begin
                $display("[PASS] %-28s WMMA2 used s2(exp=0) → 0x41000000 (8.0)",
                         "TC_hazard_s2");
                pass_cnt++;
            end else begin
                $display("[FAIL] %-28s got=0x%08X exp=0x41000000", "TC_hazard_s2",
                         r_wmma2.data[0]);
                fail_cnt++;
            end
        end

        // ====================================================================
        // MX9 WMMA tests with LDMICRO (Phase 10)
        //   dot element = Σ_{k,b} flatten(A[k][b], mexp_a) × flatten(B[k][b], mexp_b)
        //   sum = TCU_TC_K=2 words × 4 bytes = 8 elements per output cell
        //
        // TC_MX9_mexp0:
        //   A=B=0x01 (INT8=1), mexp=0 → flat=1, dot=8 → FP32 8.0 = 0x41000000
        //
        // TC_MX9_mexp_a1:
        //   A=0x01 (INT8=1), mexp_a=1 → flat=2; B=0x01, mexp_b=0 → flat=1
        //   dot = 8 × 2×1 = 16 → FP32 16.0 = 0x41800000
        //
        // TC_MX9_sat_pos:
        //   A=0x40 (+64 INT8), mexp_a=1 → bit7=0,bit6=1 → overflow_pos → flat=0x7F (+127)
        //   B=0x01 (INT8=1), mexp_b=0 → flat=1
        //   dot = 8 × 127×1 = 1016 → FP32 1016.0 = 0x447E0000
        //   (1016 = 1.111111 × 2^9: biased_exp=136, mant=0x7E0000)
        //
        // TC_MX9_sat_neg:
        //   A=0x80 (-128 INT8), mexp_a=1 → bit7=1,bit6=0 → overflow_neg → flat=0x80 (-128)
        //   B=0x01, mexp_b=0 → flat=1
        //   dot = 8 × (-128)×1 = -1024 → FP32 -1024.0 = 0xC4800000
        // ====================================================================

        run_test_mx9("TC_MX9_mexp0",
            fill(32'h01010101), fill(32'h01010101), fill(32'h00000000),
            8'd127, 8'd127, 2'b00, 2'b00,
            32'h41000000);  // 8.0

        run_test_mx9("TC_MX9_mexp_a1",
            fill(32'h01010101), fill(32'h01010101), fill(32'h00000000),
            8'd127, 8'd127, 2'b11, 2'b00,
            32'h41800000);  // 16.0

        run_test_mx9("TC_MX9_sat_pos",
            fill(32'h40404040), fill(32'h01010101), fill(32'h00000000),
            8'd127, 8'd127, 2'b11, 2'b00,
            32'h447E0000);  // 1016.0

        run_test_mx9("TC_MX9_sat_neg",
            fill(32'h80808080), fill(32'h01010101), fill(32'h00000000),
            8'd127, 8'd127, 2'b11, 2'b00,
            32'hC4800000);  // -1024.0

        // ====================================================================
        // FLAT instruction tests (Phase B)
        //   FLAT applies micro_exp flatten in-place to one tile register.
        //   Uses the same flatten_int8_word as WMMA INT path.
        //
        // TC_FLAT_identity: mexp=0 → passthrough
        //   input=0x01020304, mexp_a=0 → flat=0x01020304
        //
        // TC_FLAT_a_double: A-tile, mexp_a=2'b11 (both pairs shift 1)
        //   input=0x01010101, flat=0x02020202
        //
        // TC_FLAT_b_double: B-tile, mexp_b=2'b11, mexp_a=0
        //   input=0x01010101, flat=0x02020202
        //
        // TC_FLAT_mixed_pairs: A-tile, mexp_a=2'b10 (pair1=1, pair0=0)
        //   input=0x01020304 → pair0(bytes 0,1): no shift → 0x0304
        //                       pair1(bytes 2,3): ×2 → 0x0204
        //   flat=0x02040304
        //
        // TC_FLAT_sat_pos: A-tile, mexp_a=2'b11, input=0x40404040 (INT8=+64)
        //   +64 << 1 = +128 > +127 → saturate → 0x7F, flat=0x7F7F7F7F
        //
        // TC_FLAT_sat_neg: A-tile, mexp_a=2'b11, input=0x80808080 (INT8=-128)
        //   -128 << 1 = -256 < -128 → saturate → 0x80, flat=0x80808080
        // ====================================================================
        run_test_flat("TC_FLAT_identity",
            2'b00, 2'b00, 1'b0, 32'h01020304, 32'h01020304);

        run_test_flat("TC_FLAT_a_double",
            2'b11, 2'b00, 1'b0, 32'h01010101, 32'h02020202);

        run_test_flat("TC_FLAT_b_double",
            2'b00, 2'b11, 1'b1, 32'h01010101, 32'h02020202);

        run_test_flat("TC_FLAT_mixed_pairs",
            2'b10, 2'b00, 1'b0, 32'h01020304, 32'h02040304);

        run_test_flat("TC_FLAT_sat_pos",
            2'b11, 2'b00, 1'b0, 32'h40404040, 32'h7F7F7F7F);

        run_test_flat("TC_FLAT_sat_neg",
            2'b11, 2'b00, 1'b0, 32'h80808080, 32'h80808080);

        // TC_FLAT_iso_a_notb: mexp_a=2'b11이지만 B-tile FLAT → mexp_b=2'b00이므로 passthrough
        //   mexp_a 오염 여부 검증: tile_type=1이면 mexp_b만 참조해야 함
        run_test_flat("TC_FLAT_iso_a_notb",
            2'b11, 2'b00, 1'b1, 32'h01020304, 32'h01020304);

        // TC_FLAT_neg_no_sat: 음수 shift, overflow 없는 정상 경로
        //   INT8=-2 (0xFE=11111110), mexp=1 → -2<<1 = -4 (0xFC=11111100), 포화 없음
        //   bit7=1, bit6=1 → {b[6:0], 1'b0} = {1111110, 0} = 0xFC
        run_test_flat("TC_FLAT_neg_no_sat",
            2'b11, 2'b00, 1'b0, 32'hFEFEFEFE, 32'hFCFCFCFC);

`endif // EXT_AG_TCU_ENABLE

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
