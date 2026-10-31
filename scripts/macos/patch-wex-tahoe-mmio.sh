#!/bin/zsh
#
# patch-wex-tahoe-mmio.sh - repair WhateverXe's Tahoe MMIO-UC signature check.
#
# WhateverXe 0.6.0/0.6.1 (adlp-edp branch) validates the kernel function
# _IOProtectCacheMode by comparing five bytes at +0xCC with a hard-coded
# "call rel32" (E8 2F F3 02 00).  macOS 26.7.2 (25G332) moved that call, so
# the check fails, tglMMIOUCRouted stays false, tglActive stays false and the
# accelerator probe is rejected (19 MB VRAM, "No Kext Loaded").
#
# This script reads the real bytes from the kernel Mach-O on this Mac and
# replaces the stale constant in the injected WhateverXe binary.  It does not
# install anything, does not touch the kernel, and keeps a .orig backup.
#
# Usage:
#   sudo ./patch-wex-tahoe-mmio.sh --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext
#   sudo ./patch-wex-tahoe-mmio.sh --kext ... --dry-run
#   sudo ./patch-wex-tahoe-mmio.sh --kext ... --restore
#
# Exit codes: 0 patched/already correct, 2 cannot locate kernel/symbol,
#             3 unexpected bytes, 4 binary not found or ambiguous.

set -euo pipefail

OLD_CONST="e82ff30200"
PROLOGUE="554889e54157415641554154534883ec28"
REL_OFFSET=$((0xCC))

KEXT=""
KERNEL=""
DRY_RUN=0
RESTORE=0

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while (( $# )); do
  case "$1" in
    --kext)    KEXT="${2:-}"; shift 2 ;;
    --kernel)  KERNEL="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --restore) RESTORE=1; shift ;;
    -h|--help) usage ;;
    *) print -u2 "error: unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "$KEXT" ]]; then
  print -u2 "error: --kext /path/to/WhateverXe.kext is required"
  exit 1
fi

BIN="$KEXT/Contents/MacOS/WhateverXe"
if [[ ! -f "$BIN" ]]; then
  print -u2 "error: not a WhateverXe bundle: $KEXT"
  exit 4
fi

if (( RESTORE )); then
  if [[ ! -f "$BIN.orig" ]]; then
    print -u2 "error: no backup at $BIN.orig"
    exit 4
  fi
  cp -p "$BIN.orig" "$BIN"
  print "restored $BIN from $BIN.orig"
  exit 0
fi

