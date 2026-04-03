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

`ifndef VX_TCU_PKG_VH
`define VX_TCU_PKG_VH

`include "VX_define.vh"

package VX_tcu_pkg;

    import VX_gpu_pkg::*;

    // Set configuration parameters
    localparam TCU_NT = `NUM_THREADS;
    localparam TCU_NR = 8;
    localparam TCU_DP = 0;

`ifdef EXT_AG_TCU_ENABLE
    // Avant-Garde flatten: scale factor bits per operand side (A or B).
    // Phase 5: E8M0 format — 8-bit unsigned, bias=127 (value = 2^(exp-127)).
    // exp_total = scale_a + scale_b - 2*bias; range [-254, +256], clamped to [-31, +30].
    // Stored in VX_tcu_scale_ctx per warp (LDSCALE writes, WMMA reads combinationally).
    localparam TCU_EXP_BITS  = 8;   // bits per side (unsigned: 0..255)
    localparam TCU_EXP_BIAS  = 127; // E8M0 bias (neutral: scale=127 → exp_total=0)
    localparam TCU_EXP_TOTAL = 10;  // signed sum width (covers [-254, +256])
`endif

    // Supported data types
    localparam TCU_FP32_ID = 0;
    localparam TCU_FP16_ID = 1;
    localparam TCU_BF16_ID = 2;
    // MX9: E8M0 + 1b micro_exp (per pair) + 8b normalized significand {s[1b],frac[6:0]}
    //   element = (-1)^s × (1 + frac/128) × 2^(micro_exp) × 2^(block_exp - bias)
    //   OT Option C: Q=128+frac, flat=Q>>(2-mexp) → INT8 [32..63] or [64..127]
    //     fmt_s patched to I8_ID; exp_total_adjusted = exp_total_base - 10
    localparam TCU_MX9_ID      = 4;
    localparam TCU_FP8E4M3_ID  = 5;  // FP8 E4M3 (bias=7, no Infinity); fmt_s[3]=0 → FP path; FEDP: FP8→BF16 then BHF MAC
    localparam TCU_FP8E5M2_ID  = 6;  // FP8 E5M2 (bias=15, has Infinity); fmt_s[3]=0 → FP path; FEDP: FP8→BF16 then BHF MAC
    // 3LEVEL: hypothetical 3-level hierarchical scale (L1=E8M0 global, L2=word-level, L3=pair-level)
    //   OT pre-computes combined shift (L2+L3) per pair from micro_ctx, then flattens INT8 mantissas.
    //   fmt_s[3]=0 → OT patches to I8_ID → INT path.  LDMICRO encodes 2-bit combined shifts.
    localparam TCU_3LEVEL_ID   = 3;
    localparam TCU_I32_ID      = 8;
    localparam TCU_I8_ID       = 9;
    localparam TCU_U8_ID       = 10;
    localparam TCU_I4_ID       = 11;
    localparam TCU_U4_ID       = 12;
    // MXINT8: E8M0 shared_exp + Signed INT8 (no micro_exp)
    //   element = INT8 × 2^(block_exp - bias)
    //   fmt_s[3]=1 → INT path 직접 라우팅 (OT fmt_s 패치 불필요)
    localparam TCU_MXINT8_ID   = 13;

    // Tile dimensions
    localparam TCU_TILE_CAP = TCU_NT * TCU_NR;
    localparam TCU_LG_TILE_CAP = $clog2(TCU_TILE_CAP);
    localparam TCU_TILE_EN = TCU_LG_TILE_CAP / 2;
    localparam TCU_TILE_EM = TCU_LG_TILE_CAP - TCU_TILE_EN;

    localparam TCU_TILE_M = 1 << TCU_TILE_EM;
    localparam TCU_TILE_N = 1 << TCU_TILE_EN;
    localparam TCU_TILE_K = TCU_TILE_CAP / ((TCU_TILE_M > TCU_TILE_N) ? TCU_TILE_M : TCU_TILE_N);

    // Block dimensions
    localparam TCU_BLOCK_CAP = TCU_NT;
    localparam TCU_LG_BLOCK_CAP = $clog2(TCU_BLOCK_CAP);
    localparam TCU_BLOCK_EN = TCU_LG_BLOCK_CAP / 2;
    localparam TCU_BLOCK_EM = TCU_LG_BLOCK_CAP - TCU_BLOCK_EN;

    localparam TCU_TC_M = 1 << TCU_BLOCK_EM;
    localparam TCU_TC_N = 1 << TCU_BLOCK_EN;
    localparam TCU_TC_K = (TCU_DP != 0) ? TCU_DP : (TCU_BLOCK_CAP / ((TCU_TC_M > TCU_TC_N) ? TCU_TC_M : TCU_TC_N));

    // Step counts
    localparam TCU_M_STEPS = TCU_TILE_M / TCU_TC_M;
    localparam TCU_N_STEPS = TCU_TILE_N / TCU_TC_N;
    localparam TCU_K_STEPS = TCU_TILE_K / TCU_TC_K;

    // A micro-tiling
    localparam TCU_A_BLOCK_SIZE = TCU_TC_M * TCU_TC_K;
    localparam TCU_A_SUB_BLOCKS = TCU_BLOCK_CAP / TCU_A_BLOCK_SIZE;

    // B micro-tiling
    localparam TCU_B_BLOCK_SIZE = TCU_TC_K * TCU_TC_N;
    localparam TCU_B_SUB_BLOCKS = TCU_BLOCK_CAP / TCU_B_BLOCK_SIZE;

    // Register counts
    localparam TCU_NRA = (TCU_TILE_M * TCU_TILE_K) / TCU_NT;
    localparam TCU_NRB = (TCU_TILE_N * TCU_TILE_K) / TCU_NT;
    //localparam TCU_NRC = (TCU_TILE_M * TCU_TILE_N) / TCU_NT;

    // Register base addresses
    localparam TCU_RA = 0;
    localparam TCU_RB = (TCU_NRB == 4) ? 28 : 10;
    localparam TCU_RC = (TCU_NRB == 4) ? 10 : 24;

    localparam TCU_UOPS      = TCU_M_STEPS * TCU_N_STEPS * TCU_K_STEPS;
    localparam TCU_FLAT_UOPS = TCU_NRA + TCU_NRB;

    // Tracing info
