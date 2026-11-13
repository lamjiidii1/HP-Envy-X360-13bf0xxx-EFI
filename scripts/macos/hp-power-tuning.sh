#!/bin/sh
#
# hp-power-tuning.sh - apply sysctl-only idle power settings at boot.
#
# Installed as /usr/local/sbin/hp-power-tuning by install-power-tuning.sh.
# Every setting here is lost on reboot, which is why this runs from launchd.
#
# Timer coalescing: kernel/foreground/timeshare/tier-0 timers may move by up to
# half their interval, at most 10 ms (Apple default: 1/8, at most 1 ms); tier-1
# up to 20 ms.  Real-time threads and hardware interrupts (audio, display) are
# not coalesced.  Measured ~0.7-1.6 W package at idle on this machine.
#
# EPP 96: the shipped WhateverXe kext already defaults to 96 (see
# tools/patches/whateverxe-xepm-epp96.patch).  The write below is a no-op on
# that build and re-asserts the value on an older kext or after a runtime
# override.  Harmless when XE-PM is not loaded.

set -u

for t in kt fp ts tier0; do
    sysctl -w kern.timer_coalesce_${t}_scale=1 kern.timer_coalesce_${t}_ns_max=10000000
done
sysctl -w kern.timer_coalesce_tier1_ns_max=20000000

# XE-PM appears ~20 s after the patcher loads; poll briefly instead of sleeping
# blindly, and exit 0 either way.
i=0
while [ "$i" -lt 30 ]; do
    if sysctl -n debug.xepm.epp >/dev/null 2>&1; then
        sysctl -w debug.xepm.epp=96
        break
    fi
    sleep 1
    i=$((i + 1))
done

exit 0
