#!/bin/bash
#
# battery-watch.sh - log real battery power and projected runtime.
#
# Why this exists
# ---------------
# `pmset -g batt` only gives a coarse percentage.  The SmartBattery node
# exposes InstantAmperage and Voltage, which are enough to compute watts and
# project runtime from the charge actually left.  Run this, unplug the
# charger, and use the machine normally; the CSV is the evidence for whether
# the `balanced` profile is enough or the display/GPU path still dominates.
#
# Usage:
#   bash battery-watch.sh                 # 10 s interval, CSV under LOGS/
#   INTERVAL=5 bash battery-watch.sh
#
# No sudo.  Stop with Ctrl-C for a summary.  Plugging the charger back in is
# fine: charging samples are recorded but excluded from the discharge average.

set -u

INTERVAL=${INTERVAL:-10}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT:-"$REPO/LOGS/battery-watch-$(date +%Y%m%d-%H%M%S).csv"}

say() { printf '%s\n' "$*"; }

val() {
    ioreg -rn AppleSmartBattery -l 2>/dev/null \
        | awk -v k="\"$1\"" '$1 == k { print $3; exit }'
}

summary() {
    say ""
    say "== summary =="
    awk -F, '
        NR > 1 && $7 == "No" && $5 + 0 < 0 { s += $5; n++; if (n == 1 || $5 < mn) mn = $5 }
        NR > 1 && $8 != "" { h += $8; hn++ }
        END {
            if (n) printf "discharge: %d samples, average %.2f W (peak %.2f W)\n", n, s / n, mn
            else   print "discharge: no samples (was the charger still connected?)"
            if (hn) printf "projected runtime: %.2f h average\n", h / hn
        }
    ' "$OUT"
    say "csv: $OUT"
}

printf 'timestamp,percent,mA,mV,watts,charging,external,projected_hours\n' > "$OUT"
say "logging to $OUT every ${INTERVAL}s"
say "Unplug the charger and use the machine normally. Ctrl-C prints a summary."
trap 'summary; exit 0' INT TERM

while :; do
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    ma=$(val InstantAmperage)
    mv=$(val Voltage)
    cc=$(val CurrentCapacity)
    mc=$(val MaxCapacity)
    ch=$(val IsCharging)
    ex=$(val ExternalConnected)

    pct=""
    [ -n "$cc" ] && [ -n "$mc" ] && [ "$mc" -gt 0 ] 2>/dev/null && pct=$((cc * 100 / mc))

    w=$(awk -v ma="${ma:-0}" -v mv="${mv:-0}" 'BEGIN { printf "%.2f", ma * mv / 1000000 }')
    hours=""
    if [ "${ma:-0}" -lt 0 ] 2>/dev/null; then
        hours=$(awk -v cc="${cc:-0}" -v mv="${mv:-0}" -v ma="$ma" \
            'BEGIN { wh = (cc / 1000) * (mv / 1000); p = (-ma * mv) / 1000000;
                      if (p > 0) printf "%.2f", wh / p }')
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$ts" "$pct" "$ma" "$mv" "$w" "$ch" "$ex" "$hours" >> "$OUT"
    printf '%s  %s%%  %s mA  %.2f W%s\n' \
        "$ts" "$pct" "$ma" "$w" "${hours:+  ~${hours} h left}"

    sleep "$INTERVAL"
done
