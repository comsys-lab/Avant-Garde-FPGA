`timescale 1ns / 1ps
import btu_pkg::*;

module btu_sub_unit (
    input  logic [4:0]              n,          // Bit width (1~16)
    input  logic [DATA_WIDTH-1:0]   data_in,    // Input 32-bit word
    output logic [MAX_OUTPUT-1:0]   bits_out    // Transposed bits (one bit per output row)
);

    // Extract packed values from input word based on n
    // For n=9~16: 2 values (upper [31:16], lower [15:0])
    // For n=1~8:  4 values ([31:24], [23:16], [15:8], [7:0])
    
    logic [15:0] val0, val1, val2, val3;  // Up to 4 values per word
    logic [3:0]  num_vals;                 // Number of values in this word
    
    always_comb begin
        // Default values
        val0 = 16'h0;
        val1 = 16'h0;
        val2 = 16'h0;
        val3 = 16'h0;
        num_vals = 4'h0;
        
        if (n >= 9) begin
            // 2 values per word (LSB-aligned in each half)
            num_vals = 2;
            val0 = data_in[15:0];   // Right value
            val1 = data_in[31:16];  // Left value
            val2 = 16'h0;
            val3 = 16'h0;
        end else begin
            // 4 values per word (LSB-aligned in each byte)
            num_vals = 4;
            val0 = {8'h0, data_in[7:0]};    // Rightmost value
            val1 = {8'h0, data_in[15:8]};   // Third value
            val2 = {8'h0, data_in[23:16]};  // Second value
            val3 = {8'h0, data_in[31:24]};  // Leftmost value
        end
    end
    
    // Generate output bits
    // For n=9~16: Output has 2n rows (n bits from left value, n bits from right value)
    // For n=1~8:  Output has 4n rows (n bits from each of 4 values)
    always_comb begin
        bits_out = '0;
        
        if (n >= 9) begin
            // 2 values case
            // ROW 0~(n-1): bits from left value (val1)
            // ROW n~(2n-1): bits from right value (val0)
            for (int bit_idx = 0; bit_idx < MAX_N; bit_idx++) begin
                if (bit_idx < n) begin
                    bits_out[bit_idx]     = val1[bit_idx];  // Left value bits (ROW 0~n-1)
                    bits_out[bit_idx + n] = val0[bit_idx];  // Right value bits (ROW n~2n-1)
                end
            end
        end else begin
            // 4 values case
            // ROW 0~(n-1):   bits from leftmost value (val3)
            // ROW n~(2n-1):  bits from second value (val2)
            // ROW 2n~(3n-1): bits from third value (val1)
            // ROW 3n~(4n-1): bits from rightmost value (val0)
            for (int bit_idx = 0; bit_idx < MAX_N; bit_idx++) begin
                if (bit_idx < n) begin
                    bits_out[bit_idx]           = val3[bit_idx];  // Leftmost
                    bits_out[bit_idx + n]       = val2[bit_idx];  // Second
                    bits_out[bit_idx + 2*n]     = val1[bit_idx];  // Third
                    bits_out[bit_idx + 3*n]     = val0[bit_idx];  // Rightmost
                end
            end
        end
    end

endmodule : btu_sub_unit
