#!/bin/bash
#
# install-boot-capture.sh - capture the live graphics state of an unattended
# (black-screen) boot to the USB stick.
#
# The 26.7.2 bring-up reaches the accelerator, but the display path dies a few
# seconds after the first modeset and nothing can be typed on the black screen.
# This installs a root LaunchDaemon that runs at boot, takes the first snapshot
# immediately, keeps a 1 Hz heartbeat alive, and repeats cheap snapshots on a
# schedule. The heartbeat and the `run.log` stage markers are what tell us
# whether the kernel wedged, which command hung, and how far it got.
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
#   sudo ./install-boot-capture.sh --schedule "0 3 8 15 30 60 120"
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
SENTINEL_FILE="/var/db/openmac-wex-capture.done"

VOLUME="MACUSB"
REBOOT=1
UNINSTALL=0
SCHEDULE="0 3 8 15 30 60 120"

usage() {
  cat <<'EOF'
install-boot-capture.sh - capture one boot to the USB stick

Usage:
  sudo install-boot-capture.sh [options]

Options:
  --volume NAME      disk label of the USB stick        (default: MACUSB)
  --schedule "LIST"  snapshot times in seconds, ascending;
                     the first entry must be 0          (default: 0 3 8 15 30 60 120)
  --no-reboot        stay running after the last snapshot
  --reboot           reboot after the last snapshot     (default)
  --uninstall        remove the daemon and its state
  -h, --help         show this text

The daemon takes the first snapshot immediately, then one at each scheduled
time. Every non-first snapshot is cheap (framebuffer/accelerator/display/
ioreg); the last one is full (adds dmesg, log show, nvram redacted, panic
reports). A 1 Hz heartbeat runs alongside so a wedge is visible in the data.
EOF
  exit 0
}

while (( $# )); do
  case "$1" in
    --volume)     VOLUME="${2:-}"; shift 2 ;;
    --no-reboot)  REBOOT=0; shift ;;
    --reboot)     REBOOT=1; shift ;;
    --schedule)   SCHEDULE="${2:-}"; shift 2 ;;
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
  rm -f "$DAEMON_PLIST" "$CAPTURE_BIN" "$SENTINEL_FILE"
  echo "removed ${LABEL}; ${LOG_FILE} was left in place"
  exit 0
fi

if [[ -z "$VOLUME" || "$VOLUME" == *$'\n'* ]]; then
  echo "error: --volume must be a non-empty single-line disk label" >&2
  exit 1
fi

