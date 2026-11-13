#!/bin/zsh
#
# idle-baseline.sh - capture an uncontaminated idle power baseline.
#
# Everything else in this repo measures while OpenCode, its TUI renderer and
# WindowServer are active; those alone keep the P-cores out of their deep
# C-states and roughly double package power.  This script is meant to be run by
# hand, from a plain Terminal window, after quitting OpenCode, so the numbers
# describe the machine rather than the tool that is measuring it.
#
# Usage:
#   sudo scripts/macos/idle-baseline.sh            # 120 s window
#   sudo scripts/macos/idle-baseline.sh 300        # 5 min window
#   sudo scripts/macos/idle-baseline.sh 120 --display-sleep
#
# Output:
#   LOGS/idle-baseline-<timestamp>/report.txt      summary + all raw samples
#   LOGS/idle-baseline-<timestamp>/msr-*.bin       debug.xepm.msr snapshots
#   LOGS/idle-baseline-<timestamp>/powermetrics.txt
#
# Exit status is 0 even when optional probes are missing, so the report is
# still usable on a machine without the diagnostic WhateverXe build.

set -u

WINDOW=${1:-120}
if [[ "$WINDOW" != <-> ]]; then
    echo "usage: sudo $0 [seconds] [--display-sleep]" >&2
    exit 2
fi
FORCE_SLEEP=0
[[ "${2:-}" == "--display-sleep" ]] && FORCE_SLEEP=1

if [[ $EUID -ne 0 ]]; then
    echo "error: run as root (sudo $0 $*)" >&2
    exit 1
fi

REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$REPO/LOGS/idle-baseline-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

exec > >(tee "$OUT/report.txt") 2>&1

TSC_HZ=$(sysctl -n machdep.tsc.frequency 2>/dev/null || echo 1881600000)   # ticks/s
BATT='AppleSmartBattery'

battery() {                  # prints "<mV> <mA(signed)> <soc>"
    # InstantAmperage is printed as unsigned 64-bit two's complement on this
    # pack, which overflows zsh arithmetic; keep the conversion in python.
    python3 - "$BATT" <<'PY'
import re, subprocess, sys
out = subprocess.run(['ioreg', '-rn', sys.argv[1]], capture_output=True, text=True).stdout
def get(key):
    m = re.search(r'"%s" = (-?\d+)' % re.escape(key), out)
    return int(m.group(1)) if m else 0
mv, ma = get('Voltage'), get('InstantAmperage')
if ma > 2**63 - 1:
    ma -= 2**64
cap, maxcap = get('AppleRawCurrentCapacity'), get('AppleRawMaxCapacity')
soc = int(round(cap * 100 / maxcap)) if maxcap else 0
print(mv, ma, soc)
PY
}

battery_watts() {            # InstantAmperage is in mA on this pack
    local mv=$1 ma=$2
    awk -v mv="$mv" -v ma="$ma" 'BEGIN{ if (ma<0) ma=-ma; printf "%.2f", mv/1000.0 * ma/1000.0 }'
}

echo "idle-baseline  $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "host           $(sysctl -n hw.model)  $(sysctl -n machdep.cpu.brand_string)"
echo "os             $(sw_vers -productVersion) ($(sw_vers -buildVersion))  kernel $(uname -r)"
echo "topology       ncpu=$(sysctl -n hw.ncpu) logical=$(sysctl -n hw.logicalcpu) physical=$(sysctl -n hw.physicalcpu)"
echo "window         ${WINDOW}s  display-sleep=${FORCE_SLEEP}"
echo

echo "== power source =="
pmset -g batt
echo

read -r MV0 MA0 SOC0 <<< "$(battery)"
echo "t0 battery     ${MV0} mV  ${MA0} mA  soc ${SOC0}%  -> $(battery_watts "$MV0" "$MA0") W"

# One cheap snapshot per window; the sysctl is the only thing running while
# the machine is supposed to be idle.
sysctl -b debug.xepm.msr > "$OUT/msr-0.bin" 2>/dev/null || true

if [[ $FORCE_SLEEP -eq 1 ]]; then
    pmset displaysleepnow
    echo "display        sleep requested"
fi

sleep $(( WINDOW / 2 ))
read -r MV1 MA1 SOC1 <<< "$(battery)"
echo "t$(( WINDOW / 2 )) battery   ${MV1} mV  ${MA1} mA  -> $(battery_watts "$MV1" "$MA1") W"
sysctl -b debug.xepm.msr > "$OUT/msr-1.bin" 2>/dev/null || true

sleep $(( WINDOW - WINDOW / 2 ))
read -r MV2 MA2 SOC2 <<< "$(battery)"
echo "t$WINDOW battery   ${MV2} mV  ${MA2} mA  -> $(battery_watts "$MV2" "$MA2") W"
sysctl -b debug.xepm.msr > "$OUT/msr-2.bin" 2>/dev/null || true
echo

