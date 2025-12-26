`timescale 1ns/1ps
`include "VX_define.vh"

module tb_ot_tcu_integration;

  // Import Packages
  import VX_gpu_pkg::*;
  import VX_ag_tcu_pkg::*;
  // import operand_tf_pkg::*; // Avoid namespace pollution, use scope resolution

  // ---------------------------------------------------------------------------
  // Parameters
  // ---------------------------------------------------------------------------
  localparam string INSTANCE_ID  = "OT_TCU_SYS";
  localparam int    CLK_PERIOD   = 10;
  localparam int    TCU_LANES    = `NUM_TCU_LANES; // 8

  // ---------------------------------------------------------------------------
  // Signals
  // ---------------------------------------------------------------------------
  logic clk, reset;

  // OT Interface (A)
  logic                         ot_a_valid_in, ot_a_ready_in;
  operand_tf_pkg::operand_input_t ot_a_data_in;
  logic                         ot_a_ready_out, ot_a_valid_out;
  operand_tf_pkg::operand_output_t ot_a_data_out;

  // OT Interface (B)
  logic                         ot_b_valid_in, ot_b_ready_in;
  operand_tf_pkg::operand_input_t ot_b_data_in;
  logic                         ot_b_ready_out, ot_b_valid_out;
  operand_tf_pkg::operand_output_t ot_b_data_out;

  // TCU Interface
  logic        execute_valid;
  logic        execute_ready;
  ag_tcu_exe_t execute_data;
  
  logic        result_valid;
  logic        result_ready;
  ag_tcu_res_t result_data;

  // Glue Logic Signals
  logic [255:0] flat_a, flat_b;

  // ---------------------------------------------------------------------------
  // DUT Instantiation
  // ---------------------------------------------------------------------------

  // 1. Operand Transformer A
  operand_transformer_top ot_a (
    .clk      (clk),
    .rst_n    (~reset),
    .valid_in (ot_a_valid_in),
    .ready_in (ot_a_ready_in),
    .data_in  (ot_a_data_in),
    .ready_out(ot_a_ready_out),
    .valid_out(ot_a_valid_out),
    .data_out (ot_a_data_out)
  );

  // 2. Operand Transformer B
  operand_transformer_top ot_b (
    .clk      (clk),
    .rst_n    (~reset),
    .valid_in (ot_b_valid_in),
    .ready_in (ot_b_ready_in),
    .data_in  (ot_b_data_in),
    .ready_out(ot_b_ready_out),
    .valid_out(ot_b_valid_out),
    .data_out (ot_b_data_out)
  );

  // 3. AG-TCU
  VX_ag_tcu_top #(
    .INSTANCE_ID(INSTANCE_ID)
  ) tcu (
    .clk          (clk),
    .reset        (reset),
    .execute_valid(execute_valid),
    .execute_data (execute_data),
    .execute_ready(execute_ready),
    .result_valid (result_valid),
    .result_data  (result_data),
    .result_ready (result_ready)
  );

  // ---------------------------------------------------------------------------
  // Connectivity / Glue Logic
  // ---------------------------------------------------------------------------
  
  // Pipeline Link: OT(Valid) -> TCU(Valid)
  // We wait for BOTH OTs to be valid before firing TCU.
  assign execute_valid = ot_a_valid_out && ot_b_valid_out;
  
  // Backpressure: OT(Ready) <- TCU(Ready)
  assign ot_a_ready_out = execute_ready && ot_b_valid_out; // Consume A only if B is also ready
  assign ot_b_ready_out = execute_ready && ot_a_valid_out; // Consume B only if A is also ready
  
  // Data Mapping (OT Flat -> TCU Lanes)
  assign flat_a = ot_a_data_out.flattened_elements;
  assign flat_b = ot_b_data_out.flattened_elements;

  always_comb begin
      execute_data = '0;
      execute_data.uuid = 32'hDEADBEEF;
      execute_data.op_args.tcu.fmt_s = 9; // Int8
      
      // Scaling handled by OT, so TCU scale is 0
      execute_data.op_args.tcu.scale_a = 0;
      execute_data.op_args.tcu.scale_b = 0;

      // Pack 256-bit Flat Vector into 8x32-bit Lanes
      for(int i=0; i<8; i++) begin
          execute_data.rs1_data[i] = flat_a[i*32 +: 32];
          execute_data.rs2_data[i] = flat_b[i*32 +: 32];
          execute_data.rs3_data[i] = 0; // No Accumulation for this test
      end
  end

  // ---------------------------------------------------------------------------
  // Clock Generation
  // ---------------------------------------------------------------------------
  initial begin
      clk = 0;
      forever #5 clk = ~clk;
  end

  // ---------------------------------------------------------------------------
  // Helper: Sign-Magnitude Shift Calculation (Same as OT Hardware)
  // ---------------------------------------------------------------------------
  function automatic logic [7:0] calc_ot_result(input logic [7:0] elem, input logic [7:0] scale);
      logic       sign;
      logic [6:0] mag;
      logic [2:0] lead_one_pos;
      logic [15:0] target_msb_pos;
      
      sign = elem[7];
      mag  = elem[6:0];
      
      // 1. Find Leading One
      if      (mag[6]) lead_one_pos = 6;
      else if (mag[5]) lead_one_pos = 5;
      else if (mag[4]) lead_one_pos = 4;
      else if (mag[3]) lead_one_pos = 3;
      else if (mag[2]) lead_one_pos = 2;
      else if (mag[1]) lead_one_pos = 1;
      else if (mag[0]) lead_one_pos = 0;
      else             return {sign, 7'd0}; 

      // 2. Calc Shift
      target_msb_pos = {13'd0, lead_one_pos} + {8'd0, scale};

      // 3. Overflow Check
      if (target_msb_pos > 6) mag = mag << (6 - lead_one_pos);
      else                    mag = mag << scale;
      
      return {sign, mag};
  endfunction

  // ---------------------------------------------------------------------------
  // Task: Drive Inputs
  // ---------------------------------------------------------------------------
  task drive_inputs();
      // -------------------------------------------------
      // Generate MX9-like Test Pattern
      // -------------------------------------------------
      
      // OT A Setup: Ascending Values {1, 2, ... 32}
      // Scales: 0, 1, 2, 3 Repeated
      ot_a_valid_in = 1;
      ot_a_data_in.cfg.scale_sharing_mode = 0;
      for(int i=0; i<32; i++) begin
          ot_a_data_in.elements[i] = i+1; 
      end
      for(int i=0; i<16; i++) begin
          ot_a_data_in.micro_scales[i] = i % 4;
      end

      // OT B Setup: Alternating Sign {1, -1, 1, -1...}
      // Scales: Constant 0
      ot_b_valid_in = 1;
      ot_b_data_in.cfg.scale_sharing_mode = 0;
      for(int i=0; i<32; i++) begin
          // Alternating +/- 1
          if (i % 2 == 0) ot_b_data_in.elements[i] = 8'd1;     // +1
          else            ot_b_data_in.elements[i] = 8'h81;    // -1 (Sign-Mag)
      end
      for(int i=0; i<16; i++) begin
          ot_b_data_in.micro_scales[i] = 0;
      end

      // Send to OT
      @(posedge clk);
      while(!ot_a_ready_in || !ot_b_ready_in) @(posedge clk); // Wait for accept
      ot_a_valid_in = 0;
      ot_b_valid_in = 0;
  endtask

  // ---------------------------------------------------------------------------
  // Main Test Procedure
  // ---------------------------------------------------------------------------
  initial begin
      // Init
      reset = 1;
      ot_a_valid_in = 0; ot_b_valid_in = 0;
      result_ready = 1;
      
      repeat(5) @(posedge clk);
      reset = 0;
      @(posedge clk);
      
      $display("Starting OT-TCU Integration Test (MX9 Patterns)...");
      
      // Drive Test Pattern
      drive_inputs();
      
      // Wait for Result
      wait(result_valid);
      @(posedge clk);
      
      // -------------------------------------------------
      // Verify Result (Golden Comparison)
      // -------------------------------------------------
      begin
         logic signed [31:0] check;
         
         for(int lane_idx=0; lane_idx<8; lane_idx++) begin
             logic signed [31:0] expected_acc;
             expected_acc = 0;
             
             // Sum 4 elements per set (since we have 32 elems / 8 lanes = 4 elems/lane if flat)
             for(int k=0; k<4; k++) begin
                 int elem_idx;
                 logic signed [7:0] ot_a_out_sim;
                 logic signed [7:0] ot_b_out_sim;
                 
                 elem_idx = lane_idx * 4 + k;

                 ot_a_out_sim = calc_ot_result(ot_a_data_in.elements[elem_idx], ot_a_data_in.micro_scales[elem_idx/2]);
                 ot_b_out_sim = calc_ot_result(ot_b_data_in.elements[elem_idx], ot_b_data_in.micro_scales[elem_idx/2]);
                 
                 expected_acc += (ot_a_out_sim * ot_b_out_sim);
             end
             
             check = result_data.data[lane_idx];
             $display("Lane %0d | Expected(Partial) %0d | Got %0d", lane_idx, expected_acc, check);
         end
         
         $display("NOTE: If 'Got' is exactly 2x 'Expected', then TCU is accumulating duplicate/paired sets.");
      end
      
      repeat(10) @(posedge clk);
      $finish;
  end

endmodule