find_kernel() {
  local candidate
  for candidate in \
    /System/Library/Kernels/kernel \
    /System/Volumes/Preboot/Cryptexes/OS/System/Library/Kernels/kernel \
    /Library/Developer/KDKs/*/System/Library/Kernels/kernel
  do
    [[ -f "$candidate" ]] && { print -r -- "$candidate"; return 0; }
  done
  return 1
}

if [[ -z "$KERNEL" ]]; then
  KERNEL="$(find_kernel)" || {
    print -u2 "error: cannot find the kernel Mach-O."
    print -u2 "       Install the Kernel Debug Kit for this build, then pass"
    print -u2 "       --kernel /Library/Developer/KDKs/.../System/Library/Kernels/kernel"
    exit 2
  }
fi
if [[ ! -f "$KERNEL" ]]; then
  print -u2 "error: kernel not readable: $KERNEL"
  exit 2
fi

for tool in nm otool perl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    print -u2 "error: $tool is not available in PATH."
    print -u2 "       nm and otool come with the Xcode Command Line Tools:"
    print -u2 "       xcode-select --install"
    exit 2
  fi
done

hexdump_at() {
  local off="$1" len="$2" file="$3"
  if command -v xxd >/dev/null 2>&1; then
    xxd -s "$off" -l "$len" -p "$file" | tr -d '\n'
  else
    od -An -v -tx1 -j "$off" -N "$len" "$file" | tr -d ' \n'
  fi
}

SYM_HEX="$(nm -n "$KERNEL" 2>/dev/null | awk '$3=="_IOProtectCacheMode"{print $1; exit}')"
if [[ -z "$SYM_HEX" ]]; then
  print -u2 "error: _IOProtectCacheMode is not in the symbol table of:"
  print -u2 "       $KERNEL"
  print -u2 "       Install the matching Kernel Debug Kit and retry with --kernel."
  exit 2
fi

VMADDR_HEX="$(otool -l "$KERNEL" | awk '/segname __TEXT/{seen=1} seen && $1=="vmaddr"{print $2; exit}')"
FILEOFF_HEX="$(otool -l "$KERNEL" | awk '/segname __TEXT/{seen=1} seen && $1=="fileoff"{print $2; exit}')"
if [[ -z "$VMADDR_HEX" || -z "$FILEOFF_HEX" ]]; then
  print -u2 "error: cannot read the __TEXT segment from $KERNEL"
  exit 2
fi

# The kernel is linked near the top of the canonical 48-bit address space.
# zsh arithmetic is signed 64-bit; subtracting two addresses in the same range
# yields the small, correct difference, and adding the small file offset keeps
# it in range.
SYM_OFF=$(( 0x${SYM_HEX#0x} - 0x${VMADDR_HEX#0x} + 0x${FILEOFF_HEX#0x} ))
if (( SYM_OFF <= 0 )); then
  print -u2 "error: could not compute the file offset of _IOProtectCacheMode"
  print -u2 "       symbol=$SYM_HEX vmaddr=$VMADDR_HEX fileoff=$FILEOFF_HEX"
  exit 2
fi

PROLOGUE_OFF=$(( SYM_OFF ))
CALL_OFF=$(( SYM_OFF + REL_OFFSET ))

ACTUAL_PROLOGUE="$(hexdump_at "$PROLOGUE_OFF" 17 "$KERNEL")"
if [[ "$ACTUAL_PROLOGUE" != "$PROLOGUE" ]]; then
  print -u2 "error: _IOProtectCacheMode does not have the expected prologue."
  print -u2 "       found:    $ACTUAL_PROLOGUE"
  print -u2 "       expected: $PROLOGUE"
  print -u2 "       The kernel layout is not the one this patch targets; stop here."
  exit 3
fi

NEW_CONST="$(hexdump_at "$CALL_OFF" 5 "$KERNEL")"
if [[ "${NEW_CONST:0:2}" != "e8" ]]; then
  print -u2 "error: the bytes at _IOProtectCacheMode+0xCC are not a call: $NEW_CONST"
  print -u2 "       Do not guess. Report this value with the macOS build number."
  exit 3
fi

print "kernel    : $KERNEL"
print "symbol    : _IOProtectCacheMode"
print "prologue  : ok"
print "old const : $OLD_CONST"
print "real call : $NEW_CONST"

if [[ "$NEW_CONST" == "$OLD_CONST" ]]; then
  print "already correct: nothing to patch."
  exit 0
fi

COUNT="$(perl -0777 -ne 'my $c = () = /\xE8\x2F\xF3\x02\x00/g; print $c' "$BIN")"
if [[ "$COUNT" == "0" ]]; then
  NEW_COUNT="$(NEW_HEX="$NEW_CONST" perl -0777 -ne '
    my $new = pack("H*", $ENV{NEW_HEX});
    my $c = () = /\Q$new\E/g; print $c' "$BIN")"
  if [[ "$NEW_COUNT" == "1" ]]; then
    print "already patched: $BIN contains the current signature."
    exit 0
  fi
fi
if [[ "$COUNT" != "1" ]]; then
  print -u2 "error: expected exactly one old signature in the binary, found $COUNT"
  exit 4
fi
BIN_OFF="$(perl -0777 -ne 'print index($_, "\xE8\x2F\xF3\x02\x00")' "$BIN")"

if (( DRY_RUN )); then
  print "dry run: would replace $OLD_CONST with $NEW_CONST in $BIN"
  exit 0
fi

if [[ ! -f "$BIN.orig" ]]; then
  cp -p "$BIN" "$BIN.orig"
  print "backup    : $BIN.orig"
fi

NEW_CONST="$NEW_CONST" perl -0777 -i -pe '
  my $new = pack("H*", $ENV{NEW_CONST});
  s/\xE8\x2F\xF3\x02\x00/$new/;
' "$BIN"

AFTER="$(hexdump_at "$BIN_OFF" 5 "$BIN")"
if [[ "$AFTER" != "$NEW_CONST" ]]; then
  print -u2 "error: patch verification failed: found $AFTER, expected $NEW_CONST"
  print -u2 "       Restore with --restore and report this."
  exit 3
fi
print "patched   : $BIN"
print "verify    : $AFTER"
print ""
print "Next: reboot with this EFI and check:"
print "  ioreg -l | grep -E 'TGLMMIOStrongUC|TGLTahoeMMIOGuard|N97NativeStartAllowed'"
