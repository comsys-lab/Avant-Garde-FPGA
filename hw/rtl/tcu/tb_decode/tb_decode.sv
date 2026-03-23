// Level 8 Testbench: VX_decode standalone
//
// DUT: VX_decode only.
// TB drives fetch_if (raw 32-bit instructions) and samples decode_if.data
// combinationally at the handshake posedge. No VX_issue/execute/commit.
//
// Phase 10 TC:
//   TC1: WMMA decode fields   — fmt_d=FP32(Phase10), tcu_op=WMMA, used_rs=111
//   TC2: LDSCALE decode fields — tcu_op=LDSCALE, wb=1, used_rs=001
//   TC3: LDMICRO decode fields — tcu_op=LDMICRO=3'b011, wb=0, used_rs=011 [Phase10]
//   TC4: ALU ADD decode        — ex_type=EX_ALU (format-agnostic sanity check)

`include "VX_define.vh"
`timescale 1ns/1ps

import VX_gpu_pkg::*;
import VX_tcu_pkg::*;

module tb_decode;

    // =========================================================================
    // Clock / reset
    // =========================================================================
    logic clk = 0;
    logic reset;
    always #5 clk = ~clk;

    // =========================================================================
    // TCU opcode (custom-0)
    // =========================================================================
    localparam logic [6:0] TCU_OPCODE = 7'h0B;

    // =========================================================================
    // Interfaces
    // =========================================================================
    VX_fetch_if        fetch_if();
    VX_decode_sched_if decode_sched_if();  // VX_decode drives internally, TB ignores
    VX_decode_if       decode_if();        // VX_decode output → TB samples directly

    // TB always accepts decode output (no ibuffer backpressure)
    assign decode_if.ready = 1'b1;

    // =========================================================================
    // DUT: VX_decode only
    // =========================================================================
    VX_decode #(.INSTANCE_ID("tb_decode_d")) decode_dut (
        .clk             (clk),
        .reset           (reset),
        .fetch_if        (fetch_if),
        .decode_if       (decode_if),
        .decode_sched_if (decode_sched_if)
    );

    // =========================================================================
    // Pass/fail counters and UUID
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;
    logic [UUID_WIDTH-1:0] next_uuid = UUID_WIDTH'(1);

    // =========================================================================
    // Instruction encoding helpers
    // =========================================================================
    // WMMA: funct7=7'h02, funct3=0, opcode=TCU_OPCODE
    //   fmt_d in rd[3:0], fmt_s in rs1[3:0]
    function automatic logic [31:0] encode_wmma(
        input logic [3:0] fmt_d, fmt_s);
        return {7'h02, 5'h0, {1'b0, fmt_s}, 3'h0, {1'b0, fmt_d}, TCU_OPCODE};
    endfunction

    // LDSCALE: funct7=7'h06 (funct7[2:0]=3'b110), rd=x1 → wb=1
    function automatic logic [31:0] encode_ldscale(input logic [4:0] scale_rs1);
        return {7'h06, 5'h0, scale_rs1, 3'h0, 5'h1, TCU_OPCODE};
    endfunction

    // LDMICRO: funct7=7'h04 (funct7[2:0]=3'b100), rs2=x7, rs1=x6, rd=x0 → wb=0
    function automatic logic [31:0] encode_ldmicro();
        return {7'h04, 5'd7, 5'd6, 3'h0, 5'h0, TCU_OPCODE};
    endfunction

    // ADDI rd, rs1, imm12 (RV32I ALU)
    function automatic logic [31:0] encode_addi(
        input logic [4:0] rd, rs1, input logic [11:0] imm);
        return {imm, rs1, 3'b000, rd, 7'h13};
    endfunction

    // =========================================================================
    // send_fetch_sample: drive fetch_if, capture decode_if.data at handshake
    // =========================================================================
    task automatic send_fetch_sample(
        input  logic [31:0] instr,
        output decode_t     sampled
    );
        @(posedge clk); #1;
        fetch_if.valid      = 1'b1;
        fetch_if.data.uuid  = next_uuid++;
        fetch_if.data.wid   = '0;
        fetch_if.data.tmask = '1;
        fetch_if.data.PC    = '0;
        fetch_if.data.instr = instr;
        @(posedge clk);
        while (!fetch_if.ready) @(posedge clk);
        // VX_elastic_buffer(SIZE=0) is combinational: decode_if.data valid here
        sampled = decode_if.data;
        #1;
        fetch_if.valid = 1'b0;
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin
        reset          = 1'b1;
        fetch_if.valid = 1'b0;
        fetch_if.data  = '0;
        repeat(4) @(posedge clk);
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;

        $display("=== Level 8: VX_decode standalone ===");
        $display("  TCU_FP32_ID=%0d  TCU_I8_ID=%0d  TCU_MX9_ID=%0d",
                 TCU_FP32_ID, TCU_I8_ID, TCU_MX9_ID);
        $display("  TCU_OPCODE=0x%02h  WMMA funct7=0x02  LDSCALE funct7=0x06  LDMICRO funct7=0x04",
                 TCU_OPCODE);
        $display("------------------------------------------------------------");

        // ==================================================================
        // TC1: WMMA decode fields
        //   Encoded: fmt_d=TCU_FP32_ID, fmt_s=TCU_I8_ID
        //   Expected: ex_type=EX_TCU, tcu_op=WMMA, used_rs=111, fmt correct
        // ==================================================================
        begin : tc1
            decode_t sampled;
            bit      ok = 1;
            logic [3:0] fmt_d = 4'(TCU_FP32_ID);  // Phase 10: INT FEDP outputs FP32
            logic [3:0] fmt_s = 4'(TCU_I8_ID);

            send_fetch_sample(encode_wmma(fmt_d, fmt_s), sampled);

            if (sampled.ex_type !== EX_BITS'(EX_TCU)) begin
                $display("[FAIL] TC1_wmma  ex_type=0x%0h (exp EX_TCU=0x%0h)",
                         sampled.ex_type, EX_BITS'(EX_TCU));
                ok = 0;
            end
            if (sampled.op_type !== INST_OP_BITS'(INST_TCU_WMMA)) begin
                $display("[FAIL] TC1_wmma  op_type=0x%0h (exp INST_TCU_WMMA)",
                         sampled.op_type);
                ok = 0;
            end
`ifdef EXT_AG_TCU_ENABLE
            if (sampled.op_args.tcu.tcu_op !== TCU_OP_WMMA) begin
                $display("[FAIL] TC1_wmma  tcu_op=0x%0h (exp TCU_OP_WMMA=0x%0h)",
                         sampled.op_args.tcu.tcu_op, TCU_OP_WMMA);
                ok = 0;
            end
`endif
            if (sampled.op_args.tcu.fmt_s !== fmt_s) begin
                $display("[FAIL] TC1_wmma  fmt_s=0x%0h (exp 0x%0h)",
                         sampled.op_args.tcu.fmt_s, fmt_s);
                ok = 0;
            end
            if (sampled.op_args.tcu.fmt_d !== fmt_d) begin
                $display("[FAIL] TC1_wmma  fmt_d=0x%0h (exp 0x%0h = TCU_FP32_ID)",
                         sampled.op_args.tcu.fmt_d, fmt_d);
                ok = 0;
            end
            if (sampled.used_rs !== 3'b111) begin
                $display("[FAIL] TC1_wmma  used_rs=%03b (exp 111: rs1+rs2+rs3 all used)",
                         sampled.used_rs);
                ok = 0;
            end
            if (!sampled.wb) begin
                $display("[FAIL] TC1_wmma  wb=0 (exp 1)");
                ok = 0;
            end

            if (ok) begin
                $display("[PASS] TC1_wmma_decode_fields      ex_type/tcu_op/fmt_d(FP32)/used_rs correct");
                pass_cnt++;
            end else fail_cnt++;
        end

        // ==================================================================
        // TC2: LDSCALE decode fields
        //   Expected: ex_type=EX_TCU, tcu_op=LDSCALE, wb=1, used_rs=001
        // ==================================================================
        begin : tc2
            decode_t sampled;
            bit      ok = 1;

            send_fetch_sample(encode_ldscale(5'd5), sampled);

            if (sampled.ex_type !== EX_BITS'(EX_TCU)) begin
                $display("[FAIL] TC2_ldscale  ex_type mismatch");
                ok = 0;
            end
`ifdef EXT_AG_TCU_ENABLE
            if (sampled.op_args.tcu.tcu_op !== TCU_OP_LDSCALE) begin
                $display("[FAIL] TC2_ldscale  tcu_op=0x%0h (exp TCU_OP_LDSCALE)",
                         sampled.op_args.tcu.tcu_op);
                ok = 0;
            end
`endif
            if (!sampled.wb) begin
                $display("[FAIL] TC2_ldscale  wb=0 (exp 1, rd=x1)");
                ok = 0;
            end
            if (!sampled.used_rs[0] || sampled.used_rs[1] || sampled.used_rs[2]) begin
                $display("[FAIL] TC2_ldscale  used_rs=%03b (exp 001: rs1 only)",
                         sampled.used_rs);
                ok = 0;
            end

            if (ok) begin
                $display("[PASS] TC2_ldscale_decode_fields   tcu_op=LDSCALE, wb=1, used_rs=001");
                pass_cnt++;
            end else fail_cnt++;
        end

        // ==================================================================
        // TC3: LDMICRO decode fields  [Phase 10 new]
        //   funct7=7'h04 → tcu_op=3'b011=LDMICRO, rd=x0 → wb=0, used_rs=011
        // ==================================================================
        begin : tc3
            decode_t sampled;
            bit      ok = 1;

            send_fetch_sample(encode_ldmicro(), sampled);

            if (sampled.ex_type !== EX_BITS'(EX_TCU)) begin
                $display("[FAIL] TC3_ldmicro  ex_type mismatch");
                ok = 0;
            end
`ifdef EXT_AG_TCU_ENABLE
            if (sampled.op_args.tcu.tcu_op !== TCU_OP_LDMICRO) begin
                $display("[FAIL] TC3_ldmicro  tcu_op=0x%0h (exp TCU_OP_LDMICRO=3'b011)",
                         sampled.op_args.tcu.tcu_op);
                ok = 0;
            end
`endif
            if (sampled.wb !== 1'b0) begin
                $display("[FAIL] TC3_ldmicro  wb=%0b (exp 0: no GPR writeback)", sampled.wb);
                ok = 0;
            end
            if (!sampled.used_rs[0] || !sampled.used_rs[1]) begin
                $display("[FAIL] TC3_ldmicro  used_rs[1:0]=%02b (exp 11: rs1+rs2 used)",
                         sampled.used_rs[1:0]);
                ok = 0;
            end
            if (sampled.used_rs[2]) begin
                $display("[FAIL] TC3_ldmicro  used_rs[2]=1 (exp 0: rs3 unused)");
                ok = 0;
            end

            if (ok) begin
                $display("[PASS] TC3_ldmicro_decode_fields   tcu_op=LDMICRO, wb=0, used_rs=011");
                pass_cnt++;
            end else fail_cnt++;
        end

        // ==================================================================
        // TC4: ALU ADD decode (format-agnostic sanity check)
        //   ADDI x1, x0, 42 → ex_type must be EX_ALU (not EX_TCU)
        // ==================================================================
        begin : tc4
            decode_t sampled;
            bit      ok = 1;

            send_fetch_sample(encode_addi(5'd1, 5'd0, 12'd42), sampled);

            if (sampled.ex_type !== EX_BITS'(EX_ALU)) begin
                $display("[FAIL] TC4_alu_add  ex_type=0x%0h (exp EX_ALU=0x%0h)",
                         sampled.ex_type, EX_BITS'(EX_ALU));
                ok = 0;
            end

            if (ok) begin
                $display("[PASS] TC4_alu_add_decode          ex_type=EX_ALU correct");
                pass_cnt++;
            end else fail_cnt++;
        end

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
