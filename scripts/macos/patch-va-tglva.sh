#!/bin/bash
#
# patch-va-tglva.sh - make WhateverXe's VA (video decode) compatibility shim
# accept macOS 15.6+ instead of only the exact build 24H32.
#
# Why this exists
# ---------------
# WhateverXe Graphics installs its own shim next to Apple's TGL VA driver:
#
#   /Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle/Contents/MacOS/
#       TGLVA
#       AppleIntelTGLGraphicsVADriver
#
# TGLVA hooks the VA driver's HEVC/H.264 decode path.  The 0.3.1 build gates
# that hook on the exact build string:
#
#   ProductBuildVersion == "24H32"
#
# On 24H232 (Sequoia 15.8.2) the guard fails and VTDecoderXPCService aborts:
#
#   TGLVA adapter fatal: SPS OS/donor ABI guard
#
# launchd then marks com.apple.coremedia.videodecoder inactive, and every
# caller that synchronously waits for a decode hangs - App Store screenshots
# and previews (HEIC), the dynamic wallpaper, Quick Look, and video
# conferencing.  The App Store does not crash; the main thread waits forever
# in VTTileDecompressionSessionCopyProperty.
#
# Graphics 0.4.0 rebuilds TGLVA with an OS-family guard keyed on
# kern.osrelease (24.6.0 here).  Its AppleIntelTGLGraphicsVADriver differs
# only in the PCI device-ID dispatch table; the rest of the code is
# byte-identical, so replacing only TGLVA is enough on this machine.
#
# Verified 2026-11-05: after installing this shim, `sips` decoded a HEIC
# thumbnail in under a second and no TGLVA fatal was logged, where the 0.3.1
# shim hung indefinitely.
#
# Usage:
#   sudo bash patch-va-tglva.sh                 install (downloads v0.4.0)
#   sudo bash patch-va-tglva.sh --test          install, then decode a HEIC
#   sudo bash patch-va-tglva.sh --from FILE     install a local copy
#   sudo bash patch-va-tglva.sh --rollback      restore the newest backup
#   bash patch-va-tglva.sh --status             show the current state
#   bash patch-va-tglva.sh --dry-run            print what would happen
#
# Options:
#   --no-restart   do not restart the decode services afterwards
#   --force        allow replacing an unknown TGLVA
#   --backup DIR   backup to restore with --rollback
#
# The original bundle is copied to
#   /Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle.backup-<stamp>
# and is never deleted by this script.  Reinstalling WhateverXe Graphics will
# overwrite the patch; run the script again afterwards.

set -u

BUNDLE=/Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle
SHIM="$BUNDLE/Contents/MacOS/TGLVA"
OLD_SHA=0c4df393547ba1bdb9bb2a4827355a6216c44d0c5ac14af13269d9a80e6e35ac
NEW_SHA=db879dbae1c708b5fcdb3c39e251e63e635016d19885e9186fdc6baca68414aa
NEW_URL="https://raw.githubusercontent.com/b00t0x/WhateverXe-Graphics/v0.4.0/payloads/Sequoia/Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle/Contents/MacOS/TGLVA"
STAMP=$(date +%Y%m%d-%H%M%S)

ACTION=install
SRC=
BACKUP=
DO_RESTART=1
DO_TEST=0
FORCE=0
DRY_RUN=0

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --install)    ACTION=install ;;
    --rollback)   ACTION=rollback ;;
    --status|--check) ACTION=status ;;
    --test)       DO_TEST=1 ;;
    --from)       shift; SRC=${1:-}; [ -n "$SRC" ] || die "--from needs a path" ;;
    --backup)     shift; BACKUP=${1:-}; [ -n "$BACKUP" ] || die "--backup needs a path" ;;
    --no-restart) DO_RESTART=0 ;;
    --force)      FORCE=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

sha_of() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}'; }

current_state() {
  cur=$(sha_of "$SHIM")
  case "$cur" in
    "$OLD_SHA") echo "0.3.1 (guard requires build 24H32)" ;;
    "$NEW_SHA") echo "0.4.0 (OS-family guard, works on 24.6.0+)" ;;
    "")         echo "missing" ;;
    *)          echo "unknown ($cur)" ;;
  esac
}

