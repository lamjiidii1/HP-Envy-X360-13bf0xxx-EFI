#!/bin/bash
#
# battery-cap-compare.sh - measure battery draw with XCPM low power mode OFF
# and compare it with the recorded `balanced` (cap ON) baseline.
#
# Why this exists
# ---------------
# `balanced` sets `lowpowermode 1` on battery.  That cap lowered AC package
# power from 19.9 W to 10.3 W under all-core load, but its cost on *light*
# battery use was never measured.  This runs the same kind of session as the
# 2026-11-07 baseline (display on, light use, no background apps) with the cap
# removed, then restores `balanced`.
#
# Usage
#   bash scripts/macos/battery-cap-compare.sh
#   DURATION=300 bash scripts/macos/battery-cap-compare.sh     # 5 minutes
#   BASELINE_W=7.93 bash scripts/macos/battery-cap-compare.sh
#   bash scripts/macos/battery-cap-compare.sh --analyze LOGS/battery-watch-*.csv
#
# Requirements
#   - on battery (unplug the charger)
#   - the machine in normal light use: read a document, do not run benchmarks
#   - OpenCode closed.  Its helper and renderer keep ~2 cores busy, so a
#     measurement taken with the desktop open is a measurement of the agent.
#   - an admin password for pmset (prompted once; kept alive for the run)
#
# The script restores `lowpowermode 1` on every exit path, including Ctrl-C.

set -u

DURATION=${DURATION:-840}          # 14 min, same as the recorded baseline
INTERVAL=${INTERVAL:-10}
SAMPLES=$(( DURATION / INTERVAL ))
REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT:-"$REPO/LOGS/battery-cap-off-$(date +%Y%m%d-%H%M%S).csv"}
PROFILE_SCRIPT="$REPO/scripts/macos/power-profile.sh"

BASELINE_W=${BASELINE_W:-7.93}
BASELINE_PEAK=${BASELINE_PEAK:-10.51}
BASELINE_H=${BASELINE_H:-6.03}
BASELINE_CSV=${BASELINE_CSV:-"$REPO/LOGS/battery-watch-20261107-142444.csv"}

say() { printf '%s\n' "$*"; }
die() { say "error: $*" >&2; exit 1; }

# timestamp,percent,mA,mV,watts,charging,external,projected_hours
# Prints: avg_w peak_w avg_h samples
stats() {
    awk -F, '
        NR > 1 && $7 == "No" && $6 == "No" && $5 + 0 < 0 {
            s += $5; n++; if (n == 1 || $5 < mn) mn = $5
        }
        NR > 1 && $8 != "" { h += $8; hn++ }
        END {
            if (n) printf "%.2f %.2f %.2f %d\n", -s / n, -mn, (hn ? h / hn : 0), n
            else   printf "0 0 0 0\n"
        }
    ' "$1"
}

recorded() {
    # Prefer a real CSV if it exists, else the constants from docs/14.
    # Never use the file under analysis as its own baseline.
    local target=${1:-}
    if [ -n "$BASELINE_CSV" ] && [ -f "$BASELINE_CSV" ] \
        && { [ -z "$target" ] || [ "$(stat -f %i "$BASELINE_CSV" 2>/dev/null)" != "$(stat -f %i "$target" 2>/dev/null)" ]; }; then
        read -r BASELINE_W BASELINE_PEAK BASELINE_H _ < <(stats "$BASELINE_CSV")
        BASELINE_SRC="csv: ${BASELINE_CSV#$REPO/}"
    else
        BASELINE_SRC="recorded: balanced, PDF, 2026-11-07"
    fi
}

compare() {
    local csv=$1
    local avg peak h n
    read -r avg peak h n < <(stats "$csv")
    if [ "$n" -eq 0 ]; then
        say "no discharge samples in $csv"
        return 1
    fi
    recorded "$csv"
    awk -v a="$avg" -v p="$peak" -v h="$h" -v n="$n" \
        -v bw="$BASELINE_W" -v bp="$BASELINE_PEAK" -v bh="$BASELINE_H" \
        -v src="$BASELINE_SRC" 'BEGIN {
            dw = a - bw
            printf "cap off : %.2f W avg, %.2f W peak, %.2f h projected (%d samples)\n", a, p, h, n
            printf "baseline: %.2f W avg, %.2f W peak, %.2f h projected (%s)\n", bw, bp, bh, src
            printf "delta   : %+.2f W (%+.1f%%), %+.2f h projected\n", dw, (bw ? dw / bw * 100 : 0), h - bh
            if (dw > 0)
                printf "=> the cap saves about %.2f W (%.0f%%) in this workload\n", dw, (bw ? dw / bw * 100 : 0)
            else
                printf "=> no measurable saving in this workload; the cap mainly limits burst clocks\n"
        }'
}

if [ "${1:-}" = "--analyze" ]; then
    [ -n "${2:-}" ] || die "usage: $0 --analyze FILE.csv"
    compare "$2"
    exit $?
fi

# --- preconditions -----------------------------------------------------------

ioreg -rn AppleSmartBattery -l 2>/dev/null | grep -q '"ExternalConnected" = No' \
    || die "unplug the charger first: this measures battery draw"
ioreg -rn AppleSmartBattery -l 2>/dev/null | grep -q '"IsCharging" = No' \
    || die "battery still reports charging; wait a minute and retry"

pct=$(ioreg -rn AppleSmartBattery -l 2>/dev/null \
    | awk '/"CurrentCapacity"/{c=$3} /"MaxCapacity"/{m=$3} END{if(m>0) print int(c*100/m)}')
[ -n "${pct:-}" ] && [ "$pct" -lt 25 ] 2>/dev/null \
    && die "battery is at ${pct}%; this run needs about $((DURATION / 60)) minutes"

if ps -Ao pcpu=,comm= -r 2>/dev/null | head -5 | grep -qi 'opencode'; then
    say "WARNING: OpenCode is running and near the top of the CPU list."
    say "         The result will measure the agent, not the laptop."
    say "         Quit OpenCode and run this again for a valid comparison."
    say ""
fi

say "phase   : lowpowermode 0 (cap off), then restore balanced"
say "duration: ${DURATION}s (${SAMPLES} samples every ${INTERVAL}s)"
say "csv     : $OUT"
say ""
say "Use the machine normally (read a document). Do not run a benchmark."
say ""

# --- root + keepalive --------------------------------------------------------

sudo -v || die "admin rights are required to change lowpowermode"
( while :; do sudo -n true 2>/dev/null; sleep 50; done ) &
KEEP=$!
CAF=""

cleanup() {
    [ -n "$CAF" ] && kill "$CAF" 2>/dev/null
    kill "$KEEP" 2>/dev/null
    sudo -n pmset -b lowpowermode 1 2>/dev/null \
        || sudo pmset -b lowpowermode 1 2>/dev/null \
        || say "warning: could not restore lowpowermode 1"
    say "restored: battery lowpowermode $(pmset -g custom | awk '/^Battery Power:/{f=1} f && /lowpowermode/{print $2; exit}')"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Keep the panel awake for the whole run: `balanced` sleeps it after 5 s.
caffeinate -dimsu -w $$ &
CAF=$!

sudo pmset -b lowpowermode 0 || die "pmset rejected lowpowermode 0"
say "lowpowermode set to 0; measuring..."
say ""

OUT="$OUT" SAMPLES="$SAMPLES" INTERVAL="$INTERVAL" \
    bash "$REPO/scripts/macos/battery-watch.sh"

say ""
say "== comparison =="
compare "$OUT"

# cleanup runs on EXIT and restores `balanced`.
