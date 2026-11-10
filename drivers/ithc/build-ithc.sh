#!/bin/zsh
# zsh ithc/build-ithc.sh [work-folder]
#
# Builds ITHC.kext from the sources in this folder and compares it with the
# kext in EFI/OC/Kexts:
#   1. copies ITHC/ and tools/ to the work folder
#   2. fetches MacKernelSDK (05094e5, the commit WhateverXe's CI pins)
#   3. builds with tools/build.py
#
# Needs macOS with the Xcode Command Line Tools, git and python3.
# Byte-identical output needs the same compiler (Apple clang 21.0.0,
# clang-2100.1.1.101, from Command Line Tools 26.6).
set -e
here=${0:A:h}
work=${1:-$PWD/ithc-build}
expected=b939db58c6602b331a5fc427d0bb54601c815b6f4533fc8938be49d022885260

[[ -e $work ]] && { echo "$work already exists; pass another folder"; exit 1; }
mkdir -p $work
cp -R $here/ITHC $here/tools $work/
git clone -q https://github.com/acidanthera/MacKernelSDK $work/MacKernelSDK
git -C $work/MacKernelSDK checkout -q 05094e5e88cec7caedbfb35e8449ed0db94bf95b
python3 $work/tools/build.py

built=$work/build/ITHC.kext
# The linker's LC_UUID depends on the build folder's path, so it never
# matches across machines. Stamp the original build's UUID; every other byte
# is the compiler's own output.
python3 - $built/Contents/MacOS/ITHC <<'P'
import struct, sys, uuid
path = sys.argv[1]
d = bytearray(open(path, 'rb').read())
off = 32
for _ in range(struct.unpack_from('<I', d, 16)[0]):
    cmd, size = struct.unpack_from('<II', d, off)
    if cmd == 0x1B:
        d[off + 8:off + 24] = uuid.UUID('983D18B8-894C-3863-BEC0-752ABED9CC52').bytes
        break
    off += size
else:
    sys.exit('no LC_UUID')
open(path, 'wb').write(d)
P
sum=$(shasum -a 256 $built/Contents/MacOS/ITHC | cut -d' ' -f1)
echo
echo "Built: $built"
echo "SHA-256: $sum"
if [[ $sum == $expected ]]; then
  echo "Identical to the ITHC.kext in this repo's EFI."
else
  echo "Differs from the EFI's kext ($expected)."
  echo "That's expected with a different compiler version; the source is the same."
fi
