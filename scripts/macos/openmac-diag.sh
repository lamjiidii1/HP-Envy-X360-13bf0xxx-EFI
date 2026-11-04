#!/bin/bash
#
# openmac-diag.sh - continuous, low-cost diagnostics for a hackintosh laptop.
#
# The goal is to capture the state that matters *before* a problem is noticed:
# CPU/GPU/thermal samples once a minute, full text snapshots every 15 minutes,
# hourly error/fault extracts, and a snapshot whenever a crash report appears.
#
# Everything is per-user and lives under:
#   ~/Library/Logs/OpenMacDiag/          collected data
#   ~/Library/Application Support/OpenMacDiag/   installed copy of this script
#   ~/Library/LaunchAgents/local.openmac.diag.*.plist
#
# No root is required. powermetrics and a full `log collect` archive are used
# only when they can run without a password prompt. Identity values (serial,
# MLB, ROM, UUID, MAC addresses) are redacted from text output.
#
# Usage:
#   ./openmac-diag.sh install          install and start the agents
#   ./openmac-diag.sh uninstall        stop and remove the agents (keep logs)
#   ./openmac-diag.sh status           show agent and storage state
#   ./openmac-diag.sh snapshot [why]   take one full text snapshot now
#   ./openmac-diag.sh archive          save the last hour (needs sudo for .logarchive)
#   ./openmac-diag.sh report [path]    bundle the newest data for sharing
#   ./openmac-diag.sh monitor          foreground: 60s metrics (agent uses this)
#   ./openmac-diag.sh stream           foreground: filtered live log (agent)
#   ./openmac-diag.sh selftest         check the tools this script needs
#
# Environment:
#   OPENMAC_DIAG_DIR       override the data directory
#   OPENMAC_DIAG_ARCHIVE=1 include an archive in every snapshot
#
# This script is intentionally bash 3.2 compatible (macOS /bin/bash).

set -u

VERSION="1.0.0"
LABEL="local.openmac.diag"
BASE="${OPENMAC_DIAG_DIR:-$HOME/Library/Logs/OpenMacDiag}"
APP_DIR="$HOME/Library/Application Support/OpenMacDiag"
AGENT_DIR="$HOME/Library/LaunchAgents"
SELF="$APP_DIR/openmac-diag.sh"
KEEP_SNAPSHOTS=40
KEEP_ARCHIVES=6
MAX_LIVE_MB=32
MAX_MONITOR_MB=16

SNAPSHOT_INTERVAL=900      # 15 minutes
ARCHIVE_INTERVAL=3600      # 1 hour
ARCHIVE_WINDOW="60m"
AGENTS="snapshot monitor stream archive crashwatch"

LOG=/usr/bin/log
[ -x "$LOG" ] || LOG="log"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
note() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
mkdirp() {
  ok=0
  for d in "$@"; do
    mkdir -p "$d" 2>/dev/null || ok=1
  done
  return "$ok"
}

rotate_log() {
  # rotate_log FILE MAX_MB
  f="$1"; max="$2"
  [ -f "$f" ] || return 0
  sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
  if [ "$sz" -ge $((max * 1048576)) ]; then
    mv -f "$f" "$f.1" 2>/dev/null || true
    : > "$f" 2>/dev/null || true
  fi
}

prune() {
  # prune DIRECTORY KEEP
  d="$1"; keep="$2"
  [ -d "$d" ] || return 0
  n=0
  for p in $(ls -1dt "$d"/* 2>/dev/null); do
    n=$((n + 1))
    [ "$n" -gt "$keep" ] && rm -rf "$p" 2>/dev/null
  done
}

redact() {
  # Remove machine identity from anything that may contain it. Patterns are not
  # anchored so they also match values embedded in unified-log lines.
  sed -E \
    -e 's/(Serial Number[^:]*:).*/\1 <redacted>/' \
    -e 's/(Hardware UUID:).*/\1 <redacted>/' \
    -e 's/(Provisioning UDID:).*/\1 <redacted>/' \
    -e 's/(Platform UUID:).*/\1 <redacted>/' \
    -e 's/^((IOPlatformSerialNumber|IOPlatformUUID|SystemSerialNumber|SystemUUID|MLB|ROM)[[:space:]]).*/\1<redacted>/' \
    -e 's/^((HW_MLB|HW_ROM|HW_BID|HW_ECK|HW_SC)[[:space:]]).*/\1<redacted>/' \
    -e 's/^([[:space:]]*Ethernet Address:).*/\1 <redacted>/' \
    -e 's/^([[:space:]]*Hardware Address:).*/\1 <redacted>/' \
    -e 's/ether [0-9a-fA-F:][0-9a-fA-F:]*/ether <redacted>/g' \
    -e 's/"?(IOPlatformSerialNumber|IOPlatformUUID|SystemSerialNumber|SystemUUID|MLB|ROM)"?[[:space:]]*=[[:space:]]*"?[^",<]+"?/\1 = <redacted>/g'
}

