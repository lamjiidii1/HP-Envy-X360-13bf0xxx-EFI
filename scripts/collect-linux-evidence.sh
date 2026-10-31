#!/usr/bin/env bash
# Read-only hardware evidence collector for the HP Envy x360 13-bf0xxx.
#
# Run as root:
#   sudo ./scripts/collect-linux-evidence.sh [output-dir]
#
# Default output is LOGS/linux-evidence-<timestamp>/ (gitignored). The script
# only reads sysfs, debugfs and standard tools; it changes no firmware, disk or
# kernel setting. It is meant to capture the panel EDID, ACPI tables and VBT
# data that WhateverXe needs when macOS cannot boot far enough to collect them.

set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "error: run as root (sudo $0)" >&2
    exit 1
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:-"$repo_root/LOGS/linux-evidence-$(date +%F-%H%M%S)"}
mkdir -p "$out"/{acpi,edid,dmi,pci,debugfs}

say() { printf '%s\n' "$*" | tee -a "$out/summary.txt" >/dev/null; }
have() { command -v "$1" >/dev/null 2>&1; }

say "date: $(date -Is)"
say "kernel: $(uname -a)"
say "output: $out"

# --- System identity ---------------------------------------------------------
{
    echo "== os-release =="
    cat /etc/os-release 2>/dev/null || true
    echo
    echo "== /sys/class/dmi/id =="
    for f in /sys/class/dmi/id/*; do
        [[ -r $f ]] || continue
        printf '%s: %s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null || true)"
    done
} >"$out/dmi/dmi-sysfs.txt" 2>&1 || true

if have dmidecode; then
    dmidecode -t system -t baseboard -t bios -t processor -t memory \
        >"$out/dmi/dmidecode.txt" 2>&1 || true
fi

# --- PCI ---------------------------------------------------------------------
if have lspci; then
    lspci -nn >"$out/pci/lspci-nn.txt" 2>&1 || true
    # iGPU is 00:02.0 on this platform; capture the verbose config space too.
    lspci -vv -s 00:02.0 >"$out/pci/lspci-igpu.txt" 2>&1 || true
fi

# --- ACPI tables -------------------------------------------------------------
if have acpidump; then
    acpidump >"$out/acpi/acpidump.txt" 2>&1 || true
fi
for table in /sys/firmware/acpi/tables/*; do
    [[ -f $table && -r $table ]] || continue
    cp -f "$table" "$out/acpi/$(basename "$table")" 2>/dev/null || true
done

# --- Display / EDID / VBT ----------------------------------------------------
for status in /sys/class/drm/card*-*/status; do
    [[ -r $status ]] || continue
    conn=$(basename "$(dirname "$status")")
    printf '%s: %s\n' "$conn" "$(cat "$status")" >>"$out/edid/connectors.txt"
done

for edid in /sys/class/drm/card*-*/edid; do
    [[ -s $edid ]] || continue
    conn=$(basename "$(dirname "$edid")")
    cp -f "$edid" "$out/edid/$conn.bin"
    if have edid-decode; then
        edid-decode "$edid" >"$out/edid/$conn.txt" 2>&1 || true
    fi
done

# i915 debugfs: panel timings, eDP info, and (when exposed) the raw VBT.
for node in /sys/kernel/debug/dri/*; do
    [[ -d $node ]] || continue
    tag=$(basename "$node")
    for file in i915_display_info i915_vbt i915_opregion; do
        [[ -r $node/$file ]] || continue
        cp -f "$node/$file" "$out/debugfs/${tag}-${file}" 2>/dev/null || true
    done
done

{
    echo "== DRM/i915 kernel messages =="
    dmesg 2>/dev/null | grep -iE 'edid|drm|i915|vbt|opregion|panel' || true
} >"$out/debugfs/dmesg-drm-i915.txt" 2>&1 || true

# --- Summary -----------------------------------------------------------------
say "captured:"
say "  DMI:      $out/dmi"
say "  PCI:      $out/pci"
say "  ACPI:     $out/acpi ($(find "$out/acpi" -type f | wc -l) files)"
say "  EDID:     $out/edid ($(find "$out/edid" -name '*.bin' | wc -l) panels)"
say "  debugfs:  $out/debugfs"
vbt_count=$(find "$out/debugfs" -type f -name '*i915_vbt*' | wc -l)
if [[ ! -s "$out/acpi/DSDT" && $vbt_count -eq 0 ]]; then
    say "note: DSDT/VBT were not exposed by this kernel; EDID and ACPI tables are still useful."
fi
echo "evidence written to $out"
