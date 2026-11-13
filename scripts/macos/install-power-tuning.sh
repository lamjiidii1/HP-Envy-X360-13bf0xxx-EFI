#!/bin/bash
#
# install-power-tuning.sh - re-apply sysctl-only idle power settings at boot.
#
# Why this exists
# ---------------
# Timer coalescing (`kern.timer_coalesce_*`) is a sysctl, not a pmset key, so
# it does not survive a reboot.  The shipped WhateverXe kext already defaults
# XE-PM to EPP 96, but the same daemon re-asserts it for an older kext or after
# a runtime override.  Measured together on this machine: -0.86 W mean package
# at idle (see docs/14-measurements.md).
#
# This installs a one-shot LaunchDaemon.  It does not keep watching, so a
# deliberate `sysctl -w debug.xepm.epp=0` after login still wins until reboot.
#
# Usage:
#   sudo bash install-power-tuning.sh              # install and apply now
#   sudo bash install-power-tuning.sh --apply      # apply now, leave install
#   sudo bash install-power-tuning.sh --status
#   sudo bash install-power-tuning.sh --uninstall
#
# Files:
#   /usr/local/sbin/hp-power-tuning
#   /Library/LaunchDaemons/local.hp-power-tuning.plist
#   /Library/Logs/hp-power-tuning.log

set -u

LABEL=local.hp-power-tuning
PLIST="/Library/LaunchDaemons/$LABEL.plist"
INSTALLED=/usr/local/sbin/hp-power-tuning
LOG=/Library/Logs/hp-power-tuning.log
SRC=$(cd "$(dirname "$0")" && pwd)/hp-power-tuning.sh

say() { printf '%s\n' "$*"; }
die() { say "error: $*" >&2; exit 1; }

usage() {
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash $0 $*"
}

show_status() {
    say "daemon script : $([ -x "$INSTALLED" ] && echo "$INSTALLED" || echo missing)"
    say "launchd plist : $([ -f "$PLIST" ] && echo "$PLIST" || echo missing)"
    if launchctl print "system/$LABEL" >/dev/null 2>&1; then
        say "launchd state : loaded"
    else
        say "launchd state : not loaded"
    fi
    say "current values:"
    for k in \
        kern.timer_coalesce_tier0_scale \
        kern.timer_coalesce_tier0_ns_max \
        kern.timer_coalesce_tier1_ns_max \
        debug.xepm.epp
    do
        v=$(sysctl -n "$k" 2>/dev/null) || v=unavailable
        printf '  %-38s %s\n' "$k" "$v"
    done
}

case "${1:-}" in
    -h|--help|help)
        usage; exit 0 ;;
    --status|status)
        show_status; exit 0 ;;
    --apply|apply)
        need_root "$@"
        [ -x "$INSTALLED" ] || die "$INSTALLED is not installed; run without --apply first"
        /bin/sh "$INSTALLED" && say "applied hp-power-tuning"
        show_status
        exit 0 ;;
    --uninstall|uninstall)
        need_root "$@"
        launchctl bootout "system/$LABEL" 2>/dev/null || true
        rm -f "$PLIST" "$INSTALLED"
        say "removed $LABEL and $INSTALLED"
        say "current sysctl values are left as they are until the next reboot"
        exit 0 ;;
    "")
        ;;
    *)
        die "unknown option: $1 (see --help)" ;;
esac

need_root "$@"
[ -f "$SRC" ] || die "hp-power-tuning.sh not found next to this script"

install -m 755 -o root -g wheel "$SRC" "$INSTALLED" || die "copy failed"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>$INSTALLED</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null || die "generated plist does not parse"
: > "$LOG"

launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST" || die "launchctl bootstrap failed"
launchctl enable "system/$LABEL" 2>/dev/null || true

say "installed $LABEL -> $INSTALLED"
show_status
say "the settings are re-applied at every boot; run 'sudo bash $0 --uninstall' to stop that"
