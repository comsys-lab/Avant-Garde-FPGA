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

`ifndef VX_AG_TCU_PKG_VH
`define VX_AG_TCU_PKG_VH

`include "VX_define.vh"

package VX_ag_tcu_pkg;

    import VX_gpu_pkg::*;

    // Set configuration parameters
    localparam AG_TCU_NT = 8; // Decoupled from NUM_THREADS (4) to support 8-lane TCU
    localparam AG_TCU_NR = 16;
    localparam AG_TCU_DP = 0;

    // Supported data types

    localparam AG_TCU_I32_ID  = 8;
    localparam AG_TCU_I8_ID   = 9;
    localparam AG_TCU_U8_ID   = 10;
    localparam AG_TCU_I4_ID   = 11;
    localparam AG_TCU_U4_ID   = 12;

    // Tile dimensions
    localparam AG_TCU_TILE_CAP = AG_TCU_NT * AG_TCU_NR;
    localparam AG_TCU_LG_TILE_CAP = $clog2(AG_TCU_TILE_CAP);
    localparam AG_TCU_TILE_EN = AG_TCU_LG_TILE_CAP / 2;
    localparam AG_TCU_TILE_EM = AG_TCU_LG_TILE_CAP - AG_TCU_TILE_EN;

    localparam AG_TCU_TILE_M = 1 << AG_TCU_TILE_EM;
    localparam AG_TCU_TILE_N = 1 << AG_TCU_TILE_EN;
    localparam AG_TCU_TILE_K = AG_TCU_TILE_CAP / ((AG_TCU_TILE_M > AG_TCU_TILE_N) ? AG_TCU_TILE_M : AG_TCU_TILE_N);

    // Block dimensions
    localparam AG_TCU_BLOCK_CAP = AG_TCU_NT;
    localparam AG_TCU_LG_BLOCK_CAP = $clog2(AG_TCU_BLOCK_CAP);
    localparam AG_TCU_BLOCK_EN = AG_TCU_LG_BLOCK_CAP / 2;
    localparam AG_TCU_BLOCK_EM = AG_TCU_LG_BLOCK_CAP - AG_TCU_BLOCK_EN;

    localparam AG_TCU_TC_M = 1 << AG_TCU_BLOCK_EM;
    localparam AG_TCU_TC_N = 1 << AG_TCU_BLOCK_EN;
    localparam AG_TCU_TC_K = (AG_TCU_DP != 0) ? AG_TCU_DP : (AG_TCU_BLOCK_CAP / ((AG_TCU_TC_M > AG_TCU_TC_N) ? AG_TCU_TC_M : AG_TCU_TC_N));

    // Step counts
    localparam AG_TCU_M_STEPS = AG_TCU_TILE_M / AG_TCU_TC_M;
    localparam AG_TCU_N_STEPS = AG_TCU_TILE_N / AG_TCU_TC_N;
    localparam AG_TCU_K_STEPS = AG_TCU_TILE_K / AG_TCU_TC_K;

    // A micro-tiling
    localparam AG_TCU_A_BLOCK_SIZE = AG_TCU_TC_M * AG_TCU_TC_K;
    localparam AG_TCU_A_SUB_BLOCKS = AG_TCU_BLOCK_CAP / AG_TCU_A_BLOCK_SIZE;

    // B micro-tiling
    localparam AG_TCU_B_BLOCK_SIZE = AG_TCU_TC_K * AG_TCU_TC_N;
    localparam AG_TCU_B_SUB_BLOCKS = AG_TCU_BLOCK_CAP / AG_TCU_B_BLOCK_SIZE;

    // Register counts
    //localparam AG_TCU_NRA = (AG_TCU_TILE_M * AG_TCU_TILE_K) / AG_TCU_NT;
    localparam AG_TCU_NRB = (AG_TCU_TILE_N * AG_TCU_TILE_K) / AG_TCU_NT;
    //localparam AG_TCU_NRC = (AG_TCU_TILE_M * AG_TCU_TILE_N) / AG_TCU_NT;

    // Register base addresses
    localparam AG_TCU_RA = 0;
    localparam AG_TCU_RB = (AG_TCU_NRB == 4) ? 28 : 10;
    localparam AG_TCU_RC = (AG_TCU_NRB == 4) ? 10 : 24;

    localparam AG_TCU_UOPS = AG_TCU_M_STEPS * AG_TCU_N_STEPS * AG_TCU_K_STEPS;

    // Tracing info
`ifdef SIMULATION
    task trace_fmt(input int level, input [3:0] fmt);
        case (fmt)

            AG_TCU_I32_ID:  `TRACE(level, ("i32"))
            AG_TCU_I8_ID:   `TRACE(level, ("i8"))
            AG_TCU_U8_ID:   `TRACE(level, ("u8"))
            AG_TCU_I4_ID:   `TRACE(level, ("i4"))
            AG_TCU_U4_ID:   `TRACE(level, ("u4"))
            default:     `TRACE(level, ("?"))
        endcase
    endtask

    task trace_ex_op(input int level,
                     input [INST_OP_BITS-1:0] op_type,
                     input op_args_t op_args
    );
        case (INST_AG_TCU_BITS'(op_type))
            INST_AG_TCU_WMMA: begin
                `TRACE(level, ("WMMA."));
                trace_fmt(level, op_args.ag_tcu.fmt_s);
                `TRACE(level, ("."));
                trace_fmt(level, op_args.ag_tcu.fmt_d);
                `TRACE(level, (".%0d.%0d", op_args.ag_tcu.step_m, op_args.ag_tcu.step_n));
            end
            default: `TRACE(level, ("?"))
        endcase
    endtask
`endif

    `DECL_EXECUTE_T (ag_tcu_exe_t, `NUM_TCU_LANES);
    `DECL_RESULT_T (ag_tcu_res_t, `NUM_TCU_LANES);

endpackage

`endif // VX_AG_TCU_PKG_VH
