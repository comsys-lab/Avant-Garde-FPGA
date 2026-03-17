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

// VX_tcu_scale_ctx — Avant-Garde Flatten: per-warp scale context register.
//
// Stores the microscaling exponent pair (scale_a, scale_b) for each warp.
// Written by LDSCALE instructions, read combinationally by the flatten stage
// inside VX_tcu_int on each WMMA dispatch.
//
// Scale encoding (LDSCALE rs1_data[0]):
//   bits [EXP_BITS-1:0]         = scale_a  (A-matrix shared exponent)
//   bits [2*EXP_BITS-1:EXP_BITS] = scale_b  (B-matrix shared exponent)
//
// WMMA semantics after flatten:
//   exp_total = scale_a + scale_b
//   D = ((A × B) << exp_total) + C      (same as before, just new source)

`include "VX_define.vh"

`ifdef EXT_AG_TCU_ENABLE

module VX_tcu_scale_ctx import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter NUM_WARPS = `NUM_WARPS
) (
    input wire clk,
    input wire reset,

    // Write port — driven by LDSCALE execute_fire
    input wire                          wr_valid,
    input wire [NW_WIDTH-1:0]           wr_wid,
    input wire [TCU_EXP_BITS-1:0]       wr_scale_a,
    input wire [TCU_EXP_BITS-1:0]       wr_scale_b,

    // Read port — combinational, indexed by warp ID of incoming WMMA
    input wire [NW_WIDTH-1:0]           rd_wid,
    output wire [TCU_EXP_BITS-1:0]      rd_scale_a,
    output wire [TCU_EXP_BITS-1:0]      rd_scale_b
);
    reg [TCU_EXP_BITS-1:0] scale_a_r [NUM_WARPS];
    reg [TCU_EXP_BITS-1:0] scale_b_r [NUM_WARPS];

    always @(posedge clk) begin
        if (reset) begin
            for (integer i = 0; i < NUM_WARPS; i++) begin
                scale_a_r[i] <= '0;
                scale_b_r[i] <= '0;
            end
        end else if (wr_valid) begin
            scale_a_r[wr_wid] <= wr_scale_a;
            scale_b_r[wr_wid] <= wr_scale_b;
        end
    end

    assign rd_scale_a = scale_a_r[rd_wid];
    assign rd_scale_b = scale_b_r[rd_wid];

endmodule

`endif // EXT_AG_TCU_ENABLE
