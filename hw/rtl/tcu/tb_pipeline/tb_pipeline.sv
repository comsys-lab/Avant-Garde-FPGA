// Level 9 Testbench: Full Pipeline (VX_fetch → VX_decode → VX_issue → VX_execute → VX_commit)
//
// Phase 10 필수 TC (3개):
//
// TC1: int_path
//   LDSCALE(scale_a=129, scale_b=127) → exp_total=+2
//   WMMA(A=B=0x01010101, C=FP32 0.0)  → dot/uop=8, FP32 out
//   k0 = 8.0×2^2 = 32.0 (0x42000000), kfinal = 64.0 (0x42800000)
//
// TC2: mx9_int_path
//   LDSCALE(scale_a=scale_b=127) → exp_total=0
//   WMMA MX9(A=B=0x00000101, C=FP32 0.0), no LDMICRO (mexp=0=identity)
//   OT: flatten(INT8, mexp=0)=passthrough, patch fmt_s→I8 → INT path
//   dot/uop = 2words×(1+1+0+0) = 4, FP32 4.0×2^0 = 4.0
//   k0=4.0 (0x40800000), kfinal=8.0 (0x41000000)
//
// TC3: ldmicro_mx9
//   LDSCALE(scale_a=scale_b=127) → exp_total=0
//   LDMICRO(mexp_a={1,1}, mexp_b={0,0})
//   WMMA MX9(A=B=0x01010101, C=FP32 0.0)
//   OT: flatten(1, mexp=1)=2 for A (all bytes), B unchanged
//   dot/uop = 2words×(2+2+2+2) = 16
//   k0=16.0 (0x41800000), kfinal=32.0 (0x42000000)
//
// // TC4: mx9_exp_scale  [Phase 10 조합 검증 — 세 기능 동시 동작]
//   LDSCALE(scale_a=129, scale_b=127) → exp_total=+2
//   LDMICRO(mexp_a={1,1}, mexp_b={0,0})
//   WMMA MX9(A=B=0x01010101, C=FP32 0.0)
//   A flatten(mexp=1): 1→2 → A_flat=0x02020202
//   dot/uop = 16,  FP32(16) × 2^2 = FP32(64.0)
//   k0=64.0 (0x42800000), kfinal=128.0 (0x43000000)
//
//   NT=4: TC_M=2, TC_N=2, TC_K=2, M_STEPS=4, N_STEPS=2, K_STEPS=2, UOPS=16
//
// 메모리 모델:
//   - imem[IMEM_WORDS]: icache 자동 응답 (req 1사이클 후 rsp)
//   - 레지스터 프리로드: LUI+ADDI+FMV.W.X 명령어 → 파이프라인 정상 통과
//   - preload_phase 제거 → scoreboard RUNTIME_ASSERT 없음

