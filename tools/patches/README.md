# Binary patches

## `patch-applealc-alc245-layout11.py`

Removes the `SignalProcessing` (DSP) blocks from AppleALC's ALC245 layout 11.

- **Why:** layout 11 routes the microphone through Apple's noise-reduction
  DSP. On this laptop that path dereferences a missing parameter and panics in
  `EupDSP::ConfigParamInt` inside `coreaudiod` as soon as anything records.
  Removing the DSP keeps headphone output and microphone input, without the
  processing.
- **Source:** [retropineaple/whateverxe-hp-envy-x360](https://github.com/retropineaple/whateverxe-hp-envy-x360/blob/main/tools/patch-applealc-alc245-layout11.py),
  used with attribution.
- **Reproduced here:** applying it to upstream AppleALC 1.9.8 RELEASE produces
  byte-for-byte the `AppleALC.kext` shipped in `efi/base/OC/Kexts`
  (SHA-256 `ee5ed2952138f819e4cd679649e3c3a042ed0796d4782c296fade2982e02849d`).
- **Tested against:** AppleALC 1.9.8 only. Re-check the compressed layout
  offsets if you update AppleALC.

```sh
curl -LO https://github.com/acidanthera/AppleALC/releases/download/1.9.8/AppleALC-1.9.8-RELEASE.zip
unzip -q AppleALC-1.9.8-RELEASE.zip
./patch-applealc-alc245-layout11.py AppleALC.kext/Contents/MacOS/AppleALC /tmp/AppleALC
shasum -a 256 /tmp/AppleALC
# ee5ed2952138f819e4cd679649e3c3a042ed0796d4782c296fade2982e02849d
```

The patch is only needed for the ALC245 + CS35L41 speaker configuration of
this laptop. It is not needed for other codecs.

## `whateverxe-xepm-hwp-caps.patch`

Fixes XE-PM's HWP rescale so it honors deliberate caps instead of maximizing
every request.

- **Why:** upstream `xpSetMult` rewrote any HWP maximum below the core's
  highest performance to that highest value. That corrects XCPM's 100 MHz vs
  78.7 MHz unit mismatch on Alder Lake P-cores, but it also discards
  `lowpowermode 1`: the 2.4 GHz cap became a ~4.7 GHz request, and P-cores ran
  at ~3.8 GHz / ~21 W package instead of ~2.2 GHz / ~11 W.
- **Source:** [lamjiidii1/WhateverXe](https://github.com/lamjiidii1/WhateverXe)
  `main` @ `dffff328cfd7e21c524463c9fb12af1db1c143ac`.
- **Fix:** convert the requested ratio with `unit = 78741 kHz` on P-cores and
  `100000 kHz` on E-cores (CPUID leaf `1AH` EAX[31:24]: `0x40` Core, `0x20`
  Atom), clamp to `HWP_CAPABILITIES.highest`, and scale `desired` the same way.
  If the core type is unknown, leave the request as XCPM wrote it.
- **Tested:** i7-1250U (2P+8E), Tahoe 26.7.1 (25G241). With
  `lowpowermode 1`, one busy thread went from 3.81–3.84 GHz / 20.6–21.8 W to
  2.21–2.23 GHz / 10.8–11.7 W; with `lowpowermode 0`, 3.81 GHz is still
  reached.
- **Apply:** from the fork root, `git apply whateverxe-xepm-hwp-caps.patch`,
  then `python3 tools/build.py --release`.

The patch is against `dffff328` only; re-check the context if the fork moves.

## `whateverxe-xepm-epp96.patch`

Changes XE-PM's built-in EPP default from `0` to `96` (and documents why).

- **Why:** EPP `0` asks for maximum performance on every HWP request. On this
  i7-1250U that costs roughly 0.5–0.8 W at idle for no measurable turbo gain;
  EPP `96` leaves one-core turbo unchanged (3828 → 3819 MHz) and costs about
  2 % sustained all-thread clock. `-wex-pm` applies it 20 s after load and
  re-checks at 60 s, so no boot argument or daemon is needed.
- **Source:** [lamjiidii1/WhateverXe](https://github.com/lamjiidii1/WhateverXe)
  branch `tune/xepm-epp96` @ `e339315`, on top of
  `whateverxe-xepm-hwp-caps.patch` (`00193a7`).
- **Change:** `gXpEpp = 96;` in `xePmInstall()` plus the header comment. The
  sysctl `debug.xepm.epp` still overrides it at runtime (`0` = performance,
  `-1` = leave XCPM's own value).
- **Apply:** with the cap patch already applied,
  `git apply whateverxe-xepm-epp96.patch`, then
  `python3 tools/build.py --release`.
- **Tested:** i7-1250U (2P+8E), Tahoe 26.7.1 (25G241); the deployed kext has
  SHA-256 `a84472e2510e7ec2cf8885ff1a922c00a4593af694f5d5e5b29a8102276aaa64`.

## `whateverxe-xepm-msr-probe.patch`

Diagnostic-only patch used to answer "why does the package never go below
PC3?" on this laptop. It is **not** part of the shipped EFI; keep it for the
next time package C-states come up.

- **Adds:** `debug.xepm.msr`, a read-only binary snapshot of 20 power MSRs
  (`{u32 id, i32 status, u64 value}[]`: `0xE2`, `0x60`, `0x3F8`–`0x3FA`,
  `0x630`–`0x632`, `0xDB0`, `0xDB1`, `0x1FC`, `0x1A0`, `0x1B0`, `0x19C`,
  `0x610`, `0x614`, `0x770`, `0x771`, `0x774`, `0xCE`), read through
  `rdmsr_carefully()` so unimplemented MSRs are reported instead of faulting;
  and `debug.xepm.pcst` / `debug.xepm.pcst_status`, a guarded write of the
  `0xE2` bits 3:0 package C-state limit that refuses to run when the CFG lock
  is set.
- **Source:** [lamjiidii1/WhateverXe](https://github.com/lamjiidii1/WhateverXe)
  branch `tune/xepm-epp96` @ `e339315`, on top of `whateverxe-xepm-epp96.patch`.
- **Apply:** `git apply whateverxe-xepm-msr-probe.patch`, `python3
  tools/build.py --release`, then decode two snapshots with
  `python3 scripts/macos/xepm-msr.py first.bin second.bin --seconds N`.
- **What it settled** (i7-1250U, Tahoe 26.7.1, quiet battery idle):
  `0xE2 = 0x74008008` — limit 8 (C10), CFG lock set, C1 and package demotion
  enabled; so the limit was never the blocker. `0x60` is unsupported;
  `0x3F8` (PC3) advances ~87 s per 120 s window while `0x3F9`–`0x632` stay at
  zero, i.e. the package stops at PC3. `0x771`/`0x774` confirmed HWP is
  enabled with EPP 96. The earlier "P-cores never idle" reading was traced to
  measuring with the agent desktop active, not to these registers.
- **Caveat:** the snapshot loops the MSR list once per read; read it twice and
  divide by `machdep.tsc.frequency`, as `xepm-msr.py` does. The probe build is
  not byte-identical to the shipped kext (debug sysctls only), so do not ship
  it.
- **Status values:** `debug.xepm.pcst_status` is `-2` never attempted, `-1`
  value out of range, `-3` refused because the CFG lock is set, otherwise the
  limit now in `0xE2`. This laptop's CFG lock is set, so a write is refused
  and the limit stays 8.

## `patch-intel-bt-lowpower` (built into `scripts/build_efi.py`)

Forces `IntelBluetoothFirmware` to advertise `kIOPMLowPower` for the USB
controller, so it can idle-suspend.

- **Why:** the unmodified 2.5.1 kext leaves the AX211 controller in power state
  2 (`CapabilityFlags` without `kIOPMLowPower`), which costs roughly 0.2–0.4 W
  and keeps the USB device out of its low-power state even when Bluetooth is
  idle.
- **Change:** one machine-code immediate in
  `IntelBluetoothFirmware.kext/Contents/MacOS/IntelBluetoothFirmware` at file
  offset `0xA95168` (for the pinned 2.5.1 binary, SHA-256
  `2da7a9d1213fbb0ba1a6b11396ea416fd06ba4597dfca569aa1c6f53ada25617`):
  `2` → `0x10000` (`kIOPMLowPower`).
- **Where:** `patch_intel_bt_lowpower()` in `scripts/build_efi.py`. It is
  applied to the copied build payload, never to `efi/base`; the manifest
  records the result under `kext_patches`.
- **Verify:** after a boot with Bluetooth on,
  `ioreg -r -c IOUSBHostDevice -l -w0 | grep -A2 '"idProduct" = 51'` should
  show `CapabilityFlags` containing `65536`. The patch is inert if the base
  binary does not match the pinned hash (the build refuses to patch).
- **Caveat:** it is a byte patch against one release. Re-derive the offset
  before updating `IntelBluetoothFirmware`.
