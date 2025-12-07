# Verilated -*- Makefile -*-
# DESCRIPTION: Verilator output: Make include file with class lists
#
# This file lists generated Verilated files, for including in higher level makefiles.
# See Vvortex_afu_shim.mk for the caller.

### Switches...
# C11 constructs required?  0/1 (always on now)
VM_C11 = 1
# Timing enabled?  0/1
VM_TIMING = 0
# Coverage output mode?  0/1 (from --coverage)
VM_COVERAGE = 0
# Parallel builds?  0/1 (from --output-split)
VM_PARALLEL_BUILDS = 1
# Tracing output mode?  0/1 (from --trace/--trace-fst)
VM_TRACE = 0
# Tracing output mode in VCD format?  0/1 (from --trace)
VM_TRACE_VCD = 0
# Tracing output mode in FST format?  0/1 (from --trace-fst)
VM_TRACE_FST = 0

### Object file lists...
# Generated module classes, fast-path, compile with highest optimization
VM_CLASSES_FAST += \
	Vvortex_afu_shim \
	Vvortex_afu_shim___024root__DepSet_h9827e285__0 \
	Vvortex_afu_shim___024root__DepSet_h9827e285__1 \
	Vvortex_afu_shim___024root__DepSet_h9827e285__2 \
	Vvortex_afu_shim___024root__DepSet_h9827e285__3 \
	Vvortex_afu_shim___024root__DepSet_hbfdf255d__0 \
	Vvortex_afu_shim___024unit__DepSet_h64c7c04d__0 \
	Vvortex_afu_shim_VX_trace_pkg__DepSet_h52ee3d90__0 \
	Vvortex_afu_shim_VX_schedule_if__DepSet_h81d49551__0 \
	Vvortex_afu_shim_VX_fetch_if__DepSet_h9504b005__0 \
	Vvortex_afu_shim_VX_issue_sched_if__DepSet_hf5ef1846__0 \
	Vvortex_afu_shim_VX_decode_if__DepSet_ha466624f__0 \
	Vvortex_afu_shim_VX_mem_bus_if__D40_T7__DepSet_hd87156a7__0 \
	Vvortex_afu_shim_VX_mem_bus_if__D4_T3__DepSet_hce8f7e1f__0 \
	Vvortex_afu_shim_VX_mem_bus_if__D40_T5__DepSet_hc0d49794__0 \
	Vvortex_afu_shim_VX_mem_bus_if__D10_T3__DepSet_h9530dc3a__0 \
	Vvortex_afu_shim_VX_mem_bus_if__D40_T6__DepSet_h772d4bad__0 \
	Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2__DepSet_he010c8e9__0 \
	Vvortex_afu_shim_VX_mem_bus_if__D4_T2__DepSet_h4daa68ab__0 \
	Vvortex_afu_shim_VX_lsu_mem_if__D10_T3__DepSet_hc2077da8__0 \
	Vvortex_afu_shim_VX_result_if__Tz84__DepSet_h6c4eeb4c__0 \
	Vvortex_afu_shim_VX_execute_if__Tz91__DepSet_h0686f8d7__0 \
	Vvortex_afu_shim_VX_result_if__Tz92__DepSet_h87940aee__0 \
	Vvortex_afu_shim_VX_execute_if__Tz96__DepSet_h6536e623__0 \
	Vvortex_afu_shim_VX_result_if__Tz97__DepSet_h45049c60__0 \
	Vvortex_afu_shim_VX_result_if__Tz101__DepSet_h67aa22cf__0 \
	Vvortex_afu_shim_VX_writeback_if__DepSet_hda4c4b46__0 \
	Vvortex_afu_shim_VX_ibuffer_if__DepSet_h233a42e3__0 \
	Vvortex_afu_shim_VX_scoreboard_if__DepSet_h0c50a98b__0 \
	Vvortex_afu_shim_VX_operands_if__DepSet_hb87dbdd3__0 \

