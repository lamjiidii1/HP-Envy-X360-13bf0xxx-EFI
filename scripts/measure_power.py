#!/usr/bin/env python3
"""
measure_power.py - Real-Time Battery Power Drain & Energy Telemetry Logger for macOS

Measures total laptop platform power draw (CPU, GPU, Display, RAM, SSD, Wi-Fi)
directly from AppleSmartBattery via IOKit.
Displays live telemetry in the terminal and concurrently saves all samples to
both a clean human-readable text report and a CSV file for analysis.

Usage:
    python3 scripts/measure_power.py
    python3 scripts/measure_power.py --interval 1.0 --duration 10m
    python3 scripts/measure_power.py --out ~/Desktop/tahoe_idle_test
"""

import sys
import os
import time
import datetime
import subprocess
import re
import signal
import argparse

# ANSI color codes (disabled if stdout is not a TTY or --no-color is set)
USE_COLOR = sys.stdout.isatty()

def colorize(text, color_code):
    if not USE_COLOR:
        return text
    return f"\033[{color_code}m{text}\033[0m"

def green(t): return colorize(t, "32")
def yellow(t): return colorize(t, "33")
def red(t): return colorize(t, "31")
def cyan(t): return colorize(t, "36")
def bold(t): return colorize(t, "1")
def dim(t): return colorize(t, "2")
def magenta(t): return colorize(t, "35")


def parse_int(val, signed=True):
    """Safely parse integer from IOKit, handling signed 32/64-bit 2s complement."""
    if val is None:
        return 0
    try:
        s = str(val).strip().strip('"')
        n = int(s)
        if signed:
            if n >= 2**63:
                n -= 2**64
            elif n >= 2**31:
                n -= 2**32
        return n
    except (ValueError, TypeError):
        return 0


def get_cpu_brand():
    """Retrieve CPU brand string via sysctl."""
    try:
        out = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True)
        return out.strip()
    except Exception:
        return "Unknown Intel/Apple CPU"


def get_macos_version():
    """Retrieve macOS version string."""
    try:
        out = subprocess.check_output(["sw_vers", "-productVersion"], text=True)
        build = subprocess.check_output(["sw_vers", "-buildVersion"], text=True)
        return f"{out.strip()} (Build {build.strip()})"
    except Exception:
        return "macOS"


def query_battery_raw():
    """Query IOKit AppleSmartBattery properties."""
    try:
        out = subprocess.check_output(["ioreg", "-rn", "AppleSmartBattery"], text=True)
    except Exception as e:
        return None

    props = {}
    for line in out.splitlines():
        m = re.match(r'\s*"([^"]+)"\s*=\s*(.*)', line)
        if m:
            props[m.group(1)] = m.group(2).strip().strip('"')
    return props


def sample_battery():
    """Take a snapshot of battery voltage, current, capacity, and compute energy/power."""
    props = query_battery_raw()
    if not props:
        return None

    now = datetime.datetime.now()
    voltage_mv = parse_int(props.get("Voltage"), signed=False)
    # Prefer InstantAmperage if present, otherwise Amperage
    amperage_raw = props.get("InstantAmperage") or props.get("Amperage")
    amperage_ma = parse_int(amperage_raw, signed=True)
    current_cap_mah = parse_int(props.get("CurrentCapacity"), signed=False)
    max_cap_mah = parse_int(props.get("MaxCapacity"), signed=False)
    design_cap_mah = parse_int(props.get("DesignCapacity"), signed=False)
    cycle_count = parse_int(props.get("CycleCount"), signed=False)
    temp_raw = parse_int(props.get("Temperature"), signed=False)

    is_charging = props.get("IsCharging") == "Yes"
    external_connected = props.get("ExternalConnected") == "Yes"
    fully_charged = props.get("FullyCharged") == "Yes"

    # Conversions
    voltage_v = voltage_mv / 1000.0
    current_wh = (current_cap_mah * voltage_mv) / 1000000.0
    max_wh = (max_cap_mah * voltage_mv) / 1000000.0
    design_wh = (design_cap_mah * voltage_mv) / 1000000.0 if design_cap_mah > 0 else max_wh

    # Battery temperature: Apple SmartBattery reports in 0.01 °C or tenths of Kelvin
    # Usually around 2800-3200 (28.0°C - 32.0°C in hundredths of deg C)
    temp_c = (temp_raw / 100.0) if temp_raw > 1000 else (temp_raw / 10.0 - 273.15 if temp_raw > 2000 else float(temp_raw))

    # Power in Watts (positive for power draw/discharge, negative for incoming charge)
    if amperage_ma < 0:
        power_w = abs(amperage_ma) * voltage_mv / 1000000.0
        state = "Discharging"
    elif amperage_ma > 0:
        power_w = -(amperage_ma * voltage_mv / 1000000.0) # Negative means charging
        state = "Charging"
    else:
        power_w = 0.0
        if external_connected:
            state = "AC (Full)" if fully_charged else "AC (Idle)"
        else:
            state = "Idle"

    pct = (current_cap_mah / max_cap_mah * 100.0) if max_cap_mah > 0 else 0.0

    return {
        "timestamp_dt": now,
        "timestamp_str": now.strftime("%Y-%m-%d %H:%M:%S"),
        "time_only": now.strftime("%H:%M:%S"),
        "voltage_v": voltage_v,
        "voltage_mv": voltage_mv,
        "amperage_ma": amperage_ma,
        "current_cap_mah": current_cap_mah,
        "max_cap_mah": max_cap_mah,
        "design_cap_mah": design_cap_mah,
        "current_wh": current_wh,
        "max_wh": max_wh,
        "design_wh": design_wh,
        "power_w": power_w,
        "pct": pct,
        "state": state,
        "is_charging": is_charging,
        "external_connected": external_connected,
        "cycle_count": cycle_count,
        "temp_c": temp_c
    }


