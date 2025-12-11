`timescale 1ns / 1ps
import btu_pkg::*;

module btu_top (
    input  logic        clk,
    input  logic        rst_n,
    
    // Input interface
    input  logic        valid_in,
    output logic        ready_in,
    input  btu_input_t  data_in,
    
    // Output interface
    input  logic        ready_out,
    output logic        valid_out,
    output btu_output_t data_out
);

    // FSM states
    typedef enum logic [1:0] {
        IDLE    = 2'b00,
        PROCESS = 2'b01,
        VALID   = 2'b10
    } state_t;
    
    state_t state, next_state;
    
    // Registered input
    btu_input_t data_reg;
    logic load_input;
    
    // Sub-unit outputs
    logic [NUM_WORDS-1:0][MAX_OUTPUT-1:0] sub_unit_bits;
    
    // Instantiate 32 sub-units
    genvar i;
    generate
        for (i = 0; i < NUM_WORDS; i++) begin : gen_sub_units
            btu_sub_unit u_sub_unit (
                .n        (data_reg.n),
                .data_in  (data_reg.data[i]),
                .bits_out (sub_unit_bits[i])
            );
        end
    endgenerate
    
    // Transpose and compress logic
    logic [6:0] num_output_rows;
    logic [MAX_OUTPUT-1:0][DATA_WIDTH-1:0] transposed_rows;
    logic [MAX_OUTPUT-1:0][DATA_WIDTH-1:0] full_transposed_rows;  // All 64 rows before compression
    
    always_comb begin
        // Calculate number of output rows
        if (data_reg.n >= 9)
            num_output_rows = {2'b00, data_reg.n, 1'b0};  // 2n
        else
            num_output_rows = {1'b0, data_reg.n, 2'b00};  // 4n
        
        // Step 1: Collect bits from all sub-units to form full transposed rows
        full_transposed_rows = '0;
        for (int row = 0; row < MAX_OUTPUT; row++) begin
            for (int col = 0; col < NUM_WORDS; col++) begin
                full_transposed_rows[row][col] = sub_unit_bits[col][row];
            end
        end
        
        // Step 2: Compress - pack only valid rows into output
        transposed_rows = '0;
        for (int i = 0; i < MAX_OUTPUT; i++) begin
            if (i < num_output_rows) begin
                transposed_rows[i] = full_transposed_rows[i];
            end
            // else: transposed_rows[i] remains 0 (don't care)
        end
    end
    
    // FSM - State register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end
    
    // FSM - Next state logic
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (valid_in)
                    next_state = PROCESS;
            end
            
            PROCESS: begin
                next_state = VALID;
            end
            
            VALID: begin
                if (ready_out)
                    next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // FSM - Output logic
    always_comb begin
        ready_in = (state == IDLE);
        valid_out = (state == VALID);
        load_input = (state == IDLE && valid_in);
    end
    
    // Input register
    always_ff @(posedge clk) begin
        if (load_input) begin
            data_reg <= data_in;
        end
    end
    
    // Output assignment
    assign data_out.num_rows = num_output_rows;
    assign data_out.rows = transposed_rows;

endmodule : btu_top
