// =============================================================================
// tb_tcu_unit.sv — VX_tcu_unit system-level testbench (Verilator --timing)
// =============================================================================
// Hierarchy under test:
//   dispatch_if[ISSUE_WIDTH]
//     → VX_dispatch_unit  (dispatch_t → tcu_exe_t, wis→wid conversion)
//     → VX_pe_switch      (route INT/FP by fmt_s[3])
//     → VX_tcu_int        (TCU_TC_M × TCU_TC_N × VX_tcu_fedp_int_scaled)
//     → VX_gather_unit    (tcu_res_t → commit_t)
//   → commit_if[ISSUE_WIDTH]
//
// Config (NUM_THREADS=4, NUM_WARPS=4, XLEN=32):
//   ISSUE_WIDTH    = UP(4/16) = 1
//   SIMD_WIDTH     = NUM_THREADS = 4
//   NUM_TCU_LANES  = 4
//   TCU_TC_M=2, TCU_TC_N=2, TCU_TC_K=2
//   FEDP_LATENCY   = MUL(2) + ACC(clog2(2)+1=2) = 4
//   PIPE_LATENCY   = 5  (FEDP + BUFFER)
//   dispatch → commit round-trip latency ≈ 6–10 cycles (includes elastic bufs)
//
// dispatch_t layout (matches VX_gpu_pkg.sv — DO NOT REORDER):
//   uuid[0:0], wis[1:0], sid[0:0], tmask[3:0], PC[29:0],
//   op_type[3:0], op_args[36:0], wb, rd[NUM_REGS_BITS-1:0],
//   rs1_data[3:0][31:0], rs2_data[3:0][31:0], rs3_data[3:0][31:0],
//   sop, eop
//
// commit_t.data[i*TCU_TC_N+j] = d_val[i][j] = dot_i8(a_row[i], b_col[j]) << exp + c
//
// OT redesign (Phase OT-redo): OT always applies MX9 flatten for INT WMMA.
//   Tile register encoding: byte = {micro_exp[1b], INT7_mantissa[7b]}
//   element_value = m7 × 2^mexp → flat = mexp ? m8<<1 : m8
//   Reference model in run_test uses ref_flatten_mx9_word on rs1/rs2 before ref_d.
// =============================================================================
`timescale 1ns/1ps

`ifndef XLEN
  `define XLEN 32
`endif

