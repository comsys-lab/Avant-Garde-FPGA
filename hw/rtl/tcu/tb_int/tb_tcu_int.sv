// =============================================================================
// tb_tcu_int.sv — VX_tcu_int integration testbench (Verilator --timing)
// =============================================================================
// Tests VX_tcu_int which wraps multiple VX_tcu_fedp_int_scaled instances.
//
// With default config (NUM_THREADS=4, XLEN=32):
//   TCU_BLOCK_CAP = NUM_THREADS = 4
//   TCU_TC_M=2, TCU_TC_N=2, TCU_TC_K=2
//   FEDP_LATENCY = MUL(2) + ACC($clog2(2)+1=2) = 4
//   PIPE_LATENCY = FEDP_LATENCY + BUFFER(1) = 5
//
// Each execute fires 4 FEDP units (i,j in [0..1]×[0..1]) simultaneously.
// rs1_data[0:1] → a_row[i=0], rs1_data[2:3] → a_row[i=1]
// rs2_data[0:1] → b_col[j=0], rs2_data[2:3] → b_col[j=1]
// rs3_data[i*TCU_TC_N+j] → c_val[i][j]
// result.data[i*TCU_TC_N+j] → d_val[i][j]
// =============================================================================
`timescale 1ns/1ps

`ifndef XLEN
  `define XLEN 32
`endif

`include "VX_define.vh"

module tb_tcu_int;

    import VX_gpu_pkg::*;
    import VX_tcu_pkg::*;

    // =========================================================================
    // Dimensions — computed from VX_tcu_pkg (same as hardware)
    // =========================================================================
    // TCU_TC_M=2, TCU_TC_N=2, TCU_TC_K=2, NUM_TCU_LANES=4
    localparam PIPE_LATENCY = 5;   // MUL(2)+ACC(clog2(2)+1=2)+BUFFER(1)

    // =========================================================================
    // Clock & Reset
    // =========================================================================
    logic clk, reset;
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Interfaces
    // =========================================================================
    VX_execute_if #(.data_t(tcu_exe_t)) execute_if();
    VX_result_if  #(.data_t(tcu_res_t)) result_if();

    // Phase 7: feedback wires from VX_tcu_int (unused in this TB — no OT present)
    wire ot_fedp_enable_unused;
    wire ot_result_fire_unused;
    wire [NW_WIDTH-1:0] ot_result_wid_unused;

    // =========================================================================
    // DUT
    // =========================================================================
    VX_tcu_int #(
        .INSTANCE_ID ("tb_tcu_int")
    ) dut (
        .clk            (clk),
        .reset          (reset),
        .execute_if     (execute_if),
        .result_if      (result_if),
`ifdef EXT_AG_TCU_ENABLE
        .ot_fedp_enable (ot_fedp_enable_unused),
        .ot_result_fire (ot_result_fire_unused),
        .ot_result_wid  (ot_result_wid_unused)
`endif
    );

    // TB always accepts results immediately (no backpressure)
    assign result_if.ready = 1'b1;

    // =========================================================================
    // Pass / Fail counters
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;

    // =========================================================================
    // Reference model
    // Computes d[i][j] = saturate32(dot_i8(rs1[i*K:], rs2[j*K:]) << exp) + c
    // where K = TCU_TC_K, each rs word packs 4×INT8.
    // Phase 5: exp_total is signed 10-bit (E8M0).
    // =========================================================================
    function automatic logic signed [31:0] ref_d (
        input logic [`NUM_TCU_LANES-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic signed [9:0] exp_total,
        input int i, j
    );
        logic signed [31:0] dot;
        logic signed [61:0] shifted;
        logic signed [31:0] sat;
        int ai, bi;

        dot = '0;
        for (int k = 0; k < TCU_TC_K; k++) begin
            ai = i * TCU_TC_K + k;
            bi = j * TCU_TC_K + k;
            for (int b = 0; b < 4; b++)
                dot += $signed(rs1[ai][8*b+7 -: 8]) * $signed(rs2[bi][8*b+7 -: 8]);
        end

        if (exp_total[9]) begin // sign bit = 1 → negative exp → right shift
            shifted = 62'($signed(dot)) >>> 5'($signed(-exp_total));
        end else begin
            shifted = 62'($signed(dot)) <<< 5'($signed(exp_total));
        end
        if      (shifted > 62'(32'sh7FFF_FFFF)) sat = 32'h7FFF_FFFF;
        else if (shifted < 62'(32'sh8000_0000)) sat = 32'h8000_0000;
        else                                    sat = shifted[31:0];

        return sat + $signed(rs3[i * TCU_TC_N + j]);
    endfunction

    // =========================================================================
    // Drive one execute transaction (valid/ready handshake)
    // =========================================================================
    task automatic fire_execute (input tcu_exe_t exe_data);
        // Apply valid + data, then wait for ready at posedge
        @(posedge clk); #1;
        execute_if.valid = 1'b1;
        execute_if.data  = exe_data;

        // Spin until execute fires (ready=1 while valid=1)
        // Under normal load, ready is 1 on the first cycle
        @(posedge clk);
        while (!execute_if.ready) @(posedge clk);

        // Fire happened — deassert valid one cycle later
        #1;
        execute_if.valid = 1'b0;
    endtask

    // =========================================================================
    // Wait for one result (result_if.valid pulse)
    // =========================================================================
    task automatic wait_result (output tcu_res_t res);
        while (!result_if.valid) @(posedge clk);
        #1;
        res = result_if.data;
    endtask

    // =========================================================================
    // AG-TCU: LDSCALE — write scale_a/scale_b to warp-context before WMMA
    // =========================================================================
