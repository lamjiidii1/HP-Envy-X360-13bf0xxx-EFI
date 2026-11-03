#!/bin/zsh
#
# patch-wex-sequoia-mmio.sh - repair WhateverXe's Sequoia MMIO-UC signature check.
#
# WhateverXe 0.6.0/0.6.1 validates the kernel function _IOProtectCacheMode by
# comparing five bytes at +0xCA with a hard-coded "call rel32"
# (E8 71 CB 02 00, targeting build 24H32).  macOS 15.8.2 (24H232) moved that
# call by +0x30, so the ninth comparison fails, tglMMIOUCRouted stays false,
# tglActive stays false and the accelerator never starts: framebuffer only,
# about 19 MB VRAM and no Metal.
#
# This script replaces the stale constant in the injected WhateverXe binary.
# With --kernel it reads the real bytes from the kernel Mach-O; without one it
# falls back to the known 24H232 value and says so.  It parses the Mach-O
# itself with perl, so nm/otool and the Xcode Command Line Tools are not
# needed.  It does not install anything, does not touch the kernel, and keeps
# a .orig backup.
#
# Usage:
#   sudo ./patch-wex-sequoia-mmio.sh --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext
#   sudo ./patch-wex-sequoia-mmio.sh --kext ... --kernel /Library/Developer/KDKs/KDK_.../System/Library/Kernels/kernel
#   sudo ./patch-wex-sequoia-mmio.sh --kext ... --dry-run
#   sudo ./patch-wex-sequoia-mmio.sh --kext ... --restore
#
# Exit codes: 0 patched/already correct, 2 cannot locate kernel/symbol,
#             3 unexpected bytes, 4 binary not found or ambiguous.

set -euo pipefail
setopt null_glob

OLD_CONST="e871cb0200"
# Known value for _IOProtectCacheMode+0xCA on macOS 15.8.2 (24H232).
FALLBACK_CONST="e8a1cb0200"
PROLOGUE="554889e54157415641554154534883ec28"
REL_OFFSET=$((0xCA))

KEXT=""
KERNEL_ARG=""
DRY_RUN=0
RESTORE=0

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
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

# count_hex FILE HEXBYTES -> number of non-overlapping byte-string matches
count_hex() {
  perl -e '
    my ($path, $hex) = @ARGV;
    open my $fh, "<:raw", $path or die "open $path: $!\n";
    local $/;
    my $d = <$fh>;
    my $pat = pack("H*", $hex);
    my $n = 0;
    my $at = -1;
    while (($at = index($d, $pat, $at + 1)) >= 0) { $n++ }
    print $n;
  ' "$1" "$2"
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
  kernel_required=1
else
  candidates=(
    /Library/Developer/KDKs/*/System/Library/Kernels/kernel
    /Library/Developer/KDKs/*/System/Library/Kernels/kernel.development
    /System/Volumes/Preboot/Cryptexes/OS/System/Library/Kernels/kernel
    /System/Library/Kernels/kernel
  )
  kernel_required=0
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
  if (( kernel_required )); then
    print -u2 "error: no kernel Mach-O with _IOProtectCacheMode symbols was found."
    print -u2 "Tried:"
    for t in "${tried[@]}"; do print -u2 "  $t"; done
    [[ -n "$last_error" ]] && print -u2 "Last error: $last_error"
    print -u2 ""
    print -u2 "Install the Kernel Debug Kit that matches this macOS build, then run:"
    print -u2 "  ls /Library/Developer/KDKs/"
    print -u2 "  sudo $0 --kext $KEXT \\"
    print -u2 "    --kernel /Library/Developer/KDKs/KDK_<build>/System/Library/Kernels/kernel"
    exit 2
  fi
  print "warning   : no kernel with symbols found; assuming the 24H232 value."
  print "            On another macOS build, pass --kernel <KDK kernel> instead."
  NEW_CONST="$FALLBACK_CONST"
else
  SYM_OFF="${INFO%% *}"
  SYM_OFF=$(( SYM_OFF ))
  rest="${INFO#* }"

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
    print -u2 "error: the bytes at _IOProtectCacheMode+0xCA are not a call: $NEW_CONST"
    print -u2 "       Do not guess. Report this value with the macOS build number."
    exit 3
  fi
  print "prologue  : ok"
fi

print "old const : $OLD_CONST"
print "real call : $NEW_CONST"

if [[ "${NEW_CONST:8:2}" != "00" ]]; then
  print -u2 "error: the high byte of the call displacement is ${NEW_CONST:8:2}, not 00."
  print -u2 "       This tool only rewrites a four-byte immediate; stop here."
  exit 3
fi

# The anchor is the ioreg property name, not the constant: it tells us this is
# a WhateverXe build with the Sequoia guard at all.
ANCHOR_COUNT="$(perl -0777 -ne 'my $c = () = /\QTGLSequoiaMMIOGuard\E/g; print $c' "$BIN")"
if [[ "$ANCHOR_COUNT" != "1" ]]; then
  print -u2 "error: expected one TGLSequoiaMMIOGuard anchor in $BIN, found $ANCHOR_COUNT"
  print -u2 "       This is not the expected WhateverXe build. Do not guess."
  exit 4
fi

# The constant is stored twice.  The live comparison is the four-byte
# immediate of
#   c7 45 <disp8> <imm32>    movl $imm32,-N(%rbp)
# and the fifth byte comes from the adjacent
#   c6 45 <disp8> 00         movb $0,-(N-4)(%rbp)
# The second copy is a five-byte array in the literal pool next to the guard's
# property name.  Replacing the four-byte immediate covers both; the pool copy
# keeps its trailing zero.  The Tahoe repair tool proved that the movl is the
# live one, so a site without the C7 45 prefix is never counted as live.
OLD_LIVE="${OLD_CONST:0:8}"
NEW_LIVE="${NEW_CONST:0:8}"

SITES="$(perl - "$BIN" "$OLD_LIVE" "$NEW_LIVE" <<'PERL'
use strict;
use warnings;
my ($path, $oldhex, $newhex) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!\n";
local $/;
my $d = <$fh>;
close $fh;
sub sites {
    my ($pat) = @_;
    my @out;
    my $p = -1;
    while (($p = index($d, $pat, $p + 1)) >= 0) {
        push @out, $p;
    }
    return @out;
}
sub live {
    my @in = @_;
    return grep { $_ >= 3 && substr($d, $_ - 3, 2) eq "\xC7\x45" } @in;
}
my @old = sites(pack('H*', $oldhex));
my @new = sites(pack('H*', $newhex));
my @live = live(@old);
my @live_new = live(@new);
printf "%d %d %d %d %s\n", scalar @old, scalar @new, scalar @live,
    scalar @live_new, join(',', @old);
PERL
)"

