#!/bin/bash
#
# power-audit.sh - measure CPU package power, average frequency and thermal
# headroom on this machine, optionally with and without XCPM low power mode.
#
# Why this exists
# ---------------
# `hw.cpufrequency` is cosmetic: SMBIOS type 4 reports 1880 MHz, and macOS
# copies that into hw.cpufrequency / About This Mac.  The real XCPM table is
# 4700..400 MHz.  To see what the CPU actually does we have to read the
# package energy counters and the XCPM frequency ratio from powermetrics,
# which needs root.
#
# Usage:
#   sudo bash power-audit.sh                  # read-only snapshot
#   sudo bash power-audit.sh --run            # + idle / 1-thread / all-thread
#   sudo bash power-audit.sh --compare-lpm    # --run with lowpowermode 0 and 1
#
# Environment:
#   DURATION=10   seconds per phase
#   OUT=...       output directory (default LOGS/power-audit-<timestamp>)
#
# `--compare-lpm` changes lowpowermode for the duration of the test and
# restores both AC and battery values on exit.  It is the only mode that
# writes anything; the default snapshot mode is read-only.

set -u

DURATION=${DURATION:-10}
OUT=${OUT:-}
MODE=snapshot
COMPARE=0

say() { printf '%s\n' "$*"; }
die() { say "error: $*" >&2; exit 1; }

usage() {
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --run)         MODE=run ;;
        --compare-lpm) MODE=run; COMPARE=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash $0 $*"
command -v powermetrics >/dev/null || die "powermetrics not found"

REPO=$(cd "$(dirname "$0")/../.." && pwd)
if [ -z "$OUT" ]; then
    OUT="$REPO/LOGS/power-audit-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT" || die "cannot create $OUT"

AC_LPM=$(pmset -g custom | awk '/^AC Power:/{s="AC"} /^Battery Power:/{s="BAT"} $1=="lowpowermode"&&s=="AC"{print $2; exit}')
BAT_LPM=$(pmset -g custom | awk '/^AC Power:/{s="AC"} /^Battery Power:/{s="BAT"} $1=="lowpowermode"&&s=="BAT"{print $2; exit}')
AC_LPM=${AC_LPM:-0}
BAT_LPM=${BAT_LPM:-0}

restore_settings() {
    pkill -KILL -P $$ -x yes 2>/dev/null
    pmset -c lowpowermode "$AC_LPM" 2>/dev/null
    pmset -b lowpowermode "$BAT_LPM" 2>/dev/null
    say "restored lowpowermode (AC=$AC_LPM, battery=$BAT_LPM)"
}
trap restore_settings EXIT

snapshot() {
    {
        sw_vers
        say "--- xcpm ---"
        sysctl -a 2>/dev/null | grep -E '^machdep\.xcpm\.' | sort
        say "--- hw frequency (cosmetic) ---"
        sysctl hw.cpufrequency hw.cpufrequency_min hw.cpufrequency_max hw.tbfrequency 2>/dev/null
        say "--- pmset ---"
        pmset -g custom
    } > "$OUT/snapshot.txt" 2>&1

    pmset -g therm  > "$OUT/thermal.txt" 2>&1
    pmset -g batt  > "$OUT/battery.txt" 2>&1
    ioreg -rn AppleSmartBattery -l > "$OUT/battery-ioreg.txt" 2>&1
    ioreg -l -w0 2>/dev/null \
        | grep -E '"WEXPowerProfile"|"IOPlatformPowerProfile"|"IOPlatformSystemSleepPolicy"' \
        > "$OUT/power-profiles.txt"

    say "snapshot: $OUT/snapshot.txt"
    say "power source: $(pmset -g batt | grep -o "Now drawing from '[^']*'")"
    say "lpm_enabled: $(sysctl -n machdep.xcpm.lpm_enabled)"
}