`ifdef EXT_AG_TCU_ENABLE
    task automatic fire_ldscale (input logic [7:0] scale_a, scale_b);
        tcu_exe_t pkt;
        tcu_res_t dummy;
        pkt                         = '0;
        pkt.uuid                    = 44'hDEAD;
        pkt.wid                     = '0;
        pkt.tmask                   = '1;
        pkt.op_type                 = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.wb                      = 1'b1;
        pkt.rd                      = '0;   // write to r0 (no-op)
        pkt.sop                     = 1'b1;
        pkt.eop                     = 1'b1;
        // Phase 5 E8M0 packing: rs1_data[0][7:0]=scale_a, [15:8]=scale_b
        pkt.rs1_data[0]             = {16'b0, scale_b, scale_a};
        pkt.op_args.tcu.fmt_s       = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d       = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op      = TCU_OP_LDSCALE;
        fire_execute(pkt);
        // Consume the LDSCALE dummy result so the queue doesn't back up
        wait_result(dummy);
    endtask
`endif

    // =========================================================================
    // Full run_test: build packet → execute → compare
    // =========================================================================
    task automatic run_test (
        input string name,
        input logic [`NUM_TCU_LANES-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [7:0] exp_a, exp_b  // Phase 5: E8M0 unsigned 8-bit
    );
        tcu_exe_t exe_data;
        tcu_res_t res;
        logic signed [9:0] exp_total;
        bit test_pass;

        // Phase 5: exp_total = a + b - 2*bias (E8M0 decode)
        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;

        // Phase 7: tb_int directly drives VX_tcu_int (no OT present in this TB).
        // exp_total is written to execute_if.data.op_args.tcu.exp_total directly.
        // LDSCALE + scale_ctx path is bypassed (scale_ctx does not exist here).

        // ---- Build execute packet ----------------------------------------
        exe_data           = '0;
        exe_data.uuid      = 44'd1;
        exe_data.wid       = '0;
        exe_data.tmask     = '1;           // All lanes active
        exe_data.PC        = '0;
        exe_data.op_type   = INST_ALU_BITS'(INST_TCU_WMMA);  // 4'h0
        exe_data.wb        = 1'b1;
        exe_data.rd        = '0;
        exe_data.rs1_data  = rs1;
        exe_data.rs2_data  = rs2;
        exe_data.rs3_data  = rs3;
        exe_data.pid       = '0;
        exe_data.sop       = 1'b1;
        exe_data.eop       = 1'b1;

        // TCU args
        exe_data.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);   // 4'd9 → INT path, I8
        exe_data.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);  // 4'd8
        exe_data.op_args.tcu.step_m = 4'd0;
        exe_data.op_args.tcu.step_n = 4'd0;
`ifdef EXT_AG_TCU_ENABLE
        exe_data.op_args.tcu.tcu_op   = TCU_OP_WMMA;
        // Phase 7: exp_total written directly into payload (OT output field)
        exe_data.op_args.tcu.exp_total = exp_total;
`endif

        // ---- Execute -------------------------------------------------------
        fire_execute(exe_data);

        // ---- Wait for result -----------------------------------------------
        wait_result(res);

        // ---- Compare -------------------------------------------------------
        test_pass = 1;
        for (int i = 0; i < TCU_TC_M; i++) begin
            for (int j = 0; j < TCU_TC_N; j++) begin
                logic signed [31:0] got, exp_val;
                got     = $signed(res.data[i * TCU_TC_N + j]);
                exp_val = ref_d(rs1, rs2, rs3, exp_total, i, j);
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
    // Helper — replicate one 32-bit word to all NUM_TCU_LANES slots
    // =========================================================================
    function automatic logic [`NUM_TCU_LANES-1:0][`XLEN-1:0] fill (
        input logic [`XLEN-1:0] w
    );
        logic [`NUM_TCU_LANES-1:0][`XLEN-1:0] r;
        for (int i = 0; i < `NUM_TCU_LANES; i++) r[i] = w;
        return r;
    endfunction

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin
        // ---- Reset ----------------------------------------------------------
        reset         = 1'b1;
        execute_if.valid = 1'b0;
        execute_if.data  = '0;
        repeat(4) @(posedge clk);
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;

        $display("=== VX_tcu_int testbench ===");
        $display("  TCU_TC_M=%0d  TCU_TC_N=%0d  TCU_TC_K=%0d", TCU_TC_M, TCU_TC_N, TCU_TC_K);
        $display("  NUM_TCU_LANES=%0d  PIPE_LATENCY=%0d", `NUM_TCU_LANES, PIPE_LATENCY);
        $display("------------------------------------------------------------");

        // ====================================================================
        // TC1: All-ones I8, exp=0  →  each FEDP: N*4*1*1 = 8
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        run_test("TC1_ones_exp0",
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd127, 8'd127);

        // ====================================================================
        // TC2: All-ones, exp_a=2 + exp_b=2 → 8 << 4 = 128
        //   E8M0: scale_a=129 (127+2), scale_b=129 → exp_total=+4
        // ====================================================================
        run_test("TC2_ones_exp4",
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd129, 8'd129);

        // ====================================================================
        // TC3: All-ones, C accumulator=100  →  8+100=108
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        run_test("TC3_ones_accum",
            fill(32'h01010101), fill(32'h01010101), fill(32'd100),
            8'd127, 8'd127);

        // ====================================================================
        // TC4: Asymmetric rows/cols
        //   rs1[0:1]=2s (row0), rs1[2:3]=3s (row1)
        //   rs2[0:1]=1s (col0), rs2[2:3]=4s (col1)
        //   d[0][0]=16, d[0][1]=64, d[1][0]=24, d[1][1]=96
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        begin
            logic [`NUM_TCU_LANES-1:0][`XLEN-1:0] rs1_v, rs2_v;
            for (int k = 0; k < `NUM_TCU_LANES; k++) begin
                rs1_v[k] = (k < TCU_TC_K) ? 32'h02020202 : 32'h03030303;
                rs2_v[k] = (k < TCU_TC_K) ? 32'h01010101 : 32'h04040404;
            end
            run_test("TC4_asymmetric",
                rs1_v, rs2_v, fill(32'd0),
                8'd127, 8'd127);
        end

        // ====================================================================
        // TC5: Negative × Positive, exp=0
        //   rs1=all 0xFF (-1 as I8), rs2=all 0x01 (+1)  →  dot = -8 per FEDP
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        run_test("TC5_neg_dot",
            fill(32'hFFFFFFFF), fill(32'h01010101), fill(32'd0),
            8'd127, 8'd127);

        // ====================================================================
        // TC6: Positive saturation — (-128)×(-128), exp_total=+14
        //   dot = 8 × 128^2 = 131072; 131072 << 14 = 2147483648 → 0x7FFFFFFF
        //   E8M0: scale_a=134 (127+7), scale_b=134 → exp_total=+14
        // ====================================================================
        run_test("TC6_pos_saturation",
            fill(32'h80808080), fill(32'h80808080), fill(32'd0),
            8'd134, 8'd134);

        // ====================================================================
        // TC7: Right-shift (negative exp) — exp_a=-4, exp_b=0 → exp_total=-4
        //   dot = 8; 8 >>> 4 = 0 → D=0
        //   E8M0: scale_a=123 (127-4), scale_b=127 → exp_total=-4
        // ====================================================================
        run_test("TC7_rshift4_ones",
            fill(32'h01010101), fill(32'h01010101), fill(32'd0),
            8'd123, 8'd127);

        // ====================================================================
        // TC8: MX-style block, exp_a=3, exp_b=3 (exp_total=6)
        //   row-0 mantissas: [1,2,3,4], col-0 mantissas: [1,1,1,1]
        //   dot per FEDP (N=2 words × 4 bytes):
        //     i=0,j=0: (1+2+3+4)*2 = 20  →  20<<6=1280
        //   E8M0: scale_a=130 (127+3), scale_b=130 → exp_total=+6
        // ====================================================================
        run_test("TC8_MX_style_block",
            fill(32'h04030201), fill(32'h01010101), fill(32'd0),
            8'd130, 8'd130);

        // ====================================================================
        // TC9: C accumulator with negative C
        //   all-ones dot=8, C=-200  →  8+(-200)=-192
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        run_test("TC9_neg_accum",
            fill(32'h01010101), fill(32'h01010101), fill(-32'd200),
            8'd127, 8'd127);

        // ====================================================================
        // TC10: Zero dot product (multiply by zero)
        //   E8M0: scale_a=127, scale_b=127 → exp_total=0
        // ====================================================================
        run_test("TC10_zero_dot",
            fill(32'h01010101), fill(32'h00000000), fill(32'd42),
            8'd127, 8'd127);

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
