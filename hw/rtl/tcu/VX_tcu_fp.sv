// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

module VX_tcu_fp import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter HANDLE_SUBNORMAL = 0  // 0: flush-to-zero (default, inference), 1: CLZ normalize
) (
    `SCOPE_IO_DECL

    input wire          clk,
    input wire          reset,

    // Inputs
    VX_execute_if.slave execute_if,

    // Outputs
    VX_result_if.master result_if

);
    `UNUSED_SPARAM (INSTANCE_ID);

    localparam MDATA_WIDTH = UUID_WIDTH + NW_WIDTH + PC_BITS + NUM_REGS_BITS;

`ifdef TCU_DSP
    localparam FCVT_LATENCY = 1;
    localparam FMUL_LATENCY = 8;
    localparam FADD_LATENCY = 11;
    localparam FACC_LATENCY = $clog2(2 * TCU_TC_K + 1) * FADD_LATENCY;
    localparam FEDP_LATENCY = FCVT_LATENCY + FMUL_LATENCY + FACC_LATENCY;
`elsif TCU_DPI
    localparam FMUL_LATENCY = 2;
    localparam FACC_LATENCY = 2;
    localparam FEDP_LATENCY = FMUL_LATENCY + FACC_LATENCY;
`elsif TCU_BHF
    localparam FMUL_LATENCY = 2;
    localparam FADD_LATENCY = 2;
    localparam FRND_LATENCY = 1;
    localparam FACC_LATENCY  = $clog2(2 * TCU_TC_K + 1) * (FADD_LATENCY + FRND_LATENCY);
    localparam FEDP_LATENCY = (FMUL_LATENCY + FRND_LATENCY) + 1 + FACC_LATENCY;
`endif

    localparam PIPE_LATENCY = FEDP_LATENCY + 1;
    localparam MDATA_QUEUE_DEPTH = 1 << $clog2(PIPE_LATENCY);

    localparam LG_A_BS = $clog2(TCU_A_BLOCK_SIZE);
    localparam LG_B_BS = $clog2(TCU_B_BLOCK_SIZE);
    localparam OFF_W   = $clog2(TCU_BLOCK_CAP);

    wire [3:0] step_m = execute_if.data.op_args.tcu.step_m;
    wire [3:0] step_n = execute_if.data.op_args.tcu.step_n;

    wire [3:0] fmt_s = execute_if.data.op_args.tcu.fmt_s;
    wire [3:0] fmt_d = execute_if.data.op_args.tcu.fmt_d;

    `UNUSED_VAR ({step_m, step_n, fmt_d});
    // fmt_s and scale_A/scale_B are used: [2:0] captured in BUFFER_EX per (i,j).

/* Phase C: FP8 native multiply moved to VX_tcu_fedp_bhf.sv (g_prod).
   These FP8→BF16 upconversion functions are superseded and retained for reference only.

`ifdef TCU_BHF
    // FP8 E4M3 → BF16: {s,e[3:0],m[2:0]}, bias=7
    function automatic logic [15:0] fp8e4m3_to_bf16(input logic [7:0] fp8);
        logic s; logic [3:0] e; logic [2:0] m;
        s = fp8[7]; e = fp8[6:3]; m = fp8[2:0];
        if (e == 4'h0)       return {s, 15'b0};
        else if (e == 4'hF)  return (m != 3'h0) ? {s, 8'hFF, 7'h40} : {s, 8'hFE, 7'h7F};
        else                 return {s, e + 8'd120, m, 4'b0};
    endfunction

    // FP8 E5M2 → BF16: {s,e[4:0],m[1:0]}, bias=15
    function automatic logic [15:0] fp8e5m2_to_bf16(input logic [7:0] fp8);
        logic s; logic [4:0] e; logic [1:0] m;
        s = fp8[7]; e = fp8[6:2]; m = fp8[1:0];
        if (e == 5'h00)      return {s, 15'b0};
        else if (e == 5'h1F) return (m == 2'h0) ? {s, 8'hFF, 7'b0} : {s, 8'hFF, 7'h40};
        else                 return {s, e + 8'd112, m, 5'b0};
    endfunction

    function automatic logic [31:0] fp8e4m3_to_bf16_word(input logic [31:0] word);
        return {fp8e4m3_to_bf16(word[31:24]), fp8e4m3_to_bf16(word[15:8])};
    endfunction
    function automatic logic [31:0] fp8e5m2_to_bf16_word(input logic [31:0] word);
        return {fp8e5m2_to_bf16(word[31:24]), fp8e5m2_to_bf16(word[15:8])};
    endfunction
`endif // TCU_BHF
*/

    wire [MDATA_WIDTH-1:0] mdata_queue_din, mdata_queue_dout;
    wire mdata_queue_full;

    assign mdata_queue_din = {
        execute_if.data.uuid,
        execute_if.data.wid,
        execute_if.data.PC,
        execute_if.data.rd
    };

    wire execute_fire = execute_if.valid && execute_if.ready;
    wire result_fire = result_if.valid && result_if.ready;
    wire fedp_enable, fedp_done;

    // FEDP delay handling
    reg [PIPE_LATENCY-1:0] fedp_delay_pipe;
    always @(posedge clk) begin
        if (reset) begin
            fedp_delay_pipe <= '0;
        end else begin
            if (fedp_enable) begin
                fedp_delay_pipe <= fedp_delay_pipe >> 1;
            end
            if (execute_fire) begin
                fedp_delay_pipe[PIPE_LATENCY-1] <= 1;
            end
        end
    end
    assign fedp_done = fedp_delay_pipe[0];

    assign result_if.valid  = fedp_done;
    assign fedp_enable      = ~result_if.valid || result_if.ready;
    assign execute_if.ready = ~mdata_queue_full && fedp_enable;

    VX_fifo_queue #(
        .DATAW (MDATA_WIDTH),
        .DEPTH (MDATA_QUEUE_DEPTH),
        .OUT_REG (1)
    ) mdata_queue (
        .clk    (clk),
        .reset  (reset),
        .push   (execute_fire),
        .pop    (result_fire),
        .data_in(mdata_queue_din),
        .data_out(mdata_queue_dout),
        `UNUSED_PIN(empty),
        `UNUSED_PIN(alm_empty),
        .full   (mdata_queue_full),
        `UNUSED_PIN(alm_full),
        `UNUSED_PIN(size)
    );

    wire [OFF_W-1:0] a_off = (OFF_W'(step_m) & OFF_W'(TCU_A_SUB_BLOCKS-1)) << LG_A_BS;
    wire [OFF_W-1:0] b_off = (OFF_W'(step_n) & OFF_W'(TCU_B_SUB_BLOCKS-1)) << LG_B_BS;

    wire [TCU_TC_M-1:0][TCU_TC_N-1:0][`XLEN-1:0] d_val;

    for (genvar i = 0; i < TCU_TC_M; ++i) begin : g_i
        for (genvar j = 0; j < TCU_TC_N; ++j) begin : g_j

            wire [TCU_TC_K-1:0][`XLEN-1:0] a_row = execute_if.data.rs1_data[a_off + i * TCU_TC_K +: TCU_TC_K];
            wire [TCU_TC_K-1:0][`XLEN-1:0] b_col = execute_if.data.rs2_data[b_off + j * TCU_TC_K +: TCU_TC_K];
            wire [`XLEN-1:0] c_val = execute_if.data.rs3_data[i * TCU_TC_N + j];

            wire [2:0] fmt_s_r, fmt_d_r;
            wire [TCU_TC_K-1:0][`XLEN-1:0] a_row_r, b_col_r;
            wire [`XLEN-1:0] c_val_r;
            // Phase D: buffer per-(i,j) scale slices; compute exp_total_r after the register.
            wire [TCU_EXP_BITS-1:0] scale_A_ij = execute_if.data.op_args.tcu.scale_A[i*TCU_EXP_BITS +: TCU_EXP_BITS];
            wire [TCU_EXP_BITS-1:0] scale_B_ij = execute_if.data.op_args.tcu.scale_B[j*TCU_EXP_BITS +: TCU_EXP_BITS];
            wire [TCU_EXP_BITS-1:0] scale_A_ij_r, scale_B_ij_r;

            `BUFFER_EX (
                {a_row_r, b_col_r, c_val_r, fmt_s_r,    fmt_d_r,    scale_A_ij_r,  scale_B_ij_r},
                {a_row,   b_col,   c_val,   fmt_s[2:0], fmt_d[2:0], scale_A_ij,    scale_B_ij},
                fedp_enable,
                0, // resetw
                1  // depth
            );

            // Per-(i,j) signed exp_total: E8M0 sum minus 2×bias
            wire signed [TCU_EXP_TOTAL-1:0] exp_total_r =
                $signed(TCU_EXP_TOTAL'({2'b0, scale_A_ij_r}))
              + $signed(TCU_EXP_TOTAL'({2'b0, scale_B_ij_r}))
              - $signed(TCU_EXP_TOTAL'(2 * TCU_EXP_BIAS));

        `ifdef TCU_DPI
            VX_tcu_fedp_dpi #(
                .LATENCY (FEDP_LATENCY),
                .N (TCU_TC_K)
            ) fedp (
                .clk   (clk),
                .reset (reset),
                .enable(fedp_enable),
                .fmt_s (fmt_s_r),
                .fmt_d (fmt_d_r),
                .a_row (a_row_r),
                .b_col (b_col_r),
                .c_val (c_val_r),
                .d_val (d_val[i][j])
            );
        `elsif TCU_BHF
            // Phase C: FP8 native multiply handled inside VX_tcu_fedp_bhf (g_prod).
            // fmt_s_r passed directly; no FP8→BF16 upconversion needed.
            VX_tcu_fedp_bhf #(
                .LATENCY     (FEDP_LATENCY),
                .N           (TCU_TC_K),
                .EXP_TOTAL_W (TCU_EXP_TOTAL)
            ) fedp (
                .clk      (clk),
                .reset    (reset),
                .enable   (fedp_enable),
                .fmt_s    (fmt_s_r[2:0]),
                .fmt_d    (fmt_d_r),
                .exp_total(exp_total_r),
                .a_row    (a_row_r),
                .b_col    (b_col_r),
                .c_val    (c_val_r),
                .d_val    (d_val[i][j])
            );
        `elsif TCU_DSP
            VX_tcu_fedp_dsp #(
                .LATENCY (FEDP_LATENCY),
                .N (TCU_TC_K)
            ) fedp (
                .clk   (clk),
                .reset (reset),
                .enable(fedp_enable),
                .fmt_s (fmt_s_r),
                .fmt_d (fmt_d_r),
                .a_row (a_row_r),
                .b_col (b_col_r),
                .c_val (c_val_r),
                .d_val (d_val[i][j])
            );
        `endif

        `ifdef DBG_TRACE_TCU
            always @(posedge clk) begin
                if (execute_if.valid && execute_if.ready) begin
                    `TRACE(3, ("%t: %s FEDP-enq: wid=%0d, i=%0d, j=%0d, m=%0d, n=%0d, a_row=", $time, INSTANCE_ID, execute_if.data.wid, i, j, step_m, step_n))
                    `TRACE_ARRAY1D(2, "0x%0h", a_row, TCU_TC_K)
                    `TRACE(3, (", b_col="));
                    `TRACE_ARRAY1D(2, "0x%0h", b_col, TCU_TC_K)
                    `TRACE(3, (", c_val=0x%0h (#%0d)\n", c_val, execute_if.data.uuid));
                end
                if (result_if.valid && result_if.ready) begin
                    `TRACE(3, ("%t: %s FEDP-deq: wid=%0d, i=%0d, j=%0d, d_val=0x%0h (#%0d)\n", $time, INSTANCE_ID, result_if.data.wid, i, j, d_val[i][j], result_if.data.uuid));
                end
            end
        `endif // DBG_TRACE_TCU
        end
    end

    assign result_if.data.wb  = 1;
    assign result_if.data.tmask = {`NUM_THREADS{1'b1}};
    assign result_if.data.data  = d_val;
    assign result_if.data.pid = 0;
    assign result_if.data.sop = 1;
    assign result_if.data.eop = 1;

    assign {
        result_if.data.uuid,
        result_if.data.wid,
        result_if.data.PC,
        result_if.data.rd
    } = mdata_queue_dout;

endmodule
