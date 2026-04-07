// =============================================================================
// tb_tcu_demo.sv — AG-TCU Waveform Demonstration Testbench
// =============================================================================
// 교수님 waveform 검증용 데모 테스트벤치.
//
// 3개 시나리오를 순차 실행하며 TCU 파이프라인 동작을 시각적으로 확인한다.
//
// ─── 시나리오 요약 ───────────────────────────────────────────────────────────
//  demo_phase=1 | INT8     | A=B=0x01010101, exp_total=0   → result=16.0
//  demo_phase=2 | MXINT8   | A=B=0x01010101, exp_total=+1  → result=32.0
//  demo_phase=3 | 3LEVEL   | A=0x02020101, pair0_shift=1,  → result=288.0
//               |           |   pair1_shift=2                (KEY: OT transform)
//
// ─── 핵심 관측 포인트 (Waveform 기준) ─────────────────────────────────────
//  1. demo_phase          — 현재 시나리오 번호 (1/2/3)
//  2. dispatch_if.valid   — TCU로 보내는 명령어 (LDSCALE/LDMICRO/WMMA)
//  3. dispatch_if.data.rs1_data[0]    — OT 입력 A operand (raw)
//  4. dut/.../ot_execute_if.rs1_data[0]  — OT 출력 A operand (flattened, 1cy 뒤)
//  5. dut/.../ot_execute_if.fmt_s        — 3LEVEL(3)→INT8(9)로 OT가 패치
//  6. commit_if.data.data[0]          — 최종 FP32 결과
//
// ─── Waveform 사용법 ──────────────────────────────────────────────────────
//  cd hw/rtl/tcu/tb_wmma/vivado
//  make gui-demo
//  Vivado GUI에서 "Demo Signals" 그룹부터 확인
// =============================================================================
`timescale 1ns/1ps

`ifndef XLEN
  `define XLEN 32
`endif

