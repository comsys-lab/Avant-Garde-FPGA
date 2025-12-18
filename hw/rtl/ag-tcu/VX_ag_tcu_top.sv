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

module VX_ag_tcu_top import VX_gpu_pkg::*, VX_ag_tcu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    `SCOPE_IO_DECL

    input wire clk,
    input wire reset,

    // Dispatch Interface
    input wire execute_valid,
    input ag_tcu_exe_t execute_data,
    output wire execute_ready,

    // Commit Interface
    output wire result_valid,
    output ag_tcu_res_t result_data,
    input wire result_ready
);
    VX_execute_if #(
        .data_t (ag_tcu_exe_t)
    ) execute_if();

    VX_result_if #(
        .data_t (ag_tcu_res_t)
    ) result_if();

    assign execute_if.valid = execute_valid;
    assign execute_if.data = execute_data;
    assign execute_ready = execute_if.ready;

    wire [7:0] scale_a = execute_data.op_args.tcu.scale_a;
    wire [7:0] scale_b = execute_data.op_args.tcu.scale_b;
    wire [8:0] scale_combined;

    VX_ag_tcu_scale ag_tcu_scale (
        .scale_a        (scale_a),
        .scale_b        (scale_b),
        .scale_combined (scale_combined)
    );

    VX_ag_tcu_core #(
        .INSTANCE_ID (INSTANCE_ID)
    ) ag_tcu_unit (
        `SCOPE_IO_BIND (0)
        .clk            (clk),
        .reset          (reset),
        .scale_combined (scale_combined),
        .execute_if     (execute_if),
        .result_if      (result_if)
    );

    assign result_valid = result_if.valid;
    assign result_data = result_if.data;
    assign result_if.ready = result_ready;

endmodule
