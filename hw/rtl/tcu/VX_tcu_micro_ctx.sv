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

// VX_tcu_micro_ctx — per-warp micro-scale context register file.
//
// Stores per-group scale factor bits for INT8 tiles (A and B).
// Written by LDMICRO instructions, read combinationally by VX_tcu_operand_transformer.
//
// Parameterization:
//   SCALE_BITS       : bits per scale factor entry
//   LOG2_SCALE_GROUP : log2 of how many bytes share one scale entry
//                      default=1 → GROUP_SIZE=2 (pair-shared, MX9 behavior)
//
// Per word (XLEN=32 → N_BYTES=4):
//   N_CTX = N_BYTES >> LOG2_SCALE_GROUP  scale entries per word
//   CTX_W = N_CTX * SCALE_BITS           total bits per thread
//
// LDMICRO payload (CTX_W bits per thread):
//   rs1_data[t][CTX_W-1:0] = {ctx[N_CTX-1], ..., ctx[1], ctx[0]}  (A tile, LSB-first)
//   rs2_data[t][CTX_W-1:0] = same layout (B tile)

`include "VX_define.vh"

`ifdef EXT_AG_TCU_ENABLE

module VX_tcu_micro_ctx import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter  NUM_WARPS       = `NUM_WARPS,
    parameter  SCALE_BITS      = 1,  // bits per scale factor entry
    parameter  LOG2_SCALE_GROUP = 1,  // default=1 → GROUP_SIZE=2 (pair-shared, MX9 behavior)
    // Derived: must be localparam in #() so they are in scope for port declarations.
    // Vivado xvlog requires identifiers used in ports to be declared before the port list;
    // localparams in the parameter port list satisfy this requirement (IEEE 1800-2017 §23.10).
    localparam N_BYTES = `XLEN / 8,                      // = 4 for XLEN=32
    localparam N_CTX   = N_BYTES >> LOG2_SCALE_GROUP,    // default=1 → 2
    localparam CTX_W   = N_CTX * SCALE_BITS              // default → 2 bits
) (
    input wire clk,
    input wire reset,

    // Write port — driven by LDMICRO execute_fire (input side of OT)
    input wire                                             wr_valid,
    input wire [NW_WIDTH-1:0]                              wr_wid,
    input wire [`NUM_THREADS-1:0][CTX_W-1:0]              wr_meta_a,
    input wire [`NUM_THREADS-1:0][CTX_W-1:0]              wr_meta_b,

    // Read port — combinational, indexed by warp ID of incoming WMMA/FLAT
    input wire [NW_WIDTH-1:0]                              rd_wid,
    output wire [`NUM_THREADS-1:0][CTX_W-1:0]             rd_meta_a,
    output wire [`NUM_THREADS-1:0][CTX_W-1:0]             rd_meta_b
);

    // Storage: [warp][thread] CTX_W bits (N_CTX entries of SCALE_BITS each)
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

    // Safe read: clamp rd_wid to avoid X-index on Vivado xsim when input is invalid.
    wire [NW_WIDTH-1:0] safe_rd_wid = (rd_wid < NUM_WARPS) ? rd_wid : '0;

    for (genvar t = 0; t < `NUM_THREADS; t++) begin : g_rd
        assign rd_meta_a[t] = meta_a_r[safe_rd_wid][t];
        assign rd_meta_b[t] = meta_b_r[safe_rd_wid][t];
    end

endmodule

`endif // EXT_AG_TCU_ENABLE
