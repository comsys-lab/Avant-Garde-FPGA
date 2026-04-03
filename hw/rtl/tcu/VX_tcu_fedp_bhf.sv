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

module VX_tcu_fedp_bhf #(
    parameter LATENCY      = 1,
    parameter N            = 1,
    parameter EXP_TOTAL_W  = 10  // signed global exponent width (TCU_EXP_TOTAL)
) (
    input  wire clk,
    input  wire reset,
    input  wire enable,

    input  wire[2:0] fmt_s,
    input  wire[2:0] fmt_d,

    input  wire signed [EXP_TOTAL_W-1:0] exp_total,  // global exponent (scale_a+scale_b-254)

    input  wire [N-1:0][`XLEN-1:0] a_row,
    input  wire [N-1:0][`XLEN-1:0] b_col,
    input  wire [`XLEN-1:0] c_val,
    output wire [`XLEN-1:0] d_val
);
    localparam TCK = 2 * N;
    localparam LEVELS = $clog2(TCK);
    localparam FMUL_LATENCY = 2;
    localparam FADD_LATENCY = 2;
    localparam FRND_LATENCY = 1;
    localparam FRED_LATENCY = LEVELS * (FADD_LATENCY + FRND_LATENCY);
    localparam TOTAL_LATENCY= (FMUL_LATENCY + FRND_LATENCY) + 1 + FRED_LATENCY + (FADD_LATENCY + FRND_LATENCY);
    `STATIC_ASSERT (LATENCY == 0 || LATENCY == TOTAL_LATENCY, ("invalid latency! expected=%0d, actual=%0d", TOTAL_LATENCY, LATENCY));

    localparam FMT_DELAY = FMUL_LATENCY + FRND_LATENCY;
    localparam C_DELAY = (FMUL_LATENCY + FRND_LATENCY) + 1 + FRED_LATENCY;

    `UNUSED_VAR (fmt_d);

    wire [2:0] frm = '0; // RNE rounding mode

    wire [TCK-1:0][15:0] a_row16;
    wire [TCK-1:0][15:0] b_col16;

    for (genvar i = 0; i < N; i++) begin : g_unpack
        assign a_row16[2*i]   = a_row[i][15:0];
        assign a_row16[2*i+1] = a_row[i][31:16];
        assign b_col16[2*i]   = b_col[i][15:0];
        assign b_col16[2*i+1] = b_col[i][31:16];
    end

    // Transprecision Multiply

    wire [2:0] fmt_s_delayed;

    VX_pipe_register #(
        .DATAW (3),
        .DEPTH (FMT_DELAY)
    ) pipe_fmt_s (
        .clk     (clk),
        .reset   (reset),
        .enable  (enable),
        .data_in (fmt_s),
        .data_out(fmt_s_delayed)
    );

    wire [32:0] mult_result [TCK];

    for (genvar i = 0; i < TCK; i++) begin : g_prod
        wire [32:0] mult_result_fp16;
        wire [32:0] mult_result_bf16;

        // FP16 multiplication
        VX_tcu_bhf_fmul #(
            .IN_EXPW (5),
            .IN_SIGW (10+1),
            .OUT_EXPW(8),
            .OUT_SIGW(24),
            .IN_REC  (0), // input in IEEE format
            .OUT_REC (1), // output in recoded format
            .MUL_LATENCY (FMUL_LATENCY),
            .RND_LATENCY (FRND_LATENCY)
        ) fp16_mul (
            .clk    (clk),
            .reset  (reset),
            .enable (enable),
            .frm    (frm),
            .a      (a_row16[i]),
            .b      (b_col16[i]),
            .y      (mult_result_fp16),
            `UNUSED_PIN(fflags)
        );

        // BF16 multiplication
        VX_tcu_bhf_fmul #(
            .IN_EXPW (8),
            .IN_SIGW (7+1),
            .OUT_EXPW(8),
            .OUT_SIGW(24),
            .IN_REC  (0), // input in IEEE format
            .OUT_REC (1), // output in recoded format
            .MUL_LATENCY (FMUL_LATENCY),
            .RND_LATENCY (FRND_LATENCY)
        ) bf16_mul (
            .clk    (clk),
            .reset  (reset),
            .enable (enable),
            .frm    (frm),
            .a      (a_row16[i]),
            .b      (b_col16[i]),
            .y      (mult_result_bf16),
            `UNUSED_PIN(fflags)
        );

        // -----------------------------------------------------------------------
        // FP8 native multiply (Phase C): FP8×FP8 → FP32 recoded, no BHF fmul.
        // Packing: FP8 byte resides at [15:8] of each 16-bit half-word.
        //   a_row16[2*k]   = a_row[k][15:0]  → FP8[0] = [15:8]
        //   a_row16[2*k+1] = a_row[k][31:16] → FP8[1] = [15:8] of this slice
        // Math:
        //   prod_m = {1,m_a} × {1,m_b}  (integer multiply of implicit-1 mantissas)
        //   FP32_exp = e_a + e_b + bias_adj + prod_m[MSB]
        //   FP32_man = prod_m[MSB] ? {prod_m[MSB-1:0], pad} : {prod_m[MSB-2:0], pad}
        //   Pipeline: combinational compute → DEPTH(FMT_DELAY) register → fNToRecFN
        // -----------------------------------------------------------------------

        wire [7:0] fp8_byte_a = a_row16[i][15:8];
        wire [7:0] fp8_byte_b = b_col16[i][15:8];

        // --- FP8 E4M3 × E4M3 → FP32 ---
        // Encoding: s[7] e[6:3] m[2:0], bias=7, no Inf (e=0xF,m=0 is sat.max)
        wire        e4m3_sa     = fp8_byte_a[7];
        wire [3:0]  e4m3_ea     = fp8_byte_a[6:3];
        wire [2:0]  e4m3_ma     = fp8_byte_a[2:0];
        wire        e4m3_sb     = fp8_byte_b[7];
        wire [3:0]  e4m3_eb     = fp8_byte_b[6:3];
        wire [2:0]  e4m3_mb     = fp8_byte_b[2:0];

        wire e4m3_a_zero   = (e4m3_ea == 4'h0) & (e4m3_ma == 3'h0);
        wire e4m3_b_zero   = (e4m3_eb == 4'h0) & (e4m3_mb == 3'h0);
        wire e4m3_a_nan    = (e4m3_ea == 4'hF) & (e4m3_ma != 3'h0);
        wire e4m3_b_nan    = (e4m3_eb == 4'hF) & (e4m3_mb != 3'h0);
        wire e4m3_a_denorm = (e4m3_ea == 4'h0) & (e4m3_ma != 3'h0); // flush-to-zero
        wire e4m3_b_denorm = (e4m3_eb == 4'h0) & (e4m3_mb != 3'h0);

        wire [3:0]  e4m3_maf  = {1'b1, e4m3_ma};   // implicit-1 mantissa
        wire [3:0]  e4m3_mbf  = {1'b1, e4m3_mb};
        wire [7:0]  e4m3_pm   = 8'(e4m3_maf) * 8'(e4m3_mbf);  // 4b×4b→8b ∈ [64,225]
        // FP32 exp: e_a+e_b - 2×bias(7) + FP32_bias(127) + norm_bit = e_a+e_b+113+norm
        wire [8:0]  e4m3_fexp = {5'b0, e4m3_ea} + {5'b0, e4m3_eb} + 9'd113
                                + {8'b0, e4m3_pm[7]};
        wire [22:0] e4m3_fman = e4m3_pm[7] ? {e4m3_pm[6:0], 16'b0}
                                            : {e4m3_pm[5:0], 17'b0};
        wire e4m3_sr = e4m3_sa ^ e4m3_sb;

        logic [31:0] e4m3_fp32;
        always_comb begin
            if (e4m3_a_zero | e4m3_b_zero | e4m3_a_denorm | e4m3_b_denorm)
                e4m3_fp32 = {e4m3_sr, 31'h0};      // ±0
            else if (e4m3_a_nan | e4m3_b_nan)
                e4m3_fp32 = 32'h7FC00000;           // canonical qNaN
            else
                e4m3_fp32 = {e4m3_sr, e4m3_fexp[7:0], e4m3_fman};
        end

        wire [31:0] e4m3_fp32_d;
        VX_pipe_register #(.DATAW(32), .DEPTH(FMT_DELAY)) pipe_e4m3 (
            .clk(clk), .reset(reset), .enable(enable),
            .data_in(e4m3_fp32), .data_out(e4m3_fp32_d)
        );

        wire [32:0] mult_result_fp8e4m3;
        fNToRecFN #(.expWidth(8), .sigWidth(24)) e4m3_to_rec (
            .in(e4m3_fp32_d), .out(mult_result_fp8e4m3)
        );

        // --- FP8 E5M2 × E5M2 → FP32 ---
        // Encoding: s[7] e[6:2] m[1:0], bias=15, has Inf (e=0x1F,m=0)
        wire        e5m2_sa     = fp8_byte_a[7];
        wire [4:0]  e5m2_ea     = fp8_byte_a[6:2];
        wire [1:0]  e5m2_ma     = fp8_byte_a[1:0];
        wire        e5m2_sb     = fp8_byte_b[7];
        wire [4:0]  e5m2_eb     = fp8_byte_b[6:2];
        wire [1:0]  e5m2_mb     = fp8_byte_b[1:0];

        wire e5m2_a_zero   = (e5m2_ea == 5'h00) & (e5m2_ma == 2'h0);
        wire e5m2_b_zero   = (e5m2_eb == 5'h00) & (e5m2_mb == 2'h0);
        wire e5m2_a_inf    = (e5m2_ea == 5'h1F) & (e5m2_ma == 2'h0);
        wire e5m2_b_inf    = (e5m2_eb == 5'h1F) & (e5m2_mb == 2'h0);
        wire e5m2_a_nan    = (e5m2_ea == 5'h1F) & (e5m2_ma != 2'h0);
        wire e5m2_b_nan    = (e5m2_eb == 5'h1F) & (e5m2_mb != 2'h0);
        wire e5m2_a_denorm = (e5m2_ea == 5'h00) & (e5m2_ma != 2'h0); // flush-to-zero
        wire e5m2_b_denorm = (e5m2_eb == 5'h00) & (e5m2_mb != 2'h0);

        wire [2:0]  e5m2_maf  = {1'b1, e5m2_ma};   // implicit-1 mantissa
        wire [2:0]  e5m2_mbf  = {1'b1, e5m2_mb};
        wire [5:0]  e5m2_pm   = 6'(e5m2_maf) * 6'(e5m2_mbf);  // 3b×3b→6b ∈ [16,49]
        // FP32 exp: e_a+e_b - 2×bias(15) + FP32_bias(127) + norm_bit = e_a+e_b+97+norm
        wire [8:0]  e5m2_fexp = {4'b0, e5m2_ea} + {4'b0, e5m2_eb} + 9'd97
                                + {8'b0, e5m2_pm[5]};
        wire [22:0] e5m2_fman = e5m2_pm[5] ? {e5m2_pm[4:0], 18'b0}
                                            : {e5m2_pm[3:0], 19'b0};
        wire e5m2_sr = e5m2_sa ^ e5m2_sb;

        logic [31:0] e5m2_fp32;
        always_comb begin
            if (e5m2_a_zero | e5m2_b_zero | e5m2_a_denorm | e5m2_b_denorm)
                e5m2_fp32 = {e5m2_sr, 31'h0};
            else if (e5m2_a_nan | e5m2_b_nan)
                e5m2_fp32 = 32'h7FC00000;           // canonical qNaN
            else if (e5m2_a_inf | e5m2_b_inf)
                e5m2_fp32 = {e5m2_sr, 8'hFF, 23'h0};   // ±Inf
            else
                e5m2_fp32 = {e5m2_sr, e5m2_fexp[7:0], e5m2_fman};
        end

        wire [31:0] e5m2_fp32_d;
        VX_pipe_register #(.DATAW(32), .DEPTH(FMT_DELAY)) pipe_e5m2 (
            .clk(clk), .reset(reset), .enable(enable),
            .data_in(e5m2_fp32), .data_out(e5m2_fp32_d)
        );

        wire [32:0] mult_result_fp8e5m2;
        fNToRecFN #(.expWidth(8), .sigWidth(24)) e5m2_to_rec (
            .in(e5m2_fp32_d), .out(mult_result_fp8e5m2)
        );

        logic [32:0] mult_result_mux;
        always_comb begin
            case(fmt_s_delayed)
                3'd1: mult_result_mux = mult_result_fp16;
                3'd2: mult_result_mux = mult_result_bf16;
                3'd5: mult_result_mux = mult_result_fp8e4m3; // TCU_FP8E4M3_ID
                3'd6: mult_result_mux = mult_result_fp8e5m2; // TCU_FP8E5M2_ID
                default: mult_result_mux = 'x;
            endcase
        end

        VX_pipe_register #(
            .DATAW (33),
            .DEPTH (1) // select latency
        ) pipe_mult (
            .clk      (clk),
            .reset    (reset),
            .enable   (enable),
            .data_in  (mult_result_mux),
            .data_out (mult_result[i])
        );
    end

    wire [32:0] red_in [0:LEVELS] [TCK];

    for (genvar i = 0; i < TCK; i++) begin : g_red_inputs
        assign red_in[0][i] = mult_result[i];
    end

    // Accumulate reduction tree
    for (genvar lvl = 0; lvl < LEVELS; lvl++) begin : g_red_tree
        localparam CURSZ = TCK >> lvl;
        localparam OUTSZ = CURSZ >> 1;

        for (genvar i = 0; i < OUTSZ; i++) begin : g_add
            VX_tcu_bhf_fadd #(
                .IN_EXPW (8),
                .IN_SIGW (23+1),
                .IN_REC  (1), // input in recoded format
                .OUT_REC (1), // output in recoded format
                .ADD_LATENCY (FADD_LATENCY),
                .RND_LATENCY (FRND_LATENCY)
            ) reduce_add (
                .clk    (clk),
                .reset  (reset),
                .enable (enable),
                .frm    (frm),
                .a      (red_in[lvl][2*i+0]),
                .b      (red_in[lvl][2*i+1]),
                .y      (red_in[lvl+1][i]),
                `UNUSED_PIN(fflags)
            );
        end
    end

    // Accumulation input C recoding and delay handling

    wire [32:0] c_rec, c_delayed;
    wire [31:0] result;

    fNToRecFN #(
        .expWidth (8),
        .sigWidth (24)
    ) conv_c (
        .in  (c_val[31:0]),
        .out (c_rec)
    );

    VX_pipe_register #(
        .DATAW (33),
        .DEPTH (C_DELAY)
    ) pipe_c (
        .clk     (clk),
        .reset   (reset),
        .enable  (enable),
        .data_in (c_rec),
        .data_out(c_delayed)
    );

    // -------------------------------------------------------------------------
    // Post-multiply global exponent shift (Avant-Garde paper):
    //   D = (sum(A_i * B_i) * 2^exp_total) + C
    //   Applied after reduction tree, before final C accumulation.
    //   exp_total delayed by C_DELAY to align with red_in[LEVELS][0].
    // -------------------------------------------------------------------------

    // Delay exp_total same depth as c_val (C_DELAY cycles)
    wire signed [EXP_TOTAL_W-1:0] exp_total_d;
    VX_pipe_register #(
        .DATAW (EXP_TOTAL_W),
        .DEPTH (C_DELAY)
    ) pipe_exp_total (
        .clk     (clk),
        .reset   (reset),
        .enable  (enable),
        .data_in (exp_total),
        .data_out(exp_total_d)
    );

    // Convert reduction result from HardFloat recoded → IEEE FP32
    wire [31:0] red_sum_ieee;
    recFNToFN #(.expWidth(8), .sigWidth(24)) conv_red_to_ieee (
        .in  (red_in[LEVELS][0]),
        .out (red_sum_ieee)
    );

    // Adjust IEEE FP32 exponent by exp_total_d (saturating)
    wire signed [9:0] new_exp_w =
          $signed({2'b0, red_sum_ieee[30:23]})
        + $signed({{(10-EXP_TOTAL_W){exp_total_d[EXP_TOTAL_W-1]}}, exp_total_d});

    logic [31:0] red_sum_scaled;
    always_comb begin
        if      (red_sum_ieee[30:23] == 8'h00)      red_sum_scaled = red_sum_ieee;                      // ±0 / denorm
        else if (red_sum_ieee[30:23] == 8'hFF)      red_sum_scaled = red_sum_ieee;                      // ±Inf / NaN
        else if (new_exp_w >= $signed(10'd255))     red_sum_scaled = {red_sum_ieee[31], 8'hFF, 23'h0};  // overflow → ±Inf
        else if (new_exp_w <= $signed(10'd0))       red_sum_scaled = {red_sum_ieee[31], 31'h0};         // underflow → ±0
        else                                        red_sum_scaled = {red_sum_ieee[31], new_exp_w[7:0], red_sum_ieee[22:0]};
    end

    // Convert scaled result back to HardFloat recoded for final_add
    wire [32:0] red_sum_scaled_rec;
    fNToRecFN #(.expWidth(8), .sigWidth(24)) conv_scaled_to_rec (
        .in  (red_sum_scaled),
        .out (red_sum_scaled_rec)
    );

    // Final accumulation
    VX_tcu_bhf_fadd #(
        .IN_EXPW (8),
        .IN_SIGW (23+1),
        .IN_REC  (1), // input in recoded format
        .OUT_REC (0), // output in IEEE format
        .ADD_LATENCY (FADD_LATENCY),
        .RND_LATENCY (FRND_LATENCY)
    ) final_add (
        .clk    (clk),
        .reset  (reset),
        .enable (enable),
        .frm    (frm),
        .a      (red_sum_scaled_rec),
        .b      (c_delayed),
        .y      (result),
        `UNUSED_PIN(fflags)
    );

    assign d_val = `XLEN'(result);

endmodule
