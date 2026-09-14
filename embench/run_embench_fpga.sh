#!/usr/bin/env bash
# run_embench_fpga.sh — Run Embench IoT benchmark suite on Gandiva FPGA.
#
# Usage:  ./run_embench_fpga.sh [--no-synth]
#   --no-synth   Skip the initial full Vivado synthesis (assume route.dcp exists).
#
# Flow:
#   1. Build all benchmarks with scons (cross-compile for RV32IMC).
#   2. First run: full Vivado synthesis → saves route.dcp checkpoint.
#   3. Each benchmark: convert ELF→hex, fast re-bitstream from checkpoint,
#      program FPGA with openFPGALoader, capture UART output, parse CYCLES.
#   4. Print per-benchmark cycle counts and geometric mean.
set -euo pipefail
cd "$(dirname "$0")"

SKIP_SYNTH=0
for arg in "$@"; do
    [[ "$arg" == "--no-synth" ]] && SKIP_SYNTH=1
done

# ── Toolchain ────────────────────────────────────────────────────────────────
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
OBJCOPY="${GCC%-gcc}-objcopy"

# ── Tool checks ──────────────────────────────────────────────────────────────
if ! command -v vivado &>/dev/null; then
    echo "ERROR: vivado not found in PATH." >&2
    echo "Please source your Vivado settings64.sh and try again." >&2
    exit 1
fi
if ! command -v openFPGALoader &>/dev/null; then
    echo "ERROR: openFPGALoader not found in PATH." >&2
    exit 1
fi

# ── Serial port ──────────────────────────────────────────────────────────────
SERIAL_PORT="${SERIAL_PORT:-}"
if [ -z "$SERIAL_PORT" ]; then
    for p in /dev/ttyUSB1 /dev/ttyUSB0; do
        if [ -e "$p" ]; then SERIAL_PORT="$p"; break; fi
    done
fi
if [ -z "$SERIAL_PORT" ]; then
    echo "ERROR: No serial port found (/dev/ttyUSB0 or /dev/ttyUSB1)." >&2
    echo "Set SERIAL_PORT=/dev/ttyUSBx to override." >&2
    exit 1
fi
echo "Serial port: $SERIAL_PORT"

# ── Resolve paths before changing directory ──────────────────────────────────
EMBENCH_DIR=$(pwd)
FPGA_DIR=$(realpath ../fpga/arty_a7)
FPGA_BUILD="${FPGA_DIR}/build"
BIN2HEX=$(realpath ../sw/bin2hex.py)

# ── Python venv / scons ──────────────────────────────────────────────────────
if [ ! -d "embench-iot" ]; then
    echo "Cloning Embench IoT repository..."
    git clone https://github.com/embench/embench-iot.git embench-iot
fi

if ! command -v scons &>/dev/null; then
    python3 -m venv venv
    source venv/bin/activate
    pip install scons pyserial
