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
