#!/bin/bash
#
# power-profile.sh - apply a battery/thermal profile to this Hackintosh.
#
# Why this exists
# ---------------
# The HP firmware does not expose fan control to macOS, and sleep is broken,
# so the only reliable thermal levers are pmset's low power mode and the
# display/idle timers.  On Intel, macOS 15 maps `lowpowermode 1` to XCPM's
# low-power profile: the package is held to the `lpm_ratio` in
# IOPlatformPowerProfile (0x18 = 24 -> 2.4 GHz) and XCPM parks cores earlier.
# That is the closest equivalent to power-profiles-daemon's "balanced" mode
# on Fedora, and it is reversible with a single pmset command.
#
# What does NOT work
# ------------------
# WhateverXe's `-wex-pm` profile is inert on this kernel.  WhateverXe
# registers debug.xepm.* and parses the boot argument, but the HWP route
# (a routed hook on XCPM's set-multiplier function) fails to install:
#
#   debug.xepm.hwp   = 0   (hook not installed, so no MSR 0x774 write)
#   debug.xepm.route = 3   (routeFunction failed; 1 would mean installed)
#   debug.xepm.d3    = 5   (unchanged from the compiled-in default)
#
# Consequently `-wex-pm`'s EPP=0 is never applied, and there is no point in
# trying to tune `debug.xepm.epp` (the sysctl is root-only and the write
# would not reach the hardware anyway).  The boot argument is harmless and
# still patches the C-state idle table, so it is left in place.
#
# Usage:
#   sudo bash power-profile.sh status
#   sudo bash power-profile.sh balanced     # default: cap on battery only
#   sudo bash power-profile.sh battery      # cap on AC too, shortest timers
#   sudo bash power-profile.sh performance  # no cap anywhere
#
# Revert the CPU cap at any time with:
#   sudo pmset -a lowpowermode 0
#
# Nothing here touches sleep/hibernation: those settings are documented in
# docs/06-usb-acpi-power.md and must stay at sleep 0 / hibernatemode 0.

set -u

say() { printf '%s\n' "$*"; }
die() { say "error: $*" >&2; exit 1; }

usage() {
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash $0 $*"
}

# Print the effective lowpowermode for one power source.  pmset -g custom
# prints two blocks; the first matching key after the block header wins.
lpm_for() {
    pmset -g custom | awk -v want="$1" '
        /^AC Power:/      { src = "AC" }
        /^Battery Power:/ { src = "BAT" }
        $1 == "lowpowermode" && src == want { print $2; exit }
    '
}

show_status() {
    say "== pmset =="
    pmset -g custom
    say
    say "== XCPM =="
    printf 'lpm_enabled            = %s\n' "$(sysctl -n machdep.xcpm.lpm_enabled 2>/dev/null)"
    printf 'lpm_plimit_max_ratio   = %s (x100 MHz)\n' "$(sysctl -n machdep.xcpm.lpm_plimit_max_100mhz_ratio 2>/dev/null)"
    printf 'hard_plimit_max_ratio  = %s (x100 MHz)\n' "$(sysctl -n machdep.xcpm.hard_plimit_max_100mhz_ratio 2>/dev/null)"
    say
    say "== WhateverXe XE-PM (expected: route 3 / hwp 0 = hook not installed) =="
    for k in hwp epp eet_off cst d3 route; do
        printf 'debug.xepm.%-8s = %s\n' "$k" "$(sysctl -n "debug.xepm.$k" 2>/dev/null || echo n/a)"
    done
    say
    say "== thermal / power source =="
    pmset -g therm
    pmset -g batt
}

set_common_keepalive() {
    # powernap and the broken sleep settings stay as documented elsewhere.
    pmset -a powernap 0
    pmset -a hibernatemode 0 standby 0 sleep 0
}

case "${1:-}" in
    status)
        show_status
        ;;
    balanced)
        need_root "$@"
        set_common_keepalive
        pmset -b lowpowermode 1
        pmset -c lowpowermode 0
        pmset -b displaysleep 5
        pmset -c displaysleep 10
        pmset -b tcpkeepalive 0
        pmset -c tcpkeepalive 1
        pmset -b lessbright 1 halfdim 1
        say "balanced: battery capped at XCPM lpm_ratio (2.4 GHz), AC uncapped"
        show_status
        ;;
    battery)
        need_root "$@"
        set_common_keepalive
        pmset -a lowpowermode 1
        pmset -a displaysleep 5
        pmset -b tcpkeepalive 0
        pmset -a lessbright 1 halfdim 1
        say "battery: 2.4 GHz cap on both sources, 5 s display sleep"
        show_status
        ;;
    performance)
        need_root "$@"
        set_common_keepalive
        pmset -a lowpowermode 0
        pmset -a displaysleep 10
        pmset -b tcpkeepalive 1
        say "performance: no XCPM cap on either source"
        show_status
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        die "unknown profile: $1 (use status|balanced|battery|performance)"
        ;;
esac