elif [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
    if ! python3 -c "import serial" &>/dev/null; then
        pip install pyserial
    fi
fi

# ── Build benchmarks ─────────────────────────────────────────────────────────
cd embench-iot
CONFIG_DIR=$(realpath ../config/gandiva)
BUILD_DIR="bd-riscv-fpga"

cflags="-O2 -ffunction-sections -fdata-sections -march=rv32imc_zicsr -mabi=ilp32"
ldflags="-O2 -march=rv32imc_zicsr -mabi=ilp32 -Wl,--gc-sections -static \
  -T${CONFIG_DIR}/link_fpga.ld -nostartfiles ${CONFIG_DIR}/start.S"

echo "Building benchmarks (scons)..."
scons -f sconstruct.py --config-dir="${CONFIG_DIR}" \
      --build-dir="${BUILD_DIR}" \
      cc="${GCC}" \
      cflags="${cflags}" \
      ldflags="${ldflags}" \
      user_libs='m' \
      gsf=1

# ── Collect benchmark ELFs ──────────────────────────────────────────────────────
BENCHMARKS=()
# Each embench ELF lives at bd-riscv-fpga/src/<bench>/<bench> (no extension).
# Match only files whose name equals their parent directory name.
for bench_dir in "${BUILD_DIR}/src"/*/; do
    bench=$(basename "$bench_dir")
    elf="${bench_dir}${bench}"
    if [ -f "$elf" ]; then
        BENCHMARKS+=("$elf")
    fi
done

if [ ${#BENCHMARKS[@]} -eq 0 ]; then
    echo "ERROR: No benchmark ELFs found in ${BUILD_DIR}/src." >&2
    exit 1
fi

# ── FPGA paths (already resolved before cd embench-iot) ─────────────────────
mkdir -p "${FPGA_BUILD}"

# ── Phase 1: one-time full Vivado synthesis ───────────────────────────────────
if [ "${SKIP_SYNTH}" -eq 0 ] || [ ! -f "${FPGA_BUILD}/route.dcp" ]; then
    echo ""
    echo "=== Phase 1: Full Vivado synthesis (one-time, saves route.dcp + .mmi) ==="
    # Provide a blank NOP firmware so synthesis initialises BRAMs with known content.
    python3 -c "print('00000013\n' * 16384)" > "${FPGA_BUILD}/firmware.mem"
    vivado -mode batch -source "${FPGA_DIR}/gandiva_arty_a7_synth.tcl" \
           -tclargs "${FPGA_BUILD}" \
           -log "${FPGA_BUILD}/vivado_synth.log" \
           -journal "${FPGA_BUILD}/vivado_synth.jou"
    echo "Synthesis complete."
    echo "  Checkpoint : ${FPGA_BUILD}/route.dcp"
    echo "  MMI file   : ${FPGA_BUILD}/design.mmi"
    echo "  Bitstream  : ${FPGA_BUILD}/gandiva_arty_a7.bit"
else
    echo "Skipping synthesis (--no-synth or route.dcp already exists)."
fi

# Verify the routed checkpoint exists before proceeding.
if [ ! -f "${FPGA_BUILD}/route.dcp" ]; then
    echo "ERROR: ${FPGA_BUILD}/route.dcp not found." >&2
    echo "Re-run without --no-synth to generate it." >&2
    exit 1
fi

# ── Phase 2: per-benchmark fast re-bitstream + run ───────────────────────────
echo ""
echo "=== Phase 2: Running ${#BENCHMARKS[@]} benchmarks on FPGA ==="

CYCLE_COUNTS=()
BENCH_NAMES=()
FAILED=()

stty -F "$SERIAL_PORT" 115200 cs8 -cstopb -parenb -icrnl 2>/dev/null || true

for elf in "${BENCHMARKS[@]}"; do
    bench=$(basename "$elf")
    bench_build_dir="${FPGA_BUILD}/bench_${bench}"
    mkdir -p "${bench_build_dir}"

    echo ""
    echo "--- ${bench} ---"

    # ELF → binary → hex
    bin_path="${elf}.bin"
    hex_path="${elf}.hex"
    "${OBJCOPY}" -O binary "${elf}" "${bin_path}"
    python3 "${BIN2HEX}" "${bin_path}" "${hex_path}"

    # Copy hex as firmware.mem for the bench TCL to pick up.
    cp "${hex_path}" "${bench_build_dir}/firmware.mem"

    # Re-synthesize with new firmware.mem and run incremental implementation
    # from the saved routed checkpoint.  Only BRAM INIT values change, so
    # Vivado skips full placement+routing (~1-2 min vs ~8 min full flow).
    bitstream="${bench_build_dir}/gandiva_arty_a7.bit"
    echo "  Re-synthesising + incremental impl..."
    vivado -mode batch -source "${FPGA_DIR}/gandiva_arty_a7_bench.tcl" \
           -tclargs "${FPGA_BUILD}" "${bench}" \
           -log  "${bench_build_dir}/vivado_bench.log" \
           -journal "${bench_build_dir}/vivado_bench.jou" \
        || { echo "  WARNING: Vivado failed for ${bench} (see vivado_bench.log), skipping."; FAILED+=("$bench"); continue; }

    if [ ! -f "$bitstream" ]; then
        echo "  WARNING: Bitstream not produced for ${bench}, skipping."
        FAILED+=("$bench")
        continue
    fi

    # Start pyserial listener BEFORE programming — survives FTDI resets
    tmpout=$(mktemp)
    done_flag=$(mktemp)
    rm -f "$done_flag"
    python3 - "$SERIAL_PORT" "115200" "120" "$tmpout" "$done_flag" <<'PYEOF' &
import serial, sys, time, os
dev, baud, tmax = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
log_path, done_flag = sys.argv[4], sys.argv[5]
t0 = time.time()
buf = b""
found = False
with open(log_path, "wb") as fout:
    while time.time() - t0 < tmax:
        try:
            with serial.Serial(dev, baud, timeout=1) as ser:
                while time.time() - t0 < tmax:
                    chunk = ser.read(256)
                    if chunk:
                        fout.write(chunk); fout.flush()
                        buf += chunk
                        if b"RET=" in buf and b"CYCLES=" in buf:
                            found = True
                            time.sleep(0.2)
                            remainder = ser.read(1024)
                            fout.write(remainder)
                            break
            if found:
                break
        except serial.SerialException:
            time.sleep(0.5)
if found:
    open(done_flag, "w").close()
PYEOF
    PY_PID=$!
    sleep 0.5

    # Program FPGA
    echo "  Programming FPGA..."
    openFPGALoader -b arty_a7_100t "$bitstream" 2>/dev/null \
        || { echo "  WARNING: openFPGALoader failed for ${bench}, skipping."; kill $PY_PID 2>/dev/null; rm -f "$tmpout" "$done_flag"; FAILED+=("$bench"); continue; }

    # Wait for the listener to finish
    wait $PY_PID 2>/dev/null || true

    serial_output=$(cat "$tmpout" 2>/dev/null || true)
    rm -f "$tmpout"

    if [ -f "$done_flag" ]; then
        rm -f "$done_flag"
        # Parse results
        ret=$(echo "$serial_output" | grep -oP 'RET=\K\d+' | tail -1 || true)
        cycles=$(echo "$serial_output" | grep -oP 'CYCLES=\K\d+' | tail -1 || true)
        if [ -n "$ret" ] && [ -n "$cycles" ]; then
            printf "  %-24s | ret=%-3s | cycles=%s\n" "$bench" "$ret" "$cycles"
            CYCLE_COUNTS+=("$cycles")
            BENCH_NAMES+=("$bench")
            continue
        fi
    fi

    rm -f "$done_flag"
    echo "  WARNING: No valid output from ${bench} (timeout or bad output)."
    FAILED+=("$bench")
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Embench IoT — FPGA Results (Gandiva @ 25 MHz)"
echo "============================================================"
printf "  %-24s | %15s\n" "Benchmark" "Cycles"
printf "  %-24s | %15s\n" "------------------------" "---------------"
for i in "${!BENCH_NAMES[@]}"; do
    printf "  %-24s | %15s\n" "${BENCH_NAMES[$i]}" "${CYCLE_COUNTS[$i]}"
done

if [ ${#CYCLE_COUNTS[@]} -gt 0 ]; then
    # Geometric mean via awk (log-sum-exp)
    geomean=$(printf '%s\n' "${CYCLE_COUNTS[@]}" | \
        awk 'BEGIN{s=0;n=0} {s+=log($1);n++} END{printf "%d", exp(s/n)}')
    printf "  %-24s | %15s\n" "------------------------" "---------------"
    printf "  %-24s | %15d\n" "Geometric mean" "$geomean"
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo "  Failed benchmarks: ${FAILED[*]}"
fi
echo "============================================================"
