#!/bin/bash
#
# test-metal-runtime-compile.sh - prove that Metal can compile a shader from
# source on this install, despite the MTLCompilerService sandbox denials.
#
# Why this exists
# ---------------
# Every Metal app, and every launch of `MTLCompilerService`, logs:
#
#   Sandbox: MTLCompilerService(pid) deny(1) file-read-data
#     /Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/adapter.dylib
#   Sandbox: MTLCompilerService(pid) deny(1) file-map-executable
#     /Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/libigc-tgl.dylib
#
# Those denials are expected.  Apple's profile
# /System/Library/Sandbox/Profiles/com.apple.mtlcompilerservice.sb grants
# /Library/GPUBundles only inside
#
#   (with-filter (system-attribute apple-internal) ...)
#
# and this install reports "Apple Internal: disabled".  WhateverXe Graphics
# 0.3.1 routes compilation through the OS-native AIR converter, so the service
# falls back and succeeds.
#
# This script compiles a tiny kernel with device.makeLibrary(source:) and then
# builds a compute pipeline.  That exercises the same path an app uses.
#
# Usage:
#   bash test-metal-runtime-compile.sh
#   TIMEOUT=120 bash test-metal-runtime-compile.sh
#
# Requirements: the Command Line Tools (swiftc).  No sudo, no driver change,
# no network.  Nothing outside a temporary directory is written.

set -u

TIMEOUT=${TIMEOUT:-60}

say() { printf '%s\n' "$*"; }
die() { say "VERDICT: FAIL - $*"; exit 1; }

case "${1:-}" in
    -h|--help)
        sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "") ;;
    *) die "unknown argument: $1 (try --help)" ;;
esac

command -v swiftc >/dev/null 2>&1 \
    || die "swiftc not found; install the Command Line Tools (xcode-select --install)"
command -v perl >/dev/null 2>&1 \
    || die "perl not found; cannot enforce a timeout"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/openmac-metal.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/test.swift" <<'SWIFT'
import Metal
import Foundation

guard let dev = MTLCreateSystemDefaultDevice() else {
    print("FAIL: no Metal device")
    exit(2)
}
print("device: \(dev.name)")

let src = """
#include <metal_stdlib>
using namespace metal;
kernel void addone(device float *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    out[i] = out[i] + \(Float(UInt32.random(in: 1...1_000_000)));
}
"""

do {
    let lib = try dev.makeLibrary(source: src, options: nil)
    print("LIBRARY OK: \(lib.functionNames)")
    guard let f = lib.makeFunction(name: "addone") else {
        print("FAIL: function missing")
        exit(3)
    }
    let p = try dev.makeComputePipelineState(function: f)
    print("PIPELINE OK: maxThreads=\(p.maxTotalThreadsPerThreadgroup)")
} catch {
    print("COMPILE FAIL: \(error)")
    exit(4)
}
SWIFT

say "Metal device:"
system_profiler SPDisplaysDataType 2>/dev/null \
    | grep -E 'Chipset Model|Metal Support' | sed 's/^ */  /'

say ""
say "Building the test program..."
if ! swiftc -O "$TMP/test.swift" -o "$TMP/test" >"$TMP/build.log" 2>&1; then
    sed 's/^/  /' "$TMP/build.log"
    die "swiftc could not build the test program"
fi

MARK=$(date "+%Y-%m-%d %H:%M:%S")
say "Running (timeout ${TIMEOUT}s, started $MARK)..."
perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$TMP/test" 2>&1 | tee "$TMP/run.log"
STATUS=${PIPESTATUS[0]}

say ""
if [ "$STATUS" -eq 142 ]; then
    die "the program did not finish within ${TIMEOUT}s; compilation is blocked or hanging"
fi
if [ "$STATUS" -ne 0 ]; then
    die "the program exited $STATUS"
fi
if ! grep -q '^PIPELINE OK:' "$TMP/run.log"; then
    die "the pipeline did not build; see the output above"
fi

DENIALS=$(/usr/bin/log show --start "$MARK" --style compact \
    --predicate 'eventMessage CONTAINS "XeCompilerAdapter"' 2>/dev/null \
    | grep -c 'deny(' || true)

say "XeCompilerAdapter denials during the run: ${DENIALS:-0} (expected on a"
say "non-Apple-internal install; compilation still succeeded)."
say ""
say "VERDICT: PASS - Metal compiled a kernel from source and built a pipeline."
say "The sandbox denials are cosmetic; do not patch /System or weaken SIP."
