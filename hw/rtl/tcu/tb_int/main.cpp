// Verilator C++ harness for tb_tcu_int
// Supports runtime VCD tracing: pass +trace or +trace=<file>
#include "Vtb_tcu_int.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>
#include <cstring>
#include <memory>

int main(int argc, char **argv) {
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->commandArgs(argc, argv);
    const std::unique_ptr<Vtb_tcu_int> dut{new Vtb_tcu_int{contextp.get()}};

    // Parse +trace or +trace=<file> from argv
    const char *vcd_file = nullptr;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "+trace=", 7) == 0) vcd_file = argv[i] + 7;
        else if (strcmp(argv[i], "+trace") == 0) vcd_file = "wave_int.vcd";
    }

    VerilatedVcdC *vcd = nullptr;
    if (vcd_file) {
        contextp->traceEverOn(true);
        vcd = new VerilatedVcdC;
        dut->trace(vcd, 99);
        vcd->open(vcd_file);
        fprintf(stderr, "[TRACE] Writing waveform to: %s\n", vcd_file);
    }

    // MAX_TIME: ~1000 clock cycles at 10000 ps/cycle = 10,000,000 ps
    const vluint64_t MAX_TIME = 10000000;

    // Initialize coroutines at t=0
    dut->eval();
    if (vcd) vcd->dump(contextp->time());

    while (!contextp->gotFinish() && contextp->time() < MAX_TIME) {
        contextp->timeInc(1);
        dut->eval();
        if (vcd) vcd->dump(contextp->time());
    }

    if (!contextp->gotFinish()) {
        fprintf(stderr, "[ERROR] Simulation timed out after %llu ps\n",
                (unsigned long long)contextp->time());
    }

    dut->final();
    if (vcd) { vcd->close(); delete vcd; }
    return contextp->gotFinish() ? 0 : 1;
}
