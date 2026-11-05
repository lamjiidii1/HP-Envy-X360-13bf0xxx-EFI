#!/bin/bash
#
# apply-efi-cpu-speed.sh - set SMBIOS ProcessorSpeed on the real ESP.
#
# Why this exists
# ---------------
# `build/EFI` was rebuilt with ProcessorSpeed = 4700 (see build_efi.py), but
# the machine still boots the copy on disk0s1.  Replacing the whole EFI to
# change one key is unnecessarily risky, so this script mounts the ESP,
# backs up the live config.plist, changes only that key, and unmounts again.
#
# The value is cosmetic: XCPM already exposes the full 4700 -> 400 MHz
# P-state table, and powermetrics shows the real frequencies.  SMBIOS type 4
# only feeds "About This Mac", which otherwise reports the 1.88 GHz default.
#
# Usage:
#   sudo bash apply-efi-cpu-speed.sh              # patch disk0s1, unmount
#   sudo bash apply-efi-cpu-speed.sh --keep       # leave the ESP mounted
#   sudo bash apply-efi-cpu-speed.sh --disk disk1s1 --speed 4700
#
# Reboot afterwards.  To revert, restore the .bak-<timestamp> file next to
# config.plist while the ESP is mounted, then reboot.

set -u

say() { printf '%s\n' "$*"; }
die() { say "error: $*" >&2; exit 1; }

DISK=disk0s1
SPEED=4700
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --disk)  DISK=${2:-}; shift 2 ;;
        --speed) SPEED=${2:-}; shift 2 ;;
        --keep)  KEEP=1; shift ;;
        -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash $0"

mountpoint() {
    diskutil info "$DISK" 2>/dev/null \
        | awk -F': *' '/Mount Point/ { print $2; exit }'
}

mp=$(mountpoint)
if [ -z "$mp" ] || [ "$mp" = "Not mounted" ]; then
    say "mounting $DISK"
    diskutil mount "$DISK" >/dev/null || die "could not mount $DISK"
    mp=$(mountpoint)
fi
[ -n "$mp" ] && [ "$mp" != "Not mounted" ] || die "$DISK is not mounted"

CFG="$mp/EFI/OC/config.plist"
[ -f "$CFG" ] || die "no config.plist under $mp/EFI/OC"

old=$(/usr/libexec/PlistBuddy -c "Print :PlatformInfo:Generic:ProcessorSpeed" "$CFG" 2>/dev/null)
say "config: $CFG"
say "ProcessorSpeed: ${old:-<unset>} -> $SPEED"

if [ "$old" = "$SPEED" ]; then
    say "already correct, nothing to do"
else
    bak="$CFG.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$CFG" "$bak" || die "backup failed"
    say "backup: $bak"

    /usr/libexec/PlistBuddy -c "Set :PlatformInfo:Generic:ProcessorSpeed $SPEED" "$CFG" \
        || /usr/libexec/PlistBuddy -c "Add :PlatformInfo:Generic:ProcessorSpeed integer $SPEED" "$CFG" \
        || die "PlistBuddy failed"
fi

plutil -lint "$CFG" >/dev/null || die "config.plist no longer parses"

new=$(/usr/libexec/PlistBuddy -c "Print :PlatformInfo:Generic:ProcessorSpeed" "$CFG")
say "verified: ProcessorSpeed = $new"

# Keep the identity block intact; this script only touches ProcessorSpeed.
for k in SystemSerialNumber MLB SystemUUID ROM; do
    v=$(/usr/libexec/PlistBuddy -c "Print :PlatformInfo:Generic:$k" "$CFG" 2>/dev/null)
    [ -n "$v" ] || die "identity key $k went missing"
done
say "identity keys intact"

if [ "$KEEP" -eq 1 ]; then
    say "ESP left mounted at $mp"
else
    diskutil unmount "$DISK" >/dev/null && say "unmounted $DISK"
fi

say "reboot to apply; About This Mac should then show 4.7 GHz"
