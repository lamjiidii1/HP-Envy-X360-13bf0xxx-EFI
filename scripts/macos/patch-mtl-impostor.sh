#!/bin/bash
#
# patch-mtl-impostor.sh - make the WhateverXe Metal binary-archive
# compatibility hook actually install on macOS 15.6+ (24.6.0 or later).
#
# Why this exists
# ---------------
# WhateverXe Graphics 0.3.1 ships two userspace shims next to Apple's TGL
# Metal driver:
#
#   /Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle/Contents/MacOS/
#       impostor.dylib
#       descriptor.dylib
#
# impostor.dylib hooks -[MTLDevice newBinaryArchiveWithDescriptor:error:] and,
# for the legacy Intel driver, returns a normal NSError instead of letting
# MTLLoader assert.  But the 0.3.1 build enables that hook only when
#
#   kern.osversion == "24H32"
#
# On 24H232 (Sequoia 15.8.2) the hook is skipped, so any app that loads a
# precompiled Metal archive dies in:
#
#   +[MTLLoader sliceIDForDevice:legacyDriverVersion:airntDriverVersion:]:685:
#     failed assertion `Target device architecture is nil'
#
# Graphics 0.4.0 ships a new impostor.dylib that enables the same hook on
# kern.osrelease 24.6.0+ (and 25.x).  Its descriptor.dylib and libigdmd.dylib
# are byte-identical to 0.3.1, so only impostor.dylib needs replacing.
#
# Result on this machine (2026-11-04): System Settings > Battery opens and
# ControlCenter stops crash-looping.  No EFI or kernel change is involved.
#
# Usage:
#   sudo bash patch-mtl-impostor.sh                 install (downloads v0.4.0)
#   sudo bash patch-mtl-impostor.sh --test          install, then open Battery
#   sudo bash patch-mtl-impostor.sh --from FILE     install a local copy
#   sudo bash patch-mtl-impostor.sh --rollback      restore the newest backup
#   bash patch-mtl-impostor.sh --status             show the current state
#   bash patch-mtl-impostor.sh --dry-run            print what would happen
#
# Options:
#   --no-restart   do not kill System Settings / ControlCenter afterwards
#   --force        allow replacing an unknown impostor.dylib
#   --backup DIR   backup to restore with --rollback
#
# The original bundle is copied to
#   /Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle.backup-<stamp>
# and is never deleted by this script.  Reinstalling WhateverXe Graphics will
# overwrite the patch; run the script again afterwards.

set -u

BUNDLE=/Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle
SHIM="$BUNDLE/Contents/MacOS/impostor.dylib"
OLD_SHA=53c93a6eaae5a0c80a26b4a9b1500b09b62c88c52c7b40e47c81ad2c255fb57b
NEW_SHA=1cc38c7941333d3f4b88316795c78ca0095addf945fa35b6ff8634ecc93a1060
NEW_URL="https://raw.githubusercontent.com/b00t0x/WhateverXe-Graphics/v0.4.0/payloads/Sequoia/Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle/Contents/MacOS/impostor.dylib"
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

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; }

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
    "$OLD_SHA") echo "0.3.1 (hook disabled on this build)" ;;
    "$NEW_SHA") echo "0.4.0 (hook enabled on 24.6.0+)" ;;
    "")         echo "missing" ;;
    *)          echo "unknown ($cur)" ;;
  esac
}

console_user() {
  u=$(stat -f %Su /dev/console 2>/dev/null || true)
  [ "$u" = "root" ] && u=${SUDO_USER:-}
  printf '%s' "$u"
}

restart_gui() {
  [ "$DO_RESTART" = "1" ] || return 0
  u=$(console_user)
  if [ -z "$u" ] || [ "$u" = "root" ] || ! id "$u" >/dev/null 2>&1; then
    note "no console user; skipping GUI restart"
    return 0
  fi
  uid=$(id -u "$u")
  note "clearing Metal caches for $u"
  rm -rf "/Users/$u/Library/Caches/com.apple.Metal" 2>/dev/null || true
  cache=$(launchctl asuser "$uid" getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)
  [ -n "$cache" ] && rm -rf "${cache}com.apple.Metal" 2>/dev/null || true
  note "restarting System Settings and ControlCenter"
  pkill -u "$uid" -x "System Settings" 2>/dev/null || true
  pkill -u "$uid" -x ControlCenter 2>/dev/null || true
}

