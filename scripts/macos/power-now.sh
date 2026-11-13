#!/bin/bash
#
# power-now.sh - live battery power readout, no root required.
#
# Total draw comes from InstantAmperage x Voltage on the SmartBattery node.
# The percentage and AC/battery state come from pmset, so they match the menu
# bar.  On battery the projected runtime uses the charge actually left.
#
# Usage:
#   bash scripts/macos/power-now.sh              # refresh every second
#   INTERVAL=2 bash scripts/macos/power-now.sh   # every 2 s
#   SAMPLES=5 bash scripts/macos/power-now.sh    # stop after 5 samples
#   bash scripts/macos/power-now.sh --once       # print one line, exit
#
# When stdout is a terminal the line is rewritten in place; otherwise one line
# per sample is printed (useful for logging).

set -u

INTERVAL=${INTERVAL:-1}
SAMPLES=${SAMPLES:-0}
ONCE=0
[ "${1:-}" = "--once" ] && ONCE=1

# Prints: "<watts> <runtime-hours>"  (runtime empty when not discharging).
# ioreg prints a negative amperage as an unsigned 64-bit value, so normalise.
battery_watts() {
    ioreg -rn AppleSmartBattery -w0 | python3 -c '
import sys, re

s = sys.stdin.read()

def num(k, d=0):
    m = re.search(r"\"%s\" = (-?[0-9]+)" % k, s)
    return int(m.group(1)) if m else d

ma = num("InstantAmperage")
if ma >= 1 << 63:
    ma -= 1 << 64
mv = num("Voltage")
cc = num("CurrentCapacity")
mc = num("MaxCapacity")

w = ma * mv / 1e6
left = ""
if w < 0 and mv > 0 and mc > 0:
    left = "%.1f" % ((cc / 1000.0) * (mv / 1000.0) / (-w))
print("%.2f %s" % (w, left))
'
}

render() {
    local batt pct ac chg w left state sign
    batt=$(pmset -g batt)
    pct=$(printf '%s\n' "$batt" | sed -nE 's/.*[[:space:]]([0-9]+)%;.*/\1/p' | head -1)
    pct=${pct:-0}
    if printf '%s' "$batt" | grep -q "'AC Power'"; then ac=1; else ac=0; fi
    if printf '%s' "$batt" | grep -q 'charging;'; then chg=1; else chg=0; fi

    read -r w left <<<"$(battery_watts)"
    w=${w:-0.00}

    if [ "$ac" = 1 ]; then
        if [ "$chg" = 1 ]; then state="AC charging"; else state="AC idle"; fi
        sign=""
        awk -v w="$w" 'BEGIN { if (w > 0) printf "%3d%%  %-12s +%.2f W\n", '"$pct"', "'"$state"'", w;
                                else        printf "%3d%%  %-12s  %.2f W\n", '"$pct"', "'"$state"'", w }'
    else
        if [ -n "$left" ]; then
            printf '%3d%%  %-12s %.2f W draw  ~%s h left\n' "$pct" "battery" "$(awk -v w="$w" 'BEGIN{print -w}')" "$left"
        else
            printf '%3d%%  %-12s %.2f W draw\n' "$pct" "battery" "$(awk -v w="$w" 'BEGIN{print -w}')"
        fi
    fi
}

if [ "$ONCE" = 1 ]; then
    render
    exit 0
fi

trap 'printf "\n"; exit 0' INT TERM
i=0
while :; do
    line=$(render)
    if [ -t 1 ]; then
        printf '\r\033[K%s' "$line"
    else
        printf '%s\n' "$line"
    fi
    i=$((i + 1))
    [ "$SAMPLES" -gt 0 ] 2>/dev/null && [ "$i" -ge "$SAMPLES" ] && { printf '\n'; exit 0; }
    sleep "$INTERVAL"
done
