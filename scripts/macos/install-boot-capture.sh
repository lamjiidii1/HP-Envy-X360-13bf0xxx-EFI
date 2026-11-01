#!/bin/bash
#
# install-boot-capture.sh - capture the live graphics state of an unattended
# (black-screen) boot to the USB stick.
#
# The 26.7.2 bring-up now reaches the accelerator, but WindowServer dies a few
# seconds after the first modeset and there is no way to type commands on the
# black screen. This installs a root LaunchDaemon that runs at boot, records
# heartbeats, dumps the WhateverXe/IORegistry state to the USB at several
# points in time, and optionally reboots the machine afterwards.
#
# It does not change the EFI, the kernel, the graphics package or any kext.
# It writes exactly three files:
#   /usr/local/bin/openmac-wex-capture.sh
#   /Library/LaunchDaemons/org.openmac.wex-capture.plist
#   /var/log/openmac-wex-capture.log
#
# Usage (run as root, from the USB stick, in a boot that works):
#   sudo /Volumes/MACUSB/install-boot-capture.sh
#   sudo ./install-boot-capture.sh --volume MACUSB
#   sudo ./install-boot-capture.sh --no-reboot
#   sudo ./install-boot-capture.sh --uninstall
#
# After the next boot, remove the stick and read
# /Volumes/<volume>/wex-capture-YYYYmmdd-HHMMSS/.
#
# Exit codes: 0 ok, 1 usage or environment, 2 not root.

set -euo pipefail

LABEL="org.openmac.wex-capture"
CAPTURE_BIN="/usr/local/bin/openmac-wex-capture.sh"
DAEMON_PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOG_FILE="/var/log/openmac-wex-capture.log"

VOLUME="MACUSB"
REBOOT=1
UNINSTALL=0
FIRST_DELAY=25
SECOND_DELAY=65
FINAL_DELAY=110

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while (( $# )); do
  case "$1" in
    --volume)     VOLUME="${2:-}"; shift 2 ;;
    --no-reboot)  REBOOT=0; shift ;;
    --reboot)     REBOOT=1; shift ;;
    --first)      FIRST_DELAY="${2:-}"; shift 2 ;;
    --second)     SECOND_DELAY="${2:-}"; shift 2 ;;
    --final)      FINAL_DELAY="${2:-}"; shift 2 ;;
    --uninstall)  UNINSTALL=1; shift ;;
    -h|--help)    usage ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run this with sudo" >&2
  exit 2
fi

if (( UNINSTALL )); then
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
  rm -f "$DAEMON_PLIST" "$CAPTURE_BIN" /var/db/openmac-wex-capture.done
  echo "removed ${LABEL}; ${LOG_FILE} was left in place"
  exit 0
fi

if [[ -z "$VOLUME" || "$VOLUME" == *$'\n'* ]]; then
  echo "error: --volume must be a non-empty single-line disk label" >&2
  exit 1
fi

# Re-arm the one-shot capture for the next boot.
rm -f /var/db/openmac-wex-capture.done

mkdir -p /usr/local/bin

# ---------------------------------------------------------------------------
# The capture program. It runs as root from launchd, before anyone logs in.
# ---------------------------------------------------------------------------
cat > "$CAPTURE_BIN" <<'CAPTURE'
#!/bin/bash
# Installed by install-boot-capture.sh. One-shot boot capture for the
# WhateverXe black-screen diagnosis. Safe to delete.

VOLUME="__VOLUME__"
REBOOT="__REBOOT__"
FIRST_DELAY=__FIRST__
SECOND_DELAY=__SECOND__
FINAL_DELAY=__FINAL__
LOG="/var/log/openmac-wex-capture.log"
SENTINEL="/var/db/openmac-wex-capture.done"

exec >>"$LOG" 2>&1
echo "=== openmac capture start $(date '+%F %T') ==="

# One-shot: the daemon reboots the machine, so a second run would reboot it
# again. Re-arm by deleting the sentinel (or run the installer again).
if [[ -e "$SENTINEL" ]]; then
  echo "capture already completed at $(cat "$SENTINEL" 2>/dev/null); exiting"
  exit 0
fi
printf '%s\n' "$(date '+%F %T')" > "$SENTINEL"

find_volume() {
  local mount="/Volumes/$VOLUME"
  local i
  for i in $(seq 1 30); do
    if [[ -d "$mount" ]]; then
      echo "$mount"
      return 0
    fi
    # The stick may not be auto-mounted before login; ask diskutil once.
    (( i == 3 )) && diskutil mount "$VOLUME" >/dev/null 2>&1 || true
    sleep 2
  done
  return 1
}

USB="$(find_volume)" || { echo "volume $VOLUME never appeared"; exit 0; }
OUT="$USB/wex-capture-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$OUT" || exit 0
echo "output $OUT"

