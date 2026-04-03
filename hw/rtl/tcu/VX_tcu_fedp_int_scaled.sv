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

// AG-TCU: Fused Element Dot Product (Integer) with Scaling Unit FP32 Output
//
// Phase 10 redesign:
//   D = float(dot(A,B)) * 2^exp_total + C
//   where:
//     dot(A,B) = INT8×INT8 MAC (after OT flatten)
//     exp_total = scale_a + scale_b - 2*bias (E8M0, signed 10-bit)
//     C = FP32 accumulator (rs3_data, zero-initialized for first k-step)
//     D = FP32 output
//
// Pipeline stages:
//   [MUL, 2cy] INT8×INT8 MAC → PSEL
//   [RED, 1cy] Reduction tree → INT partial sum (REDW bits)
//   [SCALE,1cy] INT32→FP32 (CLZ-based) + exp_total exponent adjust → FP32
//   [FADD, 1cy] FP32_scaled + C(FP32) → FP32
//
// Total LATENCY = MUL(2) + RED($clog2(N)) + SCALE(1) + FADD(1)
//              = 5 cycles for N=2 (NT=4 / NT=8 with TCU_TC_K=2)

`include "VX_define.vh"

module VX_tcu_fedp_int_scaled #(
    parameter LATENCY   = 1,
    parameter N         = 1,
    parameter EXP_TOTAL = 10  // signed width of exp_total port (Phase 5: 10-bit E8M0)
) (
    input  wire clk,
    input  wire reset,
    input  wire enable,

    input  wire [2:0] fmt_s,
    input  wire [2:0] fmt_d,

    // AG-TCU: signed tile-level exponent = scale_a + scale_b - 2*bias.
    input  wire signed [EXP_TOTAL-1:0] exp_total,

    input  wire [N-1:0][`XLEN-1:0] a_row,
    input  wire [N-1:0][`XLEN-1:0] b_col,
    input  wire [`XLEN-1:0]        c_val,   // FP32 accumulator (IEEE 754)
    output wire [`XLEN-1:0]        d_val    // FP32 result (IEEE 754)
);
    // ---------------------------------------------------------------------------
    // Latency constants
    // ---------------------------------------------------------------------------
    localparam LEVELS        = $clog2(N);
    localparam PRODW         = 18;
    localparam PSELW         = PRODW + 1;            // unsigned guard bit
    localparam REDW          = `MAX(PRODW + LEVELS, PSELW);
    localparam MUL_LATENCY   = 2;
    localparam ADD_LATENCY   = 1;
    localparam RED_LATENCY   = LEVELS * ADD_LATENCY;
    localparam SCALE_LATENCY = 1;
    localparam FADD_LATENCY  = 1;
    localparam TOTAL_LATENCY = MUL_LATENCY + RED_LATENCY + SCALE_LATENCY + FADD_LATENCY;

    `STATIC_ASSERT (LATENCY == TOTAL_LATENCY, ("invalid LATENCY parameter!"));

    `UNUSED_VAR (fmt_d);

    // ---------------------------------------------------------------------------
    // [Stage 0] fmt_s pipeline: arrive at mult_sel 1 cycle before mult_result
    // ---------------------------------------------------------------------------
    wire [2:0] delayed_fmt_s;
    VX_pipe_register #(
        .DATAW  (3),
        .RESETW (3),
        .DEPTH  (MUL_LATENCY - 1)
    ) pipe_fmt_s (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .data_in  (fmt_s),
        .data_out (delayed_fmt_s)
    );

    // ---------------------------------------------------------------------------
    // [Stage 0] exp_total pipeline: synchronise with partial sum at RED output
    // Depth = MUL_LATENCY + RED_LATENCY so that delayed_exp arrives at the same
    // cycle as red_in[LEVELS][0] (SCALE stage input).
    // ---------------------------------------------------------------------------
    wire signed [EXP_TOTAL-1:0] delayed_exp;
    VX_pipe_register #(
        .DATAW  (EXP_TOTAL),
        .RESETW (EXP_TOTAL),
        .DEPTH  (MUL_LATENCY + RED_LATENCY)
    ) pipe_exp (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .data_in  (exp_total),
        .data_out (delayed_exp)
    );

    // ---------------------------------------------------------------------------
    // [Stage 0] c_val pipeline: align with FADD stage input
    // Depth = MUL_LATENCY + RED_LATENCY + SCALE_LATENCY
    // ---------------------------------------------------------------------------
    wire [31:0] delayed_c;
    VX_pipe_register #(
        .DATAW  (32),
        .RESETW (32),
        .DEPTH  (MUL_LATENCY + RED_LATENCY + SCALE_LATENCY)
    ) pipe_c (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .data_in  (c_val[31:0]),
        .data_out (delayed_c)
    );

    // ---------------------------------------------------------------------------
    // [Stage 1-2] Multiply stage — INT8 x INT8, unchanged from VX_tcu_fedp_int
    // ---------------------------------------------------------------------------
    wire [PSELW-1:0] mult_result [N];

    for (genvar i = 0; i < N; i++) begin : g_prod
        reg [16:0] prod_i8_1a, prod_i8_1b;
        reg [16:0] prod_u8_1a, prod_u8_1b;
        reg [9:0]  prod_i4_1a, prod_i4_1b;
        reg [9:0]  prod_u4_1a, prod_u4_1b;

        always @(posedge clk) begin
            if (reset) begin
                prod_i8_1a <= '0;
                prod_i8_1b <= '0;
            end else if (enable) begin
                prod_i8_1a <= ($signed(a_row[i][7:0])   * $signed(b_col[i][7:0]))
                            + ($signed(a_row[i][15:8])  * $signed(b_col[i][15:8]));
                prod_i8_1b <= ($signed(a_row[i][23:16]) * $signed(b_col[i][23:16]))
                            + ($signed(a_row[i][31:24]) * $signed(b_col[i][31:24]));
            end
        end

        always @(posedge clk) begin
            if (reset) begin
                prod_u8_1a <= '0;
                prod_u8_1b <= '0;
            end else if (enable) begin
                prod_u8_1a <= (a_row[i][7:0]   * b_col[i][7:0])
                            + (a_row[i][15:8]  * b_col[i][15:8]);
                prod_u8_1b <= (a_row[i][23:16] * b_col[i][23:16])
                            + (a_row[i][31:24] * b_col[i][31:24]);
            end
        end

        always @(posedge clk) begin
            if (reset) begin
                prod_i4_1a <= '0;
                prod_i4_1b <= '0;
            end else if (enable) begin
                prod_i4_1a <= (($signed(a_row[i][3:0])   * $signed(b_col[i][3:0]))
                             + ($signed(a_row[i][7:4])   * $signed(b_col[i][7:4])))
                            + (($signed(a_row[i][11:8])  * $signed(b_col[i][11:8]))
                             + ($signed(a_row[i][15:12]) * $signed(b_col[i][15:12])));
                prod_i4_1b <= (($signed(a_row[i][19:16]) * $signed(b_col[i][19:16]))
                             + ($signed(a_row[i][23:20]) * $signed(b_col[i][23:20])))
                            + (($signed(a_row[i][27:24]) * $signed(b_col[i][27:24]))
                             + ($signed(a_row[i][31:28]) * $signed(b_col[i][31:28])));
            end
        end

        always @(posedge clk) begin
            if (reset) begin
                prod_u4_1a <= '0;
                prod_u4_1b <= '0;
            end else if (enable) begin
                prod_u4_1a <= ((a_row[i][3:0]   * b_col[i][3:0])
                             + (a_row[i][7:4]   * b_col[i][7:4]))
                            + ((a_row[i][11:8]  * b_col[i][11:8])
                             + (a_row[i][15:12] * b_col[i][15:12]));
                prod_u4_1b <= ((a_row[i][19:16] * b_col[i][19:16])
                             + (a_row[i][23:20] * b_col[i][23:20]))
                            + ((a_row[i][27:24] * b_col[i][27:24])
                             + (a_row[i][31:28] * b_col[i][31:28]));
            end
        end

        wire [17:0] sum_i8 = $signed(prod_i8_1a) + $signed(prod_i8_1b);
        wire [17:0] sum_u8 = prod_u8_1a + prod_u8_1b;
        wire [10:0] sum_i4 = $signed(prod_i4_1a) + $signed(prod_i4_1b);
        wire [10:0] sum_u4 = prod_u4_1a + prod_u4_1b;

        reg [PSELW-1:0] mult_sel;
        always @(*) begin
            case (delayed_fmt_s)
            3'd1: mult_sel = PSELW'($signed(sum_i8));  // I8_ID=9,      fmt_s[2:0]=001
            3'd2: mult_sel = PSELW'(sum_u8);           // U8_ID=10,     fmt_s[2:0]=010
            3'd3: mult_sel = PSELW'($signed(sum_i4));  // I4_ID=11,     fmt_s[2:0]=011
            3'd4: mult_sel = PSELW'(sum_u4);           // U4_ID=12,     fmt_s[2:0]=100
            3'd5: mult_sel = PSELW'($signed(sum_i8));  // MXINT8_ID=13, fmt_s[2:0]=101 → signed INT8
            default: mult_sel = '0;  // reset 기간 X 전파 방지 (정상 동작 시 미도달)
            endcase
        end

        VX_pipe_register #(
            .DATAW (PSELW),
            .DEPTH (1)
        ) pipe_sel (
            .clk      (clk),
            .reset    (reset),
            .enable   (enable),
            .data_in  (mult_sel),
            .data_out (mult_result[i])
        );
    end

    // ---------------------------------------------------------------------------
    // [Stage 3-...] Reduction tree — unchanged from VX_tcu_fedp_int
    // ---------------------------------------------------------------------------
    wire [REDW-1:0] red_in [LEVELS+1][N];

    for (genvar i = 0; i < N; i++) begin : g_red_inputs
        assign red_in[0][i] = REDW'($signed(mult_result[i]));
    end

    for (genvar lvl = 0; lvl < LEVELS; lvl++) begin : g_red_tree
        localparam integer CURSZ = N >> lvl;
        localparam integer OUTSZ = CURSZ >> 1;
        for (genvar i = 0; i < OUTSZ; i++) begin : g_add
            wire [REDW-1:0] sum = red_in[lvl][2*i+0] + red_in[lvl][2*i+1];
            VX_pipe_register #(
                .DATAW (REDW),
                .DEPTH (1)
            ) pipe_red (
                .clk      (clk),
                .reset    (reset),
                .enable   (enable),
                .data_in  (sum),
                .data_out (red_in[lvl+1][i])
            );
        end
    end

    // ---------------------------------------------------------------------------
    // Helper: INT32 → IEEE FP32 (exact for |v| <= 2^23, no rounding needed)
    //
    // Algorithm:
    //   1. sign = v[31]
    //   2. abs_v = |v| (32-bit 2's complement)
    //   3. Find MSB position via priority encoder (lz = 31 - MSB_pos)
    //   4. biased_exp = (31 - lz) + 127
    //   5. norm = abs_v << lz  (MSB at bit31 = implicit leading 1)
    //   6. mantissa = norm[30:8]  (23 fractional bits)
    // ---------------------------------------------------------------------------
    function automatic logic [31:0] int32_to_fp32(input logic signed [31:0] v);
        logic        sign;
        logic [31:0] abs_v;
        logic [4:0]  lz;    // leading zeros = 31 - MSB_pos
        logic [7:0]  exp_r;
        logic [31:0] norm;

        if (v == 32'sh0) return 32'h0000_0000;

        sign  = v[31];
        abs_v = sign ? 32'($unsigned(-v)) : 32'($unsigned(v));

        // Priority encoder: last assignment wins → lz = 31 - highest_set_bit
        lz = 5'd31;
        for (int k = 0; k <= 31; k++) begin
            if (abs_v[k]) lz = 5'd31 - 5'(k);
        end

        exp_r = 8'd31 - 8'(lz) + 8'd127;
        norm  = abs_v << lz;          // MSB at bit31, bits[30:8] = mantissa

        return {sign, exp_r, norm[30:8]};
    endfunction

    // ---------------------------------------------------------------------------
    // Helper: Adjust IEEE FP32 exponent by signed exp_total (saturating)
    //   Result = fp32_in * 2^exp_delta
    // ---------------------------------------------------------------------------
    function automatic logic [31:0] fp32_exp_scale(
        input logic [31:0]                     fp32_in,
        input logic signed [EXP_TOTAL-1:0]    exp_delta
    );
        logic [7:0]  old_exp;
        logic signed [9:0] new_exp;

        if (fp32_in[30:23] == 8'h00) return fp32_in;  // ±0 → no-op
        if (fp32_in[30:23] == 8'hFF) return fp32_in;  // Inf/NaN → passthrough

        old_exp = fp32_in[30:23];
        new_exp = $signed({2'b0, old_exp})
                + $signed({{(10-EXP_TOTAL){exp_delta[EXP_TOTAL-1]}}, exp_delta});

        if (new_exp >= $signed(10'd255)) return {fp32_in[31], 8'hFF, 23'h0};  // overflow → ±Inf
        if (new_exp <= $signed(10'd0))   return {fp32_in[31], 31'h0};          // underflow → ±0

        return {fp32_in[31], new_exp[7:0], fp32_in[22:0]};
    endfunction

    // ---------------------------------------------------------------------------
    // Helper: IEEE 754 FP32 addition (handles normal numbers and zero)
    //   Round-to-nearest (no sticky bits, simplified for integer-origin values)
    // ---------------------------------------------------------------------------
    function automatic logic [31:0] fp32_add(
        input logic [31:0] a,
        input logic [31:0] b
    );
        logic sign_a, sign_b, sign_r;
        logic [7:0]  exp_a, exp_b, exp_big, exp_r;
        logic [23:0] sig_a, sig_b, sig_big, sig_sml;
        logic [7:0]  exp_diff;
        logic [24:0] sig_sum;
        logic [4:0]  norm_shift;
        logic [23:0] sig_norm;

        sign_a = a[31]; exp_a = a[30:23];
        sign_b = b[31]; exp_b = b[30:23];

        // Handle zero (subnormals treated as zero)
        if (exp_a == 8'h00) return b;
        if (exp_b == 8'h00) return a;
        // Handle Inf/NaN
        if (exp_a == 8'hFF) return a;
        if (exp_b == 8'hFF) return b;

        sig_a = {1'b1, a[22:0]};
        sig_b = {1'b1, b[22:0]};

        // Choose larger-magnitude operand as base (by exponent, then mantissa)
        if (exp_a > exp_b || (exp_a == exp_b && a[22:0] >= b[22:0])) begin
            exp_big  = exp_a;
            exp_diff = 8'(exp_a - exp_b);
            sig_big  = sig_a;
            sig_sml  = (exp_diff >= 8'd24) ? 24'h0 : (sig_b >> exp_diff);
            sign_r   = sign_a;
        end else begin
            exp_big  = exp_b;
            exp_diff = 8'(exp_b - exp_a);
            sig_big  = sig_b;
            sig_sml  = (exp_diff >= 8'd24) ? 24'h0 : (sig_a >> exp_diff);
            sign_r   = sign_b;
        end

        if (sign_a == sign_b) begin
            // Same sign: add significands
            sig_sum = {1'b0, sig_big} + {1'b0, sig_sml};
            if (sig_sum[24]) begin
                // Carry out → exponent +1, shift mantissa right
                exp_r = exp_big + 8'd1;
                if (exp_r == 8'hFF) return {sign_r, 8'hFF, 23'h0};  // overflow → ±Inf
                return {sign_r, exp_r, sig_sum[23:1]};
            end else begin
                return {sign_r, exp_big, sig_sum[22:0]};
            end
        end else begin
            // Different sign: subtract (big - small, |big| >= |small| by construction)
            sig_sum = {1'b0, sig_big} - {1'b0, sig_sml};
            if (sig_sum[23:0] == 24'h0) return 32'h0000_0000;  // exact cancellation

            // Normalize: find number of leading zeros in sig_sum[23:0]
            // Loop: last iteration where sig_norm[k]=1 → norm_shift = 23 - k
            norm_shift = 5'd23;
            sig_norm   = sig_sum[23:0];
            for (int k = 0; k <= 23; k++) begin
                if (sig_norm[k]) norm_shift = 5'd23 - 5'(k);
            end
            sig_norm = sig_norm << norm_shift;

            if (exp_big <= 8'(norm_shift)) return {sign_r, 31'h0};  // underflow → ±0
            exp_r = exp_big - 8'(norm_shift);
            return {sign_r, exp_r, sig_norm[22:0]};
        end
    endfunction

    // ---------------------------------------------------------------------------
    // [SCALE stage] INT32 → FP32 + exp_total adjust, registered
    // ---------------------------------------------------------------------------
    wire [31:0] red_sum_int32 = 32'($signed(red_in[LEVELS][0]));  // sign-extend REDW→32
    wire [31:0] scale_comb    = fp32_exp_scale(int32_to_fp32($signed(red_sum_int32)), delayed_exp);

    wire [31:0] pipe_scale_out;
    VX_pipe_register #(
        .DATAW (32),
        .DEPTH (SCALE_LATENCY)
    ) pipe_scale (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .data_in  (scale_comb),
        .data_out (pipe_scale_out)
    );

    // ---------------------------------------------------------------------------
    // [FADD stage] FP32_scaled + C(FP32) → FP32, registered
    // ---------------------------------------------------------------------------
    wire [31:0] fadd_comb = fp32_add(pipe_scale_out, delayed_c);
    wire [31:0] result;

    VX_pipe_register #(
        .DATAW (32),
        .DEPTH (FADD_LATENCY)
    ) pipe_fadd (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .data_in  (fadd_comb),
        .data_out (result)
    );

`ifdef XLEN_64
    assign d_val = {32'hffffffff, result};
`else
    assign d_val = result;
`endif

endmodule
