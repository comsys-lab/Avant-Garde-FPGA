// VX_fpu_unit stub for tb_execute / tb_pipeline testbenches.
// EXT_F_ENABLE is unconditionally set by VX_config.vh, so VX_execute always
// instantiates VX_fpu_unit. This stub satisfies the interface without pulling
// in the FPU backend (FPU_DPI / FPU_FPNEW / FPU_DSP) and its DPI libraries.
//
// Behavior:
//   - Accepts all dispatch immediately (ready=1 when no pending commit)
//   - Commits 1 cycle after dispatch with result = rs1_data
//     (covers FMV.W.X = integer→float bit copy, used in tb_pipeline preload)
//   - tb_decode / tb_issue / tb_execute: never dispatch FPU → stub idle

`include "VX_fpu_define.vh"

`ifdef EXT_F_ENABLE

module VX_fpu_unit import VX_gpu_pkg::*, VX_fpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire clk,
    input wire reset,

    VX_dispatch_if.slave  dispatch_if [`ISSUE_WIDTH],
    VX_commit_if.master   commit_if   [`ISSUE_WIDTH],
    VX_fpu_csr_if.master  fpu_csr_if  [`NUM_FPU_BLOCKS]
);
    `UNUSED_SPARAM (INSTANCE_ID)

    // One-entry pending-commit buffer per issue lane
    for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin : g_dispatch
        logic    pending_r;
        commit_t data_r;

        // Accept new dispatch only when no commit is pending
        assign dispatch_if[i].ready = !pending_r;

        always @(posedge clk) begin
            if (reset) begin
                pending_r <= 1'b0;
            end else if (pending_r && commit_if[i].ready) begin
                // Commit accepted by downstream
                pending_r <= 1'b0;
            end else if (dispatch_if[i].valid && dispatch_if[i].ready) begin
                // Latch dispatch → commit next cycle with rs1_data (FMV.W.X)
                pending_r         <= 1'b1;
                data_r.uuid       <= dispatch_if[i].data.uuid;
                data_r.wid        <= NW_WIDTH'(dispatch_if[i].data.wis);
                data_r.sid        <= dispatch_if[i].data.sid;
                data_r.tmask      <= dispatch_if[i].data.tmask;
                data_r.PC         <= dispatch_if[i].data.PC;
                data_r.wb         <= dispatch_if[i].data.wb;
                data_r.rd         <= dispatch_if[i].data.rd;
                data_r.data       <= dispatch_if[i].data.rs1_data;
                data_r.sop        <= 1'b1;
                data_r.eop        <= 1'b1;
            end
        end

        assign commit_if[i].valid = pending_r;
        assign commit_if[i].data  = data_r;
    end

    // Drive CSR master outputs to zero
    for (genvar i = 0; i < `NUM_FPU_BLOCKS; ++i) begin : g_csr
        assign fpu_csr_if[i].write_enable = 1'b0;
        assign fpu_csr_if[i].write_wid    = '0;
        assign fpu_csr_if[i].write_fflags = '0;
        assign fpu_csr_if[i].read_wid     = '0;
    end

endmodule

`endif // EXT_F_ENABLE
