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

// AG-TCU Operand Transformer — Phase 7 independent 1-cycle pipeline stage
//
// Responsibilities:
//   - Per-warp E8M0 scale context management (VX_tcu_scale_ctx register file)
//   - LDSCALE: write scale_a/scale_b to scale_ctx
//   - WMMA:    read scale_ctx → compute signed exp_total → latch to payload
//   - LDTILE:  NOP (zero-gate rs1/rs2/rs3 entering FEDP)
//   - Hazard:  stall LDSCALE/LDTILE if same warp has in-flight WMMA uops
//
// Phase 7 pipeline position:
//   pe_switch → [VX_tcu_operand_transformer] → VX_tcu_int (pure FEDP)
//
// Interface:
//   execute_if_in  — from pe_switch (pe_execute_if[1], INT path)
//   execute_if_out — to VX_tcu_int (op_args.tcu.exp_total filled in)
//
// Timing (1-cycle registered):
//   Cycle 0 (combinational): scale_ctx.read(wid) → exp_total, is_nop, ldscale_hazard
//   Cycle 1 (registered):    execute_if_out.data latched with exp_total + zero-gated operands
//
// Feedback ports (result_fire, result_wid, fedp_enable):
//   VX_tcu_unit connects these from VX_tcu_int's result_if side.
//
// EXT_AG_TCU_ENABLE inactive: not instantiated (bypassed in VX_tcu_unit).

`include "VX_define.vh"

module VX_tcu_operand_transformer import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter PIPE_LATENCY = 5   // = FEDP_LATENCY + 1 (mdata); OT adds 1 on top
) (
    input  wire clk,
    input  wire reset,

    // Input: from pe_switch (INT path)
    VX_execute_if.slave  execute_if_in,

    // Output: to VX_tcu_int (pure compute, exp_total filled in payload)
    VX_execute_if.master execute_if_out,

    // Feedback from VX_tcu_int — for wmma_inflight counter and ldscale_delay_pipe
    input  wire                    fedp_enable,    // ~result_if.valid || result_if.ready
    input  wire                    result_fire,    // result_if.valid && result_if.ready
    input  wire [NW_WIDTH-1:0]     result_wid      // from mdata_queue_dout in VX_tcu_int
);

    // -------------------------------------------------------------------------
    // Instruction type decode (on input side)
    // -------------------------------------------------------------------------
    wire is_ldscale_in = (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_LDSCALE);
    wire is_ldtile_in  = (execute_if_in.data.op_args.tcu.tcu_op == TCU_OP_LDTILE);
    wire is_nop_in     = is_ldscale_in || is_ldtile_in;

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

    // Flatten: scale_a + scale_b - 2×bias → signed exp_total (Phase 5 E8M0)
    wire signed [TCU_EXP_TOTAL-1:0] exp_total_comb =
          $signed(TCU_EXP_TOTAL'({2'b0, rd_scale_a}))
        + $signed(TCU_EXP_TOTAL'({2'b0, rd_scale_b}))
        - $signed(TCU_EXP_TOTAL'(2 * TCU_EXP_BIAS));

    // -------------------------------------------------------------------------
    // LDSCALE/LDTILE delay pipe — tracks NOP tokens through downstream FEDP.
    // Shift enable: fedp_enable (same gating as VX_tcu_int's fedp_delay_pipe).
    // Depth = PIPE_LATENCY (VX_tcu_int internal: FEDP_LATENCY + mdata = 5).
    // execute_fire_out pushes is_nop; result_fire is at pipe[0].
    // -------------------------------------------------------------------------
    localparam DELAY_DEPTH = PIPE_LATENCY;  // = 5 (VX_tcu_int internal latency)

    // Track is_nop at the output side (after the 1-cycle register)
    wire is_nop_out = (execute_if_out.data.op_args.tcu.tcu_op == TCU_OP_LDSCALE)
                   || (execute_if_out.data.op_args.tcu.tcu_op == TCU_OP_LDTILE);

    wire execute_fire_out = execute_if_out.valid && execute_if_out.ready;

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
    // Per-warp in-flight WMMA uop counter
    // -------------------------------------------------------------------------
    localparam INFLIGHT_W = $clog2(TCU_UOPS + 1);
    reg [INFLIGHT_W-1:0] wmma_inflight [`NUM_WARPS];

    wire wmma_dispatched = execute_fire_out && !is_nop_out;
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

    // Hazard: stall LDSCALE/LDTILE if same warp has in-flight WMMA uops
    wire ldscale_hazard = is_nop_in && (wmma_inflight[execute_if_in.data.wid] != '0);

    // -------------------------------------------------------------------------
    // 1-cycle registered pipeline stage (single-entry buffer)
    // -------------------------------------------------------------------------
    // Stage register: use tcu_exe_t directly (Verilator requires struct type for
    // member access; flat logic vector does NOT support field selects in Verilator).
    reg                 ot_valid;
    tcu_exe_t           ot_data_r;  // holds one execute payload

    // Output stalls when stage is full and output not consumed
    wire ot_stall = ot_valid && !execute_if_out.ready;

    // Input accepted when stage is not stalling and no hazard
    assign execute_if_in.ready  = !ot_stall && !ldscale_hazard;

    // Output
    assign execute_if_out.valid = ot_valid;
    assign execute_if_out.data  = ot_data_r;

    // Build modified data: fill exp_total, zero-gate nop operands
    always @(posedge clk) begin
        if (reset) begin
            ot_valid <= 1'b0;
        end else begin
            if (!ot_stall) begin
                ot_valid <= execute_if_in.valid && !ldscale_hazard;
                if (execute_if_in.valid && !ldscale_hazard) begin
                    // Copy all fields, then patch
                    ot_data_r <= execute_if_in.data;
                    // Insert exp_total into the tcu_args payload
                    ot_data_r.op_args.tcu.exp_total <= exp_total_comb;
                    // Zero-gate operands for LDSCALE/LDTILE (FEDP treats as NOP)
                    if (is_nop_in) begin
                        for (integer t = 0; t < `NUM_THREADS; t++) begin
                            ot_data_r.rs1_data[t] <= '0;
                            ot_data_r.rs2_data[t] <= '0;
                            ot_data_r.rs3_data[t] <= '0;
                        end
                    end
                end
            end
        end
    end

endmodule
