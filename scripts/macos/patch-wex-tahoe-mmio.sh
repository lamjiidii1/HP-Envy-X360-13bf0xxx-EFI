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
# This script reads the real bytes from the kernel Mach-O and replaces the
# stale constant in the injected WhateverXe binary.  It parses the Mach-O
# itself with perl, so nm/otool and the Xcode Command Line Tools are not
# needed; the Kernel Debug Kit for this macOS build is.  It does not install
# anything, does not touch the kernel, and keeps a .orig backup.
#
# Usage:
#   sudo ./patch-wex-tahoe-mmio.sh --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext
#   sudo ./patch-wex-tahoe-mmio.sh --kext ... --kernel /Library/Developer/KDKs/KDK_.../System/Library/Kernels/kernel
#   sudo ./patch-wex-tahoe-mmio.sh --kext ... --dry-run
#   sudo ./patch-wex-tahoe-mmio.sh --kext ... --restore
#
# Exit codes: 0 patched/already correct, 2 cannot locate kernel/symbol,
#             3 unexpected bytes, 4 binary not found or ambiguous.

set -euo pipefail
setopt null_glob

OLD_CONST="e82ff30200"
PROLOGUE="554889e54157415641554154534883ec28"
REL_OFFSET=$((0xCC))

KEXT=""
KERNEL_ARG=""
DRY_RUN=0
RESTORE=0

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while (( $# )); do
  case "$1" in
    --kext)    KEXT="${2:-}"; shift 2 ;;
    --kernel)  KERNEL_ARG="${2:-}"; shift 2 ;;
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

hexdump_at() {
  local off="$1" len="$2" file="$3"
  if command -v xxd >/dev/null 2>&1; then
    xxd -s "$off" -l "$len" -p "$file" | tr -d '\n'
  else
    od -An -v -tx1 -j "$off" -N "$len" "$file" | tr -d ' \n'
  fi
}

sha256_at() {
  shasum -a 256 "$1" | awk '{print $1}'
}

if (( RESTORE )); then
  if [[ ! -f "$BIN.orig" ]]; then
    print -u2 "error: no backup at $BIN.orig"
    exit 4
  fi
  cp -p "$BIN.orig" "$BIN"
  print "restored $BIN from $BIN.orig"
  print "sha256   : $(sha256_at "$BIN")"
  exit 0
fi

