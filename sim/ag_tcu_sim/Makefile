
# Repo root directory
RTL_DIR = ../../hw/rtl
SIM_DIR = .

# Proper include paths (xvlog uses -i)
INCLUDES += -i $(RTL_DIR)
INCLUDES += -i $(RTL_DIR)/libs
INCLUDES += -i $(RTL_DIR)/interfaces
INCLUDES += -i $(RTL_DIR)/core
INCLUDES += -i $(RTL_DIR)/mem
INCLUDES += -i $(RTL_DIR)/cache
INCLUDES += -i $(RTL_DIR)/fpu
INCLUDES += -i $(RTL_DIR)/tcu
INCLUDES += -i $(RTL_DIR)/ag-tcu

# Source files
SRCS += $(RTL_DIR)/VX_gpu_pkg.sv
SRCS += $(RTL_DIR)/interfaces/VX_execute_if.sv
SRCS += $(RTL_DIR)/interfaces/VX_result_if.sv
SRCS += $(RTL_DIR)/libs/VX_fifo_queue.sv
SRCS += $(RTL_DIR)/libs/VX_pipe_register.sv
SRCS += $(RTL_DIR)/libs/VX_pending_size.sv
SRCS += $(RTL_DIR)/libs/VX_shift_register.sv
SRCS += $(RTL_DIR)/libs/VX_dp_ram.sv
SRCS += $(RTL_DIR)/libs/VX_stream_buffer.sv
SRCS += $(RTL_DIR)/libs/VX_skid_buffer.sv
SRCS += $(RTL_DIR)/ag-tcu/VX_ag_tcu_pkg.sv
SRCS += $(RTL_DIR)/ag-tcu/VX_ag_tcu_top.sv

SRCS += $(RTL_DIR)/ag-tcu/VX_ag_tcu_scale.sv
SRCS += $(RTL_DIR)/ag-tcu/VX_ag_tcu_fedp_scaled.sv
SRCS += $(SIM_DIR)/tb_ag_tcu.sv

# Standard defines (xvlog uses -d)
DEFINES += -d EXT_TCU_ENABLE
DEFINES += -d DBG_TRACE_AG_TCU
DEFINES += -d VIVADO

# Simulation target
all: run

run: compile
	xsim tb_snapshot -tclbatch xsim_run.tcl

compile:
	xvlog --sv $(DEFINES) $(INCLUDES) $(SRCS)
	xelab -debug typical -top tb_ag_tcu -snapshot tb_snapshot

gui: compile
	xsim tb_snapshot -gui

clean:
	rm -rf .Xil xsim.dir *.log *.pb *.jou *.wdb
