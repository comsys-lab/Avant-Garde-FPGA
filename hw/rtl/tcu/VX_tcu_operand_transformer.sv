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

// AG-TCU Operand Transformer — Phase 10 true-INT8 MX9 redesign
//
// Responsibilities:
//   - Per-warp E8M0 scale context management (VX_tcu_scale_ctx register file)
//   - Per-warp micro-exp context management (VX_tcu_micro_ctx register file)
//   - LDSCALE:  write scale_a/scale_b to scale_ctx
//   - LDMICRO:  write pair-shared micro_exp bits to micro_ctx
//   - LDTILE:   NOP (zero-gate rs1/rs2/rs3 entering FEDP)
//   - WMMA INT (fmt_s[3]=1 OR fmt_s==TCU_MX9_ID):
//       flatten INT8 using micro_ctx → saturate(INT8 << mexp) → INT8
//       MX9: also patch fmt_s to TCU_I8_ID so pe_switch routes to INT path
//   - WMMA FP  (fmt_s[3]=0, not MX9): passthrough (BF16/FP16/FP32)
//   - Hazard: stall LDSCALE/LDTILE/LDMICRO if same warp has in-flight INT WMMA uops
//
// Flatten algorithm (INT path WMMA only):
//   Each byte is a standard INT8 (2's complement).
//   pair0 (bytes 0,1) share micro_exp bit[0] from micro_ctx.
//   pair1 (bytes 2,3) share micro_exp bit[1] from micro_ctx.
//   flat = saturate_int8(int8_val << mexp_bit)
//   Special: INT8_MIN (-128) << 1 → -256 → saturated to -128
//            INT8(64) << 1 → 128 → saturated to +127
//
// Pipeline position (before pe_switch):
//   [VX_tcu_operand_transformer] → pe_switch → {VX_tcu_fp, VX_tcu_int}
//
// Interface:
//   execute_if_in  — from dispatch_unit (per_block_execute_if, before pe_switch)
//   execute_if_out — to pe_switch
//
// Timing (1-cycle registered):
//   Cycle 0 (combinational): scale_ctx.read(wid) → exp_total; micro_ctx.read(wid) → mexp
//   Cycle 1 (registered):    execute_if_out.data latched with modified operands
//
// Feedback ports (INT path only):
//   fedp_enable / result_fire / result_wid  — from VX_tcu_int
//
// EXT_AG_TCU_ENABLE inactive: not instantiated (bypassed in VX_tcu_unit).

