#!/bin/bash
#
# post-install-check.sh - collect the state that matters after a Sequoia boot.
#
# Read-only. Writes one text file to the Desktop (or the path in $1) and prints
# a short summary. Run it after changing display mode, installing the Metal
# archive workaround, or before reporting a battery/heat problem.
#
# Usage:
#   ./post-install-check.sh
#   ./post-install-check.sh /Volumes/MACUSB/wex-check.txt
#
# Exit code is always 0 unless the output file cannot be created.

set -u

OUT="${1:-$HOME/Desktop/wex-post-install-$(date +%Y%m%d-%H%M%S).txt}"
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
: > "$OUT" || { echo "error: cannot write $OUT" >&2; exit 1; }

section() {
  printf '\n===== %s =====\n' "$1" >> "$OUT"
}

run() {
  printf '\n$ %s\n' "$*" >> "$OUT"
  "$@" >> "$OUT" 2>&1 || printf '(exit %s)\n' "$?" >> "$OUT"
}

section "macOS"
run sw_vers
run uname -a

section "CPU (expect 10 physical cores / 12 logical CPUs)"
run sysctl -n machdep.cpu.brand_string
run sysctl -n hw.ncpu
run sysctl -n hw.physicalcpu
run sysctl -n hw.logicalcpu
run sysctl -n machdep.cpu.core_count
run sysctl -n machdep.cpu.thread_count
run system_profiler SPHardwareDataType
run sh -c "system_profiler SPHardwareDataType | grep -E 'Processor Name|Total Number of Cores|Hyper-Threading'"
run sh -c "ioreg -lw0 -p IODeviceTree | grep -o '\"cpu-type\" = <[^>]*>' | head -n 1"
run sh -c "nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:ctrsmt 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:ctrfixcnt 2>&1"

section "Kexts (expect RestrictEvents, CpuTopologyRebuild, WhateverXe)"
run kmutil showloaded
run kextstat

section "Graphics"
run system_profiler SPDisplaysDataType
run ioreg -rc IntelAccelerator
run ioreg -lw0 -p IODeviceTree -n GFX0
run sh -c "ioreg -lw0 | grep -o '\"TGLSequoiaMMIOGuard\" = <[^>]*>'"
run sh -c "ioreg -lw0 | grep -o '\"WhateverXeFirmwarePorts\" = <[^>]*>'"
run sh -c "ioreg -lw0 | grep -o '\"TGLMMIOStrongUCRouted\" = [^<]*'"

section "Display modes and current mode"
run system_profiler SPDisplaysDataType
run sh -c "system_profiler SPDisplaysDataType | grep -E 'Resolution|UI Looks like|Metal|VRAM|Display Type|Connection Type'"
run sh -c "defaults read com.apple.windowserver 2>/dev/null | head -80"

section "RestrictEvents NVRAM / CPU name"
run sh -c "nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:revcpu 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:revpatch 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:revcpuname 2>&1"
run sh -c "nvram -p | grep -E 'revcpu|revpatch|revcpuname|boot-args'"

section "Power and battery"
run pmset -g
run pmset -g batt
run pmset -g therm
run pmset -g assertions
run sh -c "ioreg -lw0 -r -c AppleSmartBattery | grep -E 'BatteryInstalled|MaxCapacity|DesignCapacity|CurrentCapacity|CycleCount|Temperature|TimeRemaining|ExternalConnected|IsCharging|FullyCharged'"

section "Top processes (one sample)"
run top -l 1 -o cpu -n 15

section "Recent Metal / GPU / hang evidence (5 minutes)"
run sh -c "log show --last 5m --style compact --predicate 'process == \"MTLCompilerService\" OR eventMessage CONTAINS \"XeCompilerAdapter\" OR eventMessage CONTAINS \"libigc\" OR eventMessage CONTAINS \"GPU Reset\" OR eventMessage CONTAINS \"PowerPreferences\"' 2>&1 | tail -200"

section "Compiler bundle on disk"
run sh -c "ls -l /Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/ 2>&1"
run sh -c "codesign -dv --verbose=4 /Library/GPUBundles/XeCompilerAdapter.bundle 2>&1"
run sh -c "ls -l /Library/Extensions/AppleIntelTGLCompat.kext/Contents/MacOS/ 2>&1"

section "Recent crash reports"
run sh -c "find \"$HOME/Library/Logs/DiagnosticReports\" /Library/Logs/DiagnosticReports -maxdepth 1 -type f -mtime -2 2>/dev/null | sort | tail -40"

printf '\nWrote %s\n' "$OUT"
printf 'CPU:    %s (%s logical CPUs)\n' "$(sysctl -n machdep.cpu.brand_string 2>/dev/null)" "$(sysctl -n hw.ncpu 2>/dev/null)"
printf 'Metal:  %s\n' "$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Metal Support|Metal Family/{print $2; exit}')"
printf 'Mode:   %s\n' "$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/UI Looks like/{print $2; exit}')"
printf 'Battery:%s\n' "$(pmset -g batt 2>/dev/null | tail -1)"
printf 'Next:   install the continuous collector: bash scripts/macos/openmac-diag.sh install\n'
