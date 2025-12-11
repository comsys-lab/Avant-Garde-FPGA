`timescale 1ns / 1ps
import btu_pkg::*;

module tb_btu;

    // Clock and Reset
    logic clk;
    logic rst_n;
    
    // DUT Signals
    logic        valid_in;
    logic        ready_in;
    btu_input_t  data_in;
    
    logic        ready_out;
    logic        valid_out;
    btu_output_t data_out;
    
    // Clock Generation (10ns period)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // DUT Instantiation
    btu_top dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .ready_in  (ready_in),
        .data_in   (data_in),
        .ready_out (ready_out),
        .valid_out (valid_out),
        .data_out  (data_out)
    );
    
    // Golden Model Function
    function automatic void golden_transpose(
        input logic [4:0] n,
        input logic [NUM_WORDS-1:0][DATA_WIDTH-1:0] data_in_array,
        output logic [MAX_OUTPUT-1:0][DATA_WIDTH-1:0] expected_rows,
        output logic [6:0] expected_num_rows
    );
        automatic logic [MAX_OUTPUT-1:0] bits_per_word[NUM_WORDS];
        automatic logic [31:0] word;
        automatic logic [15:0] val0, val1, val2, val3;
        automatic int word_idx, bit_idx, row, col;
        
        // Calculate expected number of rows
        if (n >= 9)
            expected_num_rows = n * 2;  // 2n
        else
            expected_num_rows = n * 4;  // 4n
        
        // Extract bits from each word
        for (word_idx = 0; word_idx < NUM_WORDS; word_idx++) begin
            word = data_in_array[word_idx];
            
            bits_per_word[word_idx] = '0;
            
            if (n >= 9) begin
                // 2 values per word
                val0 = word[15:0];   // Right value
                val1 = word[31:16];  // Left value
                
                for (bit_idx = 0; bit_idx < n; bit_idx++) begin
                    bits_per_word[word_idx][bit_idx]     = val1[bit_idx];  // Left value
                    bits_per_word[word_idx][bit_idx + n] = val0[bit_idx];  // Right value
                end
            end else begin
                // 4 values per word
                val0 = {8'h0, word[7:0]};    // Rightmost
                val1 = {8'h0, word[15:8]};   // Third
                val2 = {8'h0, word[23:16]};  // Second
                val3 = {8'h0, word[31:24]};  // Leftmost
                
                for (bit_idx = 0; bit_idx < n; bit_idx++) begin
                    bits_per_word[word_idx][bit_idx]           = val3[bit_idx];  // Leftmost
                    bits_per_word[word_idx][bit_idx + n]       = val2[bit_idx];  // Second
                    bits_per_word[word_idx][bit_idx + 2*n]     = val1[bit_idx];  // Third
                    bits_per_word[word_idx][bit_idx + 3*n]     = val0[bit_idx];  // Rightmost
                end
            end
        end
        
        // Transpose: collect bits from all words to form rows
        expected_rows = '0;
        for (row = 0; row < expected_num_rows; row++) begin
            for (col = 0; col < NUM_WORDS; col++) begin
                expected_rows[row][col] = bits_per_word[col][row];
            end
        end
    endfunction
    
    // Verification Task
    task verify_output(
        input logic [4:0] n,
        input string test_name
    );
        logic [MAX_OUTPUT-1:0][DATA_WIDTH-1:0] expected_rows;
        logic [6:0] expected_num_rows;
        int error_count;
        
        golden_transpose(n, data_in.data, expected_rows, expected_num_rows);
        
        error_count = 0;
        
        // Check number of rows
        if (data_out.num_rows !== expected_num_rows) begin
            $error("[%s] num_rows mismatch: expected=%0d, got=%0d", 
                   test_name, expected_num_rows, data_out.num_rows);
            error_count++;
        end
        
        // Check each row
        for (int row = 0; row < expected_num_rows; row++) begin
            if (data_out.rows[row] !== expected_rows[row]) begin
                $error("[%s] ROW %0d mismatch: expected=%h, got=%h", 
                       test_name, row, expected_rows[row], data_out.rows[row]);
                error_count++;
            end
        end
        
        if (error_count == 0) begin
            $display("[%s] PASSED (n=%0d, num_rows=%0d)", test_name, n, expected_num_rows);
        end else begin
            $display("[%s] FAILED with %0d errors", test_name, error_count);
        end
    endtask
    
    // Test Procedure
    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_btu);
        
        // Initialize signals
        rst_n = 0;
        valid_in = 0;
        ready_out = 0;
        data_in = '0;
        
        // Reset sequence
        #100;
        rst_n = 1;
        #20;
        
        $display("\n========================================");
        $display("BTU Testbench Started");
        $display("========================================\n");
        
        // =============================================
        // Test Case 1: n=4 (4n=16 output rows)
        // =============================================
        @(posedge clk);
        wait(ready_in);
        
        data_in.n = 5'd4;
        for (int i = 0; i < NUM_WORDS; i++) begin
            // Pack 4 4-bit values: MSB=1, LSB=1, middle=0
            // 4-bit: 0b1001 = 0x9
            data_in.data[i] = {8'h09, 8'h09, 8'h09, 8'h09};
        end
        
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        
        wait(valid_out);
        @(posedge clk);
        verify_output(5'd4, "TC1_n4");
        
        ready_out = 1;
        @(posedge clk);
        ready_out = 0;
        
        repeat(5) @(posedge clk);
        
        // =============================================
        // Test Case 2: n=9 (2n=18 output rows)
        // =============================================
        @(posedge clk);
        wait(ready_in);
        
        data_in.n = 5'd9;
        for (int i = 0; i < NUM_WORDS; i++) begin
            // Pack 2 9-bit values: MSB=1, LSB=1, middle=0
            // 9-bit: 0b100000001 = 0x101
            data_in.data[i] = {7'h0, 9'h101, 7'h0, 9'h101};
        end
        
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        
        wait(valid_out);
        @(posedge clk);
        verify_output(5'd9, "TC2_n9");
        
        ready_out = 1;
        @(posedge clk);
        ready_out = 0;
        
        repeat(5) @(posedge clk);
        
        // =============================================
        // Finish
        // =============================================
        $display("\n========================================");
        $display("BTU Testbench Completed");
        $display("========================================\n");
        
        repeat(20) @(posedge clk);
        $finish;
    end

endmodule : tb_btu