`include "VX_define.vh"

module VX_tcu_operand_transformer import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter PIPE_LATENCY_INT = 6   // VX_tcu_int: FEDP_LATENCY(5) + 1(mdata) = 6
) (
    input  wire clk,
    input  wire reset,

    // Input: from dispatch_unit (before pe_switch, handles INT and FP paths)
    VX_execute_if.slave  execute_if_in,

    // Output: to pe_switch
    VX_execute_if.master execute_if_out,

    // Feedback from VX_tcu_int — INT path wmma_inflight and ldscale_delay_pipe
    input  wire                    fedp_enable,    // ~result_if.valid || result_if.ready
    input  wire                    result_fire,    // result_if.valid && result_if.ready
    input  wire [NW_WIDTH-1:0]     result_wid      // from mdata_queue_dout in VX_tcu_int
);

    // -------------------------------------------------------------------------
    // Instruction type decode (on input side)
    // -------------------------------------------------------------------------
    wire is_ldscale_in = (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_LDSCALE);
    wire is_ldtile_in  = (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_LDTILE);
    wire is_ldmicro_in = (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_LDMICRO);
    wire is_nop_in     = is_ldscale_in || is_ldtile_in || is_ldmicro_in;

    // -------------------------------------------------------------------------
    // Scale context — per-warp E8M0 registers
    // -------------------------------------------------------------------------
    wire [TCU_EXP_BITS-1:0] rd_scale_a, rd_scale_b;

    VX_tcu_scale_ctx #(.NUM_WARPS(`NUM_WARPS)) scale_ctx (
        .clk        (clk),
        .reset      (reset),
        // Write on LDSCALE fire at input (before the 1-cycle register)
        .wr_valid   (execute_if_in.valid && execute_if_in.ready && is_ldscale_in),
        .wr_wid     (execute_if_in.data.wid),
        .wr_scale_a (execute_if_in.data.rs1_data[0][TCU_EXP_BITS-1:0]),
        .wr_scale_b (execute_if_in.data.rs1_data[0][2*TCU_EXP_BITS-1:TCU_EXP_BITS]),
        // Read combinationally by current wid (for exp_total calculation)
        .rd_wid     (execute_if_in.data.wid),
        .rd_scale_a (rd_scale_a),
        .rd_scale_b (rd_scale_b)
    );

    // exp_total = scale_a + scale_b - 2×bias → signed (E8M0, Phase 5)
    wire signed [TCU_EXP_TOTAL-1:0] exp_total_comb =
          $signed(TCU_EXP_TOTAL'({2'b0, rd_scale_a}))
        + $signed(TCU_EXP_TOTAL'({2'b0, rd_scale_b}))
        - $signed(TCU_EXP_TOTAL'(2 * TCU_EXP_BIAS));

    // -------------------------------------------------------------------------
    // Micro-exp context — per-warp, per-thread pair-shared micro_exp bits
    // -------------------------------------------------------------------------
    wire [`NUM_THREADS-1:0][1:0] rd_mexp_a, rd_mexp_b;

    wire [`NUM_THREADS-1:0][1:0] wr_mexp_a_w, wr_mexp_b_w;
    for (genvar t = 0; t < `NUM_THREADS; t++) begin : g_mexp_wr
        assign wr_mexp_a_w[t] = execute_if_in.data.rs1_data[t][1:0];
        assign wr_mexp_b_w[t] = execute_if_in.data.rs2_data[t][1:0];
    end

    VX_tcu_micro_ctx #(.NUM_WARPS(`NUM_WARPS)) micro_ctx (
        .clk        (clk),
        .reset      (reset),
        // Write on LDMICRO fire at input
        .wr_valid   (execute_if_in.valid && execute_if_in.ready && is_ldmicro_in),
        .wr_wid     (execute_if_in.data.wid),
        .wr_mexp_a  (wr_mexp_a_w),
        .wr_mexp_b  (wr_mexp_b_w),
        // Read combinationally by current wid
        .rd_wid     (execute_if_in.data.wid),
        .rd_mexp_a  (rd_mexp_a),
        .rd_mexp_b  (rd_mexp_b)
    );

    // -------------------------------------------------------------------------
    // LDSCALE/LDTILE/LDMICRO delay pipe — tracks NOP tokens through INT FEDP.
    // Shift enable: fedp_enable (same gating as VX_tcu_int's fedp_delay_pipe).
    // Depth = PIPE_LATENCY_INT (VX_tcu_int: FEDP_LATENCY + mdata = 6).
    // -------------------------------------------------------------------------
    localparam DELAY_DEPTH = PIPE_LATENCY_INT;

    // Track is_nop at the output side (after the 1-cycle register)
    wire is_nop_out = (execute_if_out.data.op_args.tcu.tcu_op == TCU_OP_LDSCALE)
                   || (execute_if_out.data.op_args.tcu.tcu_op == TCU_OP_LDTILE)
                   || (execute_if_out.data.op_args.tcu.tcu_op == TCU_OP_LDMICRO);

    wire execute_fire_out = execute_if_out.valid && execute_if_out.ready;
    wire is_fp_out  = !execute_if_out.data.op_args.tcu.fmt_s[3];  // FP when fmt_s[3]=0

    reg [DELAY_DEPTH-1:0] ldscale_delay_pipe;
    always @(posedge clk) begin
        if (reset) begin
            ldscale_delay_pipe <= '0;
        end else begin
            if (fedp_enable) ldscale_delay_pipe <= ldscale_delay_pipe >> 1;
            if (execute_fire_out)
                ldscale_delay_pipe[DELAY_DEPTH-1] <= is_nop_out;
        end
    end
    wire result_is_ldscale = ldscale_delay_pipe[0];

    // -------------------------------------------------------------------------
    // Per-warp in-flight WMMA uop counter (INT path only, fmt_s[3]=1)
    // FP WMMA not tracked: exp_total already captured in OT stage.
    // Note: after OT patches MX9 → I8 (fmt_s[3]=1), MX9 WMMA is also counted.
    // -------------------------------------------------------------------------
    localparam INFLIGHT_W = $clog2(TCU_UOPS + 1);
    reg [INFLIGHT_W-1:0] wmma_inflight [`NUM_WARPS];

    wire wmma_dispatched = execute_fire_out && !is_nop_out && !is_fp_out;  // INT (fmt_s[3]=1)
    wire wmma_completed  = result_fire && !result_is_ldscale;

    always @(posedge clk) begin
        if (reset) begin
            for (integer w = 0; w < `NUM_WARPS; w++) wmma_inflight[w] <= '0;
        end else begin
            for (integer w = 0; w < `NUM_WARPS; w++) begin
                logic inc_w, dec_w;
                inc_w = wmma_dispatched && (execute_if_out.data.wid == NW_WIDTH'(w));
                dec_w = wmma_completed  && (result_wid              == NW_WIDTH'(w));
                if      (inc_w && !dec_w) wmma_inflight[w] <= wmma_inflight[w] + INFLIGHT_W'(1);
                else if (!inc_w && dec_w) wmma_inflight[w] <= wmma_inflight[w] - INFLIGHT_W'(1);
            end
        end
    end

    // Hazard: stall LDSCALE/LDTILE/LDMICRO if same warp has in-flight INT WMMA uops
    wire ldscale_hazard = is_nop_in && (wmma_inflight[execute_if_in.data.wid] != '0);

    // -------------------------------------------------------------------------
    // INT8 flatten with saturation (INT path WMMA only)
    //   flat = saturate_int8(int8_val << mexp)
    //   For mexp=0: no change (passthrough).
    //   For mexp=1: left-shift by 1 with INT8 saturation.
    //     overflow_pos: int8_val[7]=0, int8_val[6]=1  → clamp to +127
    //     overflow_neg: int8_val[7]=1, int8_val[6]=0  → clamp to -128
    // -------------------------------------------------------------------------
    function automatic logic [7:0] flatten_int8_byte(
        input logic [7:0] int8_in,
        input logic       mexp
    );
        logic overflow_pos, overflow_neg;
        if (!mexp) return int8_in;                         // mexp=0: passthrough
        overflow_pos = (int8_in[7] == 1'b0) && (int8_in[6] == 1'b1);  // +overflow
        overflow_neg = (int8_in[7] == 1'b1) && (int8_in[6] == 1'b0);  // -overflow
        if (overflow_pos) return 8'h7F;
        if (overflow_neg) return 8'h80;
        return {int8_in[6:0], 1'b0};  // << 1
    endfunction

    // Flatten a 32-bit word (4 INT8 bytes, 2 pairs)
    //   mexp[0]: pair0 (bytes 0,1), mexp[1]: pair1 (bytes 2,3)
    function automatic logic [31:0] flatten_int8_word(
        input logic [31:0] word,
        input logic [1:0]  mexp
    );
        return {flatten_int8_byte(word[31:24], mexp[1]),
                flatten_int8_byte(word[23:16], mexp[1]),
                flatten_int8_byte(word[15:8],  mexp[0]),
                flatten_int8_byte(word[7:0],   mexp[0])};
    endfunction

    // INT WMMA trigger (fmt_s[3]=1, tcu_op=WMMA, not nop)
    wire do_flatten_int = !is_nop_in
        && execute_if_in.data.op_args.tcu.fmt_s[3]
        && (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_WMMA);

    // MX9 WMMA trigger (fmt_s==TCU_MX9_ID, fmt_s[3]=0, tcu_op=WMMA, not nop)
    // OT flattens INT8 using micro_ctx, then patches fmt_s → TCU_I8_ID
    wire do_flatten_mx9 = !is_nop_in
        && (execute_if_in.data.op_args.tcu.fmt_s == 4'(TCU_MX9_ID))
        && (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_WMMA);

    // -------------------------------------------------------------------------
    // 1-cycle registered pipeline stage (single-entry buffer)
    // -------------------------------------------------------------------------
    reg                 ot_valid;
    tcu_exe_t           ot_data_r;

    wire ot_stall = ot_valid && !execute_if_out.ready;

    assign execute_if_in.ready  = !ot_stall && !ldscale_hazard;
    assign execute_if_out.valid = ot_valid;
    assign execute_if_out.data  = ot_data_r;

    // -------------------------------------------------------------------------
    // Combinational next-value computation
    // -------------------------------------------------------------------------
    tcu_exe_t ot_data_next;
    always_comb begin
        ot_data_next = execute_if_in.data;
        // Insert exp_total into the tcu_args payload
        ot_data_next.op_args.tcu.exp_total = exp_total_comb;

        if (is_nop_in) begin
            // Zero-gate operands for LDSCALE/LDTILE/LDMICRO (FEDP treats as NOP)
            for (integer t = 0; t < `NUM_THREADS; t++) begin
                ot_data_next.rs1_data[t] = '0;
                ot_data_next.rs2_data[t] = '0;
                ot_data_next.rs3_data[t] = '0;
            end
        end else if (do_flatten_mx9) begin
            // MX9 INT WMMA: flatten INT8 using micro_ctx, patch fmt_s → I8
            for (integer t = 0; t < `NUM_THREADS; t++) begin
                ot_data_next.rs1_data[t] = flatten_int8_word(
                    execute_if_in.data.rs1_data[t], rd_mexp_a[t]);
                ot_data_next.rs2_data[t] = flatten_int8_word(
                    execute_if_in.data.rs2_data[t], rd_mexp_b[t]);
            end
            // Patch: fmt_s → TCU_I8_ID so pe_switch routes to INT path
            ot_data_next.op_args.tcu.fmt_s = 4'(TCU_I8_ID);
        end else if (do_flatten_int) begin
            // Plain INT8 WMMA: apply micro_ctx flatten (mexp=0 = passthrough if no LDMICRO)
            for (integer t = 0; t < `NUM_THREADS; t++) begin
                ot_data_next.rs1_data[t] = flatten_int8_word(
                    execute_if_in.data.rs1_data[t], rd_mexp_a[t]);
                ot_data_next.rs2_data[t] = flatten_int8_word(
                    execute_if_in.data.rs2_data[t], rd_mexp_b[t]);
            end
        end
        // FP WMMA (BF16/FP16/FP32): passthrough (exp_total already patched above)
    end

    // Build modified data: single NBA from combinational next value
    always @(posedge clk) begin
        if (reset) begin
            ot_valid <= 1'b0;
        end else begin
            if (!ot_stall) begin
                ot_valid <= execute_if_in.valid && !ldscale_hazard;
                if (execute_if_in.valid && !ldscale_hazard) begin
                    ot_data_r <= ot_data_next;
                end
            end
        end
    end

endmodule