`include "VX_define.vh"

module tb_tcu_demo;

    import VX_gpu_pkg::*;
    import VX_tcu_pkg::*;

    localparam LG_N = $clog2(TCU_N_STEPS);
    localparam LG_M = $clog2(TCU_M_STEPS);

    // =========================================================================
    // Clock & Reset
    // =========================================================================
    logic clk, reset;
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Demo phase marker — visible in waveform
    //   1 = INT8 (baseline, no scaling)
    //   2 = MXINT8 (global scale ×2)
    //   3 = 3LEVEL (hierarchical pair shift, OT transform visible)
    // =========================================================================
    int  demo_phase;   // 현재 시나리오 번호
    int  pass_cnt, fail_cnt;

    // =========================================================================
    // Interfaces & DUT
    // =========================================================================
    VX_dispatch_if dispatch_if[1]();
    VX_commit_if   commit_if  [1]();

    VX_tcu_unit #(.INSTANCE_ID("demo")) dut (
        .clk(clk), .reset(reset),
        .dispatch_if(dispatch_if), .commit_if(commit_if)
    );

    genvar g;
    generate
        for (g = 0; g < 1; g++) begin : g_commit_ready
            assign commit_if[g].ready = 1'b1;
        end
    endgenerate

    // =========================================================================
    // Waveform probe signals — byte-level breakdown for easy inspection
    // =========================================================================

    // ── Dispatch input: A operand byte breakdown (thread 0, word 0) ──────────
    // pair0 = bytes [1:0], pair1 = bytes [3:2]
    wire [7:0] disp_a_b0 = dispatch_if[0].data.rs1_data[0][ 7: 0]; // pair0, byte0
    wire [7:0] disp_a_b1 = dispatch_if[0].data.rs1_data[0][15: 8]; // pair0, byte1
    wire [7:0] disp_a_b2 = dispatch_if[0].data.rs1_data[0][23:16]; // pair1, byte0
    wire [7:0] disp_a_b3 = dispatch_if[0].data.rs1_data[0][31:24]; // pair1, byte1
    // B operand
    wire [7:0] disp_b_b0 = dispatch_if[0].data.rs2_data[0][ 7: 0];
    wire [7:0] disp_b_b1 = dispatch_if[0].data.rs2_data[0][15: 8];
    wire [7:0] disp_b_b2 = dispatch_if[0].data.rs2_data[0][23:16];
    wire [7:0] disp_b_b3 = dispatch_if[0].data.rs2_data[0][31:24];
    // tcu_op / fmt_s shortcuts
    wire [2:0] disp_tcu_op = dispatch_if[0].data.op_args.tcu.tcu_op;
    wire [3:0] disp_fmt_s  = dispatch_if[0].data.op_args.tcu.fmt_s;

    // ── OT output: A operand after Operand Transformer (1 cycle later) ───────
    // fmt_s: 3LEVEL(3) → I8(9) patched by OT; bytes show flatten result
`ifdef EXT_AG_TCU_ENABLE
    wire        ot_valid  = dut.g_blocks[0].ot_execute_if.valid;
    wire [3:0]  ot_fmt_s  = dut.g_blocks[0].ot_execute_if.data.op_args.tcu.fmt_s;
    wire [2:0]  ot_tcu_op = dut.g_blocks[0].ot_execute_if.data.op_args.tcu.tcu_op;
    wire [31:0] ot_a_word = dut.g_blocks[0].ot_execute_if.data.rs1_data[0];
    wire [31:0] ot_b_word = dut.g_blocks[0].ot_execute_if.data.rs2_data[0];
    // OT output byte breakdown — compare with disp_a_bX above
    wire [7:0]  ot_a_b0   = ot_a_word[ 7: 0]; // pair0: expect sat(disp_a_b0 << shift)
    wire [7:0]  ot_a_b1   = ot_a_word[15: 8]; // pair0
    wire [7:0]  ot_a_b2   = ot_a_word[23:16]; // pair1: different shift than pair0
    wire [7:0]  ot_a_b3   = ot_a_word[31:24]; // pair1
    wire [7:0]  ot_b_b0   = ot_b_word[ 7: 0];
    wire [7:0]  ot_b_b1   = ot_b_word[15: 8];
    wire [7:0]  ot_b_b2   = ot_b_word[23:16];
    wire [7:0]  ot_b_b3   = ot_b_word[31:24];
    // PE path selector: 0=FP, 1=INT
    wire        pe_sel    = dut.g_blocks[0].pe_sel_w;
