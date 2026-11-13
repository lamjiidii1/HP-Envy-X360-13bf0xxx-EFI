#!/usr/bin/env python3
"""Decode the XE-PM MSR snapshot (sysctl debug.xepm.msr).

The snapshot is a binary array of {uint32 id, int32 status, uint64 value}.
Package C-state residency counters are in TSC ticks (turbostat divides them
by the TSC delta), so the delta between two reads becomes a residency
percentage once the window length is known.

The sysctl only exists in a probe build of WhateverXe; the shipped kext does
not expose it, so use powermetrics' "Package 0 C-state residency" line there.

Examples:
  sudo sysctl -b debug.xepm.msr > /tmp/msr1.bin
  sleep 10
  sudo sysctl -b debug.xepm.msr > /tmp/msr2.bin
  scripts/macos/xepm-msr.py /tmp/msr1.bin /tmp/msr2.bin --seconds 10

  # write the deepest package C-state limit (8 = C10/no limit on TGL/ADL/RPL)
  sudo sysctl -w debug.xepm.pcst=8
  sysctl debug.xepm.pcst_status
"""

import argparse
import struct
import subprocess

NAMES = {
    0x0E2: "PKG_CST_CONFIG_CONTROL",
    0x060: "PKG_C2_RESIDENCY",
    0x3F8: "PKG_C3_RESIDENCY",
    0x3F9: "PKG_C6_RESIDENCY",
    0x3FA: "PKG_C7_RESIDENCY",
    0x630: "PKG_C8_RESIDENCY",
    0x631: "PKG_C9_RESIDENCY",
    0x632: "PKG_C10_RESIDENCY",
    0xDB0: "PKG_HDC_CTL",
    0xDB1: "PM_CTL1",
    0x1FC: "POWER_CTL",
    0x1A0: "MISC_ENABLE",
    0x1B0: "ENERGY_PERF_BIAS",
    0x19C: "THERM_STATUS",
    0x610: "PKG_POWER_LIMIT",
    0x614: "PKG_POWER_INFO",
    0x770: "PM_ENABLE",
    0x771: "HWP_CAPABILITIES",
    0x774: "HWP_REQUEST",
    0x0CE: "PLATFORM_INFO",
}

RESIDENCY = {
    0x060: "PC2",
    0x3F8: "PC3",
    0x3F9: "PC6",
    0x3FA: "PC7",
    0x630: "PC8",
    0x631: "PC9",
    0x632: "PC10",
}


def load(path):
    data = open(path, "rb").read()
    if not data or len(data) % 16:
        raise SystemExit(f"{path}: {len(data)} bytes is not a multiple of 16")
    out = {}
    for off in range(0, len(data), 16):
        msr, status, value = struct.unpack_from("<Iiq", data, off)
        out[msr] = (status, value)
    return out


def tsc_hz():
    for key in ("machdep.tsc.frequency", "hw.cpufrequency"):
        try:
            return int(subprocess.check_output(["sysctl", "-n", key]))
        except Exception:
            continue
    return 2_400_000_000


def describe(msr, value):
    if msr == 0x0E2:
        limit = value & 0xF
        cfg = "locked" if value & (1 << 15) else "unlocked"
        names = {0: "C0/C1", 1: "C2", 2: "C6 non-retention", 3: "C6 retention",
                 4: "C7", 5: "C7s", 6: "C8", 7: "C9", 8: "C10 / no limit"}
        return (f"limit={limit} ({names.get(limit, 'reserved')}) {cfg}, "
                f"c1_demotion={'on' if value & (1 << 26) else 'off'}, "
                f"pkg_demotion={'on' if value & (1 << 29) else 'off'}")
    if msr == 0x770:
        return "HWP enabled" if value & 1 else "HWP disabled"
    if msr == 0x771:
        return (f"highest={value & 0xFF} guaranteed={(value >> 8) & 0xFF} "
                f"efficient={(value >> 16) & 0xFF} lowest={(value >> 24) & 0xFF}")
    if msr == 0x774:
        return (f"min={value & 0xFF} max={(value >> 8) & 0xFF} "
                f"desired={(value >> 16) & 0xFF} epp={(value >> 24) & 0xFF}")
    if msr == 0x1B0:
        return f"EPB={value & 0xF}"
    if msr == 0x1FC:
        return (f"EE_turbo={'off' if value & (1 << 19) else 'on'}, "
                f"C1E={'on' if value & 0x2 else 'off'}")
    if msr == 0xDB0:
        return f"HDC={'enabled' if value & 1 else 'disabled'}"
    if msr == 0x610:
        # RAPL power unit is 1/8 W on this platform (MSR 0x606); printed raw otherwise.
        return (f"PL1={(value & 0x7FFF) / 8:.1f} W PL2={((value >> 32) & 0x7FFF) / 8:.1f} W "
                f"locked={'yes' if value & (1 << 31) else 'no'}")
    if msr == 0x0CE:
        return f"max_non_turbo_ratio={(value >> 8) & 0xFF}"
    return ""


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("first")
    ap.add_argument("second", nargs="?")
    ap.add_argument("--seconds", type=float, default=None,
                    help="wall time between the two snapshots, for residency percentages")
    args = ap.parse_args()

    first = load(args.first)
    print(f"{'MSR':>6}  {'name':24s} {'status':>6}  value")
    for msr, name in NAMES.items():
        if msr not in first:
            continue
        status, value = first[msr]
        note = "fault (unsupported)" if status else describe(msr, value)
        print(f"0x{msr:03X}  {name:24s} {status:6d}  0x{value:016X}  {note}")

    if not args.second:
        return
    second = load(args.second)
    hz = tsc_hz()
    print("\npackage C-state residency across the two reads:")
    any_delta = False
    for msr, name in RESIDENCY.items():
        if msr not in first or msr not in second:
            continue
        d = second[msr][1] - first[msr][1]
        if d:
            any_delta = True
            line = f"  {name:5s} +{d} ticks"
            if args.seconds:
                line += f" = {d / hz / args.seconds * 100:.2f}% of the {args.seconds:g} s window"
            print(line)
    if not any_delta:
        print("  none - package counters did not advance (PC0/C2 only, or unsupported)")


if __name__ == "__main__":
    main()
