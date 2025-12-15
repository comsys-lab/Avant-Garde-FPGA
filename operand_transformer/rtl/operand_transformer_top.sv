`timescale 1ns / 1ps
import operand_tf_pkg::*;

module operand_transformer_top (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             valid_in,
    output logic             ready_in,
    input  operand_input_t   data_in,
    input  logic             ready_out,
    output logic             valid_out,
    output operand_output_t  data_out
);

    // Control signals
    logic load_input, we_temp_reg, use_odd, we_output_reg, feedback_sel;
    
    operand_transformer_ctrl u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .valid_in(valid_in), .ready_in(ready_in),
        .ready_out(ready_out), .valid_out(valid_out),
        .load_input(load_input),
        .we_temp_reg(we_temp_reg),
        .use_odd(use_odd),
        .feedback_sel(feedback_sel)
    );

    // Lane results (Temporal Registers)
    logic [15:0][ELEM_WIDTH_OUT-1:0] lane_res_even, lane_res_odd;
    
    // Configuration Buffer
    config_t cfg_buf;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cfg_buf <= '0;
        else if (load_input) cfg_buf <= data_in.cfg;
    end
    
    // Lane Instantiation
    genvar i;
    generate
        for (i = 0; i < 16; i++) begin : gen_lanes
            // Scale Selection Logic
            logic [SCALE_WIDTH-1:0] sel_scale;
            
            always_comb begin
                if (cfg_buf.scale_sharing_mode == 1'b1) begin
                    // 1:4 Sharing: Lanes 2k and 2k+1 share micro_scales[k]
                    // i=0,1 -> scale[0]
                    // i=2,3 -> scale[1] ...
                    sel_scale = data_in.micro_scales[i / 2];
                end else begin
                    // 1:2 Sharing (Default): Lane i uses micro_scales[i]
                    sel_scale = data_in.micro_scales[i];
                end
            end
        
            operand_tf_lane u_lane (
                .clk(clk), .rst_n(rst_n),
                .load_input(load_input),
                .iter_sel(use_odd),
                .feedback_sel(feedback_sel),
                .we_result(we_temp_reg),
                // Elements: 2 per lane (0/1, 2/3, ...)
                .elem_0_in(data_in.elements[2*i]),
                .elem_1_in(data_in.elements[2*i+1]),
                // Selected Micro Scale
                .micro_scale_in(sel_scale),
                // Outputs
                .res_0_out(lane_res_even[i]),
                .res_1_out(lane_res_odd[i])
            );
        end
    endgenerate

    // Output Mapping with Synchronization Register
    // Ensures all 32 elements appear simultaneously at the output port
    // Output Mapping (Direct Wire)
    // Lane Temporal Registers hold valid data during DONE_WAIT state
    always_comb begin
        for (int j = 0; j < 16; j++) begin
            data_out.flattened_elements[2*j]   = lane_res_even[j];
            data_out.flattened_elements[2*j+1] = lane_res_odd[j];
        end
    end

endmodule