redact_tree() {
  # Strip identity from every text file a snapshot produced.
  d="$1"
  [ -d "$d" ] || return 0
  find "$d" -type f \( -name '*.txt' -o -name '*.log' \) 2>/dev/null | while read -r f; do
    if redact < "$f" > "$f.redacted" 2>/dev/null; then
      mv "$f.redacted" "$f"
    else
      rm -f "$f.redacted"
    fi
  done
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

run() {
  # run OUTPUT_FILE COMMAND...
  out="$1"; shift
  {
    printf '\n$ %s\n' "$*"
    "$@" 2>&1
  } >> "$out"
}

run_sh() {
  # run_sh OUTPUT_FILE SHELL_COMMAND
  out="$1"; shift
  {
    printf '\n$ %s\n' "$*"
    /bin/sh -c "$*" 2>&1
  } >> "$out"
}

section() {
  printf '\n===== %s =====\n' "$*" >> "$out"
}

# ---------------------------------------------------------------------------
# snapshot
# ---------------------------------------------------------------------------

cmd_snapshot() {
  why="${1:-manual}"
  ts=$(date +%Y%m%d-%H%M%S)
  out="$BASE/snapshots/$ts-$why"
  mkdirp "$out/crashes" || { note "cannot create $out"; return 1; }

  note "snapshot -> $out"

  # --- identity and boot ---------------------------------------------------
  out="$out/00-meta.txt"; : > "$out"
  section "macOS"
  run "$out" sw_vers
  run "$out" uname -a
  run "$out" uptime
  run "$out" sysctl -n kern.boottime
  run "$out" sysctl -n vm.loadavg
  run "$out" date
  {
    printf '\n$ pmset -g log | tail -n 400\n'
    pmset -g log 2>&1 | tail -n 400
  } >> "$out"

  # --- CPU / memory --------------------------------------------------------
  old="$out"; out="$BASE/snapshots/$ts-$why/01-cpu.txt"; : > "$out"
  section "CPU and memory"
  run "$out" sysctl -n machdep.cpu.brand_string
  run "$out" sysctl -n hw.ncpu
  run "$out" sysctl -n hw.physicalcpu
  run "$out" sysctl -n hw.logicalcpu
  run "$out" sysctl -n machdep.cpu.core_count
  run "$out" sysctl -n machdep.cpu.thread_count
  run "$out" sysctl -n hw.memsize
  run "$out" sysctl -a
  # sysctl -a is large; drop the noisy non-CPU families
  grep -E '^(machdep\.cpu|hw\.|kern\.os|vm\.)' "$out" > "$out.tmp" 2>/dev/null || true
  [ -s "$out.tmp" ] && mv "$out.tmp" "$out"
  section "CPU name and topology (System Information vs kernel)"
  run_sh "$out" "system_profiler SPHardwareDataType | grep -E 'Processor Name|Total Number of Cores|Hyper-Threading'"
  run_sh "$out" "ioreg -lw0 -p IODeviceTree | grep -o '\"cpu-type\" = <[^>]*>' | head -n 1"
  run_sh "$out" "nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:ctrsmt 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:ctrfixcnt 2>&1"
  section "Top CPU processes"
  run "$out" top -l 1 -o cpu -n 30
  section "All processes by CPU"
  run "$out" ps -Ao pid,ppid,user,%cpu,%mem,etime,comm -r

  # --- kexts ---------------------------------------------------------------
  out="$BASE/snapshots/$ts-$why/02-kexts.txt"; : > "$out"
  section "Loaded kexts"
  run "$out" kmutil showloaded
  run "$out" kextstat
  section "Third-party graphics payloads"
  run "$out" ls -la /Library/Extensions
  run "$out" ls -la /Library/GPUBundles
  run "$out" sh -c 'ls -la /Library/GPUBundles/*/Contents/MacOS 2>&1'

  # --- GPU -----------------------------------------------------------------
  out="$BASE/snapshots/$ts-$why/03-gpu.txt"; : > "$out"
  section "Displays"
  run "$out" system_profiler SPDisplaysDataType
  section "IntelAccelerator"
  run "$out" ioreg -rc IntelAccelerator
  section "IOAccelerator"
  run "$out" ioreg -rc IOAccelerator
  section "Graphics device tree"
  run "$out" ioreg -lw0 -p IODeviceTree -n GFX0
  section "WhateverXe and guard keys"
  run_sh "$out" "ioreg -lw0 | grep -E 'TGLSequoiaMMIOGuard|TGLMMIO|WEX|WhateverXe|MetalPluginName|IOGLBundleName|IOAccelerator' | head -80"
  section "GPU statistics (IOReport)"
  run_sh "$out" "ioreg -rc IOAccelerator -d 1 | grep -E 'PerformanceStatistics|IOReportLegend|GPU|Busy|Utilization' | head -40"

  # --- display ------------------------------------------------------------
  out="$BASE/snapshots/$ts-$why/04-display.txt"; : > "$out"
  section "Display modes and current mode"
  run "$out" system_profiler SPDisplaysDataType
  run_sh "$out" "system_profiler SPDisplaysDataType | grep -E 'Resolution|UI Looks like|Metal|VRAM|Display Type|Connection Type|Online'"
  section "WindowServer preferences"
  run "$out" defaults read com.apple.windowserver
  section "Backlight and framebuffer"
  run "$out" ioreg -rc AppleBacklightDisplay
  run "$out" ioreg -rc AppleIntelFramebuffer
  run "$out" ioreg -rc IODisplay

  # --- power / battery ----------------------------------------------------
  out="$BASE/snapshots/$ts-$why/05-power.txt"; : > "$out"
  section "pmset"
  run "$out" pmset -g
  run "$out" pmset -g batt
  run "$out" pmset -g therm
  run "$out" pmset -g assertions
  section "Power history (tail)"
  run_sh "$out" "pmset -g log | tail -500"
  section "AppleSmartBattery"
  run_sh "$out" "ioreg -lw0 -r -c AppleSmartBattery | grep -E 'BatteryInstalled|MaxCapacity|DesignCapacity|CurrentCapacity|CycleCount|Temperature|TimeRemaining|ExternalConnected|IsCharging|FullyCharged|Voltage|Amperage'"
  section "XCPM / power management"
  run_sh "$out" "sysctl -a | grep -E 'machdep\\.xcpm|machdep\\.cpu\\.thermal|machdep\\.mwait' | head -40"

  # --- processes / network / audio ---------------------------------------
  out="$BASE/snapshots/$ts-$why/06-processes.txt"; : > "$out"
  section "Processes"
  run "$out" ps -Ao pid,ppid,user,%cpu,%mem,etime,state,comm
  section "Open files and ports (summary)"
  run_sh "$out" "lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | head -60"

  out="$BASE/snapshots/$ts-$why/07-network.txt"; : > "$out"
  section "Network"
  run "$out" ifconfig
  run "$out" networksetup -listallhardwareports
  run "$out" scutil --dns
  run "$out" netstat -rn
  run "$out" system_profiler SPNetworkDataType

  out="$BASE/snapshots/$ts-$why/08-audio.txt"; : > "$out"
  run "$out" system_profiler SPAudioDataType

  out="$BASE/snapshots/$ts-$why/09-usb.txt"; : > "$out"
  run "$out" system_profiler SPUSBDataType

  out="$BASE/snapshots/$ts-$why/10-bluetooth.txt"; : > "$out"
  run "$out" system_profiler SPBluetoothDataType

  # --- NVRAM (redacted) ---------------------------------------------------
  out="$BASE/snapshots/$ts-$why/11-nvram.txt"; : > "$out"
  section "NVRAM (identity redacted)"
  run_sh "$out" "nvram -p | awk -F '\\t' 'BEGIN{OFS=\"\\t\"} /^(IOPlatformSerialNumber|IOPlatformUUID|SystemSerialNumber|SystemUUID|MLB|ROM)[[:space:]]/{print \$1, \"<redacted>\"; next} {print}'"
  run "$out" nvram boot-args

  # --- unified log --------------------------------------------------------
  out="$BASE/snapshots/$ts-$why/12-logs-errors.txt"; : > "$out"
  section "Errors and faults, last 20 minutes"
  {
    printf '\n$ log show --last 20m --style compact --predicate "messageType == error OR messageType == fault"\n'
    "$LOG" show --last 20m --style compact \
      --predicate 'messageType == error OR messageType == fault' 2>&1
  } >> "$out"

  out="$BASE/snapshots/$ts-$why/13-logs-gpu.txt"; : > "$out"
  section "Metal, GPU, display, last 20 minutes"
  {
    printf '\n$ log show --last 20m --info --style compact --predicate <gpu>\n'
    "$LOG" show --last 20m --info --style compact --predicate '
      process == "MTLCompilerService" OR
      process == "WindowServer" OR
      process == "loginwindow" OR
      eventMessage CONTAINS[c] "Metal" OR
      eventMessage CONTAINS[c] "MTLLoader" OR
      eventMessage CONTAINS[c] "sliceIDForDevice" OR
      eventMessage CONTAINS[c] "GPU" OR
      eventMessage CONTAINS[c] "XeCompilerAdapter" OR
      eventMessage CONTAINS[c] "libigc" OR
      eventMessage CONTAINS[c] "IntelAccelerator" OR
      eventMessage CONTAINS[c] "WhateverXe" OR
      eventMessage CONTAINS[c] "DisplaysExt" OR
      eventMessage CONTAINS[c] "gpuRestart"
    ' 2>&1
  } >> "$out"

  out="$BASE/snapshots/$ts-$why/14-logs-apps.txt"; : > "$out"
  section "Settings, App Store, crashes, power, last 20 minutes"
  {
    printf '\n$ log show --last 20m --info --style compact --predicate <apps>\n'
    "$LOG" show --last 20m --info --style compact --predicate '
      process == "PowerPreferences" OR
      process == "powerd" OR
      process == "PowerUIAgent" OR
      process == "appstoreagent" OR
      process == "App Store" OR
      process == "ReportCrash" OR
      process == "spindump" OR
      process == "runningboardd" OR
      eventMessage CONTAINS[c] "PowerPreferences" OR
      eventMessage CONTAINS[c] "App Store" OR
      eventMessage CONTAINS[c] "gpuRestart" OR
      eventMessage CONTAINS[c] "Previous shutdown cause" OR
      eventMessage CONTAINS[c] "hang"
    ' 2>&1
  } >> "$out"

  out="$BASE/snapshots/$ts-$why/15-logs-sandbox.txt"; : > "$out"
  section "Sandbox denials, last 20 minutes"
  {
    printf '\n$ log show --last 20m --info --style compact --predicate <sandbox>\n'
    "$LOG" show --last 20m --info --style compact --predicate '
      eventMessage CONTAINS[c] "Sandbox:" AND
      (eventMessage CONTAINS[c] "deny" OR eventMessage CONTAINS[c] "violation")
    ' 2>&1
  } >> "$out"

  out="$BASE/snapshots/$ts-$why/16-logs-kernel.txt"; : > "$out"
  section "Kernel GPU / hang / reset, last 20 minutes"
  {
    printf '\n$ log show --last 20m --info --style compact --predicate <kernel>\n'
    "$LOG" show --last 20m --info --style compact --predicate '
      process == "kernel" AND
      (eventMessage CONTAINS[c] "GPU" OR
       eventMessage CONTAINS[c] "Metal" OR
       eventMessage CONTAINS[c] "hang" OR
       eventMessage CONTAINS[c] "reset" OR
       eventMessage CONTAINS[c] "watchdog" OR
       eventMessage CONTAINS[c] "panic")
    ' 2>&1
  } >> "$out"

  # --- crash reports ------------------------------------------------------
  out="$BASE/snapshots/$ts-$why/17-crashes.txt"; : > "$out"
  section "Crash, hang, spin and panic reports"
  run_sh "$out" "find \"$HOME/Library/Logs/DiagnosticReports\" /Library/Logs/DiagnosticReports -maxdepth 1 -type f -mtime -3 2>/dev/null | sort"
  run_sh "$out" "ls -lt \"$HOME/Library/Logs/DiagnosticReports\" /Library/Logs/DiagnosticReports 2>/dev/null | head -80"
  # copy the recent reports so a later cleanup does not lose them
  find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports \
    -maxdepth 1 -type f -mtime -3 2>/dev/null | while read -r f; do
      cp "$f" "$BASE/snapshots/$ts-$why/crashes/" 2>/dev/null || true
    done

  # --- Metal archive workaround -----------------------------------------
  out="$BASE/snapshots/$ts-$why/19-metal-env.txt"; : > "$out"
  section "Installed Metal workaround plists"
  run_sh "$out" 'ls -l "$HOME/Library/LaunchAgents" | grep -i "metal\|wex"'
  run_sh "$out" 'for f in "$HOME/Library/LaunchAgents/local.wex.metal-archive-workaround.plist" "$HOME/Library/LaunchAgents/metal-archive-workaround.plist"; do if [ -f "$f" ]; then echo "$f"; plutil -extract Label raw -o - "$f" 2>&1; fi; done'
  section "Agent state"
  run_sh "$out" 'launchctl print gui/$(id -u)/local.wex.metal-archive-workaround 2>&1 | head -30'
  section "GUI-domain environment"
  run_sh "$out" 'launchctl print gui/$(id -u) 2>/dev/null | sed -n "/environment = {/,/}/p"'
  section "getenv values"
  run_sh "$out" 'for k in RB_USE_BINARY_ARCHIVE MTL_DEBUG_IGNORE_PRECOMPILED_BINARIES MTL_DEBUG_IGNORE_PSO_FAIL_ON_MISS; do printf "%s=" "$k"; launchctl getenv "$k" 2>/dev/null || echo "<unset>"; done'

  # --- optional: root-only measurements ----------------------------------
  out="$BASE/snapshots/$ts-$why/18-powermetrics.txt"; : > "$out"
  if [ "$(id -u)" = "0" ]; then
    section "powermetrics (root)"
    run "$out" powermetrics --samplers smc,cpu_power,gpu_power -n 1 -i 1000
  elif sudo -n true 2>/dev/null; then
    section "powermetrics (passwordless sudo)"
    run_sh "$out" "sudo -n powermetrics --samplers smc,cpu_power,gpu_power -n 1 -i 1000"
  else
    section "powermetrics skipped (needs root; run with sudo for GPU power/utilisation)"
  fi

  # --- optional log archive ----------------------------------------------
  if [ "${OPENMAC_DIAG_ARCHIVE:-0}" = "1" ] || [ "$why" = "crash" ]; then
    cmd_archive "snapshot-$ts" || true
  fi

  redact_tree "$BASE/snapshots/$ts-$why"

  prune "$BASE/snapshots" "$KEEP_SNAPSHOTS"
  note "snapshot done: $BASE/snapshots/$ts-$why"
}

# ---------------------------------------------------------------------------
# archive
# ---------------------------------------------------------------------------

cmd_archive() {
  why="${1:-hourly}"
  mkdirp "$BASE/archives" || return 1
  ts=$(date +%Y%m%d-%H%M%S)

  # `log collect` needs root; the per-user agent cannot use it. Fall back to a
  # compact error/fault extract so the hourly agent still records something.
  if [ "$(id -u)" = "0" ]; then
    dest="$BASE/archives/${ts}-${why}.logarchive"
    note "collecting $ARCHIVE_WINDOW of unified log -> $dest"
    if "$LOG" collect --last "$ARCHIVE_WINDOW" --output "$dest" 2>>"$BASE/archives/collect.log"; then
      prune "$BASE/archives" "$KEEP_ARCHIVES"
      note "archive done: $dest"
    else
      note "log collect failed; see $BASE/archives/collect.log"
      rmdir "$dest" 2>/dev/null || true
    fi
    return 0
  fi

  dest="$BASE/archives/${ts}-${why}-errors.log"
  note "not root: saving $ARCHIVE_WINDOW of errors/faults -> $dest"
  {
    printf '$ log show --last %s --style compact --predicate "messageType == error OR messageType == fault"\n' "$ARCHIVE_WINDOW"
    "$LOG" show --last "$ARCHIVE_WINDOW" --style compact \
      --predicate 'messageType == error OR messageType == fault' 2>&1
  } > "$dest"
  redact < "$dest" > "$dest.tmp" 2>/dev/null && mv "$dest.tmp" "$dest"
  if [ -s "$dest" ]; then
    prune "$BASE/archives" "$KEEP_ARCHIVES"
    note "archive done: $dest ($(wc -l < "$dest" | tr -d ' ') lines)"
  else
    note "archive produced no output"
    rm -f "$dest"
  fi
}

# ---------------------------------------------------------------------------
# monitor (60s samples)
# ---------------------------------------------------------------------------

metrics_line() {
  now=$(date '+%Y-%m-%dT%H:%M:%S%z')
  up=$(uptime | sed 's/^ *//')
  load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | sed 's/^ *//')
  cpu=$(top -l 1 -n 0 2>/dev/null | awk -F'[:,]' '/CPU usage/ {print $2 " user, " $3 " sys, " $4 " idle"; exit}')
  mem=$(top -l 1 -n 0 2>/dev/null | awk '/PhysMem/ {print; exit}')
  top3=$(ps -Ao %cpu,comm -r 2>/dev/null | sed -n '2,4p' | tr '\n' ';' | sed 's/;/; /g')
  gpu=$(ioreg -rc IOAccelerator -d 1 2>/dev/null | grep -m1 -E 'PerformanceStatistics|GPU Busy|Device Utilization' | cut -c1-300)
  therm=$(pmset -g therm 2>/dev/null | tr '\n' ' ' | cut -c1-240)
  batt=$(pmset -g batt 2>/dev/null | tail -1 | tr -d '\n')
  mtl=$(pgrep -x MTLCompilerService 2>/dev/null | wc -l | tr -d ' ')
  pp=$(pgrep -x PowerPreferences 2>/dev/null | wc -l | tr -d ' ')
  printf '%s | up=%s | load=%s | cpu=%s | mem=%s | top=%s | gpu=%s | therm=%s | batt=%s | mtl=%s | powerprefs=%s\n' \
    "$now" "$up" "$load" "$cpu" "$mem" "$top3" "$gpu" "$therm" "$batt" "$mtl" "$pp"
}

