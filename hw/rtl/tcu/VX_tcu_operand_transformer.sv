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

// VX_tcu_operand_transformer — 1-cycle registered OT stage (before pe_switch)
//
// Per instruction:
//   LDSCALE  : write E8M0 scale_a/b → scale_ctx; zero-gate operands (NOP to FEDP)
//   LDMICRO  : write per-group metadata → micro_ctx; zero-gate operands
//   LDTILE   : zero-gate operands
//   WMMA MX9 : Option-C re-quantization + fmt_s→I8 patch → INT path
//   WMMA FP/INT: passthrough (scale_A/B forwarded in payload)
//   FLAT     : flatten INT8 tile with micro_ctx shift → fmt_s→I8 patch → INT path
//
// Hazard: stall LDSCALE/LDTILE/LDMICRO while same warp has in-flight INT WMMA uops.

`include "VX_define.vh"

module VX_tcu_operand_transformer import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter PIPE_LATENCY_INT = 6,
    parameter SCALE_BITS        = 1,
    parameter LOG2_SCALE_GROUP  = 1
) (
    input  wire clk,
    input  wire reset,

    VX_execute_if.slave  execute_if_in,
    VX_execute_if.master execute_if_out,

    input  wire                    fedp_enable,
    input  wire                    result_fire,
    input  wire [NW_WIDTH-1:0]     result_wid
);

    // -------------------------------------------------------------------------
    // Instruction decode
    // -------------------------------------------------------------------------
    wire is_ldscale_in = (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_LDSCALE);
    wire is_ldtile_in  = (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_LDTILE);
    wire is_ldmicro_in = (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_LDMICRO);
    wire is_flat_in    = (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_FLAT);
    wire is_nop_in     = is_ldscale_in || is_ldtile_in || is_ldmicro_in;

    wire do_mx9 = !is_nop_in && !is_flat_in
               && (execute_if_in.data.op_args.tcu.fmt_s == 4'(TCU_MX9_ID))
               && (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_WMMA);

    wire do_3level = !is_nop_in && !is_flat_in
                  && (execute_if_in.data.op_args.tcu.fmt_s == 4'(TCU_3LEVEL_ID))
                  && (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_WMMA);

    // -------------------------------------------------------------------------
    // Scale context (per-warp E8M0 registers)
    // -------------------------------------------------------------------------
    wire [TCU_TC_M*TCU_EXP_BITS-1:0] rd_scale_A;
    wire [TCU_TC_N*TCU_EXP_BITS-1:0] rd_scale_B;

    VX_tcu_scale_ctx #(.NUM_WARPS(`NUM_WARPS)) scale_ctx (
        .clk        (clk),
        .reset      (reset),
        .wr_valid   (execute_if_in.valid && execute_if_in.ready && is_ldscale_in),
        .wr_wid     (execute_if_in.data.wid),
        .wr_scale_A (execute_if_in.data.rs1_data[0][TCU_TC_M*TCU_EXP_BITS-1:0]),
        .wr_scale_B (execute_if_in.data.rs1_data[0][TCU_TC_M*TCU_EXP_BITS +: TCU_TC_N*TCU_EXP_BITS]),
        .rd_wid     (execute_if_in.data.wid),
        .rd_scale_A (rd_scale_A),
        .rd_scale_B (rd_scale_B)
    );

    // -------------------------------------------------------------------------
    // Metadata context (per-warp, per-thread, per-group bits)
    //   N_CTX = (XLEN/8) >> LOG2_SCALE_GROUP  entries per thread (default=2, pair-shared)
    //   CTX_W = N_CTX * SCALE_BITS            bits per thread
    // -------------------------------------------------------------------------
    localparam N_BYTES = `XLEN / 8;
    localparam N_CTX   = N_BYTES >> LOG2_SCALE_GROUP;
    localparam CTX_W   = N_CTX * SCALE_BITS;

    wire [`NUM_THREADS-1:0][CTX_W-1:0] rd_meta_a, rd_meta_b;
    wire [`NUM_THREADS-1:0][CTX_W-1:0] wr_meta_a_w, wr_meta_b_w;

    for (genvar t = 0; t < `NUM_THREADS; t++) begin : g_meta_wr
        assign wr_meta_a_w[t] = execute_if_in.data.rs1_data[t][CTX_W-1:0];
        assign wr_meta_b_w[t] = execute_if_in.data.rs2_data[t][CTX_W-1:0];
    end

    VX_tcu_micro_ctx #(
        .NUM_WARPS       (`NUM_WARPS),
        .SCALE_BITS       (SCALE_BITS),
        .LOG2_SCALE_GROUP (LOG2_SCALE_GROUP)
    ) micro_ctx (
        .clk        (clk),
        .reset      (reset),
        .wr_valid   (execute_if_in.valid && execute_if_in.ready && is_ldmicro_in),
        .wr_wid     (execute_if_in.data.wid),
        .wr_meta_a  (wr_meta_a_w),
        .wr_meta_b  (wr_meta_b_w),
        .rd_wid     (execute_if_in.data.wid),
        .rd_meta_a  (rd_meta_a),
        .rd_meta_b  (rd_meta_b)
    );

    // -------------------------------------------------------------------------
    // LDSCALE/LDTILE/LDMICRO delay pipe — tracks NOP tokens through INT FEDP
    // Depth = PIPE_LATENCY_INT; shift-enable matches VX_tcu_int's fedp_delay_pipe.
    // -------------------------------------------------------------------------
    localparam DELAY_DEPTH = PIPE_LATENCY_INT;

    wire is_nop_out = (execute_if_out.data.op_args.tcu.tcu_op == TCU_OP_LDSCALE)
                   || (execute_if_out.data.op_args.tcu.tcu_op == TCU_OP_LDTILE)
                   || (execute_if_out.data.op_args.tcu.tcu_op == TCU_OP_LDMICRO);

    wire execute_fire_out = execute_if_out.valid && execute_if_out.ready;
    wire is_fp_out        = !execute_if_out.data.op_args.tcu.fmt_s[3];

    reg [DELAY_DEPTH-1:0] ldscale_delay_pipe;
    always @(posedge clk) begin
        if (reset) begin
            ldscale_delay_pipe <= '0;
        end else begin
            if (fedp_enable)       ldscale_delay_pipe <= ldscale_delay_pipe >> 1;
            if (execute_fire_out)  ldscale_delay_pipe[DELAY_DEPTH-1] <= is_nop_out;
        end
    end
    wire result_is_ldscale = ldscale_delay_pipe[0];

    // -------------------------------------------------------------------------
    // Per-warp in-flight INT WMMA counter (INT path only; fmt_s[3]=1 after OT patch)
    // -------------------------------------------------------------------------
    localparam INFLIGHT_W = $clog2(TCU_UOPS + 1);
    reg [INFLIGHT_W-1:0] wmma_inflight [`NUM_WARPS];

    wire wmma_dispatched = execute_fire_out && !is_nop_out && !is_fp_out;
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

    wire ldscale_hazard = is_nop_in && (wmma_inflight[execute_if_in.data.wid] != '0);

    // -------------------------------------------------------------------------
    // INT8 flatten with saturation: flat = saturate_int8(int8_val << shift)
    //   Overflow check: sign-extend to FLAT_W bits, verify bits[FLAT_W-1:7] all-same.
    // -------------------------------------------------------------------------
    localparam MAX_SHIFT = (1 << SCALE_BITS) - 1;
    localparam FLAT_W    = 8 + MAX_SHIFT;

    function automatic logic [7:0] flatten_int8_byte(
        input logic [7:0]           int8_in,
        input logic [SCALE_BITS-1:0] shift
    );
        logic [FLAT_W-1:0]  wide, shifted;
        logic [MAX_SHIFT:0] upper;
        if (shift == '0) return int8_in;
        wide    = {{MAX_SHIFT{int8_in[7]}}, int8_in};
        shifted = wide << shift;
        upper   = shifted[FLAT_W-1:7];
        if ((&upper) | (~|upper)) return shifted[7:0];
        return int8_in[7] ? 8'h80 : 8'h7F;  // saturate by original sign
    endfunction

    function automatic logic [N_BYTES*8-1:0] flatten_int8_word(
        input logic [N_BYTES*8-1:0] word,
        input logic [CTX_W-1:0]     meta,
        input logic [3:0]           fmt_s
    );
        logic [N_BYTES*8-1:0]            result;
        logic [N_CTX-1:0][SCALE_BITS-1:0] meta_arr;
        meta_arr = meta;
        for (integer b = 0; b < N_BYTES; b++)
            result[b*8 +: 8] = flatten_int8_byte(word[b*8 +: 8], meta_arr[b >> LOG2_SCALE_GROUP]);
        return result;
    endfunction

    // -------------------------------------------------------------------------
    // MX9 Option-C re-quantization (S=4, no saturation)
    //   Q = 128 + frac (implicit leading-1); flat = Q >> (2 - mexp_bit)
    //   mexp=0 → Q>>2 ∈ [32,63];  mexp=1 → Q>>1 ∈ [64,127]  (never overflows INT8)
    // -------------------------------------------------------------------------
    function automatic logic [7:0] mx9_requant_byte(
        input logic [7:0] mantissa_byte,
        input logic       mexp_bit
    );
        logic [7:0] Q;
        logic [6:0] flat_mag;
        Q        = {1'b1, mantissa_byte[6:0]};
        flat_mag = mexp_bit ? Q[7:1] : Q[7:2];
        if (mantissa_byte[7] == 1'b0) return {1'b0, flat_mag};
        else                          return ~{1'b0, flat_mag} + 8'd1;
    endfunction

    // -------------------------------------------------------------------------
    // 1-cycle registered pipeline stage
    // -------------------------------------------------------------------------
    reg       ot_valid;
    tcu_exe_t ot_data_r;

    wire ot_stall = ot_valid && !execute_if_out.ready;

    assign execute_if_in.ready  = !ot_stall && !ldscale_hazard;
    assign execute_if_out.valid = ot_valid;
    assign execute_if_out.data  = ot_data_r;

    tcu_exe_t ot_data_next;
    logic     mexp_bit;  // module-scope scratch to avoid loop-internal logic decl

    always_comb begin
        mexp_bit     = 1'b0;
        ot_data_next = execute_if_in.data;
        ot_data_next.op_args.tcu.scale_A = rd_scale_A;
        ot_data_next.op_args.tcu.scale_B = rd_scale_B;

        if (is_nop_in) begin
            for (integer t = 0; t < `NUM_THREADS; t++) begin
                ot_data_next.rs1_data[t] = '0;
                ot_data_next.rs2_data[t] = '0;
                ot_data_next.rs3_data[t] = '0;
            end
        end else if (is_flat_in) begin
            for (integer t = 0; t < `NUM_THREADS; t++)
                ot_data_next.rs1_data[t] = flatten_int8_word(
                    execute_if_in.data.rs1_data[t],
                    execute_if_in.data.op_args.tcu.tile_type[0] ? rd_meta_b[t] : rd_meta_a[t],
                    execute_if_in.data.op_args.tcu.fmt_s);
            ot_data_next.op_args.tcu.fmt_s = 4'(TCU_I8_ID);
        end else if (do_mx9) begin
            // With SCALE_BITS=2: LDMICRO stores {0,mexp1, 0,mexp0} in 4-bit CTX.
            // pair0 mexp = bit[0], pair1 mexp = bit[SCALE_BITS] (= bit[2]).
            for (integer t = 0; t < `NUM_THREADS; t++) begin
                for (integer b = 0; b < 4; b++) begin
                    mexp_bit = rd_meta_a[t][(b >= 2) ? SCALE_BITS : 0];
                    ot_data_next.rs1_data[t][b*8 +: 8] = mx9_requant_byte(
                        execute_if_in.data.rs1_data[t][b*8 +: 8], mexp_bit);
                    mexp_bit = rd_meta_b[t][(b >= 2) ? SCALE_BITS : 0];
                    ot_data_next.rs2_data[t][b*8 +: 8] = mx9_requant_byte(
                        execute_if_in.data.rs2_data[t][b*8 +: 8], mexp_bit);
                end
            end
            // S²=16 correction: subtract 5 from each scale_A[i] and scale_B[j]
            // so exp_total[i][j] = (scale_A[i]-5) + (scale_B[j]-5) - 254 = orig-10
            for (integer r = 0; r < TCU_TC_M; r++)
                ot_data_next.op_args.tcu.scale_A[r*TCU_EXP_BITS +: TCU_EXP_BITS] =
                    rd_scale_A[r*TCU_EXP_BITS +: TCU_EXP_BITS] - TCU_EXP_BITS'(5);
            for (integer c = 0; c < TCU_TC_N; c++)
                ot_data_next.op_args.tcu.scale_B[c*TCU_EXP_BITS +: TCU_EXP_BITS] =
                    rd_scale_B[c*TCU_EXP_BITS +: TCU_EXP_BITS] - TCU_EXP_BITS'(5);
            ot_data_next.op_args.tcu.fmt_s = 4'(TCU_I8_ID);  // fmt_s[3]=0 → 1: INT path
        end else if (do_3level) begin
            // 3-level hierarchical scale: micro_ctx holds pre-computed combined shift (L2+L3)
            // as a 2-bit value per pair (meta_arr[0]=pair0, meta_arr[1]=pair1, range 0-2).
            // flatten_int8_word applies saturate_int8(byte << combined_shift) per byte.
            for (integer t = 0; t < `NUM_THREADS; t++) begin
                ot_data_next.rs1_data[t] = flatten_int8_word(
                    execute_if_in.data.rs1_data[t], rd_meta_a[t],
                    execute_if_in.data.op_args.tcu.fmt_s);
                ot_data_next.rs2_data[t] = flatten_int8_word(
                    execute_if_in.data.rs2_data[t], rd_meta_b[t],
                    execute_if_in.data.op_args.tcu.fmt_s);
            end
            ot_data_next.op_args.tcu.fmt_s = 4'(TCU_I8_ID);
        end
        // Other WMMA (INT/FP): passthrough
    end

    always @(posedge clk) begin
        if (reset) begin
            ot_valid <= 1'b0;
        end else if (!ot_stall) begin
            ot_valid <= execute_if_in.valid && !ldscale_hazard;
            if (execute_if_in.valid && !ldscale_hazard)
                ot_data_r <= ot_data_next;
        end
    end

endmodule
