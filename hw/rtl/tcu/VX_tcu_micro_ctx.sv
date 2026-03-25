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

// VX_tcu_micro_ctx — Phase 10: per-warp micro-exponent context register.
//                   Phase A: MEXP_BITS parameterization (default=1, bit-identical to Phase 10).
//                   Phase C: MEXP_BITS→META_BITS; LOG2_GROUP_SIZE parameterization.
//
// Stores per-group metadata bits for INT8 tiles (A and B).
// Written by LDMICRO instructions, read combinationally by VX_tcu_operand_transformer.
//
// Parameterization:
//   META_BITS       : bits per ctx entry (format-agnostic)
//   LOG2_GROUP_SIZE : log2 of how many bytes share one ctx entry
//                     default=1 → GROUP_SIZE=2 (pair-shared, MX9 current behavior)
//
// Per word (XLEN=32 → N_BYTES=4):
//   N_CTX = N_BYTES >> LOG2_GROUP_SIZE  ctx entries per word
//   CTX_W = N_CTX * META_BITS           total bits per thread
//
// LDMICRO payload (CTX_W bits per thread):
//   rs1_data[t][CTX_W-1:0] = {ctx[N_CTX-1], ..., ctx[1], ctx[0]}  (A tile, LSB-first)
//   rs2_data[t][CTX_W-1:0] = same layout (B tile)
//
// Default (META_BITS=1, LOG2_GROUP_SIZE=1): CTX_W=2, bit-identical to Phase A/10.

`include "VX_define.vh"

`ifdef EXT_AG_TCU_ENABLE

module VX_tcu_micro_ctx import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter NUM_WARPS       = `NUM_WARPS,
    parameter META_BITS       = 1,  // bits per ctx entry (format-agnostic)
    parameter LOG2_GROUP_SIZE = 1   // default=1 → GROUP_SIZE=2 (pair-shared, MX9 behavior)
) (
    input wire clk,
    input wire reset,

    // Write port — driven by LDMICRO execute_fire (input side of OT)
    input wire                                             wr_valid,
    input wire [NW_WIDTH-1:0]                              wr_wid,
    input wire [`NUM_THREADS-1:0][N_CTX*META_BITS-1:0]    wr_meta_a,  // N_CTX entries for A
    input wire [`NUM_THREADS-1:0][N_CTX*META_BITS-1:0]    wr_meta_b,  // N_CTX entries for B

    // Read port — combinational, indexed by warp ID of incoming WMMA/FLAT
    input wire [NW_WIDTH-1:0]                              rd_wid,
    output wire [`NUM_THREADS-1:0][N_CTX*META_BITS-1:0]   rd_meta_a,  // N_CTX entries for A
    output wire [`NUM_THREADS-1:0][N_CTX*META_BITS-1:0]   rd_meta_b   // N_CTX entries for B
);
    localparam N_BYTES = `XLEN / 8;                    // = 4 for XLEN=32
    localparam N_CTX   = N_BYTES >> LOG2_GROUP_SIZE;   // default=1 → 2
    localparam CTX_W   = N_CTX * META_BITS;            // default → 2 bits (Phase A identical)

    // Storage: [warp][thread] CTX_W bits (N_CTX entries of META_BITS each)
    reg [CTX_W-1:0] meta_a_r [NUM_WARPS][`NUM_THREADS];
    reg [CTX_W-1:0] meta_b_r [NUM_WARPS][`NUM_THREADS];

    always @(posedge clk) begin
        if (reset) begin
            for (integer w = 0; w < NUM_WARPS; w++) begin
                for (integer t = 0; t < `NUM_THREADS; t++) begin
                    meta_a_r[w][t] <= '0;
                    meta_b_r[w][t] <= '0;
                end
            end
        end else if (wr_valid) begin
            for (integer t = 0; t < `NUM_THREADS; t++) begin
                meta_a_r[wr_wid][t] <= wr_meta_a[t];
                meta_b_r[wr_wid][t] <= wr_meta_b[t];
            end
        end
    end

    for (genvar t = 0; t < `NUM_THREADS; t++) begin : g_rd
        assign rd_meta_a[t] = meta_a_r[rd_wid][t];
        assign rd_meta_b[t] = meta_b_r[rd_wid][t];
    end

endmodule

`endif // EXT_AG_TCU_ENABLE