# macho_symbol FILE SYMBOL -> "<fileoff> <value> <textvmaddr>"
# Thin 64-bit Mach-O and universal files (x86_64 slice) are supported.
macho_symbol() {
  perl - "$1" "$2" <<'PERL'
use strict;
use warnings;

my $path = shift // die "no path\n";
my $want = shift // die "no symbol\n";

open my $fh, '<:raw', $path or die "open $path: $!\n";
local $/;
my $d = <$fh>;
close $fh;
die "file too short\n" if length($d) < 32;

my $be = unpack('N', substr($d, 0, 4));
if ($be == 0xcafebabe) {                       # universal, big-endian header
    my $nfat = unpack('N', substr($d, 4, 4));
    my $base;
    for (my $i = 0; $i < $nfat; $i++) {
        my $e = 8 + $i * 20;
        die "fat arch table out of range\n" if $e + 20 > length($d);
        my ($cpu, undef, $off, $size) =
            unpack('N4', substr($d, $e, 16));
        if ($cpu == 0x01000007) {              # CPU_TYPE_X86_64
            $base = $off;
            $d = substr($d, $off, $size);
            last;
        }
    }
    die "no x86_64 slice in universal file\n" unless defined $base;
}

my $magic = unpack('V', substr($d, 0, 4));
die sprintf("not a 64-bit Mach-O (magic 0x%08x)\n", $magic)
    if $magic != 0xfeedfacf;

my $len = length $d;
my (undef, undef, undef, undef, $ncmds, $sizeofcmds) =
    unpack('V6', substr($d, 0, 24));
die "implausible load command count\n" if $ncmds > 10000 || $ncmds == 0;

my $off = 32;
my ($text_vm, $text_off, $symoff, $nsyms, $stroff, $strsize);

for (my $i = 0; $i < $ncmds; $i++) {
    die "load command $i out of range\n" if $off + 8 > $len;
    my ($cmd, $cmdsize) = unpack('V2', substr($d, $off, 8));
    die "bad load command size\n" if $cmdsize < 8 || $off + $cmdsize > $len;
    if ($cmd == 0x19) {                        # LC_SEGMENT_64
        my $seg = substr($d, $off + 8, 16);
        $seg =~ s/\0.*//s;
        if ($seg eq '__TEXT') {
            $text_vm  = unpack('Q<', substr($d, $off + 24, 8));
            $text_off = unpack('Q<', substr($d, $off + 40, 8));
        }
    } elsif ($cmd == 0x2) {                    # LC_SYMTAB
        ($symoff, $nsyms, $stroff, $strsize) =
            unpack('V4', substr($d, $off + 8, 16));
    }
    $off += $cmdsize;
}

die "no __TEXT segment\n" unless defined $text_vm;
die "no LC_SYMTAB: the kernel is stripped\n"
    unless defined $symoff && defined $nsyms;
die "empty symbol table\n" if $nsyms == 0;

my $found;
for (my $i = 0; $i < $nsyms; $i++) {
    my $e = $symoff + $i * 16;
    last if $e + 16 > $len;
    my $strx = unpack('V', substr($d, $e, 4));
    next if $strx == 0 || $strx >= $strsize;
    my $s = substr($d, $stroff + $strx, $strsize - $strx);
    $s =~ s/\0.*//s;
    if ($s eq $want) {
        $found = unpack('Q<', substr($d, $e + 8, 8));
        last;
    }
}
die "symbol $want not found ($nsyms symbols read)\n" unless defined $found;

my $fileoff = $found - $text_vm + $text_off;
die "computed negative offset\n" if $fileoff < 0;
printf "0x%x 0x%x 0x%x\n", $fileoff, $found, $text_vm;
PERL
}

if [[ -n "$KERNEL_ARG" ]]; then
  candidates=("$KERNEL_ARG")
else
  candidates=(
    /Library/Developer/KDKs/*/System/Library/Kernels/kernel
    /Library/Developer/KDKs/*/System/Library/Kernels/kernel.development
    /System/Volumes/Preboot/Cryptexes/OS/System/Library/Kernels/kernel
    /System/Library/Kernels/kernel
  )
fi

KERNEL=""
INFO=""
tried=()
last_error=""
for candidate in "${candidates[@]}"; do
  [[ -f "$candidate" ]] || continue
  tried+=("$candidate")
  if INFO="$(macho_symbol "$candidate" _IOProtectCacheMode 2>/dev/null)"; then
    KERNEL="$candidate"
    break
  fi
  last_error="$(macho_symbol "$candidate" _IOProtectCacheMode 2>&1 >/dev/null || true)"
  INFO=""
done