def parse_duration(s):
    """Parse duration like '300', '10m', '1h', '30s' into seconds."""
    if not s:
        return None
    s = s.strip().lower()
    if s.endswith("s"):
        return float(s[:-1])
    if s.endswith("m"):
        return float(s[:-1]) * 60.0
    if s.endswith("h"):
        return float(s[:-1]) * 3600.0
    return float(s)


def main():
    global USE_COLOR
    parser = argparse.ArgumentParser(
        description="Capture real-time battery power drain (Watts & Wh) on macOS."
    )
    parser.add_argument(
        "-i", "--interval", type=float, default=2.0,
        help="Sampling interval in seconds (default: 2.0)"
    )
    parser.add_argument(
        "-d", "--duration", type=str, default=None,
        help="Optional test duration (e.g. 60s, 5m, 30m, 1h). Runs indefinitely until Ctrl+C if omitted."
    )
    parser.add_argument(
        "-o", "--out", type=str, default=None,
        help="Output base path or filename (default: power_test_YYYYMMDD_HHMMSS)"
    )
    parser.add_argument(
        "--no-color", action="store_true",
        help="Disable ANSI terminal colors."
    )
    args = parser.parse_args()

    if args.no_color:
        USE_COLOR = False

    max_duration_sec = parse_duration(args.duration)
    interval = max(0.5, args.interval)

    # Establish output file names
    start_time = datetime.datetime.now()
    default_prefix = f"power_test_{start_time.strftime('%Y%m%d_%H%M%S')}"
    if args.out:
        base_path = os.path.expanduser(args.out)
        if base_path.endswith(".txt"):
            txt_path = base_path
            csv_path = base_path[:-4] + ".csv"
        elif base_path.endswith(".csv"):
            csv_path = base_path
            txt_path = base_path[:-4] + ".txt"
        else:
            txt_path = base_path + ".txt"
            csv_path = base_path + ".csv"
    else:
        txt_path = default_prefix + ".txt"
        csv_path = default_prefix + ".csv"

    # Initial sample to get battery specs
    init_sample = sample_battery()
    if not init_sample:
        print(red("[-] Error: AppleSmartBattery device not found in IOKit."))
        print("    Ensure VirtualSMC and SMCBatteryManager are loaded.")
        sys.exit(1)

    cpu_model = get_cpu_brand()
    macos_ver = get_macos_version()

    # Open files for writing
    txt_file = open(txt_path, "w", encoding="utf-8")
    csv_file = open(csv_path, "w", encoding="utf-8")

    # CSV Header
    csv_file.write(
        "Timestamp,Elapsed_Sec,Elapsed_Fmt,Power_W,Battery_Wh,Drained_Wh_Integ,Drained_Wh_Cap,Percent,Voltage_V,Current_mA,State,Temp_C\n"
    )
    csv_file.flush()

    # Text File Header
    header_text = f"""================================================================================
                    macOS POWER DRAIN & TELEMETRY LOG
================================================================================
System:       {cpu_model}
OS:           {macos_ver}
Start Time:   {start_time.strftime('%Y-%m-%d %H:%M:%S')}
Sample Rate:  Every {interval:.1f} seconds
Battery Spec: {init_sample['max_wh']:.2f} Wh Max Capacity ({init_sample['max_cap_mah']} mAh)
              {init_sample['design_wh']:.2f} Wh Design Capacity ({init_sample['design_cap_mah']} mAh)
              Cycle Count: {init_sample['cycle_count']} | Health: {init_sample['max_cap_mah']/max(1, init_sample['design_cap_mah'])*100.0:.1f}%
Note:         For idle or load discharge measurements, test on Battery Power (unplug AC).
================================================================================

[Time]     [Elapsed]  [State]         [Power W]  [Battery Wh]  [Drained Wh]  [Level %]  [Volts]   [Amps]
---------------------------------------------------------------------------------------------------------
"""
    txt_file.write(header_text)
    txt_file.flush()

    # Print Welcome to Terminal
    print(bold("=" * 80))
    print(bold("               macOS POWER DRAIN & ENERGY TELEMETRY MONITOR"))
    print(bold("=" * 80))
    print(f" {cyan('CPU:')}        {cpu_model}")
    print(f" {cyan('OS:')}         {macos_ver}")
    max_wh_str = f"{init_sample['max_wh']:.2f} Wh"
    pct_str = f"{init_sample['pct']:.1f}%"
    print(f" {cyan('Battery:')}    {bold(max_wh_str)} max capacity ({init_sample['max_cap_mah']} mAh) | Level: {bold(pct_str)}")
    print(f" {cyan('Interval:')}   Every {interval:.1f} seconds" + (f" | Max Duration: {args.duration}" if args.duration else " | Running until Ctrl+C"))
    print(f" {cyan('Logs Saved:')} {txt_path}")
    print(f"             {csv_path}")
    print(dim("-" * 80))
    if init_sample["external_connected"]:
        print(yellow(" [!] Notice: AC Power adapter is currently plugged in."))
        print(yellow("     To measure actual battery drain (idle / load test), UNPLUG the charger now."))
    else:
        print(green(" [✓] Running on Battery Power. Measuring discharge rate in real time."))
    print(dim("-" * 80))
    print(bold(f"{'Time':<10} {'Elapsed':<10} {'State':<15} {'Power (W)':<11} {'Battery (Wh)':<14} {'Drained (Wh)':<14} {'Level':<8} {'Volts':<9} {'Current'}"))
    print(dim("-" * 80))

    # Tracking variables
    samples_count = 0
    integrated_wh_drained = 0.0
    initial_wh = init_sample["current_wh"]
    initial_mah = init_sample["current_cap_mah"]
    start_epoch = time.time()
    last_sample_epoch = start_epoch
    power_samples = []

    stop_requested = False

    def handle_sigint(signum, frame):
        nonlocal stop_requested
        stop_requested = True

    signal.signal(signal.SIGINT, handle_sigint)
    signal.signal(signal.SIGTERM, handle_sigint)

    try:
        while not stop_requested:
            now_epoch = time.time()
            elapsed_sec = now_epoch - start_epoch
            dt_sec = now_epoch - last_sample_epoch
            last_sample_epoch = now_epoch

            sample = sample_battery()
            if sample:
                samples_count += 1
                curr_power_w = sample["power_w"]

                # Accumulate energy drained via trapezoidal/rectangle integration if discharging
                if sample["state"] == "Discharging" and curr_power_w > 0:
                    power_samples.append(curr_power_w)
                    integrated_wh_drained += (curr_power_w * dt_sec) / 3600.0

                cap_wh_drained = max(0.0, initial_wh - sample["current_wh"])
                elapsed_str = str(datetime.timedelta(seconds=int(elapsed_sec)))

                # Choose display power string with color
                if sample["state"] == "Discharging":
                    # Color based on wattage: <8W (great idle), 8-15W (moderate), >15W (high load)
                    if curr_power_w < 8.0:
                        pwr_disp = green(f"{curr_power_w:6.2f} W")
                    elif curr_power_w <= 15.0:
                        pwr_disp = yellow(f"{curr_power_w:6.2f} W")
                    else:
                        pwr_disp = magenta(f"{curr_power_w:6.2f} W")
                    state_disp = cyan(f"{sample['state']:<15}")
                elif sample["state"] == "Charging":
                    pwr_disp = green(f"+{abs(curr_power_w):5.2f} W")
                    state_disp = green(f"{sample['state']:<15}")
                else:
                    pwr_disp = dim(f"{0.0:6.2f} W")
                    state_disp = dim(f"{sample['state']:<15}")

                batt_wh_disp = bold(f"{sample['current_wh']:6.2f} Wh")
                drained_disp = yellow(f"{integrated_wh_drained:6.3f} Wh")
                pct_disp = f"{sample['pct']:5.1f}%"
                volts_disp = f"{sample['voltage_v']:5.2f} V"
                amps_disp = f"{sample['amperage_ma']:+6d} mA"

                # Print terminal row
                print(f"{sample['time_only']:<10} {elapsed_str:<10} {state_disp} {pwr_disp}   {batt_wh_disp}   {drained_disp}   {pct_disp:<8} {volts_disp:<9} {amps_disp}")

                # Write to text file
                txt_row = f"{sample['time_only']:<10} {elapsed_str:<10} {sample['state']:<15} {curr_power_w:6.2f} W    {sample['current_wh']:6.2f} Wh       {integrated_wh_drained:6.3f} Wh       {sample['pct']:5.1f}%    {sample['voltage_v']:5.2f} V   {sample['amperage_ma']:+6d} mA\n"
                txt_file.write(txt_row)
                txt_file.flush()

                # Write to CSV
                csv_file.write(
                    f"{sample['timestamp_str']},{elapsed_sec:.1f},{elapsed_str},{curr_power_w:.2f},{sample['current_wh']:.3f},{integrated_wh_drained:.4f},{cap_wh_drained:.3f},{sample['pct']:.1f},{sample['voltage_v']:.3f},{sample['amperage_ma']},{sample['state']},{sample['temp_c']:.1f}\n"
                )
                csv_file.flush()

            # Check duration limit
            if max_duration_sec and elapsed_sec >= max_duration_sec:
                break

            time.sleep(interval)

    except KeyboardInterrupt:
        pass

    # Final summary calculations
    end_epoch = time.time()
    total_sec = end_epoch - start_epoch
    final_sample = sample_battery() or init_sample
    final_wh = final_sample["current_wh"]
    final_mah = final_sample["current_cap_mah"]
    elapsed_total_str = str(datetime.timedelta(seconds=int(total_sec)))

    avg_power_w = (sum(power_samples) / len(power_samples)) if power_samples else 0.0
    min_power_w = min(power_samples) if power_samples else 0.0
    max_power_w = max(power_samples) if power_samples else 0.0
    mah_drained = max(0, initial_mah - final_mah)
    wh_drained_cap = max(0.0, initial_wh - final_wh)

    # Battery life projection based on this test's average power
    projected_hours = (final_sample["max_wh"] / avg_power_w) if avg_power_w > 0.5 else 0.0

    summary_text = f"""
================================================================================
                           TEST RUN SUMMARY REPORT
================================================================================
Total Test Duration:    {elapsed_total_str} ({total_sec:.1f} seconds)
Samples Recorded:       {samples_count}

--- Battery Drain Metrics ---
Starting Energy:        {initial_wh:.2f} Wh ({init_sample['pct']:.1f}%)
Ending Energy:          {final_wh:.2f} Wh ({final_sample['pct']:.1f}%)
Battery Drop:           {init_sample['pct'] - final_sample['pct']:.1f}% ({mah_drained} mAh)

Total Energy Drained:   {integrated_wh_drained:.3f} Wh (integrated precision)
                        {wh_drained_cap:.3f} Wh (capacity delta)

--- Power Consumption (Discharge) ---
Average Power Draw:     {avg_power_w:.2f} Watts
Lowest Power (Idle):    {min_power_w:.2f} Watts
Peak Power (Burst):     {max_power_w:.2f} Watts

Projected Battery Life: {projected_hours:.1f} hours at this average power draw
                        (Battery Max Capacity: {final_sample['max_wh']:.2f} Wh)

--- Output Log Files ---
Text Report:            {os.path.abspath(txt_path)}
CSV Spreadsheet:        {os.path.abspath(csv_path)}
================================================================================
"""

    txt_file.write(summary_text)
    txt_file.close()
    csv_file.close()

    print(dim("-" * 80))
    print(bold(summary_text))


if __name__ == "__main__":
    main()