run_test() {
  [ "$DO_TEST" = "1" ] || return 0
  u=$(console_user)
  [ -n "$u" ] && [ "$u" != "root" ] || { warn "--test needs a logged-in desktop"; return 0; }
  uid=$(id -u "$u")
  say ""
  say "Opening System Settings > Battery"
  launchctl asuser "$uid" /usr/bin/open \
    "x-apple.systempreferences:com.apple.Battery-Settings.extension" 2>/dev/null || true
  sleep 8
  say ""
  say "=== PowerPreferences / MTLLoader, last 2 minutes ==="
  /usr/bin/log show --last 2m --style compact --predicate \
    'process == "PowerPreferences" OR composedMessage CONTAINS "sliceIDForDevice" OR composedMessage CONTAINS "target architecture" OR composedMessage CONTAINS "binary archive"' \
    2>&1 | tail -40
  say ""
  if /usr/bin/log show --last 2m --style compact --predicate \
       'composedMessage CONTAINS "Target device architecture is nil"' \
       2>/dev/null | grep -q 'Target device architecture is nil'; then
    say "VERDICT: still crashing (the shim did not take effect)."
  else
    say "VERDICT: no MTLLoader assertion in the last 2 minutes."
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
    say "  restart GUI: $DO_RESTART"
    say "  open Battery test: $DO_TEST"
  else
    say "  backup: ${BACKUP:-newest $BUNDLE.backup-*}"
    say "  restart GUI: $DO_RESTART"
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
  [ -f "$BACKUP/Contents/MacOS/impostor.dylib" ] || die "$BACKUP is not a driver bundle backup"
  say "Rolling back from $BACKUP"
  restart_gui
  rm -rf "$BUNDLE" || die "cannot remove $BUNDLE"
  mv "$BACKUP" "$BUNDLE" || die "cannot restore $BUNDLE"
  got=$(sha_of "$SHIM")
  if [ "$got" = "$OLD_SHA" ]; then
    note "restored 0.3.1 impostor"
  else
    warn "restored shim has unexpected hash: $got"
  fi
  say "Rollback done. The Battery pane will crash again on 24H232."
  exit 0
fi

# --- install --------------------------------------------------------------
cur=$(sha_of "$SHIM")
say "Current shim: $(current_state)"
if [ "$cur" != "$OLD_SHA" ] && [ "$cur" != "$NEW_SHA" ] && [ "$FORCE" != "1" ]; then
  die "unrecognised impostor.dylib ($cur); rerun with --force only if you have a backup"
fi

if [ -z "$SRC" ]; then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/impostor.XXXXXX") || die "mktemp failed"
  trap 'rm -rf "$tmp"' EXIT
  say "Downloading WhateverXe Graphics 0.4.0 impostor.dylib"
  curl -fL --retry 3 -o "$tmp/impostor.dylib" "$NEW_URL" \
    || die "download failed; use --from /path/to/impostor.dylib"
  SRC="$tmp/impostor.dylib"
fi
got=$(sha_of "$SRC")
[ "$got" = "$NEW_SHA" ] || die "source hash mismatch: $got (expected $NEW_SHA)"

BACKUP="$BUNDLE.backup-$STAMP"
say "Backing up the driver bundle"
cp -a "$BUNDLE" "$BACKUP" || die "backup failed"
note "$BACKUP"

say "Installing the 0.4.0 impostor.dylib"
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
  warn "bundle seal no longer matches; it may still load, but keep the backup"
fi

restart_gui
run_test

say ""
say "Patched. Reboot once when convenient and reopen Battery to prove it survives."
say "Rollback at any time with:"
say "  sudo bash $0 --rollback"