cmd_monitor() {
  mkdirp "$BASE/live" || return 1
  mon="$BASE/live/monitor.log"
  note "monitor started (60s samples)"
  while :; do
    metrics_line >> "$mon"
    rotate_log "$mon" "$MAX_MONITOR_MB"
    sleep 60
  done
}

# ---------------------------------------------------------------------------
# stream (filtered unified log)
# ---------------------------------------------------------------------------

STREAM_PREDICATE='
  process == "MTLCompilerService" OR
  process == "PowerPreferences" OR
  process == "appstoreagent" OR
  process == "App Store" OR
  process == "ReportCrash" OR
  process == "spindump" OR
  process == "WindowServer" OR
  subsystem == "com.apple.Metal" OR
  eventMessage CONTAINS[c] "MTLLoader" OR
  eventMessage CONTAINS[c] "sliceIDForDevice" OR
  eventMessage CONTAINS[c] "XeCompilerAdapter" OR
  eventMessage CONTAINS[c] "libigc" OR
  eventMessage CONTAINS[c] "PowerPreferences" OR
  eventMessage CONTAINS[c] "App Store" OR
  eventMessage CONTAINS[c] "gpuRestart" OR
  eventMessage CONTAINS[c] "GPU Restart" OR
  (process == "kernel" AND
    (eventMessage CONTAINS[c] "GPU" OR
     eventMessage CONTAINS[c] "hang" OR
     eventMessage CONTAINS[c] "reset" OR
     eventMessage CONTAINS[c] "panic"))