if [[ -z "$INFO" ]]; then
  print -u2 "error: no kernel Mach-O with _IOProtectCacheMode symbols was found."
  if (( ${#tried} )); then
    print -u2 "Tried:"
    for t in "${tried[@]}"; do print -u2 "  $t"; done
    if [[ -n "$last_error" ]]; then
      print -u2 "Last error: $last_error"
    fi
  else
    print -u2 "No candidate path exists."
  fi
  print -u2 ""
  print -u2 "Install the Kernel Debug Kit that matches this macOS build, then run:"
  print -u2 "  ls /Library/Developer/KDKs/"
  print -u2 "  sudo $0 --kext $KEXT \\"
  print -u2 "    --kernel /Library/Developer/KDKs/KDK_<build>/System/Library/Kernels/kernel"
  exit 2
fi

SYM_OFF="${INFO%% *}"
SYM_OFF=$(( SYM_OFF ))
rest="${INFO#* }"
SYM_VALUE="${rest%% *}"

print "kernel    : $KERNEL"
print "symbol    : _IOProtectCacheMode"
print "sym off   : $SYM_OFF"

CALL_OFF=$(( SYM_OFF + REL_OFFSET ))

ACTUAL_PROLOGUE="$(hexdump_at "$SYM_OFF" 17 "$KERNEL")"
if [[ "$ACTUAL_PROLOGUE" != "$PROLOGUE" ]]; then
  print -u2 "error: _IOProtectCacheMode does not have the expected prologue."
  print -u2 "       found:    $ACTUAL_PROLOGUE"
  print -u2 "       expected: $PROLOGUE"
  print -u2 "       That KDK is probably for a different macOS build; stop here."
  exit 3
fi

NEW_CONST="$(hexdump_at "$CALL_OFF" 5 "$KERNEL")"
if [[ "${NEW_CONST:0:2}" != "e8" ]]; then
  print -u2 "error: the bytes at _IOProtectCacheMode+0xCC are not a call: $NEW_CONST"
  print -u2 "       Do not guess. Report this value with the macOS build number."
  exit 3
fi

print "prologue  : ok"
print "old const : $OLD_CONST"
print "real call : $NEW_CONST"

# The five bytes sit immediately before the "TGLTahoeMMIOGuard" string in the
# WhateverXe binary.  Anchor on that string instead of scanning for the old
# value, so the patch is exact and idempotent.
ANCHOR_OFF="$(perl -0777 -ne 'my $c = () = /\QTGLTahoeMMIOGuard\E/g; print $c ? index($_, "TGLTahoeMMIOGuard") : -1' "$BIN")"
if [[ "$ANCHOR_OFF" == "-1" ]]; then
  print -u2 "error: the TGLTahoeMMIOGuard anchor is missing from $BIN"
  exit 4
fi
ANCHOR_COUNT="$(perl -0777 -ne 'my $c = () = /\QTGLTahoeMMIOGuard\E/g; print $c' "$BIN")"
if [[ "$ANCHOR_COUNT" != "1" ]]; then
  print -u2 "error: expected one TGLTahoeMMIOGuard anchor, found $ANCHOR_COUNT"
  exit 4
fi
BIN_CALL_OFF=$(( ANCHOR_OFF - 5 ))
CURRENT_CONST="$(hexdump_at "$BIN_CALL_OFF" 5 "$BIN")"

if [[ "$CURRENT_CONST" == "$OLD_CONST" ]]; then
  :
elif [[ "$CURRENT_CONST" == "$NEW_CONST" ]]; then
  print "already patched: $BIN already carries $NEW_CONST."
  exit 0
else
  print -u2 "error: unexpected bytes before the anchor: $CURRENT_CONST"
  print -u2 "       expected the old constant $OLD_CONST."
  print -u2 "       Do not guess; restore from $BIN.orig or rebuild the EFI."
  exit 3
fi

if [[ "$NEW_CONST" == "$OLD_CONST" ]]; then
  print "nothing to patch: this kernel already contains $OLD_CONST."
  print "If this Mac is 26.7.2, the selected KDK is for a different build."
  exit 0
fi

if (( DRY_RUN )); then
  print "dry run   : would replace $CURRENT_CONST with $NEW_CONST at 0x$(printf '%x' $BIN_CALL_OFF)"
  exit 0
fi

BEFORE="$(sha256_at "$BIN")"
if [[ ! -f "$BIN.orig" ]]; then
  cp -p "$BIN" "$BIN.orig"
  print "backup    : $BIN.orig"
fi

OFFSET="$BIN_CALL_OFF" NEW_HEX="$NEW_CONST" perl -0777 -i -pe '
  my $off = $ENV{OFFSET};
  my $new = pack("H*", $ENV{NEW_HEX});
  substr($_, $off, 5) = $new;
' "$BIN"

AFTER_CONST="$(hexdump_at "$BIN_CALL_OFF" 5 "$BIN")"
if [[ "$AFTER_CONST" != "$NEW_CONST" ]]; then
  print -u2 "error: patch verification failed: found $AFTER_CONST, expected $NEW_CONST"
  print -u2 "       Restore with --restore and report this."
  exit 3
fi

print "patched   : $BIN"
print "sha256    : $BEFORE -> $(sha256_at "$BIN")"
print "verify    : $AFTER_CONST"
print ""
print "Next: reboot and check:"
print "  ioreg -l | grep -E 'TGLMMIOStrongUC|TGLTahoeMMIOGuard'"
print "  ioreg -l | grep -E 'N97Native(StartAllowed|KernelReady|ProbeBlocked)'"
