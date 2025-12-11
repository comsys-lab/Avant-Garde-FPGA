`timescale 1ns / 1ps

package btu_pkg;

    // Data width parameters
    parameter int DATA_WIDTH = 32;      // Input word width
    parameter int NUM_WORDS  = 32;      // Number of input words
    parameter int MAX_N      = 16;      // Maximum bit width of packed data
    parameter int MAX_OUTPUT = 32;      // Maximum output words (max 2*16 or 4*8)

    // Input structure
    typedef struct packed {
        logic [4:0]                     n;          // Bit width (1~16)
        logic [NUM_WORDS-1:0][DATA_WIDTH-1:0] data; // 32x32-bit input data
    } btu_input_t;

    // Output structure
    typedef struct packed {
        logic [6:0]                     num_rows;   // Number of valid output rows (2n or 4n)
        logic [MAX_OUTPUT-1:0][DATA_WIDTH-1:0] rows; // Transposed and compressed output
    } btu_output_t;

endpackage : btu_pkg