read -r OLD_N NEW_N LIVE_N LIVE_NEW_N OLD_LIST <<< "$SITES"

if (( NEW_N > 0 && OLD_N == 0 )); then
  if (( LIVE_NEW_N != 1 )); then
    print -u2 "error: the patched constant is present but the live movl was not found."
    exit 3
  fi
  print "already patched: $BIN already carries $NEW_CONST."
  exit 0
fi
if (( OLD_N == 0 || NEW_N != 0 )); then
  print -u2 "error: expected the old constant and none of the new one, found old=$OLD_N new=$NEW_N."
  print -u2 "       This is not the expected WhateverXe build, or it was patched"
  print -u2 "       differently. Do not guess; restore from $BIN.orig or rebuild."
  exit 3
fi
if (( LIVE_N != 1 )); then
  print -u2 "error: expected one live movl initialiser, found $LIVE_N."
  print -u2 "       Old-constant offsets: $OLD_LIST"
  print -u2 "       Do not guess; restore from $BIN.orig or rebuild."
  exit 3
fi
if (( OLD_N > 2 )); then
  print -u2 "error: expected one or two copies of the old constant, found $OLD_N."
  print -u2 "       Old-constant offsets: $OLD_LIST"
  exit 3
fi

if [[ "$NEW_CONST" == "$OLD_CONST" ]]; then
  print "nothing to patch: this kernel already contains $OLD_CONST."
  print "If this Mac is 15.8.2 (24H232), the selected KDK is for another build."
  exit 0
fi

if (( DRY_RUN )); then
  print "dry run   : would replace $OLD_N cop$([[ $OLD_N == 1 ]] && print y || print ies) of $OLD_CONST with $NEW_CONST"
  print "            offsets: $OLD_LIST"
  exit 0
fi

BEFORE="$(sha256_at "$BIN")"
if [[ ! -f "$BIN.orig" ]]; then
  cp -p "$BIN" "$BIN.orig"
  print "backup    : $BIN.orig"
fi

OFFSETS="$OLD_LIST" OLD_HEX="$OLD_LIVE" NEW_HEX="$NEW_LIVE" perl -0777 -i -pe '
  my $old = pack("H*", $ENV{OLD_HEX});
  my $new = pack("H*", $ENV{NEW_HEX});
  for my $off (split /,/, $ENV{OFFSETS}) {
    die "offset $off out of range\n" if $off + length($old) > length($_);
    die "offset $off does not hold the old constant\n"
        unless substr($_, $off, length($old)) eq $old;
    substr($_, $off, length($old)) = $new;
  }
' "$BIN"

AFTER_OLD="$(count_hex "$BIN" "$OLD_LIVE")"
AFTER_NEW="$(count_hex "$BIN" "$NEW_LIVE")"
if [[ "$AFTER_OLD" != "0" || "$AFTER_NEW" != "$OLD_N" ]]; then
  print -u2 "error: patch verification failed: old=$AFTER_OLD new=$AFTER_NEW (expected 0/$OLD_N)"
  print -u2 "       Restore with --restore and report this."
  exit 3
fi

print "patched   : $BIN"
print "sites     : $OLD_LIST"
print "sha256    : $BEFORE -> $(sha256_at "$BIN")"
print "verify    : $AFTER_NEW copy/copies now hold $NEW_CONST"
print ""
print "Next: reboot and check:"
print "  ioreg -lw0 | grep -o '\"TGLSequoiaMMIOGuard\" = <[^>]*>'"
print "  ioreg -rc IntelAccelerator | head -1"
print "  system_profiler SPDisplaysDataType | grep -i metal"
