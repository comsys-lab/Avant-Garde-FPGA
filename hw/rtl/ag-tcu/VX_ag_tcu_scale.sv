`include "VX_define.vh"

module VX_ag_tcu_scale (
    input  wire [7:0] scale_a,
    input  wire [7:0] scale_b,
    output wire [8:0] scale_combined
);
    // Standard fixed-point adder for exponents
    assign scale_combined = 9'(scale_a) + 9'(scale_b);

endmodule
