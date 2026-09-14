#!/usr/bin/env bash
# run_embench.sh — Run Embench IoT benchmark suite on Gandiva simulation.
set -euo pipefail
cd "$(dirname "$0")"

TC="${RISCV_TC:-/home/yash/toolchains/xpack-riscv-none-elf-gcc-13.2.0-2/bin}"
GCC="${GCC:-$TC/riscv-none-elf-gcc}"

if ! command -v "$GCC" &>/dev/null; then
    if command -v riscv-none-elf-gcc &>/dev/null; then
        GCC="riscv-none-elf-gcc"
    elif command -v riscv32-unknown-elf-gcc &>/dev/null; then
        GCC="riscv32-unknown-elf-gcc"
    else
        echo "ERROR: RISC-V GCC toolchain not found." >&2; exit 1
    fi
fi

if [ ! -d "embench-iot" ]; then
    echo "Cloning Embench IoT repository..."
    git clone https://github.com/embench/embench-iot.git embench-iot
fi

if ! command -v scons &>/dev/null; then
    echo "scons not found. Creating a virtualenv to install it..."
    python3 -m venv venv
    source venv/bin/activate
    pip install scons
else
    # In case we created it earlier
    if [ -f "venv/bin/activate" ]; then
        source venv/bin/activate
    fi
fi

echo "Building tb_gandiva simulator..."

(cd ../ && ./build.sh)

cd embench-iot

echo "Building benchmarks (scons)..."
# We must use absolute path for config-dir since scons changes directories
CONFIG_DIR=$(realpath ../config/gandiva)

cflags="-O2 -ffunction-sections -fdata-sections -march=rv32imc_zicsr -mabi=ilp32"
ldflags="-O2 -march=rv32imc_zicsr -mabi=ilp32 -Wl,--gc-sections -static -T${CONFIG_DIR}/link.ld -nostartfiles ${CONFIG_DIR}/start.S"

scons -f sconstruct.py --config-dir="${CONFIG_DIR}" \
      --build-dir=bd-riscv-speed \
      cc="${GCC}" \
      cflags="${cflags}" \
      ldflags="${ldflags}" \
      user_libs='m' \
      gsf=1

echo "Running benchmarks..."
# PYTHONPATH must include the parent directory to find run_gandiva.py
OBJCOPY="${GCC%-gcc}-objcopy"
PYTHONPATH=.. ./benchmark_speed.py \
    --builddir bd-riscv-speed \
    --target-module run_gandiva \
    --cpu-mhz 50 \
    --timeout 300 \
    --objcopy "$OBJCOPY"
