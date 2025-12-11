`timescale 1ns / 1ps
import operand_tf_pkg::*;

// =============================================================================
// Module: simple_multiplier
// =============================================================================
// Purpose:
//   Generic integer scaler for Operand Transformer.
//   Computes: Result = Element << Scale (Element * 2^Scale)
//   Format: Assumes SIGN-MAGNITUDE (Bit 7 is Sign, Bits 6:0 are Magnitude)
//   
//   Logic:
//     1. Preserve Sign Bit.
//     2. Shift Magnitude (6:0) by Scale.
//     3. Handle Overflow on Magnitude (MSB-Alignment).
//     4. Output {Sign, Processed_Magnitude}.
// =============================================================================

module simple_multiplier (
    input  logic [7:0]     element_in,
    input  logic [7:0]     scale_in,
    output logic [7:0]     result_out
);
    logic       sign_bit;
    logic [6:0] magnitude_in;
    logic [6:0] magnitude_out;
    
    logic [2:0] lead_one_pos; // 0..6 (Magnitude is 7 bits)
    logic       is_zero;
    
    // Split Input
    assign sign_bit     = element_in[7];
    assign magnitude_in = element_in[6:0];
    
    // 1. Leading One Detector for 7-bit Magnitude
    always_comb begin
        is_zero = 0;
        if      (magnitude_in[6]) lead_one_pos = 6;
        else if (magnitude_in[5]) lead_one_pos = 5;
        else if (magnitude_in[4]) lead_one_pos = 4;
        else if (magnitude_in[3]) lead_one_pos = 3;
        else if (magnitude_in[2]) lead_one_pos = 2;
        else if (magnitude_in[1]) lead_one_pos = 1;
        else if (magnitude_in[0]) lead_one_pos = 0;
        else begin
            lead_one_pos = 0;
            is_zero = 1;
        end
    end

    // 2. Shift Logic with MSB Alignment (Magnitude Only)
    always_comb begin
        if (is_zero) begin
            magnitude_out = 7'd0;
        end else begin
            // Check potential MSB position after shift
            // target_pos relative to bit 0 of magnitude. Max valid is 6.
            logic [15:0] target_msb_pos;
            target_msb_pos = {13'd0, lead_one_pos} + {8'd0, scale_in};
            
            if (target_msb_pos > 6) begin
                // Overflow Case: Align MSB to bit 6 (Top of Magnitude)
                // Shift left by (6 - lead_one_pos)
                magnitude_out = magnitude_in << (6 - lead_one_pos);
            end else begin
                // Normal Case: Result fits in 7 bits
                magnitude_out = magnitude_in << scale_in;
            end
        end
        
        // 3. Recombine
        result_out = {sign_bit, magnitude_out};
    end

endmodule
