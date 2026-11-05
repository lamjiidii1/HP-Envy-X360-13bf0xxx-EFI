#!/bin/bash
#
# install-power-daemon.sh - re-apply an OpenMac power profile at every boot.
#
# Why this exists
# ---------------
# `power-profile.sh balanced` writes pmset values, and pmset persists them in
# /Library/Preferences/SystemConfiguration/com.apple.PowerManagement.plist.
# That survives a reboot, but the same keys are also what the battery menu's
# "Low Power Mode" toggle and System Settings write.  A user (or an OS update)
# can therefore silently undo the profile, which is exactly how the battery
# cap drifted back to 0 on this machine.
#
# This installs a small LaunchDaemon that runs the profile once at boot.  It
# does not keep watching: a deliberate toggle after login still wins until the
# next reboot.
#
# Usage:
#   sudo bash install-power-daemon.sh                 # install, profile=balanced
#   sudo bash install-power-daemon.sh battery         # install another profile
#   sudo bash install-power-daemon.sh --status
#   sudo bash install-power-daemon.sh --uninstall
#
# Files:
#   /usr/local/libexec/openmac/power-profile.sh
#   /Library/LaunchDaemons/local.openmac.powerprofile.plist
#   /var/log/openmac-powerprofile.log

set -u

LABEL=local.openmac.powerprofile
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LIBEXEC=/usr/local/libexec/openmac
INSTALLED_SCRIPT="$LIBEXEC/power-profile.sh"
LOG=/var/log/openmac-powerprofile.log
SRC=$(cd "$(dirname "$0")" && pwd)/power-profile.sh
PROFILE=balanced

say() { printf '%s\n' "$*"; }
die() { say "error: $*" >&2; exit 1; }

usage() {
    sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash $0 $*"
}

valid_profile() {
    case "$1" in
        balanced|battery|performance) return 0 ;;
        *) return 1 ;;
    esac
}

show_status() {
    say "profile script : $([ -x "$INSTALLED_SCRIPT" ] && echo "$INSTALLED_SCRIPT" || echo missing)"
    say "launchd plist  : $([ -f "$PLIST" ] && echo "$PLIST" || echo missing)"
    if launchctl print "system/$LABEL" >/dev/null 2>&1; then
        say "launchd state  : loaded"
    else
        say "launchd state  : not loaded"
    fi
    say "current pmset  :"
    pmset -g custom 2>/dev/null | awk '
        /^AC Power:/      { src = "AC" }
        /^Battery Power:/ { src = "BAT" }
        /lowpowermode/    { printf "  %s lowpowermode %s\n", src, $2 }
    '
}

case "${1:-}" in
    -h|--help|help)
        usage; exit 0 ;;
    --status|status)
        show_status; exit 0 ;;
    --uninstall|uninstall)
        need_root "$@"
        launchctl bootout "system/$LABEL" 2>/dev/null || true
        rm -f "$PLIST"
        rm -f "$INSTALLED_SCRIPT"
        say "removed $LABEL and $INSTALLED_SCRIPT"
        say "pmset values were left as they are; use power-profile.sh to change them"
        exit 0 ;;
    "")
        ;;
    *)
        valid_profile "$1" || die "unknown profile: $1 (balanced|battery|performance)"
        PROFILE=$1
        ;;
esac

need_root "$@"
[ -f "$SRC" ] || die "power-profile.sh not found next to this script"

mkdir -p "$LIBEXEC" || die "cannot create $LIBEXEC"
install -m 755 -o root -g wheel "$SRC" "$INSTALLED_SCRIPT" || die "copy failed"

# Run the profile only after pmset answers.  launchd starts daemons early;
# a short bounded retry avoids a silent failure on a slow boot.
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
        <string>-c</string>
        <string>for i in 1 2 3 4 5 6 7 8 9 10; do pmset -g &gt;/dev/null 2&gt;&amp;1 &amp;&amp; break; sleep 1; done; exec /bin/bash $INSTALLED_SCRIPT $PROFILE</string>
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

say "installed $LABEL -> $PROFILE"
show_status
say "the profile is re-applied at every boot; run 'sudo bash $0 --uninstall' to stop that"
