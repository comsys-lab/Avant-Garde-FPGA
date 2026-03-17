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

module VX_tcu_unit import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    `SCOPE_IO_DECL

    input wire              clk,
    input wire              reset,

    // Inputs
    VX_dispatch_if.slave    dispatch_if [`ISSUE_WIDTH],

    // Outputs
    VX_commit_if.master     commit_if [`ISSUE_WIDTH]
);
    localparam BLOCK_SIZE = `NUM_TCU_BLOCKS;
    localparam NUM_LANES  = `NUM_TCU_LANES;
    localparam PE_COUNT   = 2;

    // PIPE_LATENCY for scoreboard.
    // Phase 9: OT(1cy) is before pe_switch (handles both INT and FP paths).
    //   INT path: OT(1) + VX_tcu_int(5) = 6cy
    //   FP  path: OT(1) + VX_tcu_fp(FEDP_LATENCY_FP+1)  [backend-dependent]
/* verilator lint_off UNUSEDPARAM */
`ifdef EXT_AG_TCU_ENABLE
    localparam TCU_UNIT_PIPE_LATENCY = 6;  // Scoreboard uses INT path latency (conservative)
`else
    localparam TCU_UNIT_PIPE_LATENCY = 5;  // Without OT stage
`endif

`ifdef EXT_AG_TCU_ENABLE
    // PIPE_LATENCY_FP: VX_tcu_fp internal FEDP_LATENCY + 1 (mdata/result)
    // Mirrors the localparam computation in VX_tcu_fp.sv.
`ifdef TCU_DSP
    localparam PIPE_LATENCY_FP = 1 + 8 + $clog2(2*TCU_TC_K+1)*11 + 11 + 1;
`elsif TCU_DPI
    localparam PIPE_LATENCY_FP = 2 + 2 + 1;  // FMUL(2)+FACC(2)+mdata(1)
`elsif TCU_BHF
    localparam PIPE_LATENCY_FP = (2+1) + 1 + $clog2(2*TCU_TC_K+1)*(2+1) + (2+1) + 1;
`else
    localparam PIPE_LATENCY_FP = 5;  // fallback
`endif
`endif
/* verilator lint_on UNUSEDPARAM */

    `STATIC_ASSERT (BLOCK_SIZE == `ISSUE_WIDTH, ("must be full issue execution"));
    `STATIC_ASSERT (NUM_LANES == `NUM_THREADS, ("must be full warp execution"));
    `SCOPE_IO_SWITCH (BLOCK_SIZE);

    VX_execute_if #(
        .data_t (tcu_exe_t)
    ) per_block_execute_if[BLOCK_SIZE]();

    VX_dispatch_unit #(
        .BLOCK_SIZE (BLOCK_SIZE),
        .NUM_LANES  (NUM_LANES),
        .OUT_BUF    (3)
    ) dispatch_unit (
        .clk        (clk),
        .reset      (reset),
        .dispatch_if(dispatch_if),
        .execute_if (per_block_execute_if)
    );

    VX_result_if #(
        .data_t (tcu_res_t)
    ) per_block_result_if[BLOCK_SIZE]();

    for (genvar block_idx = 0; block_idx < BLOCK_SIZE; ++block_idx) begin : g_blocks

        VX_execute_if #(
            .data_t (tcu_exe_t)
        ) pe_execute_if[PE_COUNT]();

        VX_result_if #(
            .data_t (tcu_res_t)
        ) pe_result_if[PE_COUNT]();

