// Verilator C++ harness for tb_schedule (Level 9)
// Supports runtime VCD tracing: pass +trace or +trace=<file>
#include "Vtb_schedule.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>
#include <cstring>
#include <memory>

int main(int argc, char **argv) {
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->commandArgs(argc, argv);
    const std::unique_ptr<Vtb_schedule> dut{new Vtb_schedule{contextp.get()}};

    const char *vcd_file = nullptr;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "+trace=", 7) == 0) vcd_file = argv[i] + 7;
        else if (strcmp(argv[i], "+trace") == 0) vcd_file = "wave_schedule.vcd";
    }

    VerilatedVcdC *vcd = nullptr;
    if (vcd_file) {
        contextp->traceEverOn(true);
        vcd = new VerilatedVcdC;
        dut->trace(vcd, 99);
        vcd->open(vcd_file);
        fprintf(stderr, "[TRACE] Writing waveform to: %s\n", vcd_file);
    }

    // 6 TCs × ~100 cycles × 10ns + generous margin
    const vluint64_t MAX_TIME = 500000;

    dut->eval();
    if (vcd) vcd->dump(contextp->time());

    while (!contextp->gotFinish() && contextp->time() < MAX_TIME) {
        contextp->timeInc(1);
        dut->eval();
        if (vcd) vcd->dump(contextp->time());
    }

    if (!contextp->gotFinish()) {
        fprintf(stderr, "[ERROR] Simulation timed out after %llu ns\n",
                (unsigned long long)contextp->time());
    }

    dut->final();
    if (vcd) { vcd->close(); delete vcd; }
    return contextp->gotFinish() ? 0 : 1;
}
