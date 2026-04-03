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

// VX_tcu_scale_ctx — Phase D: per-row/col scale vector register.
//
// Stores per-row/col E8M0 exponents for the A and B matrices.
// Written by LDSCALE instructions, read combinationally by OT on WMMA dispatch.
//
// LDSCALE packing (rs1_data[0][31:0]):
//   bits [7:0]   = scale_A[0]  (A row 0 exponent, unsigned E8M0)
//   bits [15:8]  = scale_A[1]  (A row 1 exponent)
//   bits [23:16] = scale_B[0]  (B col 0 exponent)
//   bits [31:24] = scale_B[1]  (B col 1 exponent)
//
// WMMA semantics after scale lookup:
//   exp_total[i][j] = scale_A[i] + scale_B[j] - 2×bias
//   D[i][j] = FP32(A[i]·B[j]) × 2^exp_total[i][j] + C[i][j]

`include "VX_define.vh"

`ifdef EXT_AG_TCU_ENABLE

module VX_tcu_scale_ctx import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter NUM_WARPS = `NUM_WARPS
) (
    input wire clk,
    input wire reset,

    // Write port — driven by LDSCALE execute_fire
    input wire                                      wr_valid,
    input wire [NW_WIDTH-1:0]                       wr_wid,
    input wire [TCU_TC_M*TCU_EXP_BITS-1:0]         wr_scale_A,  // packed: [i*8+:8] = row i
    input wire [TCU_TC_N*TCU_EXP_BITS-1:0]         wr_scale_B,  // packed: [j*8+:8] = col j

    // Read port — combinational, indexed by warp ID of incoming WMMA
    input wire [NW_WIDTH-1:0]                       rd_wid,
    output wire [TCU_TC_M*TCU_EXP_BITS-1:0]        rd_scale_A,
    output wire [TCU_TC_N*TCU_EXP_BITS-1:0]        rd_scale_B
);
    reg [TCU_TC_M*TCU_EXP_BITS-1:0] scale_A_r [NUM_WARPS];
    reg [TCU_TC_N*TCU_EXP_BITS-1:0] scale_B_r [NUM_WARPS];

    always @(posedge clk) begin
        if (reset) begin
            for (integer w = 0; w < NUM_WARPS; w++) begin
                scale_A_r[w] <= {TCU_TC_M{TCU_EXP_BITS'(TCU_EXP_BIAS)}};  // neutral E8M0
                scale_B_r[w] <= {TCU_TC_N{TCU_EXP_BITS'(TCU_EXP_BIAS)}};
            end
        end else if (wr_valid) begin
            scale_A_r[wr_wid] <= wr_scale_A;
            scale_B_r[wr_wid] <= wr_scale_B;
        end
    end

    // Safe read: clamp rd_wid to avoid X-index on Vivado xsim when input is invalid.
    // scale_A_r/B_r are reset to TCU_EXP_BIAS (127), so reading wid=0 during idle is safe.
    wire [NW_WIDTH-1:0] safe_rd_wid = (rd_wid < NUM_WARPS) ? rd_wid : '0;

    assign rd_scale_A = scale_A_r[safe_rd_wid];
    assign rd_scale_B = scale_B_r[safe_rd_wid];

endmodule

`endif // EXT_AG_TCU_ENABLE
