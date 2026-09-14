#!/usr/bin/env python3
import argparse
import subprocess
import re
import os
import sys
import atexit
import math
import fcntl
import time

# pyrefly: ignore [missing-import]
from embench_core import log

cycle_counts = []

def print_geomean():
    if cycle_counts:
        prod = math.prod(cycle_counts)
        geomean = int(round(prod ** (1 / len(cycle_counts))))
        print(f"{'Geometric mean':<20} | Cycles: {geomean:>12}")

atexit.register(print_geomean)

def get_target_args(remnant):
    parser = argparse.ArgumentParser(description='Get target specific args')
    parser.add_argument('--objcopy', type=str, default='riscv-none-elf-objcopy', help='Objcopy tool')
    parser.add_argument('--bin2hex', type=str, default='../../sw/bin2hex.py', help='bin2hex script path')
    return parser.parse_args(remnant)

def decode_results(stdout_str, stderr_str, bench="Unknown"):
    rcstr = re.search(r'RET=(\d+)', stdout_str, re.S | re.M)
    if not rcstr:
        log.debug('Warning: Failed to find return code')
        return None

    cycles_str = re.search(r'CYCLES=(\d+)', stdout_str, re.S | re.M)
    if cycles_str:
        cycles = int(cycles_str.group(1))
        print(f"{bench:<20} | Cycles: {cycles:>12}")
        cycle_counts.append(cycles)
        # 25 MHz FPGA clock -> 25,000 cycles per ms
        ms_elapsed = float(cycles) / 25000.0
        return max(ms_elapsed, 0.001)

    log.debug('Warning: Failed to find timing')
    return None

def run_benchmark(bench, path, args):
    try:
        bin_path = path + '.bin'
        hex_path = path + '.hex'
        
        # 1. objcopy ELF to binary
        subprocess.run([args.objcopy, '-O', 'binary', path, bin_path], check=True)
        
        # 2. Convert binary to hex
        subprocess.run([sys.executable, args.bin2hex, bin_path, hex_path], check=True, stdout=subprocess.DEVNULL)
        
        # 3. Build FPGA bitstream
        build_dir = '../fpga/arty_a7/build'
        os.makedirs(build_dir, exist_ok=True)
        firmware_mem = os.path.join(build_dir, 'firmware.mem')
        subprocess.run(['cp', hex_path, firmware_mem], check=True)
        
        print(f"[{bench}] Running Vivado synthesis for FPGA...")
        fpga_dir = '../fpga/arty_a7'
        
        vivado_cmd = ['vivado', '-mode', 'batch', '-source', 'gandiva_arty_a7.tcl', '-tclargs', 'build']
        if not subprocess.run(['which', 'vivado'], stdout=subprocess.PIPE).stdout:
            print(f"ERROR: vivado not found in PATH. Skipping {bench}.")
            return None

        subprocess.run(vivado_cmd, cwd=fpga_dir, check=True, stdout=subprocess.DEVNULL)
        
        # 4. Program FPGA and capture serial output
        bitstream = 'build/gandiva_arty_a7.bit'
        serial_port = '/dev/ttyUSB1'
        if not os.path.exists(serial_port):
            serial_port = '/dev/ttyUSB0'
        
        if not os.path.exists(serial_port):
            log.warning(f"Warning: Serial port not found for {bench}.")
            return None
            
        print(f"[{bench}] Loading bitstream and listening on {serial_port}...")
        
        # Start a background process for openFPGALoader so we can immediately listen
        openfpga_cmd = ['openFPGALoader', '-b', 'arty_a7_100t', bitstream]
        if not subprocess.run(['which', 'openFPGALoader'], stdout=subprocess.PIPE).stdout:
            print(f"ERROR: openFPGALoader not found in PATH. Skipping {bench}.")
            return None
            
        load_proc = subprocess.Popen(openfpga_cmd, cwd=fpga_dir, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        
        import serial
        stdout_data = ""
        start_time = time.time()
        while time.time() - start_time < 60:
            try:
                with serial.Serial(serial_port, 115200, timeout=1) as ser:
                    while time.time() - start_time < 60:
                        chunk = ser.read(256)
                        if chunk:
                            stdout_data += chunk.decode('utf-8', errors='ignore')
                            if 'RET=' in stdout_data and 'CYCLES=' in stdout_data:
                                time.sleep(0.2)
                                stdout_data += ser.read(1024).decode('utf-8', errors='ignore')
                                break
                if 'RET=' in stdout_data and 'CYCLES=' in stdout_data:
                    break
            except serial.SerialException:
                time.sleep(0.5)
                
        load_proc.wait()
        
    except subprocess.CalledProcessError as e:
        log.warning(f'Warning: Build/Run failed for {bench}: {e}')
        return None
        
    return decode_results(stdout_data, "", bench)
