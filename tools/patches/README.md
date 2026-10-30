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
