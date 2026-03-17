// Level 9: VX_schedule Testbench
// DUT: VX_schedule (warp scheduler, PC management, stall/release, branch)
//
// TC1: pc_sequential     — warp 0 schedules repeatedly, PC +1 (word) each cycle
// TC2: stall_no_unlock   — warp stalls until decode_sched_if.unlock received
// TC3: two_warp_sched    — warp 1 activated; priority encoder picks warp 0 first
// TC4: branch_taken      — branch_ctl_if.taken=1 updates warp PC
// TC5: branch_not_taken  — branch_ctl_if.taken=0 leaves PC unchanged
// TC6: busy_signal       — busy=1 while warp active, busy=0 after TMC exit

`include "VX_define.vh"

module tb_schedule import VX_gpu_pkg::*; ();

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    localparam CLK_HALF = 5;
    logic clk = 0, reset;
    always #CLK_HALF clk = ~clk;

    // Startup address used for all TCs
    localparam logic [`XLEN-1:0] STARTUP_ADDR = `XLEN'h80000000;

    // -----------------------------------------------------------------------
    // Interfaces
    // -----------------------------------------------------------------------
    base_dcrs_t          base_dcrs;
    VX_warp_ctl_if       warp_ctl_if();
    VX_branch_ctl_if     branch_ctl_if[`NUM_ALU_BLOCKS]();
    VX_decode_sched_if   decode_sched_if();
    VX_issue_sched_if    issue_sched_if[`ISSUE_WIDTH]();
    VX_commit_sched_if   commit_sched_if();
    VX_schedule_if       schedule_if();
    VX_sched_csr_if      sched_csr_if();
    wire                 busy;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    VX_schedule #(
        .INSTANCE_ID ("tb_schedule"),
        .CORE_ID     (0)
    ) dut (
        .clk             (clk),
        .reset           (reset),
        .base_dcrs       (base_dcrs),
        .warp_ctl_if     (warp_ctl_if),
        .branch_ctl_if   (branch_ctl_if),
        .decode_sched_if (decode_sched_if),
        .issue_sched_if  (issue_sched_if),
        .commit_sched_if (commit_sched_if),
        .schedule_if     (schedule_if),
        .sched_csr_if    (sched_csr_if),
        .busy            (busy)
    );

    // -----------------------------------------------------------------------
    // TB driver signals
    // -----------------------------------------------------------------------

    // schedule_if: TB always accepts all scheduled outputs
    assign schedule_if.ready = 1'b1;

    // sched_csr_if: inputs to DUT tied to idle
    assign sched_csr_if.unlock_warp    = 1'b0;
    assign sched_csr_if.unlock_wid     = '0;
    assign sched_csr_if.alm_empty_wid  = '0;

    // issue_sched_if: idle (pending_size counter unused in TB)
    for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin : g_issue_idle
        assign issue_sched_if[i].valid = 1'b0;
        assign issue_sched_if[i].wis   = '0;
    end

    // commit_sched_if: driven by TB
    logic [`NUM_WARPS-1:0] tb_committed_warps;
    assign commit_sched_if.committed_warps = tb_committed_warps;

    // warp_ctl_if: driven by TB
    logic            tb_wctl_valid;
    logic [NW_WIDTH-1:0]  tb_wctl_wid;
    tmc_t            tb_wctl_tmc;
    wspawn_t         tb_wctl_wspawn;
    split_t          tb_wctl_split;
    join_t           tb_wctl_sjoin;
    barrier_t        tb_wctl_barrier;
    logic [NW_WIDTH-1:0]  tb_wctl_dvstack_wid;

    assign warp_ctl_if.valid        = tb_wctl_valid;
    assign warp_ctl_if.wid          = tb_wctl_wid;
    assign warp_ctl_if.tmc          = tb_wctl_tmc;
    assign warp_ctl_if.wspawn       = tb_wctl_wspawn;
    assign warp_ctl_if.split        = tb_wctl_split;
    assign warp_ctl_if.sjoin        = tb_wctl_sjoin;
    assign warp_ctl_if.barrier      = tb_wctl_barrier;
    assign warp_ctl_if.dvstack_wid  = tb_wctl_dvstack_wid;

    // branch_ctl_if: driven by TB (only index [0] exercised, NUM_ALU_BLOCKS=1)
    logic            tb_branch_valid [`NUM_ALU_BLOCKS];
    logic [NW_WIDTH-1:0]  tb_branch_wid   [`NUM_ALU_BLOCKS];
    logic            tb_branch_taken  [`NUM_ALU_BLOCKS];
    logic [PC_BITS-1:0]   tb_branch_dest  [`NUM_ALU_BLOCKS];

    for (genvar i = 0; i < `NUM_ALU_BLOCKS; ++i) begin : g_branch_drive
        assign branch_ctl_if[i].valid = tb_branch_valid[i];
        assign branch_ctl_if[i].wid   = tb_branch_wid[i];
        assign branch_ctl_if[i].taken = tb_branch_taken[i];
        assign branch_ctl_if[i].dest  = tb_branch_dest[i];
    end

    // decode_sched_if: driven by TB
    logic            tb_dec_valid;
    logic            tb_dec_unlock;
    logic [NW_WIDTH-1:0]  tb_dec_wid;

    assign decode_sched_if.valid  = tb_dec_valid;
    assign decode_sched_if.unlock = tb_dec_unlock;
    assign decode_sched_if.wid    = tb_dec_wid;

    // -----------------------------------------------------------------------
    // Test utilities
    // -----------------------------------------------------------------------
    int pass_cnt = 0, fail_cnt = 0;

    // Idle all driven inputs
    task automatic idle_inputs();
        tb_wctl_valid       = 0;
        tb_wctl_wid         = '0;
        tb_wctl_tmc         = '0;
        tb_wctl_wspawn      = '0;
        tb_wctl_split       = '0;
        tb_wctl_sjoin       = '0;
        tb_wctl_barrier     = '0;
        tb_wctl_dvstack_wid = '0;
        for (int i = 0; i < `NUM_ALU_BLOCKS; i++) begin
            tb_branch_valid[i] = 0;
            tb_branch_wid[i]   = '0;
            tb_branch_taken[i] = 0;
            tb_branch_dest[i]  = '0;
        end
        tb_dec_valid        = 0;
        tb_dec_unlock       = 0;
        tb_dec_wid          = '0;
        tb_committed_warps  = '0;
    endtask

    // Reset DUT and idle all inputs.
    // reset=0 is applied AFTER a posedge (via #1 delay) so the DUT sees
    // a clean reset=0 at the NEXT posedge without any same-cycle re-evaluation.
    task automatic do_reset();
        reset = 1;
        idle_inputs();
        repeat (4) @(posedge clk); // hold reset ≥ 4 cycles
        #1;                         // deassert between posedges to avoid race
        reset = 0;
        @(posedge clk);             // one clean cycle with reset=0
    endtask

    // Wait for one valid output on schedule_if (TB always has ready=1)
    task automatic wait_schedule(
        output logic [NW_WIDTH-1:0] wid_out,
        output logic [PC_BITS-1:0]  pc_out
    );
        @(posedge clk iff (schedule_if.valid));
        wid_out = schedule_if.data.wid;
        pc_out  = schedule_if.data.PC;
    endtask

    // One-cycle pulse on decode_sched_if.unlock for given wid.
    // Applied between posedges (via #1) so the DUT sees it cleanly.
    task automatic send_decode_unlock(input logic [NW_WIDTH-1:0] wid);
        #1;
        tb_dec_valid  = 1;
        tb_dec_unlock = 1;
        tb_dec_wid    = wid;
        @(posedge clk);
        #1;
        tb_dec_valid  = 0;
        tb_dec_unlock = 0;
    endtask

    task automatic check(input string name, input logic ok);
        if (ok) begin
            $display("[PASS] %-30s", name);
            pass_cnt++;
        end else begin
            $display("[FAIL] %-30s", name);
            fail_cnt++;
        end
    endtask

    // -----------------------------------------------------------------------
    // TC1: pc_sequential
    //   Warp 0 schedules 4 times, each time receiving decode_unlock.
    //   schedule_if.data.PC must increment by from_fullPC(4) each iteration.
    //   In debug mode (no NDEBUG): PC_BITS=XLEN=32, from_fullPC=identity → +4
    //   In release mode (NDEBUG): PC_BITS=30, from_fullPC=pc>>2 → +1
    //   PC advances when schedule_if fires (post-buffer, ready=1 always).
    // -----------------------------------------------------------------------
    task automatic tc_pc_sequential();
        automatic logic [NW_WIDTH-1:0] wid;
        automatic logic [PC_BITS-1:0]  pc, expected_pc;
        automatic logic [PC_BITS-1:0]  pc_step;
        automatic logic ok = 1;

        do_reset();
        $display("--- TC1: pc_sequential ---");
        expected_pc = from_fullPC(STARTUP_ADDR);
        pc_step     = from_fullPC(`XLEN'(4)); // correct increment regardless of mode

        for (int i = 0; i < 4; i++) begin
            wait_schedule(wid, pc);
            if (wid !== NW_WIDTH'(0) || pc !== expected_pc) begin
                $display("  iter%0d: wid=%0d PC=0x%08h, expected wid=0 PC=0x%08h",
                    i, wid, pc, expected_pc);
                ok = 0;
            end
            expected_pc = expected_pc + pc_step;
            send_decode_unlock(NW_WIDTH'(0));
        end
        check("TC1_pc_sequential", ok);
    endtask

    // -----------------------------------------------------------------------
    // TC2: stall_no_unlock
    //   Warp 0 schedules once. Without decode_unlock, must not schedule again
    //   for at least 10 cycles.
    // -----------------------------------------------------------------------
    task automatic tc_stall_no_unlock();
        automatic logic [NW_WIDTH-1:0] wid;
        automatic logic [PC_BITS-1:0]  pc;
        automatic int spurious = 0;

        do_reset();
        $display("--- TC2: stall_no_unlock ---");
        wait_schedule(wid, pc);         // warp 0 fires → stalled

        repeat (10) begin
            @(posedge clk);
            if (schedule_if.valid) spurious++;
        end
        check("TC2_stall_no_unlock", (spurious == 0));

        send_decode_unlock(NW_WIDTH'(0)); // cleanup
    endtask

    // -----------------------------------------------------------------------
    // TC3: two_warp_sched
    //   Warp 0 schedules first (only active warp after reset → stalls).
    //   Then activate warp 1 via TMC while warp 0 is stalled.
    //   Warp 1 schedules next, then after unlock warp 0 re-schedules (priority).
    // -----------------------------------------------------------------------
    task automatic tc_two_warp_sched();
        automatic logic [NW_WIDTH-1:0] wid;
        automatic logic [PC_BITS-1:0]  pc;
        automatic logic ok = 1;

        do_reset();
        $display("--- TC3: two_warp_sched ---");

        // Step 1: warp 0 schedules first (only active warp)
        wait_schedule(wid, pc);
        if (wid !== NW_WIDTH'(0)) begin
            $display("  Step1: Expected wid=0 (only active), got wid=%0d", wid);
            ok = 0;
        end
        // Warp 0 is now stalled

        // Step 2: activate warp 1 while warp 0 is stalled
        #1;
        tb_wctl_valid       = 1;
        tb_wctl_wid         = NW_WIDTH'(1);
        tb_wctl_tmc.valid   = 1;
        tb_wctl_tmc.tmask   = `NUM_THREADS'(1);
        @(posedge clk); #1; idle_inputs();

        // Step 3: warp 1 schedules (warp 0 still stalled)
        wait_schedule(wid, pc);
        if (wid !== NW_WIDTH'(1)) begin
            $display("  Step3: Expected wid=1 (warp0 stalled), got wid=%0d", wid);
            ok = 0;
        end

        // Step 4: unlock warp 0 → warp 0 re-schedules (priority 0 > 1)
        send_decode_unlock(NW_WIDTH'(0));
        wait_schedule(wid, pc);
        if (wid !== NW_WIDTH'(0)) begin
            $display("  Step4: Expected wid=0 (priority), got wid=%0d", wid);
            ok = 0;
        end
        check("TC3_two_warp_sched", ok);

        // Cleanup: deactivate both warps
        #1;
        tb_wctl_valid = 1; tb_wctl_wid = NW_WIDTH'(0);
        tb_wctl_tmc.valid = 1; tb_wctl_tmc.tmask = '0;
        @(posedge clk); #1;
        tb_wctl_wid = NW_WIDTH'(1); @(posedge clk); #1;
        idle_inputs();
    endtask

    // -----------------------------------------------------------------------
    // TC4: branch_taken
    //   Schedule warp 0. Send branch_ctl_if.taken=1 with dest=target.
    //   Next schedule_if output for warp 0 must have PC=target.
    // -----------------------------------------------------------------------
    task automatic tc_branch_taken();
        automatic logic [NW_WIDTH-1:0] wid;
        automatic logic [PC_BITS-1:0]  pc, branch_target;
        automatic logic ok;

        do_reset();
        $display("--- TC4: branch_taken ---");
        wait_schedule(wid, pc);         // warp 0 schedules → stalled
        branch_target = from_fullPC(`XLEN'h80002000); // distinct from startup
        #1;
        tb_branch_valid[0] = 1;
        tb_branch_wid[0]   = NW_WIDTH'(0);
        tb_branch_taken[0] = 1;
        tb_branch_dest[0]  = branch_target; // unlocks warp AND updates PC
        @(posedge clk);
        #1;
        idle_inputs();

        wait_schedule(wid, pc);
        ok = (wid === NW_WIDTH'(0)) && (pc === branch_target);
        if (!ok)
            $display("  wid=%0d PC=0x%08h, expected wid=0 PC=0x%08h",
                wid, pc, branch_target);
        check("TC4_branch_taken", ok);
        send_decode_unlock(NW_WIDTH'(0));
    endtask

    // -----------------------------------------------------------------------
    // TC5: branch_not_taken
    //   Schedule warp 0. Send branch_ctl_if.taken=0 (unlocks only, PC unchanged).
    //   Next schedule should have PC = startup_pc + 1 (PC advanced at schedule_if fire).
    // -----------------------------------------------------------------------
    task automatic tc_branch_not_taken();
        automatic logic [NW_WIDTH-1:0] wid;
        automatic logic [PC_BITS-1:0]  pc, next_pc;
        automatic logic ok;

        do_reset();
        $display("--- TC5: branch_not_taken ---");
        wait_schedule(wid, pc);         // warp 0 at startup_pc → stalled
        // PC advanced by schedule_if_fire; from_fullPC(4) = 4 in debug, 1 in release
        next_pc = pc + from_fullPC(`XLEN'(4));

        #1;
        tb_branch_valid[0] = 1;
        tb_branch_wid[0]   = NW_WIDTH'(0);
        tb_branch_taken[0] = 0;         // unlock only, PC not updated
        tb_branch_dest[0]  = '0;
        @(posedge clk);
        #1;
        idle_inputs();

        wait_schedule(wid, pc);
        ok = (wid === NW_WIDTH'(0)) && (pc === next_pc);
        if (!ok)
            $display("  wid=%0d PC=0x%08h, expected wid=0 PC=0x%08h",
                wid, pc, next_pc);
        check("TC5_branch_not_taken", ok);
        send_decode_unlock(NW_WIDTH'(0));
    endtask

    // -----------------------------------------------------------------------
    // TC6: busy_signal
    //   busy=1 immediately after reset (warp 0 active).
    //   After TMC exit (tmask=0), busy must deassert within a few cycles.
    // -----------------------------------------------------------------------
    task automatic tc_busy_signal();
        automatic logic [NW_WIDTH-1:0] wid_tmp;
        automatic logic [PC_BITS-1:0]  pc_tmp;
        automatic logic ok = 1;

        do_reset();
        $display("--- TC6: busy_signal ---");

        // Warp 0 schedules at do_reset's final posedge; schedule_if fires one cycle later.
        // At that same cycle, busy=1 (BUFFER_EX 1-cycle from active_warps=1 at reset).
        // wait_schedule captures the schedule event — check busy here.
        wait_schedule(wid_tmp, pc_tmp);   // warp 0 stalls after this
        if (!busy) begin
            $display("  busy should be 1 at first schedule (warp 0 active)");
            ok = 0;
        end

        // Deactivate warp 0 via TMC with tmask=0 (also unlocks stall)
        #1;
        tb_wctl_valid       = 1;
        tb_wctl_wid         = NW_WIDTH'(0);
        tb_wctl_tmc.valid   = 1;
        tb_wctl_tmc.tmask   = '0;
        @(posedge clk);
        #1;
        idle_inputs();

        // busy should deassert within a few cycles (BUFFER_EX 1-cycle delay)
        repeat (4) @(posedge clk);
        if (busy) begin
            $display("  busy should be 0 after warp 0 exit via TMC");
            ok = 0;
        end
        check("TC6_busy_signal", ok);
    endtask

    // -----------------------------------------------------------------------
    // Main
    // -----------------------------------------------------------------------
    initial begin
        base_dcrs.startup_addr = STARTUP_ADDR;
        base_dcrs.startup_arg  = '0;
        base_dcrs.mpm_class    = '0;

        $display("=== Level 9: VX_schedule Testbench ===");
        $display("NUM_WARPS=%0d  NUM_THREADS=%0d  PC_BITS=%0d  NUM_ALU_BLOCKS=%0d",
            `NUM_WARPS, `NUM_THREADS, PC_BITS, `NUM_ALU_BLOCKS);

        tc_pc_sequential();
        tc_stall_no_unlock();
        tc_two_warp_sched();
        tc_branch_taken();
        tc_branch_not_taken();
        tc_busy_signal();

        $display("=== Results: %0d PASS, %0d FAIL ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL TESTS PASSED");
        else               $display("SOME TESTS FAILED");
        $finish;
    end

endmodule
