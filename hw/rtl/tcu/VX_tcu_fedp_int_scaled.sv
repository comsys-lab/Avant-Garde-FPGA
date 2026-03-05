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

// AG-TCU: Fused Element Dot Product (Integer) with Partial Sum Alignment
//
// Implements the Avant-Garde Scaled Numeric Format semantics:
//   D = (A x B) <<± exp_total + C
// where exp_total = scale_a + scale_b - 2*bias (Phase 5: E8M0, signed 10-bit, range [-254,+256]).
// exp_total >= 0: left shift (scale up). exp_total < 0: arithmetic right shift (scale down).
// Effective range clamped to [-31, +30] (AG_TCU_EXP_MIN / AG_TCU_EXP_MAX).
//
// Design principles:
//   - INT8 x INT8 MAC array (g_prod): UNCHANGED from VX_tcu_fedp_int
//   - Reduction tree (g_red_tree):    UNCHANGED from VX_tcu_fedp_int
//   - Partial Sum Alignment stage:    NEW - combinational shift before acc
//   - exp_total pipelined as metadata alongside partial sum (no critical-path impact)
//   - Saturation policy: signed INT32 saturate on overflow from alignment shift
//   - Pipeline depth (FEDP_LATENCY):  UNCHANGED from VX_tcu_fedp_int

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
    // Phase 5: E8M0 — signed 10-bit (EXP_TOTAL), range [-254, +256], clamped to [-31, +30].
    input  wire signed [EXP_TOTAL-1:0] exp_total,

    input  wire [N-1:0][`XLEN-1:0] a_row,
    input  wire [N-1:0][`XLEN-1:0] b_col,
    input  wire [`XLEN-1:0]        c_val,
    output wire [`XLEN-1:0]        d_val
);
    // ---------------------------------------------------------------------------
    // Latency constants (must match VX_tcu_int.sv FEDP_LATENCY)
    // ---------------------------------------------------------------------------
    localparam LEVELS      = $clog2(N);
    localparam PRODW       = 18;
    localparam PSELW       = PRODW + 1;            // unsigned guard bit
    localparam REDW        = `MAX(PRODW + LEVELS, PSELW);
    localparam MUL_LATENCY = 2;
    localparam ADD_LATENCY = 1;
    localparam RED_LATENCY = LEVELS * ADD_LATENCY;
    localparam ACC_LATENCY = RED_LATENCY + ADD_LATENCY;

    // Alignment result width: REDW bits shifted left by up to 30 positions.
    // 30 = AG_TCU_EXP_MAX clamp (effective left-shift ceiling).
    // Right shifts reduce magnitude and never exceed REDW bits.
    localparam ALIGNED_W   = REDW + 30;

    `STATIC_ASSERT (LATENCY == (MUL_LATENCY + ACC_LATENCY), ("invalid LATENCY parameter!"));

    `UNUSED_VAR ({a_row, b_col, c_val});
    `UNUSED_VAR (fmt_d);

    // ---------------------------------------------------------------------------
    // [Stage 0] fmt_s pipeline: arrive at mult_sel 1 cycle before mult_result
    // ---------------------------------------------------------------------------
    wire [2:0] delayed_fmt_s;
    VX_pipe_register #(
        .DATAW (3),
        .DEPTH (MUL_LATENCY - 1)
    ) pipe_fmt_s (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .data_in  (fmt_s),
        .data_out (delayed_fmt_s)
    );

    // ---------------------------------------------------------------------------
    // [Stage 0] exp_total pipeline: synchronise with partial sum at LEVELS output
    // Depth = MUL_LATENCY + RED_LATENCY so that delayed_exp arrives at the same
    // cycle as red_in[LEVELS][0].
    // ---------------------------------------------------------------------------
    wire signed [EXP_TOTAL-1:0] delayed_exp;
    VX_pipe_register #(
        .DATAW (EXP_TOTAL),
        .DEPTH (MUL_LATENCY + RED_LATENCY)
    ) pipe_exp (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .data_in  (exp_total),
        .data_out (delayed_exp)
    );

    // ---------------------------------------------------------------------------
    // [Stage 1-2] Multiply stage — INT8 x INT8, UNCHANGED from VX_tcu_fedp_int
    // ---------------------------------------------------------------------------
    wire [PSELW-1:0] mult_result [N];

    for (genvar i = 0; i < N; i++) begin : g_prod
        reg [16:0] prod_i8_1a, prod_i8_1b;
        reg [16:0] prod_u8_1a, prod_u8_1b;
        reg [9:0]  prod_i4_1a, prod_i4_1b;
        reg [9:0]  prod_u4_1a, prod_u4_1b;

        always @(posedge clk) begin
            if (enable) begin
                prod_i8_1a <= ($signed(a_row[i][7:0])   * $signed(b_col[i][7:0]))
                            + ($signed(a_row[i][15:8])  * $signed(b_col[i][15:8]));
                prod_i8_1b <= ($signed(a_row[i][23:16]) * $signed(b_col[i][23:16]))
                            + ($signed(a_row[i][31:24]) * $signed(b_col[i][31:24]));
            end
        end

        always @(posedge clk) begin
            if (enable) begin
                prod_u8_1a <= (a_row[i][7:0]   * b_col[i][7:0])
                            + (a_row[i][15:8]  * b_col[i][15:8]);
                prod_u8_1b <= (a_row[i][23:16] * b_col[i][23:16])
                            + (a_row[i][31:24] * b_col[i][31:24]);
            end
        end

        always @(posedge clk) begin
            if (enable) begin
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
            if (enable) begin
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
            3'd1: mult_sel = PSELW'($signed(sum_i8));
            3'd2: mult_sel = PSELW'(sum_u8);
            3'd3: mult_sel = PSELW'($signed(sum_i4));
            3'd4: mult_sel = PSELW'(sum_u4);
            default: mult_sel = 'x;
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
    // [Stage 3-...] Reduction tree — UNCHANGED from VX_tcu_fedp_int
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
    // c_val delay pipeline — same depth as VX_tcu_fedp_int
    // ---------------------------------------------------------------------------
    wire [31:0] delayed_c;
    VX_pipe_register #(
        .DATAW (32),
        .DEPTH (MUL_LATENCY + RED_LATENCY)
    ) pipe_c (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .data_in  (c_val[31:0]),
        .data_out (delayed_c)
    );

    // ---------------------------------------------------------------------------
    // [NEW] Partial Sum Alignment Stage (combinational, before pipe_acc)
    //
    // Phase 5: E8M0 bidirectional shift based on sign of delayed_exp.
    //   delayed_exp >= 0 : left  shift (scale up)   P = dot <<< delayed_exp
    //   delayed_exp <  0 : right shift (scale down)  P = dot >>> |delayed_exp|
    //
    // ALIGNED_W = REDW + 30 accommodates max effective left shift (+30 clamp).
    // Signed saturate to INT32 before adding delayed_c.
    //
    // Clamp policy (matches simx AG_TCU_EXP_MAX/MIN):
    //   exp > +30 → early saturation (shift_amt clamped to 30, saturates below)
    //   exp < -31 → flush to zero    (shift_amt clamped to 31, result ≈ 0)
    //
    // Critical path: barrel-shift → comparators → MUX → 32-bit adder
    // This fits within the existing ACC_LATENCY = 1 pipeline stage.
    // ---------------------------------------------------------------------------
    wire is_rshift = delayed_exp[EXP_TOTAL-1]; // sign bit of signed EXP_TOTAL-bit exp
    // Clamp to valid shift range before extracting 5-bit shift amount.
    wire exp_overflow  = !is_rshift && ($signed(delayed_exp) > $signed(EXP_TOTAL'(30)));
    wire exp_underflow =  is_rshift && ($signed(delayed_exp) < $signed(EXP_TOTAL'(-31)));
    // Extract 5-bit shift amount: abs(delayed_exp), clamped to [0,31].
    wire [4:0] shift_amt = exp_overflow  ? 5'd30
                         : exp_underflow ? 5'd31
                         : is_rshift     ? 5'($signed(-delayed_exp))
                         :                 5'($signed(delayed_exp));

    wire signed [ALIGNED_W-1:0] partial_aligned =
        is_rshift ? (ALIGNED_W'($signed(red_in[LEVELS][0])) >>> shift_amt)
                  : (ALIGNED_W'($signed(red_in[LEVELS][0])) <<< shift_amt);

    // Signed INT32 saturation
    localparam signed [ALIGNED_W-1:0] INT32_MAX = ALIGNED_W'(32'sh7FFF_FFFF);
    localparam signed [ALIGNED_W-1:0] INT32_MIN = ALIGNED_W'(32'sh8000_0000);

    wire overflow_pos = ($signed(partial_aligned) > $signed(INT32_MAX));
    wire overflow_neg = ($signed(partial_aligned) < $signed(INT32_MIN));

    wire [31:0] partial_sat =
        overflow_pos ? 32'h7FFF_FFFF :
        overflow_neg ? 32'h8000_0000 :
        partial_aligned[31:0];

    // ---------------------------------------------------------------------------
    // Final accumulation — reuses existing pipe_acc structure
    // ---------------------------------------------------------------------------
    wire [31:0] result;

    wire [31:0] acc = partial_sat + delayed_c;
    VX_pipe_register #(
        .DATAW (32),
        .DEPTH (1)
    ) pipe_acc (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .data_in  (acc),
        .data_out (result)
    );

`ifdef XLEN_64
    assign d_val = {32'hffffffff, result};
`else
    assign d_val = result;
`endif

endmodule