console_user() {
  u=$(stat -f %Su /dev/console 2>/dev/null || true)
  [ "$u" = "root" ] && u=${SUDO_USER:-}
  printf '%s' "$u"
}

restart_decode() {
  [ "$DO_RESTART" = "1" ] || return 0
  u=$(console_user)
  if [ -z "$u" ] || [ "$u" = "root" ] || ! id "$u" >/dev/null 2>&1; then
    note "no console user; skipping decode-service restart"
    return 0
  fi
  note "restarting VTDecoderXPCService / WallpaperVideoExtension / avconferenced"
  pkill -u "$u" -x VTDecoderXPCService 2>/dev/null || true
  pkill -u "$u" -x WallpaperVideoExtension 2>/dev/null || true
  pkill -u "$u" -x avconferenced 2>/dev/null || true
  sleep 2
}

run_test() {
  [ "$DO_TEST" = "1" ] || return 0
  u=$(console_user)
  [ -n "$u" ] && [ "$u" != "root" ] || { warn "--test needs a logged-in desktop"; return 0; }
  uid=$(id -u "$u")

  heic=""
  for f in "/System/Library/Desktop Pictures/.thumbnails/Valley Light.heic" \
           /System/Library/Desktop\ Pictures/.thumbnails/*.heic; do
    [ -f "$f" ] && { heic="$f"; break; }
  done
  if [ -z "$heic" ]; then
    warn "no HEIC sample found; skipping decode test"
    return 0
  fi

  out="${TMPDIR:-/tmp}/tglva-test-$$.png"
  rm -f "$out"
  mark=$(date "+%Y-%m-%d %H:%M:%S")
  say ""
  say "Log window starts at $mark"
  say "Decoding $(basename "$heic") (15 s timeout)"

  launchctl asuser "$uid" /usr/bin/sips -s format png "$heic" --out "$out" \
    >/tmp/tglva-sips.$$.log 2>&1 &
  pid=$!
  for _ in $(seq 1 15); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    say "  RESULT: HUNG (sips did not finish in 15 s)"
    decoded=0
  else
    wait "$pid"
    rc=$?
    if [ -s "$out" ]; then
      say "  RESULT: decoded OK (exit $rc, $(stat -f%z "$out") bytes)"
      decoded=1
    else
      say "  RESULT: exited $rc but produced no file"
      decoded=0
    fi
  fi
  rm -f "$out" "/tmp/tglva-sips.$$.log"

  say ""
  say "=== TGLVA / decoder log since $mark ==="
  /usr/bin/log show --start "$mark" --style compact --predicate \
    'process CONTAINS[c] "VTDecoder" OR process == "avconferenced" OR eventMessage CONTAINS[c] "TGLVA" OR eventMessage CONTAINS[c] "videodecoder"' \
    2>&1 | grep -iE 'TGLVA|fatal|service inactive|SPS|videodecoder' | tail -25

  say ""
  if /usr/bin/log show --start "$mark" --style compact --predicate \
       'eventMessage CONTAINS "TGLVA adapter fatal"' 2>/dev/null \
       | grep -q 'TGLVA adapter fatal'; then
    say "VERDICT: FAILED - TGLVA is still aborting."
  elif [ "$decoded" = "1" ]; then
    say "VERDICT: PASS - the HEIC decoded and no TGLVA fatal was logged."
  else
    say "VERDICT: inconclusive - no fatal, but the HEIC did not decode."
  fi
}

# --- status ---------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
  say "Bundle : $BUNDLE"
  say "Shim   : $(current_state)"
  say "macOS  : $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
  say "Darwin : $(uname -r)"
  backups=$(ls -dt "$BUNDLE".backup-* 2>/dev/null || true)
  if [ -n "$backups" ]; then
    say "Backups:"
    printf '%s\n' "$backups" | sed 's/^/  /'
  else
    say "Backups: none"
  fi
  exit 0
fi

# --- dry run --------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  say "Dry run: $ACTION"
  say "  bundle: $BUNDLE"
  say "  current shim: $(current_state)"
  if [ "$ACTION" = "install" ]; then
    say "  source: ${SRC:-$NEW_URL}"
    say "  expected sha256: $NEW_SHA"
    say "  backup: $BUNDLE.backup-$STAMP"
    say "  restart decode services: $DO_RESTART"
    say "  run HEIC test: $DO_TEST"
  else
    say "  backup: ${BACKUP:-newest $BUNDLE.backup-*}"
    say "  restart decode services: $DO_RESTART"
  fi
  exit 0
fi

# An already-patched install is a no-op, so report it before asking for root.
if [ "$ACTION" = "install" ] && [ "$(sha_of "$SHIM")" = "$NEW_SHA" ] && [ "$FORCE" != "1" ]; then
  say "Current shim: $(current_state)"
  say "Already patched; nothing to do."
  run_test
  exit 0
fi

[ "$(id -u)" = "0" ] || die "run with sudo for --install or --rollback"

# --- rollback -------------------------------------------------------------
if [ "$ACTION" = "rollback" ]; then
  [ -n "$BACKUP" ] || BACKUP=$(ls -dt "$BUNDLE".backup-* 2>/dev/null | head -1)
  [ -n "$BACKUP" ] && [ -d "$BACKUP" ] || die "no backup found"
  [ -f "$BACKUP/Contents/MacOS/TGLVA" ] || die "$BACKUP is not a VA bundle backup"
  say "Rolling back from $BACKUP"
  restart_decode
  rm -rf "$BUNDLE" || die "cannot remove $BUNDLE"
  mv "$BACKUP" "$BUNDLE" || die "cannot restore $BUNDLE"
  got=$(sha_of "$SHIM")
  if [ "$got" = "$OLD_SHA" ]; then
    note "restored 0.3.1 TGLVA"
  else
    warn "restored shim has unexpected hash: $got"
  fi
  say "Rollback done. HEIC/HEVC hardware decode will hang again on 24H232."
  exit 0
fi

# --- install --------------------------------------------------------------
cur=$(sha_of "$SHIM")
say "Current shim: $(current_state)"
if [ "$cur" != "$OLD_SHA" ] && [ "$cur" != "$NEW_SHA" ] && [ "$FORCE" != "1" ]; then
  die "unrecognised TGLVA ($cur); rerun with --force only if you have a backup"
fi

if [ -z "$SRC" ]; then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/tglva.XXXXXX") || die "mktemp failed"
  trap 'rm -rf "$tmp"' EXIT
  say "Downloading WhateverXe Graphics 0.4.0 TGLVA"
  curl -fL --retry 3 -o "$tmp/TGLVA" "$NEW_URL" \
    || die "download failed; use --from /path/to/TGLVA"
  SRC="$tmp/TGLVA"
fi
got=$(sha_of "$SRC")
[ "$got" = "$NEW_SHA" ] || die "source hash mismatch: $got (expected $NEW_SHA)"

BACKUP="$BUNDLE.backup-$STAMP"
say "Backing up the VA driver bundle"
cp -a "$BUNDLE" "$BACKUP" || die "backup failed"
note "$BACKUP"

say "Installing the 0.4.0 TGLVA"
install -m 0644 -o root -g wheel "$SRC" "$SHIM" || die "install failed"
shasum -a 256 "$SHIM" | sed 's/^/  /'

if codesign --verify "$SHIM" >/dev/null 2>&1; then
  note "shim signature valid"
else
  warn "shim signature does not verify"
fi
if codesign --verify --strict "$BUNDLE" >/dev/null 2>&1; then
  note "bundle signature valid"
else
  warn "bundle seal no longer matches; keep the backup"
fi

restart_decode
run_test

say ""
say "Patched. Reboot once when convenient and decode a HEIC or open the App Store."
say "Rollback at any time with:"
say "  sudo bash $0 --rollback"
