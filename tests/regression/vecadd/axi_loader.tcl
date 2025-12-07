
puts "DEBUG_XSIM: Starting Optimized AXI Backdoor Loader"
set debug_parent "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/memory_subsystem/inst/interconnect/interconnect_ddr4_mem00"
puts "DEBUG_XSIM: SCAN START INTERCONNECT"
if {[catch {
    foreach obj [get_objects -filter {NAME =~ *S*_AXI*} $debug_parent/*] {
        puts "DEBUG_XSIM: PORT: $obj"
    }
} err]} {
    puts "DEBUG_XSIM: Error listing objects: $err"
}
puts "DEBUG_XSIM: SCAN END"

# Correct Path verified by Diagnostic Dump (Single Slash, Underscore)
set axi_path "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/memory_subsystem/inst/interconnect/interconnect_ddr4_mem00/S01_AXI"

# Aliases (Using underscore as flattened/interface ports)
set s_awaddr  "${axi_path}_awaddr"
set s_awvalid "${axi_path}_awvalid"
set s_awlen   "${axi_path}_awlen"
set s_awsize  "${axi_path}_awsize"
set s_awburst "${axi_path}_awburst"
set s_wdata   "${axi_path}_wdata"
set s_wstrb   "${axi_path}_wstrb"
set s_wvalid  "${axi_path}_wvalid"
set s_wlast   "${axi_path}_wlast"
set s_bready  "${axi_path}_bready"

# Initialize Global Timer (Start LATE: 1ms to ensure calibration done)
set current_time_ns 1000000 ;# Start at 1ms
set period 100 ;# 100ns period

# Procedure to schedule writes from a file to a base address
proc schedule_writes {filename base_addr} {
    global current_time_ns period axi_path
    global s_awaddr s_awvalid s_awlen s_awsize s_awburst
    global s_wdata s_wstrb s_wvalid s_wlast s_bready

    puts "DEBUG_XSIM: Scheduling writes for $filename at [format 0x%x $base_addr]"

    if {[catch {
        set fp [open $filename r]
        set file_data [read $fp]
        close $fp
    } err]} {
        puts "DEBUG_XSIM: Error reading $filename: $err"
        return
    }

    set lines [split $file_data "\n"]
    set offset 0
    set byte_count 0

    foreach line $lines {
        set line [string trim $line]
        if {$line eq ""} continue
        
        # Data is hex
        set hex_data $line
        # format addr as hex digits only
        set hex_addr [format "%x" [expr $base_addr + $offset]]
        
        set t_ns "${current_time_ns}ns"
        
        # Check READY status
        if {[catch {
            set awready_val [get_value -radix bin ${axi_path}_awready]
            set wready_val  [get_value -radix bin ${axi_path}_wready]
            puts "DEBUG_XSIM: [format %x $hex_addr] AWREADY=$awready_val WREADY=$wready_val"
        } err]} {
             puts "DEBUG_XSIM: Error reading READY: $err"
        }

        # Use -radix hex for all vector forces
        # AW Channel
        add_force $s_awaddr  -radix hex [list $hex_addr $t_ns]
        add_force $s_awvalid [list 1 $t_ns]
        add_force $s_awlen   -radix hex [list 00 $t_ns]
        add_force $s_awsize  -radix hex [list 2 $t_ns]  ;# 4 bytes
        add_force $s_awburst -radix hex [list 1 $t_ns]  ;# INCR
        
        # W Channel
        add_force $s_wdata   -radix hex [list $hex_data $t_ns]
        add_force $s_wstrb   -radix hex [list F $t_ns]
        add_force $s_wlast   [list 1 $t_ns]
        add_force $s_wvalid  [list 1 $t_ns]
        
        set off_time_ns [expr $current_time_ns + ($period / 2)]
        set off_t_ns "${off_time_ns}ns"
        
        # Schedule deassertion
        add_force $s_awvalid [list 0 $off_t_ns] -cancel_after [expr $off_time_ns + 10]ns
        add_force $s_wvalid  [list 0 $off_t_ns] -cancel_after [expr $off_time_ns + 10]ns
        
        set current_time_ns [expr $current_time_ns + $period]
        incr byte_count 4
        set offset [expr $offset + 4]
    }
    puts "DEBUG_XSIM: Finished scheduling $filename. Total bytes: $byte_count"
}

# 1. Reset Control
# Previous working paths
set p_reset_path "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/vortex_afu_1/inst/afu_wrap/reset"
set v_reset_path "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/vortex_afu_1/inst/afu_wrap/vx_reset"
set a_reset_path "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/vortex_afu_1/inst/afu_wrap/ap_reset"

# Release AFU Reset early (to enable DDR)
# Reset Sequence: Assert (1) -> Release (0)
add_force $p_reset_path 1
add_force $p_reset_path 0 1000ns

# Core Resets (Active High) - Hold VERY LONG (2ms)
# Note: vx_reset and ap_reset logic
set core_reset_path "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/vortex_afu_1/inst/afu_wrap/vortex_axi/vortex/reset"
add_force $v_reset_path 1
add_force $a_reset_path 1
add_force $core_reset_path 1

# Release Core Resets at 2ms (After writes complete)
add_force $v_reset_path 0 2000000ns
add_force $a_reset_path 0 2000000ns
add_force $core_reset_path 0 2000000ns

# 2. Schedule Writes
# Ensure BREADY is always high to accept responses
add_force $s_bready 1

# Load Kernel Code (At 0x20000)
schedule_writes "/home/yonghun/vortex/tests/regression/vecadd/kernel.dat" 0x20000

# Load Kernel Args (At 0x10300)
schedule_writes "/home/yonghun/vortex/tests/regression/vecadd/args.dat" 0x10300

# Load Vector Data (Src0 at 0x30000)
schedule_writes "/home/yonghun/vortex/tests/regression/vecadd/src0.dat" 0x30000

# Load Vector Data (Src1 at 0x40000)
schedule_writes "/home/yonghun/vortex/tests/regression/vecadd/src1.dat" 0x40000

add_force $s_bready 1

puts "DEBUG_XSIM: Finished scheduling."