# One powermetrics window.  Prefer CPU+GPU power; fall back to CPU only if the
# GPU sampler is not available on this build.
#
# Ask for P-state and PLIMIT detail too.  This 24H232 build silently ignores
# --show-pstates (no PState block appears), so the per-CPU frequency lines are
# the source of truth; the flags are kept because other builds honour them.
sample() {
    local name=$1 count=$2 out="$OUT/$1.powermetrics.txt"
    rm -f "$out"
    if ! powermetrics --samplers cpu_power,gpu_power --show-pstates --show-plimits \
            -i 1000 -n "$count" -o "$out" >/dev/null 2>&1; then
        rm -f "$out"
        if ! powermetrics --samplers cpu_power,gpu_power -i 1000 -n "$count" \
                -o "$out" >/dev/null 2>&1; then
            rm -f "$out"
            powermetrics --samplers cpu_power -i 1000 -n "$count" \
                -o "$out" >/dev/null 2>&1 || true
        fi
    fi
}

# Start N spinners, sample for DURATION seconds, then stop them.
#
# SIGKILL is deliberate: the osascript admin trampoline runs the shell with
# SIGTERM ignored, and children inherit that disposition.  A plain `kill`
# therefore leaves the spinner alive and `wait` blocks forever.
run_load() {
    local name=$1 procs=$2
    local pids=() i
    for ((i = 0; i < procs; i++)); do
        yes > /dev/null &
        pids+=("$!")
    done
    sleep 1
    sample "$name" "$DURATION"
    for i in "${pids[@]}"; do kill -KILL "$i" 2>/dev/null; done
    wait 2>/dev/null
}

pkg_stats() {
    grep -E 'Intel energy model derived package power' "$1" 2>/dev/null \
        | grep -oE '[0-9]+(\.[0-9]+)?W' | tr -d 'W' \
        | awk '{s += $1; n++; if (n == 1 || $1 > mx) mx = $1; if (n == 1 || $1 < mn) mn = $1}
               END { if (n) printf "%.2f W avg, %.2f-%.2f W (n=%d)", s / n, mn, mx, n; else print "n/a" }'
}

freq_stats() {
    grep -oE '\([0-9]+(\.[0-9]+)? Mhz\)' "$1" 2>/dev/null \
        | grep -oE '[0-9]+(\.[0-9]+)?' \
        | awk '{s += $1; n++; if ($1 > mx) mx = $1; if ($1 >= 4000) hi++}
               END { if (n) printf "peak %.0f MHz, %d/%d core-samples >=4 GHz", mx, hi + 0, n; else print "n/a" }'
}

summarize() {
    local f="$OUT/$1.powermetrics.txt"
    [ -f "$f" ] || { say "$1: no data"; return; }
    say "$1:"
    say "  package: $(pkg_stats "$f")"
    say "  cpu    : $(freq_stats "$f")"
    say "  $(grep 'Package 0 C-state residency' "$f" | tail -1 | sed 's/^Package 0 //')"
    say "  $(grep 'GPU 0 DC6 Residency' "$f" | tail -1 | sed 's/^GPU 0 //')"
}

run_phase() {
    local tag=$1
    say "== $tag (lowpowermode AC=$(pmset -g custom | awk '/^AC Power:/{s="AC"} /^Battery Power:/{s="BAT"} $1=="lowpowermode"&&s=="AC"{print $2; exit}'), lpm_enabled=$(sysctl -n machdep.xcpm.lpm_enabled)) =="

    say "  idle ${DURATION}s (3 s settle first)"
    sleep 3
    sample "$tag-idle" "$DURATION"

    say "  one thread ${DURATION}s"
    run_load "$tag-single" 1

    say "  all threads (${NCpu:-12}) ${DURATION}s"
    run_load "$tag-all" "${NCpu:-12}"

    pmset -g therm > "$OUT/$tag-thermal.txt" 2>&1
    summarize "$tag-idle"
    summarize "$tag-single"
    summarize "$tag-all"
}

NCpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 12)

snapshot

if [ "$MODE" = run ]; then
    say
    say "NOTE: load phases heat the package.  Stop now with Ctrl-C if that is not wanted."
    if [ "$COMPARE" = 1 ]; then
        pmset -a lowpowermode 0
        run_phase lpm0
        pmset -a lowpowermode 1
        say "lpm_enabled after enabling lowpowermode: $(sysctl -n machdep.xcpm.lpm_enabled)"
        run_phase lpm1
    else
        run_phase current
    fi
    say
    say "raw powermetrics: $OUT/*.powermetrics.txt"
fi