`include "VX_define.vh"

module tb_pipeline;

    import VX_gpu_pkg::*;
    import VX_tcu_pkg::*;

    // =========================================================================
    // Clock / reset
    // =========================================================================
    logic clk   = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    // =========================================================================
    // Constants
    // =========================================================================
    localparam IC_DATA_SIZE = ICACHE_WORD_SIZE;
    localparam IC_TAG_WIDTH = ICACHE_TAG_WIDTH;

    localparam logic [6:0] TCU_OPCODE = 7'h0B;

    // TC1 — INT path (Phase 10: fmt_d=FP32=0)
    localparam logic [31:0] INSTR_LDSCALE  = 32'h0C02_808B;  // LDSCALE rs1=x5 (funct7=7'h06)
    localparam logic [31:0] INSTR_WMMA_INT = 32'h0404_800B;  // fmt_d=FP32=0, fmt_s=I8=9
    localparam logic [31:0] SCALE_VAL_E2   = 32'h0000_7F81;  // {scale_b=127, scale_a=129}
    localparam logic [31:0] A_VAL_INT      = 32'h0101_0101;
    localparam logic [31:0] C_VAL_FP       = 32'h0000_0000;  // FP32 0.0

    // TC2 — MX9 INT path (no LDMICRO, exp_total=0)
    localparam logic [31:0] INSTR_WMMA_MX9 = 32'h0402_000B;  // fmt_d=FP32=0, fmt_s=MX9=4
    localparam logic [31:0] SCALE_VAL_E0   = 32'h0000_7F7F;  // {scale_b=127, scale_a=127}
    localparam logic [31:0] A_VAL_MX9      = 32'h0000_0101;  // bytes=[1,1,0,0]

    // TC3 — LDMICRO + MX9
    localparam logic [31:0] INSTR_LDMICRO  = 32'h0873_000B;  // rs2=x7, rs1=x6
    localparam logic [31:0] A_VAL_MX9_ALL  = 32'h0101_0101;  // all bytes=1
    localparam logic [31:0] MEXP_A_VAL     = 32'h0000_0003;  // {pair1=1, pair0=1}
    localparam logic [31:0] MEXP_B_VAL     = 32'h0000_0000;  // {pair1=0, pair0=0}

    // register indices
    localparam [4:0] SCALE_REG  = 5;   // x5
    localparam [4:0] MEXP_A_REG = 6;   // x6
    localparam [4:0] MEXP_B_REG = 7;   // x7
    localparam [4:0] TMP_IREG   = 10;  // x10 (a0) — temp for LUI/ADDI before FMV.W.X

    // =========================================================================
    // Instruction memory
    // =========================================================================
    localparam logic [31:0] IMEM_BASE  = 32'h8000_0000;
    localparam              IMEM_WORDS = 4096;          // 16KB

    logic [31:0] imem [0:IMEM_WORDS-1];

    // word index = req_data.addr[11:0]  (lower 12 bits of word-address)
    // IMEM_BASE word-addr lower12 = 0, so direct indexing works for our PC range

    // =========================================================================
    // Interfaces
    // =========================================================================
    VX_schedule_if schedule_if();

    VX_mem_bus_if #(
        .DATA_SIZE (IC_DATA_SIZE),
        .TAG_WIDTH (IC_TAG_WIDTH)
    ) icache_bus_if();

    VX_fetch_if        fetch_if();
    VX_decode_sched_if decode_sched_if();
    VX_decode_if       decode_if();

    VX_writeback_if   issue_wb       [`ISSUE_WIDTH]();
    VX_writeback_if   commit_wb      [`ISSUE_WIDTH]();
    VX_dispatch_if    issue_dispatch [NUM_EX_UNITS * `ISSUE_WIDTH]();
    VX_commit_if      commit_mid     [NUM_EX_UNITS * `ISSUE_WIDTH]();
    VX_issue_sched_if issue_sched_if [`ISSUE_WIDTH]();
    VX_branch_ctl_if  branch_ctl_if  [`NUM_ALU_BLOCKS]();
    VX_warp_ctl_if    warp_ctl_if();
    VX_commit_csr_if  commit_csr_if();
    VX_commit_sched_if commit_sched_if();
    VX_sched_csr_if   sched_csr_if();
    VX_lsu_mem_if #(
        .NUM_LANES (`NUM_LSU_LANES),
        .DATA_SIZE (4),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) lsu_mem_if[`NUM_LSU_BLOCKS]();

    // =========================================================================
    // icache auto-response: imem[addr] → rsp 1사이클 후
    // =========================================================================
    logic                      icache_rsp_pending_r = 1'b0;
    logic [IC_DATA_SIZE*8-1:0] icache_rsp_data_r;
    logic [IC_TAG_WIDTH-1:0]   icache_rsp_tag_r;

    assign icache_bus_if.req_ready     = 1'b1;
    assign icache_bus_if.rsp_valid     = icache_rsp_pending_r;
    assign icache_bus_if.rsp_data.data = icache_rsp_data_r;
    assign icache_bus_if.rsp_data.tag  = icache_rsp_tag_r;

    always @(posedge clk) begin
        if (reset) begin
            icache_rsp_pending_r <= 1'b0;
        end else if (!icache_rsp_pending_r && icache_bus_if.req_valid) begin
            // 새 요청 래치
            icache_rsp_data_r    <= imem[icache_bus_if.req_data.addr[$clog2(IMEM_WORDS)-1:0]];
            icache_rsp_tag_r     <= icache_bus_if.req_data.tag;
            icache_rsp_pending_r <= 1'b1;
        end else if (icache_bus_if.rsp_valid && icache_bus_if.rsp_ready) begin
            // fetch가 수신 완료
            icache_rsp_pending_r <= 1'b0;
        end
    end

    // =========================================================================
    // Writeback: commit_wb 직결 (preload_phase 없음)
    // =========================================================================
    for (genvar i = 0; i < `ISSUE_WIDTH; i++) begin : g_wb_mux
        assign issue_wb[i].valid = commit_wb[i].valid;
        assign issue_wb[i].data  = commit_wb[i].data;
    end

    // =========================================================================
    // DUT: VX_fetch
    // =========================================================================
    VX_fetch #(
        .INSTANCE_ID ("tb_pipeline_fetch")
    ) fetch_dut (
        .clk           (clk),
        .reset         (reset),
        .icache_bus_if (icache_bus_if),
        .schedule_if   (schedule_if),
        .fetch_if      (fetch_if)
    );

    // =========================================================================
    // DUT: VX_decode
    // =========================================================================
    VX_decode #(
        .INSTANCE_ID ("tb_pipeline_decode")
    ) decode_dut (
        .clk             (clk),
        .reset           (reset),
        .fetch_if        (fetch_if),
        .decode_if       (decode_if),
        .decode_sched_if (decode_sched_if)
    );

    // =========================================================================
    // DUT: VX_issue
    // =========================================================================
    VX_issue #(
        .INSTANCE_ID ("tb_pipeline_issue")
    ) issue_dut (
        .clk            (clk),
        .reset          (reset),
        .decode_if      (decode_if),
        .writeback_if   (issue_wb),
        .dispatch_if    (issue_dispatch),
        .issue_sched_if (issue_sched_if)
    );

    // =========================================================================
    // DUT: VX_execute
    // =========================================================================
    base_dcrs_t base_dcrs_tie;
    assign base_dcrs_tie = '0;

    VX_execute #(
        .INSTANCE_ID ("tb_pipeline_execute"),
        .CORE_ID     (0)
    ) execute_dut (
        .clk           (clk),
        .reset         (reset),
        .base_dcrs     (base_dcrs_tie),
        .lsu_mem_if    (lsu_mem_if),
        .dispatch_if   (issue_dispatch),
        .commit_if     (commit_mid),
        .sched_csr_if  (sched_csr_if),
        .branch_ctl_if (branch_ctl_if),
        .warp_ctl_if   (warp_ctl_if),
        .commit_csr_if (commit_csr_if)
    );

    // =========================================================================
    // DUT: VX_commit
    // =========================================================================
    VX_commit #(
        .INSTANCE_ID ("tb_pipeline_commit")
    ) commit_dut (
        .clk             (clk),
        .reset           (reset),
        .commit_if       (commit_mid),
        .writeback_if    (commit_wb),
        .commit_csr_if   (commit_csr_if),
        .commit_sched_if (commit_sched_if)
    );

    // =========================================================================
    // Tie-offs
    // =========================================================================
    for (genvar i = 0; i < `NUM_LSU_BLOCKS; i++) begin : g_tie_lsu
        assign lsu_mem_if[i].req_ready = 1'b0;
        assign lsu_mem_if[i].rsp_valid = 1'b0;
        assign lsu_mem_if[i].rsp_data  = '0;
    end

    assign warp_ctl_if.dvstack_ptr   = '0;
    assign sched_csr_if.cycles       = '0;
    assign sched_csr_if.active_warps = '0;
    assign sched_csr_if.thread_masks = '0;
    assign sched_csr_if.alm_empty    = '0;

    // =========================================================================
    // Helpers
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;
    logic [UUID_WIDTH-1:0] next_uuid = UUID_WIDTH'(1);
    logic [PC_BITS-1:0]    prog_pc;   // 프로그램 카운터 (imem 쓰기 + schedule 주소)

    // -------------------------------------------------------------------------
    // imem_write: prog_pc 위치에 instruction 저장 (함수 — combinational)
    // -------------------------------------------------------------------------
    function automatic void imem_write(input logic [PC_BITS-1:0] pc,
                                       input logic [31:0]         instr);
        imem[(pc - IMEM_BASE) >> 2] = instr;
    endfunction

    // -------------------------------------------------------------------------
    // RISC-V instruction encoders
    //   LUI  rd, imm20:        {imm20[19:0], rd, 7'h37}
    //   ADDI rd, rs1, imm12:   {imm12[11:0], rs1, 3'b000, rd, 7'h13}
    //   FMV.W.X fd, rs1:       {7'h78, 5'h0, rs1, 3'b000, fd, 7'h53}
    // -------------------------------------------------------------------------
    function automatic logic [31:0] encode_lui(input logic [4:0]  rd,
                                               input logic [31:0] val);
        // LUI immediate = upper 20 bits; ADDI sign-extends lower 12.
        // If lower12 >= 0x800, ADDI subtracts, so add 1 to LUI imm.
        logic [11:0] lo12 = val[11:0];
        logic [19:0] hi20 = val[31:12] + (lo12 >= 12'h800 ? 20'd1 : 20'd0);
        return {hi20, rd, 7'h37};
    endfunction

    function automatic logic [31:0] encode_addi(input logic [4:0]  rd,
                                                input logic [4:0]  rs1,
                                                input logic [11:0] imm12);
        return {imm12, rs1, 3'b000, rd, 7'h13};
    endfunction

    function automatic logic [31:0] encode_fmvwx(input logic [4:0] fd,
                                                  input logic [4:0] rs1);
        return {7'h78, 5'h0, rs1, 3'b000, fd, 7'h53};
    endfunction

    // -------------------------------------------------------------------------
    // TB signals — schedule_if (TB is the scheduler)
    // -------------------------------------------------------------------------
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

    // =========================================================================
    // send_instr: schedule → fetch → icache(auto) → decode → issue
    //   imem_write()로 미리 instruction 저장 후 호출
    // =========================================================================
    task automatic send_instr (
        input logic [PC_BITS-1:0]      pc,
        input logic [NW_WIDTH-1:0]     wid,
        input logic [`NUM_THREADS-1:0] tmask
    );
        tb_sched_valid = 1;
        tb_sched_uuid  = next_uuid;
        tb_sched_wid   = wid;
        tb_sched_tmask = tmask;
        tb_sched_pc    = pc;
        next_uuid      = next_uuid + 1;

        @(posedge clk iff (schedule_if.valid && schedule_if.ready));
        #1;
        tb_sched_valid = 0;

        // icache auto-response가 처리될 때까지 대기
        @(posedge clk iff (icache_bus_if.rsp_valid && icache_bus_if.rsp_ready));
        #1;
    endtask

    // =========================================================================
    // wait_commit / collect_wbs
    // =========================================================================
    task automatic wait_commit (output writeback_t res);
        @(posedge clk);
        while (!commit_wb[0].valid) @(posedge clk);
        res = commit_wb[0].data;
        @(posedge clk);
    endtask

    task automatic collect_wbs (
        input  int         count,
        output writeback_t results []
    );
        results = new[count];
        for (int i = 0; i < count; i++) begin
            @(posedge clk);
            while (!commit_wb[0].valid) @(posedge clk);
            results[i] = commit_wb[0].data;
        end
    endtask

    // =========================================================================
    // load_int_reg: 32-bit 값을 정수 레지스터 rd에 로드 (LUI + ADDI)
    //   prog_pc는 inout — 사용된 만큼 자동 증가
    // =========================================================================
    task automatic load_int_reg (
        input logic [4:0]          rd,
        input logic [31:0]         val,
        inout logic [PC_BITS-1:0]  cur_pc
    );
        writeback_t dummy;
        imem_write(cur_pc,   encode_lui (rd, val));
        imem_write(cur_pc+4, encode_addi(rd, rd, val[11:0]));
        send_instr(cur_pc,   NW_WIDTH'(0), {`NUM_THREADS{1'b1}}); wait_commit(dummy); cur_pc += 4;
        send_instr(cur_pc,   NW_WIDTH'(0), {`NUM_THREADS{1'b1}}); wait_commit(dummy); cur_pc += 4;
    endtask

    // =========================================================================
    // load_float_reg: 32-bit 비트 패턴을 float 레지스터 fd에 로드
    //   LUI + ADDI (→ TMP_IREG) + FMV.W.X (→ fd)
    // =========================================================================
    task automatic load_float_reg (
        input logic [4:0]          fd,    // float reg index (0..31 within float file)
        input logic [31:0]         val,
        inout logic [PC_BITS-1:0]  cur_pc
    );
        writeback_t dummy;
        imem_write(cur_pc,   encode_lui  (TMP_IREG, val));
        imem_write(cur_pc+4, encode_addi (TMP_IREG, TMP_IREG, val[11:0]));
        imem_write(cur_pc+8, encode_fmvwx(fd, TMP_IREG));
        send_instr(cur_pc,   NW_WIDTH'(0), {`NUM_THREADS{1'b1}}); wait_commit(dummy); cur_pc += 4;
        send_instr(cur_pc,   NW_WIDTH'(0), {`NUM_THREADS{1'b1}}); wait_commit(dummy); cur_pc += 4;
        send_instr(cur_pc,   NW_WIDTH'(0), {`NUM_THREADS{1'b1}}); wait_commit(dummy); cur_pc += 4;
    endtask

    // =========================================================================
    // preload_tiles: A/B/C tile 레지스터 전체를 명령어로 초기화
    // =========================================================================
    task automatic preload_tiles (
        input logic [31:0]         a_val,
        input logic [31:0]         b_val,
        input logic [31:0]         c_val,
        inout logic [PC_BITS-1:0]  cur_pc
    );
        // A-tile: TCU_M_STEPS × TCU_K_STEPS regs starting at TCU_RA
        for (int m = 0; m < TCU_M_STEPS; m++)
            for (int k = 0; k < TCU_K_STEPS; k++)
                load_float_reg(5'(TCU_RA + m * TCU_K_STEPS + k), a_val, cur_pc);
        // B-tile: TCU_K_STEPS × TCU_N_STEPS regs starting at TCU_RB
        for (int k = 0; k < TCU_K_STEPS; k++)
            for (int n = 0; n < TCU_N_STEPS; n++)
                load_float_reg(5'(TCU_RB + k * TCU_N_STEPS + n), b_val, cur_pc);
        // C-tile: TCU_M_STEPS × TCU_N_STEPS regs starting at TCU_RC
        for (int m = 0; m < TCU_M_STEPS; m++)
            for (int n = 0; n < TCU_N_STEPS; n++)
                load_float_reg(5'(TCU_RC + m * TCU_N_STEPS + n), c_val, cur_pc);
    endtask

    // =========================================================================
    // Main stimulus
    // =========================================================================
    initial begin
        // imem 초기화
        for (int i = 0; i < IMEM_WORDS; i++) imem[i] = 32'h0000_0013; // ADDI x0,x0,0 = NOP

        reset          = 1'b1;
        tb_sched_valid = 0;
        tb_sched_uuid  = '0;
        tb_sched_wid   = '0;
        tb_sched_tmask = '0;
        tb_sched_pc    = '0;
        prog_pc        = IMEM_BASE;

        repeat(4) @(posedge clk);
        @(posedge clk); #1;
        reset = 1'b0;
        @(posedge clk); #1;

        $display("=== tb_pipeline: Phase 10 AG-TCU Full Pipeline ===");
        $display("  TILE %0dx%0d  TC %0dx%0d  TC_K=%0d  UOPS=%0d",
                 TCU_TILE_M, TCU_TILE_N, TCU_TC_M, TCU_TC_N, TCU_TC_K, TCU_UOPS);
        $display("------------------------------------------------------------");

        // ======================================================================
        // TC1: int_path
        //   LUI+ADDI+FMV.W.X로 tile 레지스터 초기화 → scoreboard assertion 없음
        //   LDSCALE(exp_total=+2) → WMMA INT
        //   k0=32.0(0x42000000), kfinal=64.0(0x42800000)
        // ======================================================================
        begin : tc1
            writeback_t ldscale_wb;
            writeback_t results[];
            bit ok = 1;
            logic [31:0] exp_k0    = 32'h4200_0000;  // FP32 32.0
            logic [31:0] exp_final = 32'h4280_0000;  // FP32 64.0

            // A=B=0x01010101, C=0.0 → tile regs via LUI+ADDI+FMV.W.X
            preload_tiles(A_VAL_INT, A_VAL_INT, C_VAL_FP, prog_pc);
            // scale reg x5 = 0x7F81 → via LUI+ADDI
            load_int_reg(SCALE_REG, SCALE_VAL_E2, prog_pc);

            // LDSCALE
            imem_write(prog_pc, INSTR_LDSCALE);
            send_instr(prog_pc, NW_WIDTH'(0), {`NUM_THREADS{1'b1}});
            wait_commit(ldscale_wb);
            prog_pc += 4;

            // WMMA INT
            imem_write(prog_pc, INSTR_WMMA_INT);
            send_instr(prog_pc, NW_WIDTH'(0), {`NUM_THREADS{1'b1}});
            collect_wbs(TCU_UOPS, results);
            prog_pc += 4;

            for (int r = 0; r < TCU_UOPS; r++)
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    logic [31:0] got = results[r].data[t];
                    if (got !== exp_k0 && got !== exp_final) begin
                        $display("  [FAIL] commit[%0d][t=%0d] = 0x%08X  (exp 0x%08X or 0x%08X)",
                                 r, t, got, exp_k0, exp_final);
                        ok = 0;
                    end
                end

            if (ok) begin
                $display("[PASS] TC1_int_path   k0=32.0  kfinal=64.0  (%0d×%0d tiles)",
                         TCU_M_STEPS, TCU_N_STEPS);
                pass_cnt++;
            end else begin
                $display("[FAIL] TC1_int_path");
                fail_cnt++;
            end
        end

        // ======================================================================
        // TC2: mx9_int_path
        //   Phase 10: MX9 → OT flatten(mexp=0=identity) + fmt_s patch → INT path
        //   LDSCALE(exp_total=0), WMMA MX9(A=B=0x00000101, C=FP32 0.0)
        //   bytes=[1,1,0,0], dot/uop=4, FP32 4.0×2^0=4.0
        //   k0=4.0(0x40800000), kfinal=8.0(0x41000000)
        // ======================================================================
        begin : tc2
            writeback_t ldscale_wb2;
            writeback_t results2[];
            bit ok2 = 1;
            logic [31:0] exp_k0    = 32'h4080_0000;  // FP32 4.0
            logic [31:0] exp_final = 32'h4100_0000;  // FP32 8.0

            preload_tiles(A_VAL_MX9, A_VAL_MX9, C_VAL_FP, prog_pc);
            load_int_reg(SCALE_REG, SCALE_VAL_E0, prog_pc);

            imem_write(prog_pc, INSTR_LDSCALE);
            send_instr(prog_pc, NW_WIDTH'(0), {`NUM_THREADS{1'b1}});
            wait_commit(ldscale_wb2);
            prog_pc += 4;

            imem_write(prog_pc, INSTR_WMMA_MX9);
            send_instr(prog_pc, NW_WIDTH'(0), {`NUM_THREADS{1'b1}});
            collect_wbs(TCU_UOPS, results2);
            prog_pc += 4;

            for (int r = 0; r < TCU_UOPS; r++)
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    logic [31:0] got = results2[r].data[t];
                    if (got !== exp_k0 && got !== exp_final) begin
                        $display("  [FAIL] commit[%0d][t=%0d] = 0x%08X  (exp 0x%08X or 0x%08X)",
                                 r, t, got, exp_k0, exp_final);
                        ok2 = 0;
                    end
                end

            if (ok2) begin
                $display("[PASS] TC2_mx9_int_path   k0=4.0  kfinal=8.0  (%0d×%0d tiles)",
                         TCU_M_STEPS, TCU_N_STEPS);
                pass_cnt++;
            end else begin
                $display("[FAIL] TC2_mx9_int_path");
                fail_cnt++;
            end
        end

        // ======================================================================
        // TC3: ldmicro_mx9
        //   Phase 10: LDMICRO(mexp_a={1,1}, mexp_b={0,0}) + MX9 WMMA
        //   LDSCALE(exp_total=0), LDMICRO(x6=3, x7=0), WMMA MX9(A=B=0x01010101, C=FP32 0.0)
        //   A bytes=[1,1,1,1], flatten(mexp=1)=[2,2,2,2]; B bytes=[1,1,1,1]
        //   dot/uop = 2words×(2+2+2+2) = 16, FP32 16.0×2^0=16.0
        //   k0=16.0(0x41800000), kfinal=32.0(0x42000000)
        // ======================================================================
        begin : tc3
            writeback_t ldscale_wb3;
            writeback_t results3[];
            bit ok3 = 1;
            logic [31:0] exp_k0    = 32'h4180_0000;  // FP32 16.0
            logic [31:0] exp_final = 32'h4200_0000;  // FP32 32.0

            preload_tiles(A_VAL_MX9_ALL, A_VAL_MX9_ALL, C_VAL_FP, prog_pc);
            load_int_reg(SCALE_REG,  SCALE_VAL_E0,  prog_pc);
            load_int_reg(MEXP_A_REG, MEXP_A_VAL,    prog_pc);  // x6 = 3
            load_int_reg(MEXP_B_REG, MEXP_B_VAL,    prog_pc);  // x7 = 0

            // LDSCALE
            imem_write(prog_pc, INSTR_LDSCALE);
            send_instr(prog_pc, NW_WIDTH'(0), {`NUM_THREADS{1'b1}});
            wait_commit(ldscale_wb3);
            prog_pc += 4;

            // LDMICRO: wb=0이므로 commit 없음 → fixed wait
            imem_write(prog_pc, INSTR_LDMICRO);
            send_instr(prog_pc, NW_WIDTH'(0), {`NUM_THREADS{1'b1}});
            repeat(20) @(posedge clk); #1;
            prog_pc += 4;

            // WMMA MX9
            imem_write(prog_pc, INSTR_WMMA_MX9);
            send_instr(prog_pc, NW_WIDTH'(0), {`NUM_THREADS{1'b1}});
            collect_wbs(TCU_UOPS, results3);
            prog_pc += 4;

            for (int r = 0; r < TCU_UOPS; r++)
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    logic [31:0] got = results3[r].data[t];
                    if (got !== exp_k0 && got !== exp_final) begin
                        $display("  [FAIL] commit[%0d][t=%0d] = 0x%08X  (exp 0x%08X or 0x%08X)",
                                 r, t, got, exp_k0, exp_final);
                        ok3 = 0;
                    end
                end

            if (ok3) begin
                $display("[PASS] TC3_ldmicro_mx9   k0=16.0  kfinal=32.0  (%0d×%0d tiles)",
                         TCU_M_STEPS, TCU_N_STEPS);
                pass_cnt++;
            end else begin
                $display("[FAIL] TC3_ldmicro_mx9");
                fail_cnt++;
            end
        end

        // ======================================================================
        // TC4: mx9_exp_scale  [Phase 10 조합 검증]
        //   LDSCALE(scale_a=129, scale_b=127) → exp_total=+2
        //   LDMICRO(mexp_a={1,1}, mexp_b={0,0})
        //   WMMA MX9(A=B=0x01010101, C=FP32 0.0)
        //   A flatten(mexp=1): 1 → 2 (all bytes)  → A_flat=0x02020202
        //   B: mexp=0, unchanged                   → B_flat=0x01010101
        //   dot/uop = 2words × (2×1)×4bytes = 16
        //   FP32(16) × 2^2 = FP32(64.0)
        //   k0=64.0(0x42800000), kfinal=128.0(0x43000000)
        // ======================================================================
        begin : tc4
            writeback_t ldscale_wb4;
            writeback_t results4[];
            bit ok4 = 1;
            logic [31:0] exp_k0    = 32'h4280_0000;  // FP32 64.0
            logic [31:0] exp_final = 32'h4300_0000;  // FP32 128.0

            // A=B=0x01010101 (all bytes=1), C=FP32(0.0)
            preload_tiles(A_VAL_MX9_ALL, A_VAL_MX9_ALL, C_VAL_FP, prog_pc);
            // scale_a=129, scale_b=127 → exp_total=+2 (TC1과 동일한 scale)
            load_int_reg(SCALE_REG,  SCALE_VAL_E2,  prog_pc);
            // mexp_a = {pair1=1, pair0=1} → x6=3 (TC3과 동일)
            load_int_reg(MEXP_A_REG, MEXP_A_VAL,    prog_pc);
            load_int_reg(MEXP_B_REG, MEXP_B_VAL,    prog_pc);  // x7=0

            // LDSCALE
            imem_write(prog_pc, INSTR_LDSCALE);
            send_instr(prog_pc, NW_WIDTH'(0), {`NUM_THREADS{1'b1}});
            wait_commit(ldscale_wb4);
            prog_pc += 4;

            // LDMICRO: wb=0 → commit 없음 → fixed wait
            imem_write(prog_pc, INSTR_LDMICRO);
            send_instr(prog_pc, NW_WIDTH'(0), {`NUM_THREADS{1'b1}});
            repeat(20) @(posedge clk); #1;
            prog_pc += 4;

            // WMMA MX9: OT가 mexp_a 읽어 flatten(2×), exp_total=+2로 FP32 scale
            imem_write(prog_pc, INSTR_WMMA_MX9);
            send_instr(prog_pc, NW_WIDTH'(0), {`NUM_THREADS{1'b1}});
            collect_wbs(TCU_UOPS, results4);
            prog_pc += 4;

            for (int r = 0; r < TCU_UOPS; r++)
                for (int t = 0; t < `SIMD_WIDTH; t++) begin
                    logic [31:0] got = results4[r].data[t];
                    if (got !== exp_k0 && got !== exp_final) begin
                        $display("  [FAIL] TC4 commit[%0d][t=%0d] = 0x%08X  (exp 0x%08X or 0x%08X)",
                                 r, t, got, exp_k0, exp_final);
                        ok4 = 0;
                    end
                end

            if (ok4) begin
                $display("[PASS] TC4_mx9_exp_scale   k0=64.0(0x%08X)  kfinal=128.0(0x%08X)  flatten×scale both active",
                         exp_k0, exp_final);
                pass_cnt++;
            end else begin
                $display("[FAIL] TC4_mx9_exp_scale");
                fail_cnt++;
            end
        end

        // --- Summary ---
        $display("------------------------------------------------------------");
        $display("Results: %0d PASS / %0d FAIL  (total %0d)",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");
        $display("============================================================");
        $finish;
    end

endmodule
