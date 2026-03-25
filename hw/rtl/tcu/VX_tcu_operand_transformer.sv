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
//                              Phase C: META_BITS/LOG2_GROUP_SIZE parameterization
//
// Responsibilities:
//   - Per-warp E8M0 scale context management (VX_tcu_scale_ctx register file)
//   - Per-warp metadata context management (VX_tcu_micro_ctx register file)
//   - LDSCALE:  write scale_a/scale_b to scale_ctx
//   - LDMICRO:  write per-group metadata bits to micro_ctx
//   - LDTILE:   NOP (zero-gate rs1/rs2/rs3 entering FEDP)
//   - WMMA INT (fmt_s[3]=1 OR fmt_s==TCU_MX9_ID):
//       flatten INT8 using micro_ctx → saturate(INT8 << decode_meta(meta, fmt_s)) → INT8
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
    parameter PIPE_LATENCY_INT = 6,  // VX_tcu_int: FEDP_LATENCY(5) + 1(mdata) = 6
    parameter META_BITS        = 1,  // bits per ctx entry (format-agnostic); default=1 → Phase A identical
    parameter LOG2_GROUP_SIZE  = 1   // default=1 → GROUP_SIZE=2 (pair-shared, MX9 behavior)
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
    wire is_flat_in    = (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_FLAT);
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
    // Metadata context — per-warp, per-thread, per-group bits
    // Phase C: META_BITS-wide per ctx entry, N_CTX entries per thread
    //   N_CTX = (XLEN/8) >> LOG2_GROUP_SIZE  (default=2, pair-shared)
    //   CTX_W = N_CTX * META_BITS            (default=2 bits → Phase A identical)
    // -------------------------------------------------------------------------
    localparam N_BYTES = `XLEN / 8;
    localparam N_CTX   = N_BYTES >> LOG2_GROUP_SIZE;
    localparam CTX_W   = N_CTX * META_BITS;

    wire [`NUM_THREADS-1:0][CTX_W-1:0] rd_meta_a, rd_meta_b;

    wire [`NUM_THREADS-1:0][CTX_W-1:0] wr_meta_a_w, wr_meta_b_w;
    for (genvar t = 0; t < `NUM_THREADS; t++) begin : g_meta_wr
        assign wr_meta_a_w[t] = execute_if_in.data.rs1_data[t][CTX_W-1:0];
        assign wr_meta_b_w[t] = execute_if_in.data.rs2_data[t][CTX_W-1:0];
    end

    VX_tcu_micro_ctx #(
        .NUM_WARPS       (`NUM_WARPS),
        .META_BITS       (META_BITS),
        .LOG2_GROUP_SIZE (LOG2_GROUP_SIZE)
    ) micro_ctx (
        .clk        (clk),
        .reset      (reset),
        // Write on LDMICRO fire at input
        .wr_valid   (execute_if_in.valid && execute_if_in.ready && is_ldmicro_in),
        .wr_wid     (execute_if_in.data.wid),
        .wr_meta_a  (wr_meta_a_w),
        .wr_meta_b  (wr_meta_b_w),
        // Read combinationally by current wid
        .rd_wid     (execute_if_in.data.wid),
        .rd_meta_a  (rd_meta_a),
        .rd_meta_b  (rd_meta_b)
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
    // INT8 flatten with saturation (INT path WMMA / FLAT)
    //   flat = saturate_int8(int8_val << effective_shift)
    //   effective_shift = decode_meta(meta_entry, fmt_s)
    //   For shift=0: passthrough. For META_BITS=1 (default): bit-identical to Phase A/10.
    //
    // Overflow detection (general N-bit shift):
    //   Sign-extend int8_in to FLAT_W = 8+MAX_SHIFT bits, left-shift by shift.
    //   Bits [FLAT_W-1:7] must all be equal (all-0 or all-1); otherwise saturate.
    //   Saturation uses the original sign of int8_in (not the shifted result).
    // -------------------------------------------------------------------------
    localparam MAX_SHIFT = (1 << META_BITS) - 1;  // maximum effective shift (conservative)
    localparam FLAT_W    = 8 + MAX_SHIFT;          // working width; default(META_BITS=1): 9

    function automatic logic [7:0] flatten_int8_byte(
        input logic [7:0]            int8_in,
        input logic [META_BITS-1:0]  shift   // effective shift: value = int8 × 2^shift
    );
        logic [FLAT_W-1:0]  wide;
        logic [FLAT_W-1:0]  shifted;
        logic [MAX_SHIFT:0] upper;      // bits [FLAT_W-1:7] of shifted
        logic               no_overflow;
        if (shift == '0) return int8_in;                         // shift=0: passthrough
        wide    = {{MAX_SHIFT{int8_in[7]}}, int8_in};            // sign-extend
        shifted = wide << shift;                                 // logical left shift
        upper   = shifted[FLAT_W-1:7];                          // sign-check region
        no_overflow = (&upper) | (~|upper);                      // all-same → fits INT8
        if (!no_overflow) return int8_in[7] ? 8'h80 : 8'h7F;    // saturate by original sign
        return shifted[7:0];
    endfunction

    // fmt_s 기반 metadata 해석 → effective shift 반환
    // 현재(Phase C): passthrough (META_BITS=1, MX9만 존재 → shift = meta 전체)
    // 미래 3-level 포맷 추가 시 이 함수에 case 한 줄만 추가
    function automatic logic [META_BITS-1:0] decode_meta(
        input logic [META_BITS-1:0] meta,
        /* verilator lint_off UNUSED */
        input logic [3:0]           fmt_s
        /* verilator lint_on UNUSED */
    );
        // fmt_s retained for future 3-level format support.
        // Future: case (fmt_s) TCU_3LEVEL_ID: return meta[...] + meta[...]; endcase
        return meta;
    endfunction

    // Flatten a word (N_BYTES × INT8) using per-group metadata
    //   meta  : CTX_W bits = N_CTX × META_BITS (LSB-first, ctx[0] at bits[META_BITS-1:0])
    //   fmt_s : used by decode_meta() for format-specific interpretation
    //
    // 2D packed array casting: meta_arr[i] = meta[i*META_BITS +: META_BITS]
    // byte b → ctx_index = b >> LOG2_GROUP_SIZE (wire routing after loop unroll)
    // Default (META_BITS=1, LOG2_GROUP_SIZE=1): bit-identical to Phase A/10.
    function automatic logic [N_BYTES*8-1:0] flatten_int8_word(
        input logic [N_BYTES*8-1:0]  word,
        input logic [CTX_W-1:0]      meta,
        input logic [3:0]            fmt_s
    );
        logic [N_BYTES*8-1:0]             result;
        logic [N_CTX-1:0][META_BITS-1:0]  meta_arr;
        meta_arr = meta;  // 1D → 2D 캐스팅: meta_arr[i] = meta[i*META_BITS +: META_BITS]
        for (integer b = 0; b < N_BYTES; b++) begin
            logic [META_BITS-1:0] eff_shift;
            eff_shift = decode_meta(meta_arr[b >> LOG2_GROUP_SIZE], fmt_s);
            result[b*8 +: 8] = flatten_int8_byte(word[b*8 +: 8], eff_shift);
        end
        return result;
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
                    execute_if_in.data.rs1_data[t], rd_meta_a[t],
                    execute_if_in.data.op_args.tcu.fmt_s);
                ot_data_next.rs2_data[t] = flatten_int8_word(
                    execute_if_in.data.rs2_data[t], rd_meta_b[t],
                    execute_if_in.data.op_args.tcu.fmt_s);
            end
            // Patch: fmt_s → TCU_I8_ID so pe_switch routes to INT path
            ot_data_next.op_args.tcu.fmt_s = 4'(TCU_I8_ID);
        end else if (do_flatten_int) begin
            // Plain INT8 WMMA: apply micro_ctx flatten (meta=0 = passthrough if no LDMICRO)
            for (integer t = 0; t < `NUM_THREADS; t++) begin
                ot_data_next.rs1_data[t] = flatten_int8_word(
                    execute_if_in.data.rs1_data[t], rd_meta_a[t],
                    execute_if_in.data.op_args.tcu.fmt_s);
                ot_data_next.rs2_data[t] = flatten_int8_word(
                    execute_if_in.data.rs2_data[t], rd_meta_b[t],
                    execute_if_in.data.op_args.tcu.fmt_s);
            end
        end
        else if (is_flat_in) begin
            // FLAT: apply metadata flatten to rs1_data, route to INT path
            // tile_type[0]=0 → A tile (use rd_meta_a), tile_type[0]=1 → B tile (use rd_meta_b)
            for (integer t = 0; t < `NUM_THREADS; t++) begin
                ot_data_next.rs1_data[t] = flatten_int8_word(
                    execute_if_in.data.rs1_data[t],
                    execute_if_in.data.op_args.tcu.tile_type[0] ? rd_meta_b[t] : rd_meta_a[t],
                    execute_if_in.data.op_args.tcu.fmt_s);
            end
            // Route to INT path (pe_switch uses fmt_s[3]=1)
            ot_data_next.op_args.tcu.fmt_s = 4'(TCU_I8_ID);
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
