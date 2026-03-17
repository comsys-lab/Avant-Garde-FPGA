// VX_fpu_unit stub for tb_execute Level 6 testbench.
// EXT_F_ENABLE is unconditionally set by VX_config.vh, so VX_execute always
// instantiates VX_fpu_unit. This stub satisfies the interface without pulling
// in the FPU backend (FPU_DPI / FPU_FPNEW / FPU_DSP) and its DPI libraries.
// The TB never dispatches FPU instructions, so the stub is never exercised.

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
    `UNUSED_VAR (clk)
    `UNUSED_VAR (reset)

    // Accept all dispatch requests, never commit
    for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin : g_dispatch
        `UNUSED_VAR (dispatch_if[i].valid)
        `UNUSED_VAR (dispatch_if[i].data)
        assign dispatch_if[i].ready = 1'b1;

        assign commit_if[i].valid = 1'b0;
        assign commit_if[i].data  = '0;
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
