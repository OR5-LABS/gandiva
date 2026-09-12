# CoreMark on Gandiva

This directory contains the scripts and source files to run the [EEMBC CoreMark](https://www.eembc.org/coremark/) benchmark on the Gandiva RV32IMC processor.

## Toolchain & Environment

The benchmark is compiled for a 32-bit RISC-V target with the `IMC` extensions (Integer, Multiply/Divide, Compressed instructions). 

- **Compiler**: RISC-V GCC Toolchain (xPack `riscv-none-elf-gcc` v13.2.0)
- **Simulator**: Verilator `v5.050`
- **Architecture**: `RV32IMC`
- **Compiler Flags**:
  
  ```bash
  -O2 -march=rv32imc -mabi=ilp32 -nostartfiles -fno-pic -Wl,--no-relax
  ```

## Performance Results

Gandiva achieves a score of **2.41 CoreMark/MHz** across both simulation and FPGA execution.

### Simulation
- **Environment**: Verilator testbench (`tb_gandiva`)
- **Execution**: 1000 iterations
- **Cycles per Iteration**: ~414,035 cycles
- **CoreMark/MHz**: 2.41

### FPGA (Arty A7-100T)
- **Environment**: Bare-metal execution on the Arty A7 FPGA running at 25 MHz (or 100 MHz).
- **Execution**: 1000 iterations
- **CoreMark/MHz**: 2.41
- **Note**: The core is identical on FPGA and simulation, meaning the IPC (Instructions Per Cycle) and resulting CoreMark/MHz score are exactly identical. Absolute runtime scales linearly with the physical clock frequency.

## Usage

- To run full 1000-iteration test in the Verilator simulation:
  ```bash
  ./run_coremark.sh
  ```

- To run a short 10-iteration test in verilator simulation:
  ```bash
  ./run_coremark_10.sh
  ```

- To run a full 1000-iteration test on the Arty A7 FPGA (compiles bitstream and loads via `openFPGALoader`):
  ```bash
  ./run_coremark_arty.sh
  ```