now() { date '+%F %T'; }
uptime_short() { sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/'; }

quick_dump() {
  local dir="$1"
  mkdir -p "$dir"
  {
    echo "captured $(now)"
    echo "boottime $(uptime_short)"
    echo "loadavg $(sysctl -n vm.loadavg 2>/dev/null)"
    echo "state $(sysctl -n kern.sched 2>/dev/null | head -1)"
  } > "$dir/summary.txt" 2>&1

  ioreg -l -w0 > "$dir/ioreg_full.txt" 2>&1 || true
  ioreg -l -w0 | grep -E '"(TGL|N97|WEX|WhateverXe)[A-Za-z0-9]*"' \
    > "$dir/ioreg_wex.txt" 2>&1 || true
  ioreg -rc AppleIntelFramebuffer -w0 > "$dir/ioreg_framebuffer.txt" 2>&1 || true
  ioreg -rc IntelAccelerator -w0 > "$dir/ioreg_accelerator.txt" 2>&1 || true
  ioreg -rc IODisplay -w0 > "$dir/ioreg_display.txt" 2>&1 || true

  kextstat > "$dir/kextstat.txt" 2>&1 || true
  dmesg > "$dir/dmesg.txt" 2>&1 || true
  system_profiler SPDisplaysDataType > "$dir/displays.txt" 2>&1 || true
  ps -axl > "$dir/ps.txt" 2>&1 || true
}

full_dump() {
  local dir="$1"
  quick_dump "$dir"
  kmutil showloaded > "$dir/kmutil.txt" 2>&1 || true
  log show --last 15m --style compact \
    --predicate 'process == "kernel"' > "$dir/kernel.txt" 2>&1 || true
  log show --last 15m --style compact \
    --predicate 'process == "WindowServer" OR process == "loginwindow"' \
    > "$dir/windowserver.txt" 2>&1 || true
  # Never publish the activation identity.
  nvram -p 2>/dev/null \
    | sed -E 's/(MLB|ROM|SystemSerialNumber|HW_MLB|HW_ROM|system-id)([^[:space:]]*)[[:space:]]+.*$/\1 <redacted>/' \
    > "$dir/nvram-redacted.txt" 2>&1 || true
  ls -la /Library/Logs/DiagnosticReports > "$dir/diagnostic-reports.txt" 2>&1 || true
  find /Library/Logs/DiagnosticReports -maxdepth 1 -type f -newer "$OUT" \
    -exec cp {} "$dir/" \; 2>/dev/null || true
  ioreg -l -w0 > "$dir/ioreg_full_late.txt" 2>&1 || true
}

heartbeat() {
  local end="$1" file="$2"
  local t=0
  while (( t < end )); do
    printf '%s uptime=%s load=%s\n' "$(now)" "$(uptime_short)" \
      "$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')" >> "$file"
    sleep 5
    t=$(( t + 5 ))
  done
}

echo "first dump in ${FIRST_DELAY}s"
heartbeat "$FIRST_DELAY" "$OUT/heartbeat.txt"
quick_dump "$OUT/first" || true
echo "first dump done $(now)"

echo "second dump in $(( SECOND_DELAY - FIRST_DELAY ))s"
heartbeat "$(( SECOND_DELAY - FIRST_DELAY ))" "$OUT/heartbeat.txt"
quick_dump "$OUT/second" || true
echo "second dump done $(now)"

echo "final dump in $(( FINAL_DELAY - SECOND_DELAY ))s"
heartbeat "$(( FINAL_DELAY - SECOND_DELAY ))" "$OUT/heartbeat.txt"
full_dump "$OUT/final" || true
echo "final dump done $(now)"

echo "DONE $(now)" > "$OUT/DONE"
sync
if [[ "$REBOOT" == "1" ]]; then
  echo "rebooting"
  sleep 2
  shutdown -r now
fi
CAPTURE

for pair in "VOLUME:$VOLUME" "REBOOT:$REBOOT" "FIRST:$FIRST_DELAY" "SECOND:$SECOND_DELAY" "FINAL:$FINAL_DELAY"; do
  key="${pair%%:*}"
  value="${pair#*:}"
  case "$key" in
    VOLUME) perl -pi -e "s/__VOLUME__/\Q${value}\E/" "$CAPTURE_BIN" ;;
    REBOOT) perl -pi -e "s/__REBOOT__/${value}/" "$CAPTURE_BIN" ;;
    FIRST)  perl -pi -e "s/__FIRST__/${value}/" "$CAPTURE_BIN" ;;
    SECOND) perl -pi -e "s/__SECOND__/${value}/" "$CAPTURE_BIN" ;;
    FINAL)  perl -pi -e "s/__FINAL__/${value}/" "$CAPTURE_BIN" ;;
  esac
done

for placeholder in __VOLUME__ __REBOOT__ __FIRST__ __SECOND__ __FINAL__; do
  if grep -q "$placeholder" "$CAPTURE_BIN"; then
    echo "error: could not substitute $placeholder" >&2
    exit 1
  fi
done

chmod 755 "$CAPTURE_BIN"
chown root:wheel "$CAPTURE_BIN"

cat > "$DAEMON_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${CAPTURE_BIN}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>${LOG_FILE}</string>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
</dict>
</plist>
PLIST

chmod 644 "$DAEMON_PLIST"
chown root:wheel "$DAEMON_PLIST"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Reload if an older copy is already registered; otherwise it runs next boot.
launchctl bootout "system/${LABEL}" 2>/dev/null || true

echo "installed ${LABEL}"
echo "  capture script : ${CAPTURE_BIN}"
echo "  daemon         : ${DAEMON_PLIST}"
echo "  volume         : /Volumes/${VOLUME}"
echo "  dumps          : ${FIRST_DELAY}s, ${SECOND_DELAY}s, ${FINAL_DELAY}s after login is not required"
echo "  reboot after   : $([[ "$REBOOT" == "1" ]] && echo yes || echo no)"
echo
echo "Reboot normally now. When the machine is back, unplug the stick and read"
echo "/Volumes/${VOLUME}/wex-capture-*/ on it."
echo
echo "The capture is one-shot: after it finishes it reboots and will not run"
echo "again. Re-arm by deleting /var/db/openmac-wex-capture.done and rebooting."
