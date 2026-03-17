// Level 8b: VX_fetch Testbench
// DUT: VX_fetch (I-cache tag store, PC/tmask roundtrip, pipeline)
//
// Architecture:
//   schedule_if (TB drives) → [VX_fetch] → icache_bus_if.req (TB captures)
//   icache_bus_if.rsp (TB drives) → [VX_fetch] → fetch_if (TB captures)
//
// TB models a 1-cycle I-cache: when req fires, respond next cycle.
//
// TC1: single_fetch        — one warp request, verify PC/tmask roundtrip
// TC2: four_warp_tag_store — 4 warps with different PCs/tmasks, responses
//                            returned in order, verify no cross-warp corruption
// TC3: interleaved_rsp     — 4 sequential requests, responses returned in
//                            reverse order to exercise tag store indexing
// TC4: ibuf_backpressure   — fetch_if.ready=0 stalls DUT (rsp_ready=0)
// TC5: tmask_fidelity      — partial thread masks preserved through tag store

`include "VX_define.vh"

module tb_fetch import VX_gpu_pkg::*; ();

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    localparam CLK_HALF = 5;
    logic clk = 0, reset;
    always #CLK_HALF clk = ~clk;

    // -----------------------------------------------------------------------
    // I-cache bus parameters
    //   DATA_SIZE = ICACHE_WORD_SIZE = 4 bytes (32-bit instruction)
    //   TAG_WIDTH = ICACHE_TAG_WIDTH = UUID_WIDTH + NW_WIDTH
    // -----------------------------------------------------------------------
    localparam IC_DATA_SIZE = ICACHE_WORD_SIZE;  // 4
    localparam IC_TAG_WIDTH = ICACHE_TAG_WIDTH;  // UUID_WIDTH + NW_WIDTH

    // -----------------------------------------------------------------------
    // Interfaces
    // -----------------------------------------------------------------------
    VX_schedule_if schedule_if();
    VX_fetch_if    fetch_if();

    // I-cache bus: DUT is master (drives req, reads rsp)
    // TB acts as slave (accepts req, drives rsp)
    VX_mem_bus_if #(
        .DATA_SIZE  (IC_DATA_SIZE),
        .TAG_WIDTH  (IC_TAG_WIDTH)
    ) icache_bus_if();

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    VX_fetch #(
        .CORE_ID     (0),
        .INSTANCE_ID ("tb_fetch")
    ) dut (
        .clk            (clk),
        .reset          (reset),
        .icache_bus_if  (icache_bus_if),
        .schedule_if    (schedule_if),
        .fetch_if       (fetch_if)
    );

    // -----------------------------------------------------------------------
    // TB driver signals
    // -----------------------------------------------------------------------

    // schedule_if: TB drives (simulating scheduler output)
    logic                     tb_sched_valid;
    logic [UUID_WIDTH-1:0]    tb_sched_uuid;
    logic [NW_WIDTH-1:0]      tb_sched_wid;
    logic [`NUM_THREADS-1:0]  tb_sched_tmask;
    logic [PC_BITS-1:0]       tb_sched_pc;

    assign schedule_if.valid       = tb_sched_valid;
    assign schedule_if.data.uuid   = tb_sched_uuid;
    assign schedule_if.data.wid    = tb_sched_wid;
    assign schedule_if.data.tmask  = tb_sched_tmask;
    assign schedule_if.data.PC     = tb_sched_pc;

    // icache_bus_if slave side: TB accepts requests and drives responses
    logic                         tb_icache_req_ready;
    logic                         tb_icache_rsp_valid;
    logic [IC_DATA_SIZE*8-1:0]    tb_icache_rsp_data;
    // tag_t type from VX_mem_bus_if: {uuid[UUID_WIDTH], value[NW_WIDTH]}
    // We use a flat wire and construct the packed struct
    logic [IC_TAG_WIDTH-1:0]      tb_icache_rsp_tag_flat;

    assign icache_bus_if.req_ready      = tb_icache_req_ready;
    assign icache_bus_if.rsp_valid      = tb_icache_rsp_valid;
    assign icache_bus_if.rsp_data.data  = tb_icache_rsp_data;
    // tag_t is packed: {uuid, value}, IC_TAG_WIDTH = UUID_WIDTH + NW_WIDTH
    assign icache_bus_if.rsp_data.tag   = tb_icache_rsp_tag_flat;

    // fetch_if: TB drives ready (decode side backpressure)
    logic tb_fetch_ready;
    assign fetch_if.ready = tb_fetch_ready;
