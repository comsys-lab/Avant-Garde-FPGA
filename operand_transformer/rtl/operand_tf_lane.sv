`timescale 1ns / 1ps
import operand_tf_pkg::*;

// =============================================================================
// Module: operand_tf_lane
// =============================================================================
// Architecture:
//   - Inputs: 2 Elements (Even/Odd), 1 Shared Micro Scale
//   - Process: Mux -> Multiplier -> Demux -> Temporal Registers
//   - Capacity: 2 bytes (1 byte per element)
// =============================================================================

module operand_tf_lane (
    input  logic                      clk,
    input  logic                      rst_n,
    
    // Control
    input  logic                      load_input,
    input  logic                      iter_sel,      // 0=Even pass, 1=Odd pass
    input  logic                      feedback_sel,  // 0=Input Buffer, 1=Feedback
    input  logic                      we_result,     // Write Enable for Result
    
    // Data
    input  logic [ELEM_WIDTH_IN-1:0]  elem_0_in,     // Even Element
    input  logic [ELEM_WIDTH_IN-1:0]  elem_1_in,     // Odd Element
    input  logic [SCALE_WIDTH-1:0]    micro_scale_in,// Shared Micro Scale
    
    // Outputs (Temporal Registers)
    output logic [ELEM_WIDTH_OUT-1:0] res_0_out,
    output logic [ELEM_WIDTH_OUT-1:0] res_1_out
);

    // =========================================================================
    // 1. Input Buffers
    // =========================================================================
    logic [ELEM_WIDTH_IN-1:0] elem_0_buf, elem_1_buf;
    logic [SCALE_WIDTH-1:0]   scale_buf;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            elem_0_buf <= '0;
            elem_1_buf <= '0;
            scale_buf  <= '0;
        end else if (load_input) begin
            elem_0_buf <= elem_0_in;
            elem_1_buf <= elem_1_in;
            scale_buf  <= micro_scale_in;
        end
    end

    // =========================================================================
    // 2. Input Mux (Select Even/Odd & Input/Feedback)
    // =========================================================================
    logic [ELEM_WIDTH_IN-1:0] mux_elem;
    
    always_comb begin
        case ({feedback_sel, iter_sel})
            2'b00: mux_elem = elem_0_buf;  // Load Even
            2'b01: mux_elem = elem_1_buf;  // Load Odd
            2'b10: mux_elem = res_0_out;   // Feedback Even
            2'b11: mux_elem = res_1_out;   // Feedback Odd
            default: mux_elem = elem_0_buf;
        endcase
    end

    // =========================================================================
    // 3. Multiplier (Element × Micro Scale)
    // =========================================================================
    logic [ELEM_WIDTH_OUT-1:0] mult_result;
    
    simple_multiplier u_mult (
        .element_in (mux_elem),
        .scale_in   (scale_buf),
        .result_out (mult_result)
    );

    // =========================================================================
    // 4. Output Demux & Temporal Registers
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_0_out <= '0;
            res_1_out <= '0;
        end else if (we_result) begin
            if (iter_sel)
                res_1_out <= mult_result; // Store Odd result
            else
                res_0_out <= mult_result; // Store Even result
        end
    end

endmodule