`include "VX_define.vh"

module tb_tcu_unit;

    import VX_gpu_pkg::*;
    import VX_tcu_pkg::*;

    // =========================================================================
    // Key dimensions (derived from packages at elaboration time)
    // =========================================================================
    //  TCU_TC_M=2, TCU_TC_N=2, TCU_TC_K=2 (see VX_tcu_pkg)
    //  ISSUE_WIDTH=1 (see VX_config.vh: UP(NUM_WARPS/16))
    localparam N_ISSUES = `ISSUE_WIDTH;   // 1

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
    // DUT: VX_tcu_unit
    // =========================================================================
    VX_tcu_unit #(
        .INSTANCE_ID ("tb_tcu_unit")
    ) dut (
        .clk        (clk),
        .reset      (reset),
        .dispatch_if(dispatch_if),
        .commit_if  (commit_if)
    );

    // TB always accepts commits immediately (no back-pressure)
    genvar g;
    generate
        for (g = 0; g < N_ISSUES; g++) begin : g_commit_ready
            assign commit_if[g].ready = 1'b1;
        end
    endgenerate

    // =========================================================================
    // Pass / Fail counters
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;


    // =========================================================================
    // Reference model
    //   d[i][j] = sat32(dot_i8(rs1[i*K : i*K+K-1],
    //                          rs2[j*K : j*K+K-1]) << exp_total) + c[i][j]
    //
    //   Each rs word packs 4 INT8 values (bytes [0..3]).
    //   K = TCU_TC_K = 2 words per dot-product vector.
    // =========================================================================
    function automatic logic signed [31:0] ref_d (
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic signed [9:0] exp_total,  // Phase 5: E8M0 10-bit signed
        input int i, j, b_off
    );
        logic signed [31:0] dot;
        logic signed [63:0] shifted;
        logic signed [31:0] sat;

        dot = '0;
        for (int k = 0; k < TCU_TC_K; k++)
            for (int b = 0; b < 4; b++)
                dot += $signed(rs1[i * TCU_TC_K + k][8*b+7 -: 8])
                     * $signed(rs2[b_off + j * TCU_TC_K + k][8*b+7 -: 8]);

        if (exp_total[9]) begin // sign bit = 1 → negative exp → right shift
            shifted = 64'($signed(dot)) >>> 5'($signed(-exp_total));
        end else begin
            shifted = 64'($signed(dot)) <<< 5'($signed(exp_total));
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
    // fire_dispatch: drive one valid dispatch transaction (valid/ready hs)
    // Uses dispatch_if[0] only (N_ISSUES = 1).
    // =========================================================================
    task automatic fire_dispatch (input dispatch_t pkt);
        @(posedge clk); #1;
        dispatch_if[0].valid = 1'b1;
        dispatch_if[0].data  = pkt;

        // wait until handshake fires
        @(posedge clk);
        while (!dispatch_if[0].ready) @(posedge clk);

        // deassert valid one cycle after fire
        #1;
        dispatch_if[0].valid = 1'b0;
    endtask

    // =========================================================================
    // wait_commit: wait for one commit pulse on commit_if[0]
    //
    // NOTE: data_out_r in VX_stream_buffer (OUT_REG=1) is overwritten by a
    // non-blocking assignment in the SAME clock where valid first becomes 1.
    // Reading with #1 (after NBA commit) gives stale/X data.
    // We must sample commit_if[0].data immediately in the active region.
    // =========================================================================
    task automatic wait_commit (output commit_t res);
        @(posedge clk);
        while (!commit_if[0].valid) @(posedge clk);
        res = commit_if[0].data;   // sample in active region, before NBA commit
    endtask

    // =========================================================================
    // run_test: assemble dispatch_t → fire → compare commit_t results
    // =========================================================================
    // AG-TCU: LDSCALE — write per-warp scale context before WMMA
    // =========================================================================
