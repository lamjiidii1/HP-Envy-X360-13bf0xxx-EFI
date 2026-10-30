#!/usr/bin/env python3
"""Remove the DSP chains from AppleALC's ALC245 layout 11.

Layout 11 sends the microphone through Apple's noise-reduction DSP
(DspNoiseReduction / EupDSP). On this laptop that path reads a missing
parameter and panics the kernel (EupDSP::ConfigParamInt, in coreaudiod) as
soon as anything records. Removing every SignalProcessing block from the
layout keeps the headphone output and the mic input, minus the processing.

The layout is stored zlib-compressed inside the AppleALC binary, along with
its compressed and uncompressed sizes. This script keeps the uncompressed size
the same by padding with spaces, and writes a smaller compressed stream in
place (zlib stops at the end of the stream, so the leftover bytes are ignored).
Only the x86_64 slice is patched.

Usage: patch-applealc-alc245-layout11.py AppleALC.kext/Contents/MacOS/AppleALC OUT
Tested with AppleALC 1.9.8 RELEASE.
"""
import plistlib
import re
import struct
import sys
import zlib

ALC245 = 0x10EC0245
LAYOUT_PREFIX = b'<dict><key>LayoutID</key><integer>11</integer>'


def blobs(data):
    for i in range(len(data) - 2):
        if data[i] != 0x78 or (data[i] * 256 + data[i + 1]) % 31:
            continue
        d = zlib.decompressobj()
        try:
            out = d.decompress(bytes(data[i:i + 200000]))
        except zlib.error:
            continue
        if d.eof:
            yield i, min(200000, len(data) - i) - len(d.unused_data), out


def is_alc245_layout11(xml):
    if not xml.startswith(LAYOUT_PREFIX):
        return False
    p = plistlib.loads(b'<?xml version="1.0"?><plist version="1.0">' + xml + b'</plist>')
    return any(ALC245 in r.get('CodecID', []) for r in p.get('PathMapRef', []))


def strip_signal_processing(xml):
    key = b'<key>SignalProcessing</key>'
    tag = re.compile(rb'<dict>|</dict>|<dict/>')
    while (i := xml.find(key + b'<dict>')) >= 0:
        k, depth = i + len(key), 0
        while True:
            m = tag.search(xml, k)
            depth += {b'<dict>': 1, b'</dict>': -1}.get(m.group(0), 0)
            k = m.end()
            if depth == 0:
                break
        xml = xml[:i] + xml[k:]
    return xml


def x86_64_slice(data):
    """(start, end) of the x86_64 code in a thin or universal Mach-O."""
    if data[:4] == b'\xca\xfe\xba\xbe':
        for n in range(struct.unpack_from('>I', data, 4)[0]):
            cpu, _, off, size, _ = struct.unpack_from('>iiIII', data, 8 + 20 * n)
            if cpu == 0x01000007:
                return off, off + size
        sys.exit('no x86_64 slice')
    return 0, len(data)


def main(src, dst):
    data = bytearray(open(src, 'rb').read())
    lo, hi = x86_64_slice(data)
    hits = [(o, c, x) for o, c, x in blobs(data) if lo <= o < hi and is_alc245_layout11(x)]
    if len(hits) != 1:
        sys.exit(f'expected one ALC245 layout 11 resource, found {len(hits)}')
    off, clen, xml = hits[0]
    new = strip_signal_processing(xml)
    if new == xml:
        sys.exit('layout 11 has no SignalProcessing (already patched?)')
    new = new[:-len(b'</dict>')] + b' ' * (len(xml) - len(new)) + b'</dict>'
    packed = zlib.compress(new, 9)
    if len(packed) > clen:
        sys.exit('recompressed layout does not fit')
    data[off:off + len(packed)] = packed
    open(dst, 'wb').write(data)
    print(f'patched layout 11 at 0x{off:x} ({clen} -> {len(packed)} compressed bytes)')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