# Sampling after the quiet window: the samplers themselves cost CPU, so they
# must not overlap the interval the MSR deltas describe.
echo "== powermetrics =="
/usr/bin/powermetrics -i 2000 -n 6 > "$OUT/powermetrics.txt" 2>&1 || true

echo
echo "== instantaneous processes =="
top -l 2 -s 2 -n 15 -o cpu -stats pid,command,cpu,power | tail -20

echo
echo "== power assertions =="
pmset -g assertions | sed -n '1,12p'

echo
echo "== display power =="
pmset -g powerstate IODisplayWrangler 2>/dev/null | sed -n '1,4p'
ioreg -r -c AppleBacklightDisplay -d 1 2>/dev/null | grep -o '"IOPowerManagement" = {[^}]*}'

echo
echo "== summary =="
python3 - "$OUT" "$TSC_HZ" "${MV0:-0}" "${MA0:-0}" "${MV2:-0}" "${MA2:-0}" <<'PY'
import os, re, struct, sys

out, tsc, mv0, ma0, mv2, ma2 = sys.argv[1], float(sys.argv[2]), *map(int, sys.argv[3:7])

def load(path):
    try:
        raw = open(path, 'rb').read()
    except OSError:
        return None
    d = {}
    for off in range(0, len(raw) - 15, 16):
        msr, status, value = struct.unpack_from('<Iiq', raw, off)
        d[msr] = (status, value)
    return d

def watts(mv, ma):
    return abs(mv) / 1000.0 * abs(ma) / 1000.0

a, b = load(os.path.join(out, 'msr-0.bin')), load(os.path.join(out, 'msr-2.bin'))
if a and b:
    print('package C-states (delta over the quiet window):')
    for msr, name in ((0x3F8, 'PC3 '), (0x3F9, 'PC6 '), (0x3FA, 'PC7 '),
                      (0x630, 'PC8 '), (0x631, 'PC9 '), (0x632, 'PC10')):
        (status, v0), (_, v2) = a[msr], b[msr]
        d = v2 - v0
        note = ' (unsupported)' if status else ''
        print(f'  {name}  {d / tsc:9.3f} s{note}')
    (_, cst) = b[0x0E2]
    (_, req) = b[0x774]
    (_, cap) = b[0x771]
    print(f'  0xE2         0x{cst & 0xFFFFFFFFFFFFFFFF:016x}  '
          f'limit={cst & 0xf}  cfg_locked={bool(cst & 0x8000)}')
    print(f'  HWP request  0x{req & 0xFFFFFFFFFFFFFFFF:016x}  '
          f'min={req & 0xff} max={(req >> 8) & 0xff} '
          f'desired={(req >> 16) & 0xff} epp={(req >> 24) & 0xff}')
    print(f'  HWP caps     0x{cap & 0xFFFFFFFFFFFFFFFF:016x}  '
          f'highest={cap & 0xff} guaranteed={(cap >> 8) & 0xff} '
          f'efficient={(cap >> 16) & 0xff}')
else:
    print('package C-states: unavailable (debug.xepm.msr is only in probe builds; '
          'the powermetrics line below is authoritative)')

print(f'battery        {watts(mv0, ma0):.2f} W -> {watts(mv2, ma2):.2f} W')

try:
    text = open(os.path.join(out, 'powermetrics.txt'), errors='replace').read()
except OSError:
    text = ''
last = text.split('*** Sampled system activity')[-1] if text else ''

power = re.search(r'package power \(CPUs\+GT\+SA\): ([0-9.]+)W', last)
if power:
    print(f'Soc package    {power.group(1)} W (energy model, sampled)')

pkg = re.search(r'Package 0 C-state residency: ([0-9.]+)% \(([^)]*)\)', last)
if pkg:
    print(f'package C-state {pkg.group(1)}% ({pkg.group(2)})')

cores = re.findall(r'Core (\d+) C-state residency: ([0-9.]+)%', last)
if cores:
    p = [f'{c}:{p}%' for c, p in cores if int(c) < 4]
    e = [f'{c}:{p}%' for c, p in cores if int(c) >= 4]
    print('P-cores idle  ' + '  '.join(p))
    print('E-cores idle  ' + '  '.join(e))

irq = re.findall(r'Vector (0x[0-9a-f]+\([^)]+\)): ([0-9.]+) interrupts/sec', last)
if irq:
    irq.sort(key=lambda x: -float(x[1]))
    print('top interrupt sources:')
    for vec, rate in irq[:6]:
        print(f'  {vec:24s} {rate:10s}/s')
PY

echo
echo "raw samples in $OUT"
echo "tip: run this with OpenCode and Terminal quit, on battery, brightness unchanged"