# Generated module classes, non-fast-path, compile with low/medium optimization
VM_CLASSES_SLOW += \
	Vvortex_afu_shim__ConstPool_0 \
	Vvortex_afu_shim___024root__Slow \
	Vvortex_afu_shim___024root__DepSet_h9827e285__0__Slow \
	Vvortex_afu_shim___024root__DepSet_h9827e285__1__Slow \
	Vvortex_afu_shim___024root__DepSet_hbfdf255d__0__Slow \
	Vvortex_afu_shim___024unit__Slow \
	Vvortex_afu_shim___024unit__DepSet_h233f0395__0__Slow \
	Vvortex_afu_shim_VX_trace_pkg__Slow \
	Vvortex_afu_shim_VX_trace_pkg__DepSet_h38143577__0__Slow \
	Vvortex_afu_shim_VX_schedule_if__Slow \
	Vvortex_afu_shim_VX_schedule_if__DepSet_h81d49551__0__Slow \
	Vvortex_afu_shim_VX_fetch_if__Slow \
	Vvortex_afu_shim_VX_fetch_if__DepSet_h9504b005__0__Slow \
	Vvortex_afu_shim_VX_issue_sched_if__Slow \
	Vvortex_afu_shim_VX_issue_sched_if__DepSet_hf5ef1846__0__Slow \
	Vvortex_afu_shim_VX_decode_if__Slow \
	Vvortex_afu_shim_VX_decode_if__DepSet_ha466624f__0__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D40_T7__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D40_T7__DepSet_hd87156a7__0__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D4_T3__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D4_T3__DepSet_hce8f7e1f__0__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D40_T5__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D40_T5__DepSet_hc0d49794__0__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D10_T3__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D10_T3__DepSet_h9530dc3a__0__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D40_T6__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D40_T6__DepSet_h772d4bad__0__Slow \
	Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2__Slow \
	Vvortex_afu_shim_VX_lsu_mem_if__N4_D4_T2__DepSet_he010c8e9__0__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D4_T2__Slow \
	Vvortex_afu_shim_VX_mem_bus_if__D4_T2__DepSet_h4daa68ab__0__Slow \
	Vvortex_afu_shim_VX_lsu_mem_if__D10_T3__Slow \
	Vvortex_afu_shim_VX_lsu_mem_if__D10_T3__DepSet_hc2077da8__0__Slow \
	Vvortex_afu_shim_VX_result_if__Tz84__Slow \
	Vvortex_afu_shim_VX_result_if__Tz84__DepSet_h6c4eeb4c__0__Slow \
	Vvortex_afu_shim_VX_execute_if__Tz91__Slow \
	Vvortex_afu_shim_VX_execute_if__Tz91__DepSet_h0686f8d7__0__Slow \
	Vvortex_afu_shim_VX_result_if__Tz92__Slow \
	Vvortex_afu_shim_VX_result_if__Tz92__DepSet_h87940aee__0__Slow \
	Vvortex_afu_shim_VX_execute_if__Tz96__Slow \
	Vvortex_afu_shim_VX_execute_if__Tz96__DepSet_h6536e623__0__Slow \
	Vvortex_afu_shim_VX_result_if__Tz97__Slow \
	Vvortex_afu_shim_VX_result_if__Tz97__DepSet_h45049c60__0__Slow \
	Vvortex_afu_shim_VX_result_if__Tz101__Slow \
	Vvortex_afu_shim_VX_result_if__Tz101__DepSet_h67aa22cf__0__Slow \
	Vvortex_afu_shim_VX_writeback_if__Slow \
	Vvortex_afu_shim_VX_writeback_if__DepSet_hda4c4b46__0__Slow \
	Vvortex_afu_shim_VX_ibuffer_if__Slow \
	Vvortex_afu_shim_VX_ibuffer_if__DepSet_h233a42e3__0__Slow \
	Vvortex_afu_shim_VX_scoreboard_if__Slow \
	Vvortex_afu_shim_VX_scoreboard_if__DepSet_h0c50a98b__0__Slow \
	Vvortex_afu_shim_VX_operands_if__Slow \
	Vvortex_afu_shim_VX_operands_if__DepSet_hb87dbdd3__0__Slow \

# Generated support classes, fast-path, compile with highest optimization
VM_SUPPORT_FAST += \
	Vvortex_afu_shim__Dpi \

# Generated support classes, non-fast-path, compile with low/medium optimization
VM_SUPPORT_SLOW += \
	Vvortex_afu_shim__Syms \

# Global classes, need linked once per executable, fast-path, compile with highest optimization
VM_GLOBAL_FAST += \
	verilated \
	verilated_dpi \
	verilated_threads \

# Global classes, need linked once per executable, non-fast-path, compile with low/medium optimization
VM_GLOBAL_SLOW += \


# Verilated -*- Makefile -*-