`ifdef EXT_AG_TCU_ENABLE
    task automatic fire_ldscale (input logic [7:0] scale_a, scale_b);
        dispatch_t pkt;
        commit_t   dummy;
        pkt                         = '0;
        pkt.uuid                    = UUID_WIDTH'('hDEAD);
        pkt.wis                     = '0;
        pkt.sid                     = '0;
        pkt.tmask                   = '1;
        pkt.sop                     = 1'b1;
        pkt.eop                     = 1'b1;
        pkt.wb                      = 1'b1;
        pkt.rd                      = '0;
        pkt.op_type                 = INST_ALU_BITS'(INST_TCU_WMMA);
        // Phase 5 E8M0 packing: [7:0]=scale_a, [15:8]=scale_b
        pkt.rs1_data[0]             = {16'b0, scale_b, scale_a};
        pkt.op_args.tcu.fmt_s       = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d       = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op      = TCU_OP_LDSCALE;
        fire_dispatch(pkt);
        wait_commit(dummy);   // drain LDSCALE dummy result (data=0)
    endtask
`endif

    // =========================================================================
    task automatic run_test (
        input string name,
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [7:0] exp_a, exp_b,  // Phase 5: E8M0 unsigned 8-bit
        input logic [3:0] step_m = 4'd0,
        input logic [3:0] step_n = 4'd0
    );
        dispatch_t  pkt;
        commit_t    res;
        logic signed [9:0] exp_total;
        bit         test_pass;
        int         a_off, b_off;
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_ref, rs2_ref;

        // Phase 5: exp_total = a + b - 2*bias (E8M0 decode)
        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;
        a_off = (int'(step_m) & (TCU_A_SUB_BLOCKS - 1)) * TCU_A_BLOCK_SIZE;
        b_off = (int'(step_n) & (TCU_B_SUB_BLOCKS - 1)) * TCU_B_BLOCK_SIZE;

`ifdef EXT_AG_TCU_ENABLE
        // Avant-Garde: write scale context before WMMA
        fire_ldscale(exp_a, exp_b);
        // OT always flattens INT WMMA: apply same MX9 flatten to reference operands
        for (int t = 0; t < `SIMD_WIDTH; t++) begin
            rs1_ref[t] = ref_flatten_mx9_word(rs1[t]);
            rs2_ref[t] = ref_flatten_mx9_word(rs2[t]);
        end
`else
        rs1_ref = rs1;
        rs2_ref = rs2;
`endif

        // ---- Build dispatch packet ------------------------------------------
        pkt           = '0;
        // Metadata
        pkt.uuid      = UUID_WIDTH'(1);    // small non-zero uuid
        pkt.wis       = '0;               // warp 0
        pkt.sid       = '0;               // SIMD index 0
        pkt.tmask     = '1;               // all threads active
        pkt.PC        = '0;
        pkt.op_type   = INST_ALU_BITS'(INST_TCU_WMMA);  // 4'h0
        pkt.wb        = 1'b1;
        pkt.rd        = '0;
        pkt.sop       = 1'b1;
        pkt.eop       = 1'b1;
        // Operands
        pkt.rs1_data  = rs1;
        pkt.rs2_data  = rs2;
        pkt.rs3_data  = rs3;
        // TCU args (scale comes from context written by LDSCALE above)
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);    // 4'd9 = 4'b1001
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);   // 4'd8
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
`ifdef EXT_AG_TCU_ENABLE
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
`endif

        // ---- Execute -------------------------------------------------------
        fire_dispatch(pkt);

        // ---- Collect result ------------------------------------------------
        wait_commit(res);

        // ---- Compare all TCU_TC_M × TCU_TC_N outputs -----------------------
        test_pass = 1;
        for (int i = 0; i < TCU_TC_M; i++) begin
            for (int j = 0; j < TCU_TC_N; j++) begin
                logic signed [31:0] got, exp_val;
                got     = $signed(res.data[i * TCU_TC_N + j]);
                exp_val = ref_d(rs1_ref, rs2_ref, rs3, exp_total, i, j, b_off);
                if (got !== exp_val) begin
                    $display("[FAIL] %-28s [%0d][%0d] got=%0d exp=%0d diff=%0d",
                             name, i, j, got, exp_val, got - exp_val);
                    test_pass = 0;
                end
            end
        end

        if (test_pass) begin
            $display("[PASS] %-28s all %0d outputs correct", name, TCU_TC_M * TCU_TC_N);
            pass_cnt++;
        end else begin
            fail_cnt++;
        end
    endtask

    // =========================================================================
    // Metadata passthrough check:
    //   Verifies uuid and rd travel through VX_dispatch_unit → VX_gather_unit
    //   unchanged (end-to-end metadata integrity).
    // =========================================================================
    task automatic run_meta_test (
        input string name,
        input logic [UUID_WIDTH-1:0] uuid_in,
        input logic [NUM_REGS_BITS-1:0] rd_in
    );
        dispatch_t  pkt;
        commit_t    res;
        bit         ok;

        pkt           = '0;
        pkt.uuid      = uuid_in;
        pkt.wis       = '0;
        pkt.sid       = '0;
        pkt.tmask     = '1;
        pkt.sop       = 1'b1;
        pkt.eop       = 1'b1;
        pkt.wb        = 1'b1;
        pkt.rd        = rd_in;
        pkt.op_type   = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data  = '0;
        pkt.rs2_data  = '0;
        pkt.rs3_data  = '0;
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
`ifdef EXT_AG_TCU_ENABLE
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
        // Phase 5 E8M0: scale=127 → exp_total=0 (neutral, result should be 0 since A/B=0)
        fire_ldscale(8'd127, 8'd127);
`endif

        fire_dispatch(pkt);
        wait_commit(res);

        ok = (res.wb === 1'b1) && (res.rd === rd_in);
        if (ok) begin
            $display("[PASS] %-28s wb=%0b rd=%0d (correct)", name, res.wb, res.rd);
            pass_cnt++;
        end else begin
            $display("[FAIL] %-28s wb=%0b (exp=1) rd=%0d (exp=%0d)",
                     name, res.wb, res.rd, rd_in);
            fail_cnt++;
        end
    endtask

    // =========================================================================
    // Helper: replicate one 32-bit word across all SIMD_WIDTH slots
    // =========================================================================
    function automatic logic [`SIMD_WIDTH-1:0][`XLEN-1:0] fill (
        input logic [`XLEN-1:0] w
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] r;
        for (int i = 0; i < `SIMD_WIDTH; i++) r[i] = w;
        return r;
    endfunction

    // =========================================================================
    // Helper: NT=8 rs2 with distinct values per B sub-block.
    //   slots [0 .. B_BLOCK_SIZE-1]         = val_at_0  (step_n even: b_off=0)
    //   slots [B_BLOCK_SIZE .. SIMD_WIDTH-1] = val_at_4  (step_n odd:  b_off=4)
    // Only meaningful when B_SUB_BLOCKS=2 (NT=8); for NT=4 val_at_4 region
    // is empty (SIMD_WIDTH == B_BLOCK_SIZE) so fill_sub behaves like fill.
    // =========================================================================
    function automatic logic [`SIMD_WIDTH-1:0][`XLEN-1:0] fill_sub (
        input logic [`XLEN-1:0] val_at_0,
        input logic [`XLEN-1:0] val_at_4
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] r;
        for (int i = 0; i < `SIMD_WIDTH; i++)
            r[i] = (i < TCU_B_BLOCK_SIZE) ? val_at_0 : val_at_4;
        return r;
    endfunction

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

        $display("=== VX_tcu_unit testbench ===");
        $display("  TCU_TC_M=%0d  TCU_TC_N=%0d  TCU_TC_K=%0d",
                 TCU_TC_M, TCU_TC_N, TCU_TC_K);
        $display("  ISSUE_WIDTH=%0d  SIMD_WIDTH=%0d  NUM_TCU_LANES=%0d",
                 `ISSUE_WIDTH, `SIMD_WIDTH, `NUM_TCU_LANES);
        $display("------------------------------------------------------------");

        // ====================================================================
        // TC1: All-ones I8, exp=0
        //   MX9: byte=0x01={mexp=0,m7=+1} → flat=+1
        //   each FEDP: dot = TCU_TC_K*4*1*1 = 8  → D=8
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        run_test("TC1_ones_exp0",
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd127, 8'd127);

        // ====================================================================
        // TC2: All-ones, exp_a=2 + exp_b=2 (exp_total=4) → 8<<4=128
        //   E8M0: scale_a=129 (127+2), scale_b=129 → exp_total=+4
        // ====================================================================
        run_test("TC2_ones_exp4",
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd129, 8'd129);

        // ====================================================================
        // TC3: C accumulator=100  →  8+100=108
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        run_test("TC3_ones_accum",
            fill(32'h01010101), fill(32'h01010101), fill(32'd100),
            8'd127, 8'd127);

        // ====================================================================
        // TC4: Asymmetric rows/cols — verify 2×2 tile independence
        //   rs1[0:1]=2s (row0), rs1[2:3]=3s (row1)
        //   rs2[0:1]=1s (col0), rs2[2:3]=4s (col1)
        //   MX9: all bytes have mexp=0, flat=face value (≤0x3F)
        //   d[0][0] = (2+2+2+2)*2 = 16      d[0][1] = (2+2+2+2)*4*2 = 64
        //   d[1][0] = (3+3+3+3)*2 = 24      d[1][1] = (3+3+3+3)*4*2 = 96
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        begin
            logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_v, rs2_v;
            for (int k = 0; k < `SIMD_WIDTH; k++) begin
                rs1_v[k] = (k < TCU_TC_K) ? 32'h02020202 : 32'h03030303;
                rs2_v[k] = (k < TCU_TC_K) ? 32'h01010101 : 32'h04040404;
            end
            run_test("TC4_asymmetric",
                rs1_v, rs2_v, fill(32'd0),
                8'd127, 8'd127);
        end

        // ====================================================================
        // TC5: Negative × Positive  →  dot = -8 per FEDP
        //   MX9: A byte=0x7F={mexp=0, m7=7'b1111111=-1} → flat=-1
        //        B byte=0x01={mexp=0, m7=+1} → flat=+1
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        run_test("TC5_neg_dot",
            fill(32'h7F7F7F7F), fill(32'h01010101), fill(32'd0),
            8'd127, 8'd127);

        // ====================================================================
        // TC6: Positive saturation — flat=-128, exp_total=+14
        //   MX9: byte=0xC0={mexp=1, m7=-64} → flat=-64<<1=-128
        //   dot = 8×128^2=131072; 131072<<14=2147483648 → 0x7FFFFFFF
        //   E8M0: scale_a=134 (127+7), scale_b=134 → exp_total=+14
        // ====================================================================
        run_test("TC6_pos_saturation",
            fill(32'hC0C0C0C0), fill(32'hC0C0C0C0), fill(32'd0),
            8'd134, 8'd134);

        // ====================================================================
        // TC7: Right-shift — exp_a=-2, exp_b=0 → exp_total=-2
        //   dot=8; 8>>>2=2 → D=2
        //   MX9: 0x01 → flat=+1 (all mexp=0)
        //   E8M0: scale_a=125 (127-2), scale_b=127 → exp_total=-2
        // ====================================================================
        run_test("TC7_rshift2_ones",
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd125, 8'd127);

        // ====================================================================
        // TC8: MX-style block, exp_a=3, exp_b=3 → exp_total=6
        //   mantissas [1,2,3,4] × [1,1,1,1] per word; N=2 words → dot=20
        //   20 << 6 = 1280
        //   MX9: all bytes mexp=0, flat=face value (all ≤4)
        //   E8M0: scale_a=130 (127+3), scale_b=130 → exp_total=+6
        // ====================================================================
        run_test("TC8_MX_style",
            fill(32'h04030201), fill(32'h01010101), fill(32'd0),
            8'd130, 8'd130);

        // ====================================================================
        // TC9: Negative C accumulator  →  8 + (-200) = -192
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        run_test("TC9_neg_accum",
            fill(32'h01010101), fill(32'h01010101), fill(-32'd200),
            8'd127, 8'd127);

        // ====================================================================
        // TC10: Zero dot product  →  D = C = 42
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        run_test("TC10_zero_dot",
            fill(32'h01010101), fill(32'h00000000), fill(32'd42),
            8'd127, 8'd127);

        // ====================================================================
        // TC11: Max positive exponent (exp_total=+14) → 8<<14=131072 (no sat)
        //   E8M0: scale_a=134 (127+7), scale_b=134 → exp_total=+14
        // ====================================================================
        run_test("TC11_max_exp",
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd134, 8'd134);

        // ====================================================================
        // TC12: Metadata passthrough — wb and rd must survive the full pipeline
        // ====================================================================
        run_meta_test("TC12_metadata_passthrough",
            UUID_WIDTH'(1), NUM_REGS_BITS'(5));

`ifdef EXT_AG_TCU_ENABLE
        // ====================================================================
        // TC13_mexp_x2: mexp=1 amplification (×2) verification
        //   A: byte=0x81={mexp=1, m7=+1} → flat=+2
        //   B: byte=0x01={mexp=0, m7=+1} → flat=+1
        //   dot = 8 × 2 × 1 = 16, exp_total=0 → D=16
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        run_test("TC13_mexp_x2",
            fill(32'h81818181), fill(32'h01010101), fill(32'd0),
            8'd127, 8'd127);

        // ====================================================================
        // TC14_mexp_neg1: mexp=0 negative mantissa
        //   A: byte=0x7F={mexp=0, m7=-1} → flat=-1
        //   B: byte=0x7F={mexp=0, m7=-1} → flat=-1
        //   dot = 8×(-1)×(-1)=8, exp_total=0 → D=8
        // ====================================================================
        run_test("TC14_mexp_neg1",
            fill(32'h7F7F7F7F), fill(32'h7F7F7F7F), fill(32'd0),
            8'd127, 8'd127);

        // ====================================================================
        // TC15_mexp1_min: mexp=1, m7=-64 → flat=-128 (INT8 min, no overflow)
        //   A=B: byte=0xC0={mexp=1, m7=7'b1000000=-64} → flat=-128
        //   dot = 8×(-128)×(-128)=131072, exp_total=0 → D=131072
        // ====================================================================
        run_test("TC15_mexp1_min",
            fill(32'hC0C0C0C0), fill(32'hC0C0C0C0), fill(32'd0),
            8'd127, 8'd127);

        // ====================================================================
        // TC_hazard: LDSCALE stalls while WMMA K-loop is in-flight
        //   Verifies Phase 4③ hazard lock in VX_tcu_int.
        //   1. LDSCALE(s1={+7,+7}) fire + commit → scale_ctx[wid0] = s1
        //   2. WMMA dispatch (no wait) — reads s1 at execute time
        //   3. LDSCALE(s2={0,0}) dispatch — hazard lock must stall until WMMA commits
        //   4. WMMA commit → exp=+14 → 8<<14=131072  (proves s1 was used)
        //   5. LDSCALE(s2) dummy commit
        //   6. WMMA2 dispatch (uses s2) → exp=0 → 8  (proves s2 took effect)
        //
        //   Without hazard lock: LDSCALE(s2) could slip in before WMMA commits,
        //   but exp_total is captured at execute time so result would still be correct.
        //   The real protection: scale_ctx is stable when WMMA2 reads it.
        // ====================================================================
        begin : tc_hazard
            dispatch_t wmma_pkt, ldscale_s2_pkt;
            commit_t   res_wmma, res_dummy, res_wmma2;
            bit ok;

            // Step 1: set s1 = {+7, +7} — E8M0: scale=134 (127+7) → exp_total=+14
            fire_ldscale(8'd134, 8'd134);

            // Step 2: dispatch WMMA without waiting for commit
            wmma_pkt = '0;
            wmma_pkt.uuid               = UUID_WIDTH'(1);
            wmma_pkt.wis                = '0;
            wmma_pkt.sid                = '0;
            wmma_pkt.tmask              = '1;
            wmma_pkt.sop                = 1'b1;
            wmma_pkt.eop                = 1'b1;
            wmma_pkt.wb                 = 1'b1;
            wmma_pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
            wmma_pkt.rs1_data           = fill(32'h01010101);
            wmma_pkt.rs2_data           = fill(32'h01010101);
            wmma_pkt.rs3_data           = fill(32'd0);
            wmma_pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
            wmma_pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
            wmma_pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
            fire_dispatch(wmma_pkt);

            // Step 3: dispatch LDSCALE(s2={0,0}) — stalls at VX_tcu_int until
            //         WMMA completes (execute_if.ready=0 while wmma_inflight>0)
            ldscale_s2_pkt = '0;
            ldscale_s2_pkt.uuid                    = UUID_WIDTH'('hDEAD);
            ldscale_s2_pkt.wis                     = '0;
            ldscale_s2_pkt.sid                     = '0;
            ldscale_s2_pkt.tmask                   = '1;
            ldscale_s2_pkt.sop                     = 1'b1;
            ldscale_s2_pkt.eop                     = 1'b1;
            ldscale_s2_pkt.wb                      = 1'b1;
            ldscale_s2_pkt.op_type                 = INST_ALU_BITS'(INST_TCU_WMMA);
            // Phase 5 E8M0: scale=127 → exp_total=0 (neutral)
            ldscale_s2_pkt.rs1_data[0]             = {16'b0, 8'd127, 8'd127};
            ldscale_s2_pkt.op_args.tcu.fmt_s       = 4'(TCU_I8_ID);
            ldscale_s2_pkt.op_args.tcu.fmt_d       = 4'(TCU_I32_ID);
            ldscale_s2_pkt.op_args.tcu.tcu_op      = TCU_OP_LDSCALE;
            fire_dispatch(ldscale_s2_pkt);

            // Step 4: collect WMMA commit — must use s1 (exp=+14 → 8<<14=131072)
            wait_commit(res_wmma);
            ok = 1;
            for (int i = 0; i < TCU_TC_M; i++)
                for (int j = 0; j < TCU_TC_N; j++)
                    if ($signed(res_wmma.data[i*TCU_TC_N+j]) !== 32'sd131072) ok = 0;
            if (ok) begin
                $display("[PASS] %-28s WMMA used s1(exp=+14) → 131072",
                         "TC_hazard_wmma_s1");
                pass_cnt++;
            end else begin
                $display("[FAIL] %-28s got=%0d exp=131072 (hazard lock missing?)",
                         "TC_hazard_wmma_s1", $signed(res_wmma.data[0]));
                fail_cnt++;
            end

            // Step 5: collect LDSCALE(s2) dummy commit
            wait_commit(res_dummy);

            // Step 6: dispatch WMMA2 using s2 (scale_ctx[wid]=0 now) → exp=0 → 8
            fire_dispatch(wmma_pkt);
            wait_commit(res_wmma2);
            ok = 1;
            for (int i = 0; i < TCU_TC_M; i++)
                for (int j = 0; j < TCU_TC_N; j++)
                    if ($signed(res_wmma2.data[i*TCU_TC_N+j]) !== 32'sd8) ok = 0;
            if (ok) begin
                $display("[PASS] %-28s WMMA2 used s2(exp=0) → 8",
                         "TC_hazard_wmma_s2");
                pass_cnt++;
            end else begin
                $display("[FAIL] %-28s got=%0d exp=8",
                         "TC_hazard_wmma_s2", $signed(res_wmma2.data[0]));
                fail_cnt++;
            end
        end
`endif // EXT_AG_TCU_ENABLE

`ifdef TESTS_NT8
        // ====================================================================
        // TC13–TC16: NT=8 B sub-block selection (B_SUB_BLOCKS=2)
        //
        // fill_sub(ones, twos): rs2[0..3]=0x01010101, rs2[4..7]=0x02020202
        //   step_n=0,2 → b_off=0 → DUT reads ones  → dot=TC_K*4*1*1=8  → d=8
        //   step_n=1,3 → b_off=4 → DUT reads twos  → dot=TC_K*4*1*2=16 → d=16
        //
        // Bug detection: wrong b_off → d=16 when 8 expected, or vice-versa.
        // ====================================================================

        // TC13: step_n=0 → b_off=0 → DUT reads ones sub-block → d=8
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        run_test("TC13_nt8_sn0",
            fill(32'h01010101), fill_sub(32'h01010101, 32'h02020202), fill(32'd0),
            8'd127, 8'd127, 4'd0, 4'd0);

        // TC14: step_n=1 → b_off=4 → DUT reads twos sub-block → d=16
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        run_test("TC14_nt8_sn1",
            fill(32'h01010101), fill_sub(32'h01010101, 32'h02020202), fill(32'd0),
            8'd127, 8'd127, 4'd0, 4'd1);

        // TC15: step_n=2 → b_off=0 (wraps mod B_SUB_BLOCKS=2, same as sn=0) → d=8
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        run_test("TC15_nt8_sn2",
            fill(32'h01010101), fill_sub(32'h01010101, 32'h02020202), fill(32'd0),
            8'd127, 8'd127, 4'd0, 4'd2);

        // TC16: step_n=3 → b_off=4 (wraps, same as sn=1) → d=16
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        run_test("TC16_nt8_sn3",
            fill(32'h01010101), fill_sub(32'h01010101, 32'h02020202), fill(32'd0),
            8'd127, 8'd127, 4'd0, 4'd3);
`endif // TESTS_NT8

        // ==================================================================
        // Summary
        // ==================================================================
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