`endif

    // ── Commit result: all 4 output elements ─────────────────────────────────
    // TC_M=2, TC_N=2 → 4 output positions per UOP
    wire [31:0] result_0 = commit_if[0].data.data[0]; // D[0][0]
    wire [31:0] result_1 = commit_if[0].data.data[1]; // D[0][1]
    wire [31:0] result_2 = commit_if[0].data.data[2]; // D[1][0]
    wire [31:0] result_3 = commit_if[0].data.data[3]; // D[1][1]

    // =========================================================================
    // Reference model utilities
    // =========================================================================
    function automatic real ref_pow2(input int e);
        real r; r = 1.0;
        if (e >= 0) begin for (int i=0; i<e;  i++) r *= 2.0; end
        else        begin for (int i=0; i<-e; i++) r /= 2.0; end
        return r;
    endfunction

    function automatic real ref_fp32_to_real(input logic [31:0] fp32);
        logic s; logic [7:0] exp; logic [22:0] mant; real val;
        s = fp32[31]; exp = fp32[30:23]; mant = fp32[22:0];
        if (exp == 8'h00 || exp == 8'hFF) return 0.0;
        val = (1.0 + real'({9'b0,mant}) / 8388608.0) * ref_pow2(int'(exp) - 127);
        return s ? -val : val;
    endfunction

    function automatic logic [31:0] ref_real_to_fp32(input real r);
        logic sign; real abs_r; integer exp_u; real sig;
        logic [7:0] biased_exp; logic [22:0] mant;
        if (r == 0.0) return 32'h00000000;
        sign = (r < 0.0) ? 1'b1 : 1'b0;
        abs_r = sign ? -r : r;
        exp_u = 0; sig = abs_r;
        while (sig >= 2.0) begin sig /= 2.0; exp_u++; end
        while (sig < 1.0)  begin sig *= 2.0; exp_u--; end
        if (exp_u + 127 >= 255) return {sign, 8'hFF, 23'h0};
        if (exp_u + 127 <= 0)   return {sign, 8'h00, 23'h0};
        biased_exp = 8'(exp_u + 127);
        mant = 23'(integer'((sig - 1.0) * 8388608.0));
        return {sign, biased_exp, mant};
    endfunction

    // INT8 dot product (raw bytes, no scale transform)
    function automatic logic signed [31:0] ref_dot(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2,
        input int i, j, b_off
    );
        logic signed [31:0] d; logic signed [7:0] a8, b8;
        d = '0;
        for (int k=0; k<TCU_TC_K; k++)
            for (int b=0; b<4; b++) begin
                a8 = $signed(rs1[i*TCU_TC_K+k][b*8+:8]);
                b8 = $signed(rs2[b_off+j*TCU_TC_K+k][b*8+:8]);
                d += a8 * b8;
            end
        return d;
    endfunction

    // FP32 reference: dot(A,B) × 2^exp_total + C
    function automatic logic [31:0] ref_d_fp32(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic signed [9:0] exp_total,
        input int i, j, b_off
    );
        logic signed [31:0] d; real fp_d, c_r, result_r;
        d        = ref_dot(rs1, rs2, i, j, b_off);
        fp_d     = real'($signed(d)) * ref_pow2(int'($signed(exp_total)));
        c_r      = ref_fp32_to_real(rs3[i*TCU_TC_N+j]);
        result_r = fp_d + c_r;
        return ref_real_to_fp32(result_r);
    endfunction

    // 3LEVEL flatten: saturate_int8(byte << shift), shift ∈ {0,1,2}
    function automatic logic signed [7:0] ref_3level_flatten_byte(
        input logic [7:0] b8, input logic [1:0] shift
    );
        logic [10:0] wide, shifted; logic [3:0] upper;
        if (shift == 2'b00) return signed'(b8);
        wide    = {{3{b8[7]}}, b8};
        shifted = wide << shift;
        upper   = shifted[10:7];
        if ((&upper) | (~|upper)) return signed'(shifted[7:0]);
        return b8[7] ? 8'sh80 : 8'sh7F;
    endfunction

    // 3LEVEL dot product: flatten then INT8 MAC
    function automatic logic [31:0] ref_d_fp32_3level(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic signed [9:0] exp_total,
        input logic [1:0] p0a, p1a, p0b, p1b,
        input int i, j, b_off
    );
        logic signed [31:0] d; real fp_d, c_r, result_r;
        logic [1:0] sha, shb;
        d = '0;
        for (int k=0; k<TCU_TC_K; k++)
            for (int b=0; b<4; b++) begin
                sha = (b >= 2) ? p1a : p0a;
                shb = (b >= 2) ? p1b : p0b;
                d += ref_3level_flatten_byte(rs1[i*TCU_TC_K+k][b*8+:8], sha)
                   * ref_3level_flatten_byte(rs2[b_off+j*TCU_TC_K+k][b*8+:8], shb);
            end
        fp_d     = real'($signed(d)) * ref_pow2(int'($signed(exp_total)));
        c_r      = ref_fp32_to_real(rs3[i*TCU_TC_N+j]);
        result_r = fp_d + c_r;
        return ref_real_to_fp32(result_r);
    endfunction

    // =========================================================================
    // Dispatch / Commit helpers
    // =========================================================================
    task automatic fire_dispatch(input dispatch_t pkt);
        @(posedge clk); #1;
        dispatch_if[0].valid = 1'b1;
        dispatch_if[0].data  = pkt;
        @(posedge clk);
        while (dispatch_if[0].ready !== 1'b1) @(posedge clk);
        #1;
        dispatch_if[0].valid = 1'b0;
    endtask

    task automatic wait_commit(output commit_t res);
        @(posedge clk);
        while (commit_if[0].valid !== 1'b1) @(posedge clk);
        res = commit_if[0].data;
    endtask

`ifdef EXT_AG_TCU_ENABLE
    task automatic fire_ldscale(input logic [7:0] scale_a, scale_b);
        dispatch_t pkt; commit_t dummy;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'('hAA);
        pkt.wis='0; pkt.sid='0; pkt.tmask='1;
        pkt.sop=1'b1; pkt.eop=1'b1; pkt.wb=1'b1;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data[0]        = {scale_b, scale_b, scale_a, scale_a};
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_LDSCALE;
        fire_dispatch(pkt);
        wait_commit(dummy);
    endtask

    task automatic fire_ldmicro_3level(
        input logic [1:0] p0a, p1a, p0b, p1b
    );
        dispatch_t pkt; commit_t dummy;
        pkt                    = '0;
        pkt.uuid               = UUID_WIDTH'('hBB);
        pkt.wis='0; pkt.sid='0; pkt.tmask='1;
        pkt.sop=1'b1; pkt.eop=1'b1; pkt.wb=1'b1;
        pkt.op_type            = INST_ALU_BITS'(INST_TCU_WMMA);
        for (int t=0; t<`SIMD_WIDTH; t++) begin
            pkt.rs1_data[t] = {28'b0, p1a, p0a};
            pkt.rs2_data[t] = {28'b0, p1b, p0b};
        end
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_I32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_LDMICRO;
        fire_dispatch(pkt);
        wait_commit(dummy);
    endtask
`endif

    // =========================================================================
    // Build dispatch packets
    // =========================================================================
    function automatic dispatch_t build_int8(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [3:0] step_m, step_n
    );
        dispatch_t pkt;
        pkt='0; pkt.uuid=UUID_WIDTH'(1);
        pkt.wis='0; pkt.sid='0; pkt.tmask='1;
        pkt.sop=1'b1; pkt.eop=1'b1; pkt.wb=1'b1;
        pkt.op_type = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data=rs1; pkt.rs2_data=rs2; pkt.rs3_data=rs3;
        pkt.op_args.tcu.fmt_s  = 4'(TCU_I8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
`ifdef EXT_AG_TCU_ENABLE
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
`endif
        return pkt;
    endfunction

    function automatic dispatch_t build_mxint8(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [3:0] step_m, step_n
    );
        dispatch_t pkt;
        pkt='0; pkt.uuid=UUID_WIDTH'(1);
        pkt.wis='0; pkt.sid='0; pkt.tmask='1;
        pkt.sop=1'b1; pkt.eop=1'b1; pkt.wb=1'b1;
        pkt.op_type = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data=rs1; pkt.rs2_data=rs2; pkt.rs3_data=rs3;
        pkt.op_args.tcu.fmt_s  = 4'(TCU_MXINT8_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
`ifdef EXT_AG_TCU_ENABLE
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
`endif
        return pkt;
    endfunction

`ifdef EXT_AG_TCU_ENABLE
    function automatic dispatch_t build_3level(
        input logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1, rs2, rs3,
        input logic [3:0] step_m, step_n
    );
        dispatch_t pkt;
        pkt='0; pkt.uuid=UUID_WIDTH'(1);
        pkt.wis='0; pkt.sid='0; pkt.tmask='1;
        pkt.sop=1'b1; pkt.eop=1'b1; pkt.wb=1'b1;
        pkt.op_type = INST_ALU_BITS'(INST_TCU_WMMA);
        pkt.rs1_data=rs1; pkt.rs2_data=rs2; pkt.rs3_data=rs3;
        pkt.op_args.tcu.fmt_s  = 4'(TCU_3LEVEL_ID);
        pkt.op_args.tcu.fmt_d  = 4'(TCU_FP32_ID);
        pkt.op_args.tcu.tcu_op = TCU_OP_WMMA;
        pkt.op_args.tcu.step_m = step_m;
        pkt.op_args.tcu.step_n = step_n;
        return pkt;
    endfunction
`endif

    // =========================================================================
    // Tile matrices
    // =========================================================================
    logic [TCU_M_STEPS-1:0][TCU_K_STEPS-1:0]
          [TCU_TC_M-1:0][TCU_TC_K-1:0][`XLEN-1:0] A_mat;
    logic [TCU_K_STEPS-1:0][TCU_N_STEPS-1:0]
          [TCU_TC_N-1:0][TCU_TC_K-1:0][`XLEN-1:0] B_mat;
    logic [TCU_M_STEPS-1:0][TCU_N_STEPS-1:0]
          [TCU_TC_M-1:0][TCU_TC_N-1:0][`XLEN-1:0] D_mat;

    task automatic fill_A(input logic [`XLEN-1:0] w);
        for (int sm=0; sm<TCU_M_STEPS; sm++)
            for (int sk=0; sk<TCU_K_STEPS; sk++)
                for (int ii=0; ii<TCU_TC_M; ii++)
                    for (int kk=0; kk<TCU_TC_K; kk++) A_mat[sm][sk][ii][kk] = w;
    endtask
    task automatic fill_B(input logic [`XLEN-1:0] w);
        for (int sk=0; sk<TCU_K_STEPS; sk++)
            for (int sn=0; sn<TCU_N_STEPS; sn++)
                for (int jj=0; jj<TCU_TC_N; jj++)
                    for (int kk=0; kk<TCU_TC_K; kk++) B_mat[sk][sn][jj][kk] = w;
    endtask
    task automatic fill_D(input logic [`XLEN-1:0] w);
        for (int sm=0; sm<TCU_M_STEPS; sm++)
            for (int sn=0; sn<TCU_N_STEPS; sn++)
                for (int ii=0; ii<TCU_TC_M; ii++)
                    for (int jj=0; jj<TCU_TC_N; jj++) D_mat[sm][sn][ii][jj] = w;
    endtask

    // =========================================================================
    // run_scenario_int8: WMMA over full UOPS, INT8 or MXINT8 format
    // =========================================================================
    task automatic run_scenario_int8(
        input string name,
        input bit use_mxint8,
        input logic [7:0] exp_a, exp_b
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_in, rs2_in, rs3_in;
        dispatch_t pkt; commit_t res;
        logic signed [9:0] exp_total;
        bit ok; ok = 1;
        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;

`ifdef EXT_AG_TCU_ENABLE
        fire_ldscale(exp_a, exp_b);
`endif

        for (int ctr=0; ctr<TCU_UOPS; ctr++) begin
            int n, m, sm, sn, sk, a_off, b_off;
            n     = (LG_N>0) ? (ctr & ((1<<LG_N)-1))           : 0;
            m     = (LG_M>0) ? ((ctr>>LG_N) & ((1<<LG_M)-1))   : 0;
            sm=m; sn=n; sk=ctr>>(LG_N+LG_M);
            a_off = (sm & (TCU_A_SUB_BLOCKS-1)) * TCU_A_BLOCK_SIZE;
            b_off = (sn & (TCU_B_SUB_BLOCKS-1)) * TCU_B_BLOCK_SIZE;

            rs1_in = '0;
            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int kk=0; kk<TCU_TC_K; kk++)
                    rs1_in[a_off+ii*TCU_TC_K+kk] = A_mat[sm][sk][ii][kk];
            rs2_in = '0;
            for (int jj=0; jj<TCU_TC_N; jj++)
                for (int kk=0; kk<TCU_TC_K; kk++)
                    rs2_in[b_off+jj*TCU_TC_K+kk] = B_mat[sk][sn][jj][kk];
            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++)
                    rs3_in[ii*TCU_TC_N+jj] = D_mat[sm][sn][ii][jj];

            pkt = use_mxint8 ? build_mxint8(rs1_in, rs2_in, rs3_in, 4'(sm), 4'(sn))
                             : build_int8  (rs1_in, rs2_in, rs3_in, 4'(sm), 4'(sn));
            fire_dispatch(pkt);
            wait_commit(res);

            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++) begin
                    logic [31:0] got, exp_v;
                    got   = res.data[ii*TCU_TC_N+jj];
                    exp_v = ref_d_fp32(rs1_in, rs2_in, rs3_in, exp_total, ii, jj, b_off);
                    D_mat[sm][sn][ii][jj] = got;
                    if (got !== exp_v) begin
                        $display("[FAIL] %s  uop=%0d [%0d][%0d] got=0x%08X exp=0x%08X",
                                 name, ctr, ii, jj, got, exp_v);
                        ok = 0;
                    end
                end
        end

        if (ok) begin
            $display("[PASS] %s  result[0]=%h (~%0.1f)",
                     name, D_mat[0][0][0][0],
                     ref_fp32_to_real(D_mat[0][0][0][0]));
            pass_cnt++;
        end else fail_cnt++;
    endtask

    // =========================================================================
    // run_scenario_3level: WMMA with 3LEVEL hierarchical pair shifts
    // KEY SCENARIO: OT transform visible in waveform (fmt_s 3→9, rs1 raw→flat)
    // =========================================================================