'

cmd_stream() {
  mkdirp "$BASE/live" || return 1
  live="$BASE/live/events.log"
  note "stream started -> $live"
  sp=""
  watchdog=""
  # Make sure a terminated agent does not leave `log stream` (or the watchdog)
  # running after launchd unloads it.
  trap 'kill "$sp" "$watchdog" 2>/dev/null; exit 0' INT TERM
  while :; do
    "$LOG" stream --style compact --level info --predicate "$STREAM_PREDICATE" >> "$live" 2>&1 &
    sp=$!
    # Restart hourly so rotate_log can run. The watchdog enforces that even if
    # `log stream` never exits on its own.
    ( sleep 3600; kill "$sp" 2>/dev/null || true ) &
    watchdog=$!
    wait "$sp" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    rotate_log "$live" "$MAX_LIVE_MB"
  done
}

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

cmd_report() {
  target="${1:-}"
  ts=$(date +%Y%m%d-%H%M%S)
  mkdirp "$BASE/reports" || return 1
  latest=$(ls -1dt "$BASE/snapshots"/* 2>/dev/null | head -1)
  if [ -z "${latest:-}" ]; then
    note "no snapshot yet; taking one now"
    cmd_snapshot report
    latest=$(ls -1dt "$BASE/snapshots"/* 2>/dev/null | head -1)
  fi
  [ -n "${latest:-}" ] || { note "cannot find a snapshot"; return 1; }

  bundle="$BASE/reports/openmac-diag-$ts.tar.gz"
  note "bundling $latest and live data -> $bundle"
  set -- "snapshots/$(basename "$latest")"
  [ -d "$BASE/live" ] && set -- "$@" live
  tar -czf "$bundle" -C "$BASE" "$@" 2>/dev/null || {
    note "tar failed"
    return 1
  }
  cp "$bundle" "$BASE/reports/latest.tar.gz" 2>/dev/null || true

  if [ -n "$target" ]; then
    mkdirp "$(dirname "$target")"
    cp "$bundle" "$target" && say "wrote $target"
  elif [ -d /Volumes/MACUSB ] && [ -w /Volumes/MACUSB ]; then
    cp "$bundle" "/Volumes/MACUSB/$(basename "$bundle")" && \
      say "wrote /Volumes/MACUSB/$(basename "$bundle")"
  else
    cp "$bundle" "$HOME/Desktop/$(basename "$bundle")" 2>/dev/null && \
      say "wrote $HOME/Desktop/$(basename "$bundle")"
  fi
  say "bundle: $bundle"
}

# ---------------------------------------------------------------------------
# install / uninstall / status
# ---------------------------------------------------------------------------

write_agent() {
  # write_agent LABEL MODE VALUE [COMMAND_ARGS...]
  #   interval N  run at login and every N seconds
  #   keepalive   run at login and restart if it exits
  #   watch PATH  run when PATH changes (new crash reports)
  label="$1"; mode="$2"; value="${3:-}"; shift 3
  plist="$AGENT_DIR/$label.plist"
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Background</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml_escape "$SELF")</string>
EOF
    for arg in "$@"; do
      printf '    <string>%s</string>\n' "$(xml_escape "$arg")"
    done
    cat <<EOF
  </array>
  <key>StandardOutPath</key><string>$(xml_escape "$BASE/launchd-$label.log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$BASE/launchd-$label.log")</string>
EOF
    case "$mode" in
      interval)
        cat <<EOF
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>$value</integer>
EOF
        ;;
      keepalive)
        cat <<EOF
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
EOF
        ;;
      watch)
        cat <<EOF
  <key>RunAtLoad</key><false/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>WatchPaths</key>
  <array>
    <string>$(xml_escape "$value")</string>
  </array>
EOF
        ;;
    esac
    cat <<EOF
</dict>
</plist>
EOF
  } > "$plist"
  plutil -lint "$plist" >/dev/null 2>&1 || note "warning: $plist did not pass plutil -lint"
}

bootstrap_agent() {
  label="$1"
  plist="$AGENT_DIR/$label.plist"
  launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || {
    note "could not bootstrap $label; run: launchctl bootstrap gui/$(id -u) $plist"
  }
}

cmd_install() {
  mkdirp "$APP_DIR" "$AGENT_DIR" "$BASE" || return 1
  cp "$0" "$SELF" || { note "cannot install $SELF"; return 1; }
  chmod 755 "$SELF"

  # 1. Snapshot every 15 minutes and at login.
  write_agent "$LABEL.snapshot" interval "$SNAPSHOT_INTERVAL" snapshot periodic

  # 2. 60-second metrics.
  write_agent "$LABEL.monitor" keepalive "" monitor

  # 3. Filtered live unified-log stream.
  write_agent "$LABEL.stream" keepalive "" stream

  # 4. Hourly error/fault archive (or a full .logarchive when run as root).
  write_agent "$LABEL.archive" interval "$ARCHIVE_INTERVAL" archive hourly

  # 5. Snapshot when a new crash report appears.
  write_agent "$LABEL.crashwatch" watch \
    "$HOME/Library/Logs/DiagnosticReports" snapshot crash

  for l in $AGENTS; do
    bootstrap_agent "$LABEL.$l"
  done

  say "installed $SELF"
  say "data:    $BASE"
  say "agents:  $AGENT_DIR/$LABEL.*.plist"
  say "status:  $SELF status"
}

cmd_uninstall() {
  for l in $AGENTS; do
    launchctl bootout "gui/$(id -u)" "$AGENT_DIR/$LABEL.$l.plist" >/dev/null 2>&1 || true
    rm -f "$AGENT_DIR/$LABEL.$l.plist"
  done
  say "agents removed; collected data kept in $BASE"
  say "remove it with: rm -rf \"$BASE\" \"$APP_DIR\""
}

cmd_status() {
  say "openmac-diag $VERSION"
  say "script:  $SELF"
  say "data:    $BASE"
  say ""
  for l in $AGENTS; do
    printf '%-28s ' "$LABEL.$l"
    if launchctl print "gui/$(id -u)/$LABEL.$l" >/dev/null 2>&1; then
      echo "loaded"
    else
      echo "not loaded"
    fi
  done
  say ""
  if [ -d "$BASE" ]; then
    say "storage:"
    du -sh "$BASE" 2>/dev/null | sed 's/^/  /'
    for d in snapshots archives live reports; do
      [ -d "$BASE/$d" ] && printf '  %-10s %s item(s)\n' "$d" "$(ls -1 "$BASE/$d" 2>/dev/null | wc -l | tr -d ' ')"
    done
    say ""
    say "latest snapshot:"
    ls -1dt "$BASE/snapshots"/* 2>/dev/null | head -1 | sed 's/^/  /'
    say "latest archive:"
    ls -1dt "$BASE/archives"/*.logarchive 2>/dev/null | head -1 | sed 's/^/  /'
  else
    say "no data collected yet"
  fi
}

cmd_selftest() {
  missing=0
  for c in sw_vers uname sysctl top ps pmset ioreg system_profiler kmutil kextstat \
           defaults ifconfig networksetup scutil netstat lsof find tar gzip pgrep; do
    if have "$c"; then
      printf 'ok    %s\n' "$c"
    else
      printf 'MISS  %s\n' "$c"; missing=$((missing + 1))
    fi
  done
  if [ -x "$LOG" ] || have log; then printf 'ok    log\n'; else printf 'MISS  log\n'; missing=$((missing + 1)); fi
  say ""
  [ "$missing" -eq 0 ] && say "all required tools present" || say "$missing tool(s) missing"
}

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  snapshot)  shift; cmd_snapshot "${1:-manual}" ;;
  archive)   shift; cmd_archive "${1:-manual}" ;;
  report)    shift; cmd_report "${1:-}" ;;
  monitor)   cmd_monitor ;;
  stream)    cmd_stream ;;
  selftest)  cmd_selftest ;;
  version)   say "$VERSION" ;;
  help|-h|--help|"") usage ;;
  *) note "unknown command: $1"; usage; exit 2 ;;
esac