`ifdef EXT_AG_TCU_ENABLE
        // Phase 9: OT before pe_switch — handles both INT and FP paths.
        // per_block_execute_if → OT(1cy) → ot_execute_if → pe_switch → {tcu_fp, tcu_int}

        VX_execute_if #(
            .data_t (tcu_exe_t)
        ) ot_execute_if();

        // Feedback wires from VX_tcu_int (INT path)
        wire        ot_fedp_enable;
        wire        ot_result_fire;
        wire [NW_WIDTH-1:0] ot_result_wid;

        VX_tcu_operand_transformer #(
            .PIPE_LATENCY_INT (5)  // VX_tcu_int internal: FEDP(4)+mdata(1)
        ) operand_xformer (
            .clk            (clk),
            .reset          (reset),
            .execute_if_in  (per_block_execute_if[block_idx]),
            .execute_if_out (ot_execute_if),
            .fedp_enable    (ot_fedp_enable),
            .result_fire    (ot_result_fire),
            .result_wid     (ot_result_wid)
        );

        // LDSCALE/LDTILE always → INT path (pe_sel=1); evaluated on OT output.
        wire pe_sel_w = ot_execute_if.data.op_args.tcu.fmt_s[3]
                      | (ot_execute_if.data.op_args.tcu.tcu_op == TCU_OP_LDSCALE)
                      | (ot_execute_if.data.op_args.tcu.tcu_op == TCU_OP_LDTILE);

        VX_pe_switch #(
            .PE_COUNT    (PE_COUNT),
            .NUM_LANES   (NUM_LANES),
            .ARBITER     ("R"),
            .REQ_OUT_BUF (0),
            .RSP_OUT_BUF (3)
        ) pe_switch (
            .clk            (clk),
            .reset          (reset),
            .pe_sel         (pe_sel_w),
            .execute_in_if  (ot_execute_if),
            .result_out_if  (per_block_result_if[block_idx]),
            .execute_out_if (pe_execute_if),
            .result_in_if   (pe_result_if)
        );

        VX_tcu_fp #(
            .INSTANCE_ID (`SFORMATF(("%s-fp%0d", INSTANCE_ID, block_idx)))
        ) tcu_fp (
            `SCOPE_IO_BIND (block_idx)
            .clk            (clk),
            .reset          (reset),
            .execute_if     (pe_execute_if[0]),
            .result_if      (pe_result_if[0])
        );

        VX_tcu_int #(
            .INSTANCE_ID (`SFORMATF(("%s-int%0d", INSTANCE_ID, block_idx)))
        ) tcu_int (
            `SCOPE_IO_BIND (block_idx)
            .clk            (clk),
            .reset          (reset),
            .execute_if     (pe_execute_if[1]),
            .result_if      (pe_result_if[1]),
            // Feedback to OT
            .ot_fedp_enable (ot_fedp_enable),
            .ot_result_fire (ot_result_fire),
            .ot_result_wid  (ot_result_wid)
        );

`else
        // Non-AG: no OT; pe_sel direct from dispatch.
        wire pe_sel_w = per_block_execute_if[block_idx].data.op_args.tcu.fmt_s[3];

        VX_pe_switch #(
            .PE_COUNT    (PE_COUNT),
            .NUM_LANES   (NUM_LANES),
            .ARBITER     ("R"),
            .REQ_OUT_BUF (0),
            .RSP_OUT_BUF (3)
        ) pe_switch (
            .clk            (clk),
            .reset          (reset),
            .pe_sel         (pe_sel_w),
            .execute_in_if  (per_block_execute_if[block_idx]),
            .result_out_if  (per_block_result_if[block_idx]),
            .execute_out_if (pe_execute_if),
            .result_in_if   (pe_result_if)
        );

        VX_tcu_fp #(
            .INSTANCE_ID (`SFORMATF(("%s-fp%0d", INSTANCE_ID, block_idx)))
        ) tcu_fp (
            `SCOPE_IO_BIND (block_idx)
            .clk        (clk),
            .reset      (reset),
            .execute_if (pe_execute_if[0]),
            .result_if  (pe_result_if[0])
        );

        VX_tcu_int #(
            .INSTANCE_ID (`SFORMATF(("%s-int%0d", INSTANCE_ID, block_idx)))
        ) tcu_int (
            `SCOPE_IO_BIND (block_idx)
            .clk        (clk),
            .reset      (reset),
            .execute_if (pe_execute_if[1]),
            .result_if  (pe_result_if[1])
        );
`endif

    end

    VX_gather_unit #(
        .BLOCK_SIZE (BLOCK_SIZE),
        .NUM_LANES  (NUM_LANES),
        .OUT_BUF    (3)
    ) gather_unit (
        .clk       (clk),
        .reset     (reset),
        .result_if (per_block_result_if),
        .commit_if (commit_if)
    );

endmodule