`ifdef EXT_AG_TCU_ENABLE
    task automatic run_scenario_3level(
        input string name,
        input logic [7:0] exp_a, exp_b,
        input logic [1:0] p0a, p1a,   // pair0/pair1 combined shift for A
        input logic [1:0] p0b, p1b    // pair0/pair1 combined shift for B
    );
        logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_in, rs2_in, rs3_in;
        dispatch_t pkt; commit_t res;
        logic signed [9:0] exp_total;
        bit ok; ok = 1;
        exp_total = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b}) - 10'sd254;

        fire_ldscale(exp_a, exp_b);
        fire_ldmicro_3level(p0a, p1a, p0b, p1b);

        for (int ctr=0; ctr<TCU_UOPS; ctr++) begin
            int n, m, sm, sn, sk, a_off, b_off;
            n     = (LG_N>0) ? (ctr & ((1<<LG_N)-1))           : 0;
            m     = (LG_M>0) ? ((ctr>>LG_N) & ((1<<LG_M)-1))   : 0;
            sm=m; sn=n; sk=ctr>>(LG_N+LG_M);
            a_off = (sm & (TCU_A_SUB_BLOCKS-1)) * TCU_A_BLOCK_SIZE;
            b_off = (sn & (TCU_B_SUB_BLOCKS-1)) * TCU_B_BLOCK_SIZE;

            rs1_in = '0;
            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int kk=0; kk<TCU_TC_K; kk++)
                    rs1_in[a_off+ii*TCU_TC_K+kk] = A_mat[sm][sk][ii][kk];
            rs2_in = '0;
            for (int jj=0; jj<TCU_TC_N; jj++)
                for (int kk=0; kk<TCU_TC_K; kk++)
                    rs2_in[b_off+jj*TCU_TC_K+kk] = B_mat[sk][sn][jj][kk];
            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++)
                    rs3_in[ii*TCU_TC_N+jj] = D_mat[sm][sn][ii][jj];

            pkt = build_3level(rs1_in, rs2_in, rs3_in, 4'(sm), 4'(sn));
            fire_dispatch(pkt);
            wait_commit(res);

            for (int ii=0; ii<TCU_TC_M; ii++)
                for (int jj=0; jj<TCU_TC_N; jj++) begin
                    logic [31:0] got, exp_v;
                    got   = res.data[ii*TCU_TC_N+jj];
                    exp_v = ref_d_fp32_3level(rs1_in, rs2_in, rs3_in,
                                              exp_total, p0a, p1a, p0b, p1b, ii, jj, b_off);
                    D_mat[sm][sn][ii][jj] = got;
                    if (got !== exp_v) begin
                        $display("[FAIL] %s  uop=%0d [%0d][%0d] got=0x%08X exp=0x%08X",
                                 name, ctr, ii, jj, got, exp_v);
                        ok = 0;
                    end
                end
        end

        if (ok) begin
            $display("[PASS] %s  result[0]=%h (~%0.1f)",
                     name, D_mat[0][0][0][0],
                     ref_fp32_to_real(D_mat[0][0][0][0]));
            pass_cnt++;
        end else fail_cnt++;
    endtask
`endif

    // =========================================================================
    // Main — 3 scenarios
    // =========================================================================
    initial begin
        pass_cnt = 0; fail_cnt = 0; demo_phase = 0;
        dispatch_if[0].valid = 0;
        dispatch_if[0].data  = '0;

        // Reset
        reset = 1;
        repeat(5) @(posedge clk);
        reset = 0;
        repeat(3) @(posedge clk);

        // =====================================================================
        // Scenario 1: INT8 — no scaling, pure dot product
        //   A=B=0x01010101 (all elements = +1)
        //   exp_total = 0  →  result = FP32(dot × 1)
        //   NT=4: 16.0 (0x41800000)
        // =====================================================================
        demo_phase = 1;
        $display("\n=== Scenario 1: INT8 (baseline, no scaling) ===");
        $display("    A=B=0x01010101, exp_total=0 → expect 16.0");
        fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'h00000000);
        run_scenario_int8("INT8_neutral", 0, 8'd127, 8'd127);

        // =====================================================================
        // Scenario 2: MXINT8 — global scale doubles the result
        //   Same A, B as above; exp_a=128, exp_b=127 → exp_total = +1
        //   result = Scenario1_result × 2^1 = FP32(32.0)
        //   NT=4: 32.0 (0x42000000)
        //
        //   Waveform: watch LDSCALE {scale_b=127, scale_a=128} then WMMA
        // =====================================================================
        demo_phase = 2;
        $display("\n=== Scenario 2: MXINT8 (global scale ×2) ===");
        $display("    A=B=0x01010101, exp_total=+1 → expect 32.0");
        fill_A(32'h01010101); fill_B(32'h01010101); fill_D(32'h00000000);
        run_scenario_int8("MXINT8_scale_x2", 1, 8'd128, 8'd127);

        // =====================================================================
        // Scenario 3: 3LEVEL — hierarchical pair-level shift (KEY DEMO)
        //   A = 0x02020101  (pair0_bytes=0x01, pair1_bytes=0x02)
        //   B = 0x01010101
        //   L2=1, L3_pair0=0, L3_pair1=1
        //   → pair0_shift = 1+0 = 1 : OT 0x01→sat(0x01<<1)=0x02
        //   → pair1_shift = 1+1 = 2 : OT 0x02→sat(0x02<<2)=0x08
        //   OT output rs1_data[0]:  0x02020101 → 0x08080202  ← KEY observation
        //   OT output fmt_s:        3 (3LEVEL)  → 9 (I8_ID)  ← OT patches
        //   B also flattened: pair0→0x02, pair1→0x04
        //   dot/word = 2×(0x02×0x02)+2×(0x08×0x04) = 8+64 = 72
        //   NT=4: 288.0 (0x43900000)
        // =====================================================================
`ifdef EXT_AG_TCU_ENABLE
        demo_phase = 3;
        $display("\n=== Scenario 3: 3LEVEL hierarchy (OT transform visible) ===");
        $display("    A=0x02020101, pair0_shift=1, pair1_shift=2");
        $display("    OT: rs1[0] 0x02020101 -> 0x08080202, fmt_s 3->9");
        $display("    expect 288.0");
        fill_A(32'h02020101); fill_B(32'h01010101); fill_D(32'h00000000);
        run_scenario_3level("3LEVEL_hierarchy",
            8'd127, 8'd127,
            2'd1, 2'd2,   // A: pair0_shift=1, pair1_shift=2
            2'd1, 2'd2);  // B: same shifts
`endif

        // Summary
        demo_phase = 0;
        $display("\n=== Demo Summary: %0d PASS / %0d FAIL ===\n",
                 pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("All scenarios PASSED. Open waveform to inspect pipeline stages.");

        repeat(10) @(posedge clk);
        $finish;
    end

endmodule
