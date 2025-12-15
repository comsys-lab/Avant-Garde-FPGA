`timescale 1ns / 1ps
import operand_tf_pkg::*;

module operand_transformer_ctrl (
    input  logic clk,
    input  logic rst_n, // Active Low Reset

    // Handshake Inputs
    input  logic valid_in,
    output logic ready_in,
    
    input  logic ready_out,
    output logic valid_out,

    // Datapath Control Signals
    output logic load_input,
    output logic use_odd, // 0: Even (0,2..), 1: Odd (1,3..)
    output logic we_temp_reg,
    output logic feedback_sel   // Select Feedback path
);

    // Default Feedback to 0 (No L3 scaling yet)
    assign feedback_sel = 1'b0;

    // FSM States
    // Implements Avant-Garde's two-pass operand flattening:
    // - PROCESS_EVEN: 1st iteration (Elements 0, 2, ..., 30)
    // - PROCESS_ODD:  2nd iteration (Elements 1, 3, ..., 31)
    // Each state triggers temporal register write-back of 16 results.
    typedef enum logic [2:0] {
        IDLE,
        PROCESS_EVEN,  // Process even indices
        PROCESS_ODD,   // Process odd indices
        DONE_WAIT      // Wait for output handshake
    } state_t;

    state_t state, next_state;

    // State Transition
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            state <= IDLE;
        else 
            state <= next_state;
    end

    // Next State Logic
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (valid_in) 
                    next_state = PROCESS_EVEN;
            end
            PROCESS_EVEN: begin
                // One cycle to latch result of even set
                next_state = PROCESS_ODD;
            end
            PROCESS_ODD: begin
                // One cycle to latch result of odd set
                // Direct Transition to DONE_WAIT (Output wired to Temp Regs)
                next_state = DONE_WAIT;
            end
            DONE_WAIT: begin
                if (ready_out) 
                    next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    // Output Logic
    always_comb begin
        // Defaults
        ready_in      = 0;
        valid_out     = 0;
        load_input    = 0;
        use_odd       = 0;
        we_temp_reg   = 0;

        case (state)
            IDLE: begin
                ready_in = 1;
                if (valid_in) begin
                    load_input = 1;
                end
            end
            PROCESS_EVEN: begin
                // Select Even inputs for mul array
                use_odd = 0;
                // Enable write to temp regs
                we_temp_reg    = 1;
            end
            PROCESS_ODD: begin
                // Select Odd inputs
                use_odd = 1;
                we_temp_reg    = 1;
            end
            DONE_WAIT: begin
                valid_out = 1;
            end
        endcase
    end

endmodule