# The schedule must be a list of non-negative, strictly ascending integers with
# a first entry of 0, so that the first snapshot is taken immediately.
read -r -a schedule_values <<< "$SCHEDULE"
if (( ${#schedule_values[@]} == 0 )); then
  echo "error: --schedule must not be empty" >&2
  exit 1
fi
prev=-1
for value in "${schedule_values[@]}"; do
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "error: --schedule entry is not a non-negative integer: $value" >&2
    exit 1
  fi
  if (( value <= prev )); then
    echo "error: --schedule must be strictly ascending: $SCHEDULE" >&2
    exit 1
  fi
  prev="$value"
done
if [[ "${schedule_values[0]}" != "0" ]]; then
  echo "error: the first --schedule entry must be 0 (capture starts immediately)" >&2
  exit 1
fi
SCHEDULE="${schedule_values[*]}"

# Re-arm the one-shot capture for the next boot.
rm -f "$SENTINEL_FILE"

mkdir -p /usr/local/bin

# ---------------------------------------------------------------------------
# The capture program. It runs as root from launchd, before anyone logs in.
# ---------------------------------------------------------------------------
cat > "$CAPTURE_BIN" <<'CAPTURE'
#!/bin/bash
# Installed by install-boot-capture.sh. One-shot boot capture for the
# WhateverXe black-screen diagnosis. Safe to delete.
#
# Design notes (learned from the 21:00 run, which died after two heartbeats):
#   * the first snapshot is taken immediately, before any delay, because the
#     kernel can die within seconds of the daemon starting;
#   * the heartbeat is 1 Hz and forks nothing but `date` once every ten beats;
#   * `run.log` gets a line before and after every capture command, with a
#     `sync`, so the last line identifies the command that hung;
#   * the one-shot sentinel is written only after DONE, so an early death
#     re-arms the capture for the next boot instead of leaving us blind.

VOLUME="__VOLUME__"
REBOOT="__REBOOT__"
SCHEDULE="__SCHEDULE__"
LOG="/var/log/openmac-wex-capture.log"
SENTINEL="/var/db/openmac-wex-capture.done"

exec >>"$LOG" 2>&1
echo "=== openmac capture start $(date '+%F %T') ==="

if [[ -e "$SENTINEL" ]]; then
  echo "sentinel $SENTINEL exists ($(cat "$SENTINEL" 2>/dev/null)); nothing to do"
  exit 0
fi
echo "no sentinel yet; capturing"

find_volume() {
  local mount="/Volumes/$VOLUME"
  local i
  for i in $(seq 1 30); do
    if [[ -d "$mount" ]]; then
      echo "$mount"
      return 0
    fi
    (( i == 3 )) && diskutil mount "$VOLUME" >/dev/null 2>&1 || true
    sleep 2
  done
  return 1
}

USB="$(find_volume)" || { echo "volume $VOLUME never appeared"; exit 0; }
OUT="$USB/wex-capture-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$OUT" || exit 0
RUN="$OUT/run.log"

mark() {
  local line
  line="$(date '+%F %T') [${SECONDS}s] $*"
  printf '%s\n' "$line" >>"$RUN" 2>/dev/null
  printf '%s\n' "$line"
  sync
}

mark "capture start, output=$OUT"

# --- heartbeat -------------------------------------------------------------
# 1 Hz, no forks in the common case: $SECONDS is a bash builtin. Every tenth
# beat also records the wall clock and syncs, so the USB copy stays readable
# even if the machine resets without a clean unmount.
beat() {
  local n=0
  while :; do
    n=$(( n + 1 ))
    if (( n % 10 == 0 )); then
      printf '%s beat=%s\n' "$(date '+%F %T')" "$SECONDS" \
        >>"$OUT/heartbeat.txt" 2>/dev/null
      sync
    else
      printf 'beat=%s\n' "$SECONDS" >>"$OUT/heartbeat.txt" 2>/dev/null
    fi
    sleep 1
  done
}

beat &
BEAT=$!
trap 'kill "$BEAT" 2>/dev/null || true' EXIT
mark "heartbeat started (pid $BEAT)"

# --- snapshots -------------------------------------------------------------
# cap <dir> <name> <command...> : announce, run, announce. The two markers are
# the whole point: if run.log stops between begin and end, that command hung.
cap() {
  local dir="$1" name="$2"
  shift 2
  mark "  begin $name"
  "$@" >"$dir/$name.txt" 2>&1 || true
  mark "  end   $name"
}

snap_core() {
  local dir="$1"
  mkdir -p "$dir" || return 0
  mark "snapshot $dir (core)"
  {
    echo "captured $(date '+%F %T')"
    echo "elapsed_s $SECONDS"
    echo "boot_args $(sysctl -n kern.bootargs 2>/dev/null)"
    echo "uname $(uname -a 2>/dev/null)"
  } >"$dir/summary.txt" 2>/dev/null || true
  sync

  # Ordered cheapest-and-most-informative first: the WhateverXe diagnostics
  # are published as ioreg properties on the framebuffer and accelerator.
  cap "$dir" ioreg_framebuffer ioreg -rc AppleIntelFramebuffer -w0
  cap "$dir" ioreg_accelerator ioreg -rc IntelAccelerator -w0
  cap "$dir" ioreg_display     ioreg -rc IODisplay -w0
  sync
  mark "snapshot $dir core done"
}

snap_full() {
  local dir="$1"
  snap_core "$dir"
  cap "$dir" ioreg_full   ioreg -l -w0
  grep -E '"(TGL|N97|WEX|WhateverXe|AGDP)[A-Za-z0-9_]*"' \
    "$dir/ioreg_full.txt" >"$dir/ioreg_wex.txt" 2>/dev/null || true
  cap "$dir" kextstat    kextstat
  cap "$dir" kmutil      kmutil showloaded
  cap "$dir" dmesg       dmesg
  cap "$dir" displays    system_profiler SPDisplaysDataType
  cap "$dir" ps          ps -axl
  sync
  mark "snapshot $dir full done"
}

snap_final_extras() {
  local dir="$1"
  cap "$dir" kernel log show --last 20m --style compact \
    --predicate 'process == "kernel"'
  cap "$dir" windowserver log show --last 20m --style compact \
    --predicate 'process == "WindowServer" OR process == "loginwindow"'
  mark "  begin nvram (redacted)"
  # Never publish the activation identity.
  nvram -p 2>/dev/null \
    | sed -E 's/(MLB|ROM|SystemSerialNumber|HW_MLB|HW_ROM|system-id)([^[:space:]]*)[[:space:]]+.*$/\1 <redacted>/' \
    >"$dir/nvram-redacted.txt" 2>&1 || true
  mark "  end   nvram (redacted)"
  ls -la /Library/Logs/DiagnosticReports >"$dir/diagnostic-reports.txt" 2>&1 || true
  find /Library/Logs/DiagnosticReports -maxdepth 1 -type f -newer "$RUN" \
    -exec cp {} "$dir/" \; 2>/dev/null || true
  sync
}

# The last scheduled stage is the only expensive one, so a slow dump can never
# eat the window in which a later, more interesting snapshot should be taken.
last_stage="$(printf '%s\n' $SCHEDULE | tail -1)"

for t in $SCHEDULE; do
  if (( SECONDS < t )); then
    sleep $(( t - SECONDS ))
  fi
  dir="$(printf '%s/t%03d' "$OUT" "$t")"
  if [[ "$t" == "$last_stage" ]]; then
    snap_full "$dir"
    snap_final_extras "$dir"
  else
    snap_core "$dir"
  fi
done

# --- status summary --------------------------------------------------------
mark "writing status summary"
{
  echo "capture: $OUT"
  echo "first stage: $(head -1 "$OUT"/t000/summary.txt 2>/dev/null | tr '\n' ' ')"
  echo
  echo "stages:"
  for d in "$OUT"/t[0-9][0-9][0-9]; do
    [[ -d "$d" ]] || continue
    printf '  %s  %s\n' "$(basename "$d")" \
      "$(tr '\n' ' ' <"$d/summary.txt" 2>/dev/null)"
  done
  echo
  echo "last heartbeat: $(tail -1 "$OUT/heartbeat.txt" 2>/dev/null)"
  echo
  echo "WhateverXe properties seen (last stage wins on duplicates):"
  grep -hoE '"(N97|TGL|WEX|WhateverXe|AGDP)[A-Za-z0-9_]*" = [^<]*' \
    "$OUT"/t*/ioreg_accelerator.txt "$OUT"/t*/ioreg_framebuffer.txt \
    2>/dev/null | sort -u | head -100
} >"$OUT/status.txt" 2>&1 || true
sync

mark "DONE"
printf '%s\n' "$(date '+%F %T')" >"$OUT/DONE"
sync

# Only now is the run complete: an early death leaves no sentinel, so the next
# boot captures again.
printf '%s\n' "$(date '+%F %T')" >"$SENTINEL"
sync

kill "$BEAT" 2>/dev/null || true
trap - EXIT

if [[ "$REBOOT" == "1" ]]; then
  mark "rebooting"
  sleep 3
  shutdown -r now
fi
CAPTURE

for pair in "VOLUME:$VOLUME" "REBOOT:$REBOOT" "SCHEDULE:$SCHEDULE"; do
  key="${pair%%:*}"
  value="${pair#*:}"
  case "$key" in
    VOLUME)   perl -pi -e "s/__VOLUME__/\Q${value}\E/" "$CAPTURE_BIN" ;;
    REBOOT)   perl -pi -e "s/__REBOOT__/${value}/" "$CAPTURE_BIN" ;;
    SCHEDULE) perl -pi -e "s/__SCHEDULE__/\Q${value}\E/" "$CAPTURE_BIN" ;;
  esac
done

for placeholder in __VOLUME__ __REBOOT__ __SCHEDULE__; do
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
echo "  snapshots at   : ${SCHEDULE} s after the daemon starts"
echo "  reboot after   : $([[ "$REBOOT" == "1" ]] && echo yes || echo no)"
echo
echo "Reboot normally now. When the machine is back, unplug the stick and read"
echo "/Volumes/${VOLUME}/wex-capture-*/ on it."
echo
echo "The capture is one-shot only after it finishes: the sentinel is written"
echo "after DONE, so a boot that dies early re-arms it for the next boot."
echo "To stop it from running again (for example after a boot loop), boot safe"
echo "mode and run:"
echo "  sudo launchctl bootout system/${LABEL}"
echo "  sudo rm -f ${SENTINEL_FILE}"