`ifdef SIMULATION
    task trace_fmt(input int level, input [3:0] fmt);
        case (fmt)
            TCU_FP32_ID: `TRACE(level, ("fp32"))
            TCU_FP16_ID: `TRACE(level, ("fp16"))
            TCU_BF16_ID: `TRACE(level, ("bf16"))
            TCU_MX9_ID:      `TRACE(level, ("mx9"))
            TCU_3LEVEL_ID:   `TRACE(level, ("3level"))
            TCU_MXINT8_ID:   `TRACE(level, ("mxint8"))
            TCU_FP8E4M3_ID:  `TRACE(level, ("fp8e4m3"))
            TCU_FP8E5M2_ID:  `TRACE(level, ("fp8e5m2"))
            TCU_I32_ID:  `TRACE(level, ("i32"))
            TCU_I8_ID:   `TRACE(level, ("i8"))
            TCU_U8_ID:   `TRACE(level, ("u8"))
            TCU_I4_ID:   `TRACE(level, ("i4"))
            TCU_U4_ID:   `TRACE(level, ("u4"))
            default:     `TRACE(level, ("?"))
        endcase
    endtask

    task trace_ex_op(input int level,
                     input [INST_OP_BITS-1:0] op_type,
                     input op_args_t op_args
    );
        case (INST_TCU_BITS'(op_type))
            INST_TCU_WMMA: begin
                `TRACE(level, ("WMMA."));
                trace_fmt(level, op_args.tcu.fmt_s);
                `TRACE(level, ("."));
                trace_fmt(level, op_args.tcu.fmt_d);
                `TRACE(level, (".%0d.%0d", op_args.tcu.step_m, op_args.tcu.step_n));
            end
            default: `TRACE(level, ("?"))
        endcase
    endtask
`endif

    `DECL_EXECUTE_T (tcu_exe_t, `NUM_TCU_LANES);
    `DECL_RESULT_T (tcu_res_t, `NUM_TCU_LANES);

endpackage

`endif // VX_TCU_PKG_VH
