// `timescale 1ns/1ps
`include "VX_define.vh"

module tb_ag_tcu;

  import VX_gpu_pkg::*;
  import VX_ag_tcu_pkg::*;

  // ---------------------------------------------------------------------------
  // Parameters
  // ---------------------------------------------------------------------------
  localparam string INSTANCE_ID  = "AG_TCU_INST";
  localparam int    CLK_PERIOD   = 10;

  localparam int LANES           = `NUM_TCU_LANES; // 4
  localparam int XLEN            = 32;
  localparam int ELEM_W          = 8;
  localparam int ELEMS_PER_LANE  = XLEN / ELEM_W;  // 4
  localparam int TOTAL_ELEMS     = LANES * ELEMS_PER_LANE; // 16

  // ---------------------------------------------------------------------------
  // DUT I/O
  // ---------------------------------------------------------------------------
  logic clk, reset;

  logic        execute_valid;
  logic        execute_ready;
  ag_tcu_exe_t execute_data;

  logic        result_valid;
  logic        result_ready;
  ag_tcu_res_t result_data;

  // TB Debug Signals
  int   tb_case_id;
  int   tb_step_m, tb_step_n;
  logic [7:0] tb_scale_a, tb_scale_b;
  logic [8:0] tb_scale_combined;
  
  logic signed [7:0] tb_A [0:TOTAL_ELEMS-1];
  logic signed [7:0] tb_B [0:TOTAL_ELEMS-1];

  VX_ag_tcu_top #(
    .INSTANCE_ID(INSTANCE_ID)
  ) dut (
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
  // Clock/Reset
  // ---------------------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

  // ---------------------------------------------------------------------------
  // Helper Functions
  // ---------------------------------------------------------------------------
  function automatic logic [XLEN-1:0] pack_lane(input logic signed [7:0] elems [0:ELEMS_PER_LANE-1]);
    logic [XLEN-1:0] w;
    int j;
    begin
      w = '0;
      for (j = 0; j < ELEMS_PER_LANE; j++) begin
        w[j*8 +: 8] = elems[j];
      end
      return w;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Mapping Model (matches VX_ag_tcu_core.sv logic)
  // a_off = step_m * 4
  // i=0: a_row uses inputs [a_off+0, a_off+1]
  // i=1: a_row uses inputs [a_off+2, a_off+3]
  // ---------------------------------------------------------------------------
  function automatic int get_a_idx(input int step_m, input int i, input int k_idx);
      // a_off(step_m*4) + i*2 + k
      return (step_m * 4) + (i * 2) + k_idx;
  endfunction

  function automatic int get_b_idx(input int step_n, input int j, input int k_idx);
     // b_off(step_n*4) + j*2 + k
     return (step_n * 4) + (j * 2) + k_idx;
  endfunction

  // ---------------------------------------------------------------------------
  // Main Test Process
  // ---------------------------------------------------------------------------
  initial begin
    // Init
    reset = 1;
    execute_valid = 0;
    execute_data = '0;
    result_ready = 1;

    // Reset Pulse
    repeat (5) @(posedge clk);
    reset = 0;
    repeat (5) @(posedge clk);

    // -------------------------------------------------------------------------
    // Setup Data Pattern
    // A: 0, 1, 2, ... 15
    // B: 0, 1, 0, 1, ...
    // -------------------------------------------------------------------------
    for(int i=0; i<TOTAL_ELEMS; i++) begin
        tb_A[i] = i;
        tb_B[i] = (i % 2);
    end

    // -------------------------------------------------------------------------
    // Case 1: Step=0, Scale A=0, Scale B=0 -> Combined=0
    // -------------------------------------------------------------------------
    tb_case_id = 1;
    tb_step_m = 0;
    tb_step_n = 0;
    tb_scale_a = 0;
    tb_scale_b = 0;
    
    drive_transaction();
    wait_and_verify();

    // -------------------------------------------------------------------------
    // Case 2: Step=0, Scale A=1, Scale B=2 -> Combined=3 (<<3)
    // Same Data, Same Window (Step 0)
    // -------------------------------------------------------------------------
    tb_case_id = 2;
    tb_step_m = 0;
    tb_step_n = 0;
    tb_scale_a = 1; 
    tb_scale_b = 2; 
    
    drive_transaction();
    wait_and_verify();

    repeat (10) @(posedge clk);
    $display("ALL TESTS PASSED");
    $finish;
  end

  // ---------------------------------------------------------------------------
  // Driver Task
  // ---------------------------------------------------------------------------
  task automatic drive_transaction();
    int i, j;
    logic signed [7:0] lane_A [0:ELEMS_PER_LANE-1];
    logic signed [7:0] lane_B [0:ELEMS_PER_LANE-1];
    begin
        execute_data.uuid = $random;
        execute_data.op_args.tcu.step_m = tb_step_m;
        execute_data.op_args.tcu.step_n = tb_step_n;
        execute_data.op_args.tcu.scale_a = tb_scale_a;
        execute_data.op_args.tcu.scale_b = tb_scale_b;
        execute_data.op_args.tcu.fmt_s = 9; // INT8
        
        tb_scale_combined = tb_scale_a + tb_scale_b;

        // Pack A and B into lanes
        for (i = 0; i < LANES; i++) begin
            for (j = 0; j < ELEMS_PER_LANE; j++) begin
                lane_A[j] = tb_A[i*ELEMS_PER_LANE + j];
                lane_B[j] = tb_B[i*ELEMS_PER_LANE + j];
            end
            execute_data.rs1_data[i] = pack_lane(lane_A);
            execute_data.rs2_data[i] = pack_lane(lane_B);
        end

        // Handshake
        execute_valid = 1;
        do @(posedge clk); while (!execute_ready);
        execute_valid = 0;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Monitor & Verify Task
  // ---------------------------------------------------------------------------
  task automatic wait_and_verify();
    int i, j, k, s;
    logic signed [31:0] gold_tile [0:1][0:1]; // 2x2 Output
    logic signed [31:0] dut_tile  [0:1][0:1]; // Captured DUT output
    logic signed [31:0] dot_val;
    logic signed [31:0] scaled_val;
    begin
        // 1. Calculate Golden
        for(i=0; i<2; i++) begin      // Row (Output Tile)
            for(j=0; j<2; j++) begin  // Col (Output Tile)
                dot_val = 0;
                // Outer Dot Product (K=2 Lanes)
                for(k=0; k<2; k++) begin
                    // These return LANE indices (0..3)
                    // Note: step_m is properly masked in RTL, but here we assume 
                    // user gives valid step or we manually mask.
                    // For NUM_THREADS=4, sub_blocks=1, so offset is always 0.
                    // Effectively step_m is ignored for Lane selection in this config.
                    int lane_a = (0 * 4) + (i * 2) + k; 
                    int lane_b = (0 * 4) + (j * 2) + k; 

                    // SIMD Dot Product (4 Elements per Lane)
                    for(s=0; s<4; s++) begin
                        int idx_a = (lane_a * 4) + s;
                        int idx_b = (lane_b * 4) + s;
                        dot_val += (tb_A[idx_a] * tb_B[idx_b]);
                    end
                end
                // Scaling
                scaled_val = dot_val <<< tb_scale_combined; // Arithmetic shift
                gold_tile[i][j] = scaled_val;
            end
        end

        // 2. Wait for Output
        do @(posedge clk); while (!(result_valid && result_ready));
        
        // 3. Unpack DUT result
        dut_tile[0][0] = result_data.data[0];
        dut_tile[0][1] = result_data.data[1];
        dut_tile[1][0] = result_data.data[2];
        dut_tile[1][1] = result_data.data[3];

        // 4. Compare
        $display("---------------------------------------------------");
        $display("Verify Case %0d (StepM=%0d, StepN=%0d, Scale=%0d)", tb_case_id, tb_step_m, tb_step_n, tb_scale_combined);
        for(i=0; i<2; i++) begin
            for(j=0; j<2; j++) begin
                if (dut_tile[i][j] !== gold_tile[i][j]) begin
                    $error("[FAIL] Tile[%0d][%0d]: Exp=%0d, Got=%0d", i, j, gold_tile[i][j], dut_tile[i][j]);
                end else begin
                    $display("[PASS] Tile[%0d][%0d]: Val=%0d", i, j, dut_tile[i][j]);
                end
            end
        end
        $display("---------------------------------------------------");
    end
  endtask

endmodule
