# Embench IoT on Gandiva

This directory contains the integration scripts to run the official [Embench IoT](https://embench.org/) benchmark suite on the Gandiva RV32IMC processor. Embench is a modern, free, and open-source benchmark suite designed specifically for IoT-class embedded processors.

## Toolchain & Environment

The benchmark suite is compiled for a 32-bit RISC-V target with the `IMC` and `Zicsr` extensions (Integer, Multiply/Divide, Compressed, and CSR instructions).

- **Compiler**: RISC-V GCC Toolchain (xPack `riscv-none-elf-gcc` v13.2.0)
- **Simulator**: Verilator `v5.050`
- **Architecture**: `RV32IMC_Zicsr`
- **Compiler Flags**:
  
  ```bash
  -O2 -ffunction-sections -fdata-sections -march=rv32imc_zicsr -mabi=ilp32 -Wl,--gc-sections -static
  ```

## Performance Results

Gandiva achieves a geometric mean score of **0.96 Embench Speed/MHz** across all 19 benchmarks. 

### Benchmark Breakdown

| Benchmark | Speed | Speed/MHz |
| --------- | ----- | --------- |
| aha-mont64 | 28.25 | 0.57 |
| crc32 | 44.23 | 0.88 |
| depthconv | 32.25 | 0.65 |
| edn | 35.09 | 0.70 |
| huffbench | 64.00 | 1.28 |
| matmult-int | 53.86 | 1.08 |
| md5sum | 57.61 | 1.15 |
| nettle-aes | 33.63 | 0.67 |
| nettle-sha256 | 31.67 | 0.63 |
| nsichneu | 49.74 | 0.99 |
| picojpeg | 42.15 | 0.84 |
| qrduino | 44.62 | 0.89 |
| sglib-combined | 50.99 | 1.02 |
| slre | 60.99 | 1.22 |
| statemate | 88.45 | 1.77 |
| tarfind | 80.49 | 1.61 |
| ud | 38.75 | 0.77 |
| wikisort | 98.77 | 1.98 |
| xgboost | 35.23 | 0.70 |
| **Geometric mean** | **47.87** | **0.96** |

### Simulation
- **Environment**: Verilator testbench (`tb_gandiva`)
- **Execution**: Embench standard Python test harness (`benchmark_speed.py`)
- **Geometric Mean (Relative Speed)**: 47.87
- **Geometric Mean (Speed/MHz)**: 0.96

### FPGA (Arty A7-100T)
- **Environment**: Bare-metal execution on the Arty A7 FPGA running at 25 MHz.
- **Execution**: Embench standard Python test harness (`benchmark_speed.py`)
- **Geometric Mean (Speed/MHz)**: 0.97


## Directory Layout

```
embench/
├── run_embench.sh                Main script to run the suite in simulation
├── run_embench_fpga.sh           Main script to run the suite on FPGA (via Embench framework)
├── run_embench_fpga_simple.sh    Fast, custom script to execute existing bitstreams sequentially
├── run_gandiva.py                Embench board-support target module for Simulation
├── run_gandiva_fpga.py           Embench board-support target module for FPGA
├── embench-iot/                  Git submodule containing the official Embench source
└── config/gandiva/               
    ├── boardsupport.c            Minimal implementations of UART putc and cycle counting
    ├── start.S                   CRT0 startup code (stack initialization, BSS clearing)
    └── link.ld                   Linker script mapping memory for Gandiva
```

## Usage

- To run the full benchmark suite in the Verilator simulation:
  ```bash
  ./run_embench.sh
  ```
- To run the full benchmark suite on the FPGA, compiling a Vivado bitstream for each benchmark on the fly:
  ```bash
  ./run_embench_fpga.sh
  ```
- To rapidly execute already-built bitstreams on the FPGA (if you just ran the command above and want to re-run the tests):
  ```bash
  ./run_embench_fpga_simple.sh
  ```