`ifndef L1_ENABLE
    assign fetch_if.ibuf_pop = '0;
`endif

    // -----------------------------------------------------------------------
    // Test utilities
    // -----------------------------------------------------------------------
    int pass_cnt = 0, fail_cnt = 0;

    task automatic idle_inputs();
        tb_sched_valid        = 0;
        tb_sched_uuid         = '0;
        tb_sched_wid          = '0;
        tb_sched_tmask        = '0;
        tb_sched_pc           = '0;
        tb_icache_req_ready   = 1; // default: accept requests immediately
        tb_icache_rsp_valid   = 0;
        tb_icache_rsp_data    = '0;
        tb_icache_rsp_tag_flat = '0;
        tb_fetch_ready        = 1; // default: decode always accepts
    endtask

    task automatic do_reset();
        reset = 1;
        idle_inputs();
        @(posedge clk); @(posedge clk);
        #1;          // deassert between posedges (avoids same-cycle race)
        reset = 0;
        @(posedge clk);
    endtask

    // Send one schedule entry and capture the resulting I-cache request.
    // The icache req appears at the SAME posedge as the schedule handshake
    // (elastic buffer Δ-propagation: valid_out_r becomes 1 in the same time step).
    task automatic send_schedule_and_wait_req(
        input  logic [UUID_WIDTH-1:0]    uuid,
        input  logic [NW_WIDTH-1:0]      wid,
        input  logic [`NUM_THREADS-1:0]  tmask,
        input  logic [PC_BITS-1:0]       pc,
        output logic [IC_TAG_WIDTH-1:0]  req_tag_out,
        output logic [ICACHE_ADDR_WIDTH-1:0] req_addr_out
    );
        #1;
        tb_sched_valid = 1;
        tb_sched_uuid  = uuid;
        tb_sched_wid   = wid;
        tb_sched_tmask = tmask;
        tb_sched_pc    = pc;

        // At this posedge: sched handshake fires. req_data.tag comes from
        // elastic buffer data_out_r which updates in always_ff — must add #1
        // to let the NBA phase commit before reading the registered output.
        @(posedge clk iff (schedule_if.valid && schedule_if.ready));
        #1; // wait for always_ff to commit data_out_r
        req_tag_out  = icache_bus_if.req_data.tag;
        req_addr_out = icache_bus_if.req_data.addr;
        #1;
        tb_sched_valid = 0;
    endtask

    // Drive one I-cache response AND capture the resulting fetch_if output.
    // fetch_if.valid = rsp_valid (combinatorial), so both fire at the same posedge.
    // Captures fetch_if data at the handshake cycle, then deasserts rsp with #1 delay.
    task automatic send_rsp_wait_fetch(
        input  logic [IC_TAG_WIDTH-1:0]   tag,
        input  logic [31:0]               instr,
        output logic [NW_WIDTH-1:0]       wid_out,
        output logic [`NUM_THREADS-1:0]   tmask_out,
        output logic [PC_BITS-1:0]        pc_out,
        output logic [31:0]               instr_out
    );
        #1;
        tb_icache_rsp_valid    = 1;
        tb_icache_rsp_data     = instr;
        tb_icache_rsp_tag_flat = tag;
        // rsp_valid && rsp_ready fires. Tag-store PC/tmask come from dp_ram's
        // prev_write forwarding path — must add #1 so always_ff clears
        // prev_write=0 before reading; otherwise prev_data (stale) is used.
        @(posedge clk iff (icache_bus_if.rsp_valid && icache_bus_if.rsp_ready));
        #1; // wait for always_ff so prev_write is cleared, ram[] read correct
        wid_out   = fetch_if.data.wid;
        tmask_out = fetch_if.data.tmask;
        pc_out    = fetch_if.data.PC;
        instr_out = fetch_if.data.instr;
        #1;
        tb_icache_rsp_valid = 0;
    endtask

    // Legacy: drive icache response only (no capture). Used by TC4 backpressure.
    task automatic send_icache_rsp(
        input logic [IC_TAG_WIDTH-1:0] tag,
        input logic [31:0]             instr
    );
        #1;
        tb_icache_rsp_valid    = 1;
        tb_icache_rsp_data     = instr;
        tb_icache_rsp_tag_flat = tag;
    endtask

    // Wait for fetch_if output using a while-check (polls current posedge first).
    // Use only after rsp_valid is already asserted.
    task automatic wait_fetch_output(
        output logic [NW_WIDTH-1:0]      wid_out,
        output logic [`NUM_THREADS-1:0]  tmask_out,
        output logic [PC_BITS-1:0]       pc_out,
        output logic [31:0]              instr_out
    );
        while (!(fetch_if.valid && fetch_if.ready)) @(posedge clk);
        wid_out   = fetch_if.data.wid;
        tmask_out = fetch_if.data.tmask;
        pc_out    = fetch_if.data.PC;
        instr_out = fetch_if.data.instr;
    endtask

    task automatic check(input string name, input logic ok);
        if (ok) begin
            $display("[PASS] %-35s", name);
            pass_cnt++;
        end else begin
            $display("[FAIL] %-35s", name);
            fail_cnt++;
        end
    endtask

    // -----------------------------------------------------------------------
    // TC1: single_fetch
    //   Schedule one request. Verify PC/tmask roundtrip through tag store.
    // -----------------------------------------------------------------------
    task automatic tc_single_fetch();
        automatic logic [IC_TAG_WIDTH-1:0]       req_tag;
        automatic logic [ICACHE_ADDR_WIDTH-1:0]  req_addr;
        automatic logic [NW_WIDTH-1:0]           wid_out;
        automatic logic [`NUM_THREADS-1:0]       tmask_out;
        automatic logic [PC_BITS-1:0]            pc_out;
        automatic logic [31:0]                   instr_out;
        automatic logic [`XLEN-1:0]              test_addr;
        automatic logic [PC_BITS-1:0]            test_pc;
        automatic logic [`NUM_THREADS-1:0]       test_tmask;
        automatic logic [31:0]                   test_instr;
        automatic logic ok;

        do_reset();
        $display("--- TC1: single_fetch ---");

        test_addr  = `XLEN'h80000010;
        test_pc    = from_fullPC(test_addr);
        test_tmask = `NUM_THREADS'b1111;
        test_instr = 32'hDEADBEEF;

        send_schedule_and_wait_req(UUID_WIDTH'(1), NW_WIDTH'(0),
                                   test_tmask, test_pc,
                                   req_tag, req_addr);
        send_rsp_wait_fetch(req_tag, test_instr, wid_out, tmask_out, pc_out, instr_out);

        ok = (wid_out   === NW_WIDTH'(0))    &&
             (tmask_out === test_tmask)       &&
             (pc_out    === test_pc)          &&
             (instr_out === test_instr);
        if (!ok)
            $display("  wid=%0d tmask=%0b PC=0x%08h instr=0x%08h",
                wid_out, tmask_out, pc_out, instr_out);
        check("TC1_single_fetch", ok);
    endtask

    // -----------------------------------------------------------------------
    // TC2: four_warp_tag_store
    //   4 warps with distinct PCs and tmasks, responses returned in order.
    //   Verify no cross-warp tag corruption.
    // -----------------------------------------------------------------------
    task automatic tc_four_warp_tag_store();
        automatic logic [IC_TAG_WIDTH-1:0]       req_tag    [4];
        automatic logic [ICACHE_ADDR_WIDTH-1:0]  req_addr   [4];
        automatic logic [`XLEN-1:0]              test_addrs [4];
        automatic logic [`NUM_THREADS-1:0]       test_masks [4];
        automatic logic [31:0]                   test_instrs[4];
        automatic logic [NW_WIDTH-1:0]           wid_out;
        automatic logic [`NUM_THREADS-1:0]       tmask_out;
        automatic logic [PC_BITS-1:0]            pc_out;
        automatic logic [31:0]                   instr_out;
        automatic logic ok = 1;

        do_reset();
        $display("--- TC2: four_warp_tag_store ---");

        test_addrs[0] = `XLEN'h80000000;  test_masks[0] = `NUM_THREADS'b1111;
        test_addrs[1] = `XLEN'h80000100;  test_masks[1] = `NUM_THREADS'b0011;
        test_addrs[2] = `XLEN'h80000200;  test_masks[2] = `NUM_THREADS'b0101;
        test_addrs[3] = `XLEN'h80000300;  test_masks[3] = `NUM_THREADS'b0001;

        test_instrs[0] = 32'hAAAA0000;
        test_instrs[1] = 32'hBBBB1111;
        test_instrs[2] = 32'hCCCC2222;
        test_instrs[3] = 32'hDDDD3333;

        // Send 4 requests sequentially (one per warp, in order)
        for (int w = 0; w < 4; w++) begin
            send_schedule_and_wait_req(
                UUID_WIDTH'(w+10), NW_WIDTH'(w),
                test_masks[w], from_fullPC(test_addrs[w]),
                req_tag[w], req_addr[w]);
            @(posedge clk); // gap between requests
        end

        // Return responses in order (warp 0 first)
        for (int w = 0; w < 4; w++) begin
            send_rsp_wait_fetch(req_tag[w], test_instrs[w], wid_out, tmask_out, pc_out, instr_out);

            if (wid_out   !== NW_WIDTH'(w)                 ||
                tmask_out !== test_masks[w]                 ||
                pc_out    !== from_fullPC(test_addrs[w])   ||
                instr_out !== test_instrs[w]) begin
                $display("  warp%0d: wid=%0d tmask=%0b PC=0x%08h instr=0x%08h",
                    w, wid_out, tmask_out, pc_out, instr_out);
                $display("    expected: wid=%0d tmask=%0b PC=0x%08h instr=0x%08h",
                    w, test_masks[w], from_fullPC(test_addrs[w]), test_instrs[w]);
                ok = 0;
            end
        end
        check("TC2_four_warp_tag_store", ok);
    endtask

    // -----------------------------------------------------------------------
    // TC3: interleaved_rsp
    //   4 requests issued in order (warp 0..3), responses returned in
    //   reverse order (warp 3 first). Verify correct PC/tmask per warp.
    // -----------------------------------------------------------------------
    task automatic tc_interleaved_rsp();
        automatic logic [IC_TAG_WIDTH-1:0]       req_tag    [4];
        automatic logic [ICACHE_ADDR_WIDTH-1:0]  req_addr   [4];
        automatic logic [`XLEN-1:0]              test_addrs [4];
        automatic logic [`NUM_THREADS-1:0]       test_masks [4];
        automatic logic [31:0]                   test_instrs[4];
        automatic logic [NW_WIDTH-1:0]           wid_out    [4];
        automatic logic [`NUM_THREADS-1:0]       tmask_out  [4];
        automatic logic [PC_BITS-1:0]            pc_out     [4];
        automatic logic [31:0]                   instr_out  [4];
        automatic logic ok = 1;

        do_reset();
        $display("--- TC3: interleaved_rsp ---");

        test_addrs[0] = `XLEN'h80001000;  test_masks[0] = `NUM_THREADS'b1111;
        test_addrs[1] = `XLEN'h80001040;  test_masks[1] = `NUM_THREADS'b1100;
        test_addrs[2] = `XLEN'h80001080;  test_masks[2] = `NUM_THREADS'b0110;
        test_addrs[3] = `XLEN'h800010C0;  test_masks[3] = `NUM_THREADS'b0001;

        test_instrs[0] = 32'h00000013; // NOP
        test_instrs[1] = 32'h00100093; // ADDI x1,x0,1
        test_instrs[2] = 32'h00200113; // ADDI x2,x0,2
        test_instrs[3] = 32'h00300193; // ADDI x3,x0,3

        // Issue all 4 requests
        for (int w = 0; w < 4; w++) begin
            send_schedule_and_wait_req(
                UUID_WIDTH'(w+20), NW_WIDTH'(w),
                test_masks[w], from_fullPC(test_addrs[w]),
                req_tag[w], req_addr[w]);
            @(posedge clk);
        end

        // Return responses in REVERSE order (warp 3, 2, 1, 0)
        for (int w = 3; w >= 0; w--) begin
            send_rsp_wait_fetch(req_tag[w], test_instrs[w], wid_out[w], tmask_out[w], pc_out[w], instr_out[w]);
        end

        // Verify: each response must match its originating warp
        for (int w = 0; w < 4; w++) begin
            if (wid_out[w]   !== NW_WIDTH'(w)                 ||
                tmask_out[w] !== test_masks[w]                 ||
                pc_out[w]    !== from_fullPC(test_addrs[w])   ||
                instr_out[w] !== test_instrs[w]) begin
                $display("  warp%0d: wid=%0d tmask=%0b PC=0x%08h instr=0x%08h",
                    w, wid_out[w], tmask_out[w], pc_out[w], instr_out[w]);
                ok = 0;
            end
        end
        check("TC3_interleaved_rsp", ok);
    endtask

    // -----------------------------------------------------------------------
    // TC4: ibuf_backpressure
    //   Drive fetch_if.ready=0. Verify DUT stalls I-cache rsp (rsp_ready=0),
    //   then resumes when fetch_if.ready goes back to 1.
    // -----------------------------------------------------------------------
    task automatic tc_ibuf_backpressure();
        automatic logic [IC_TAG_WIDTH-1:0]      req_tag;
        automatic logic [ICACHE_ADDR_WIDTH-1:0] req_addr;
        automatic logic [NW_WIDTH-1:0]          wid_out;
        automatic logic [`NUM_THREADS-1:0]      tmask_out;
        automatic logic [PC_BITS-1:0]           pc_out;
        automatic logic [31:0]                  instr_out;
        automatic logic ok = 1;
        automatic int   stall_cycles;

        do_reset();
        $display("--- TC4: ibuf_backpressure ---");

        // Send a request
        send_schedule_and_wait_req(
            UUID_WIDTH'(99), NW_WIDTH'(0),
            `NUM_THREADS'b1111, from_fullPC(`XLEN'h80002000),
            req_tag, req_addr);

        // Stall decode side: fetch_if.ready=0
        tb_fetch_ready = 0;

        // Drive I-cache response
        tb_icache_rsp_valid    = 1;
        tb_icache_rsp_data     = 32'hFEEDFACE;
        tb_icache_rsp_tag_flat = req_tag;

        // rsp_ready = fetch_if.ready → should be 0 → bus stalls
        stall_cycles = 0;
        repeat (5) begin
            @(posedge clk);
            if (!icache_bus_if.rsp_ready) stall_cycles++;
        end

        if (stall_cycles < 3) begin
            $display("  rsp_ready should stay 0 while fetch_if.ready=0 (got %0d stall cycles)",
                stall_cycles);
            ok = 0;
        end

        // Release decode side — rsp and fetch both fire at this posedge
        tb_fetch_ready = 1;
        @(posedge clk iff (icache_bus_if.rsp_valid && icache_bus_if.rsp_ready));
        // Capture fetch_if data at same posedge (fetch_if.valid = rsp_valid = combinatorial)
        instr_out = fetch_if.data.instr;
        wid_out   = fetch_if.data.wid;
        #1;
        tb_icache_rsp_valid = 0;

        if (instr_out !== 32'hFEEDFACE) begin
            $display("  Wrong instr after backpressure: 0x%08h", instr_out);
            ok = 0;
        end
        check("TC4_ibuf_backpressure", ok);
    endtask

    // -----------------------------------------------------------------------
    // TC5: tmask_fidelity
    //   3 requests with sparse thread masks. Verify each tmask bit pattern
    //   is preserved exactly through the tag store.
    // -----------------------------------------------------------------------
    task automatic tc_tmask_fidelity();
        automatic logic [IC_TAG_WIDTH-1:0]       req_tag;
        automatic logic [ICACHE_ADDR_WIDTH-1:0]  req_addr;
        automatic logic [NW_WIDTH-1:0]           wid_out;
        automatic logic [`NUM_THREADS-1:0]       tmask_out;
        automatic logic [PC_BITS-1:0]            pc_out;
        automatic logic [31:0]                   instr_out;
        automatic logic ok = 1;

        // Masks to test: all-ones, single-thread, alternating
        automatic logic [`NUM_THREADS-1:0] masks[3];

        do_reset();
        $display("--- TC5: tmask_fidelity ---");

        masks[0] = `NUM_THREADS'((1 << `NUM_THREADS) - 1); // all threads
        masks[1] = `NUM_THREADS'(1);                        // thread 0 only
        masks[2] = `NUM_THREADS'(4'b1010);                  // alternating

        for (int i = 0; i < 3; i++) begin
            send_schedule_and_wait_req(
                UUID_WIDTH'(i+50), NW_WIDTH'(0),
                masks[i], from_fullPC(`XLEN'h80003000 + `XLEN'(i * 4)),
                req_tag, req_addr);

            send_rsp_wait_fetch(req_tag, 32'h00000013 + 32'(i), wid_out, tmask_out, pc_out, instr_out);

            if (tmask_out !== masks[i]) begin
                $display("  iter%0d: tmask=0x%0h, expected=0x%0h",
                    i, tmask_out, masks[i]);
                ok = 0;
            end
        end
        check("TC5_tmask_fidelity", ok);
    endtask

    // -----------------------------------------------------------------------
    // Main
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Level 8b: VX_fetch Testbench ===");
        $display("PC_BITS=%0d  NUM_WARPS=%0d  NUM_THREADS=%0d  ICACHE_TAG_WIDTH=%0d",
            PC_BITS, `NUM_WARPS, `NUM_THREADS, ICACHE_TAG_WIDTH);

        tc_single_fetch();
        tc_four_warp_tag_store();
        tc_interleaved_rsp();
        tc_ibuf_backpressure();
        tc_tmask_fidelity();

        $display("=== Results: %0d PASS, %0d FAIL ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL TESTS PASSED");
        else               $display("SOME TESTS FAILED");
        $finish;
    end

endmodule
