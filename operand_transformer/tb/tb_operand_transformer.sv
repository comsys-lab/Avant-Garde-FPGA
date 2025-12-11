`timescale 1ns / 1ps
import operand_tf_pkg::*;

module tb_operand_transformer;

    // Clock and Reset
    logic clk;
    logic rst_n;
    
    // DUT Interface
    logic                valid_in, ready_in;
    operand_input_t      data_in;
    logic                ready_out, valid_out;
    operand_output_t     data_out;
    
    // DUT Instance
    operand_transformer dut (.*);
    
    // Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // Waveform Dump
    initial begin
        $dumpfile("operand_transformer.vcd");
        $dumpvars(0, tb_operand_transformer);
    end
    
    // Model Function for Expected Result Calculation (Sign-Magnitude)
    function logic [7:0] calc_expected(input logic [7:0] elem, input logic [7:0] scale);
        logic       sign;
        logic [6:0] mag;
        logic [2:0] lead_one_pos;
        logic [15:0] target_msb_pos;
        
        sign = elem[7];
        mag  = elem[6:0];
        
        // 1. Find Leading One (Magnitude)
        if      (mag[6]) lead_one_pos = 6;
        else if (mag[5]) lead_one_pos = 5;
        else if (mag[4]) lead_one_pos = 4;
        else if (mag[3]) lead_one_pos = 3;
        else if (mag[2]) lead_one_pos = 2;
        else if (mag[1]) lead_one_pos = 1;
        else if (mag[0]) lead_one_pos = 0;
        else             return {sign, 7'd0}; // Zero Magnitude

        // 2. Calc Shift
        target_msb_pos = {13'd0, lead_one_pos} + {8'd0, scale};

        // 3. Overflow Check (Max Mag bit is 6)
        if (target_msb_pos > 6) begin
            // MSB Aligned to bit 6
            mag = mag << (6 - lead_one_pos);
        end else begin
            // Normal Shift
            mag = mag << scale;
        end
        
        return {sign, mag};
    endfunction
    
    // =========================================================================
    // Test Procedure
    // =========================================================================
    initial begin
        // Initialize
        rst_n = 0;
        valid_in = 0;
        ready_out = 0;
        data_in = '0;
        
        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        
        $display("\n========================================");
        $display("Operand Transformer Test (Sign-Mag + Shift)");
        $display("========================================\n");
        
        // Mode 0 (1:2 Sharing)
        data_in.cfg.scale_sharing_mode = 0;
        wait(ready_in);
        
        // -------------------------------------------------------------
        // Setup Pattern: Mixed Signs
        // -------------------------------------------------------------
        
        // Elements: 
        // 0-15: Positive {1, 3, 7, ...}
        // 16-31: Negative {1, 3, 7, ...} (Set MSB)
        for (int i = 0; i < 32; i++) begin
            int val_idx = i % 8; // 0..7
            logic [7:0] val = (1 << (val_idx + 1)) - 1; // 1, 3, 7...
            
            if (i >= 16) val[7] = 1; // Negative for upper half
            
            data_in.elements[i] = val;
        end
        
        // Scales: 
        // Block of 4 uses 0, 1, 2, 3 repeated
        for (int lane = 0; lane < 16; lane++) begin
            data_in.micro_scales[lane] = lane / 4; 
        end
        
        // Send
        valid_in = 1;
        @(posedge clk);
        valid_in = 0;
        
        wait(valid_out);
        @(posedge clk);
        
        // Verify
        $display("\nCheck Results:");
        begin
            int fail_count = 0;
            for (int i = 0; i < 32; i++) begin
                int lane = i / 2;
                logic [7:0] elem  = data_in.elements[i];
                logic [7:0] scale = data_in.micro_scales[lane];
                logic [7:0] res   = data_out.flattened_elements[i];
                logic [7:0] exp   = calc_expected(elem, scale);
                
                string status = (res === exp) ? "✓" : "✗";
                if (res !== exp) fail_count++;
                
                $display("  Elem %2d (S=%1d E=%3d): Scale %1d -> Exp 0x%2h Got 0x%2h %s", 
                         i, elem[7], elem, scale, exp, res, status);
            end
            
            if (fail_count == 0)
                $display("\nSUCCESS: All mixed-sign checks passed!");
            else
                $display("\nFAILURE: %0d mismatches found.", fail_count);
        end
        
        ready_out = 1;
        @(posedge clk);
        ready_out = 0;
        
        repeat(10) @(posedge clk);
        $display("\nTest Complete!");
        $finish;
    end
    
    // Watchdog
    initial begin
        #5000;
        $error("Timeout!");
        $finish;
    end

endmodule
