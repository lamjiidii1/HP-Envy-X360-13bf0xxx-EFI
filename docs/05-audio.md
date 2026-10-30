# 05 — Audio

## Hardware chain

```
ALC245 codec  →  Intel Smart Sound Technology controller (8086:51CC)
              →  headphone jack / internal microphone
              →  CS35L41 smart amplifiers  →  speakers
```

macOS has no driver for the CS35L41 amplifiers, so **the speakers cannot
work**. Headphone output and the internal microphone do work. This is a
hardware limitation, not a configuration problem, and the reference laptop
reports the same.

## Why three components are needed

Tahoe removed `AppleHDA`. The old config already solved this; the rebuild keeps
the same arrangement because it is the only one proven on this laptop:

| Component | Setting | Why |
|---|---|---|
| `SimpleHDA.kext` 1.0.0 | `MinKernel 25.0.0`, `MaxKernel 25.99.99` | Provides an `AppleHDA` replacement for Tahoe |
| `AppleALC.kext` 1.9.8 (patched) | `alcid=11` | ALC245 layout 11; best headphone quality of layouts 11/12/13 |
| `DeviceProperties` `PciRoot(0x0)/Pci(0x1F,0x3)` | `device-id = C8510000` | AppleALC's controller table lacks `0x51CC`; `0x51C8` is the same controller family |
| boot arg | `shda-lang=en` | English device names in SimpleHDA instead of Chinese |

`SimpleHDA` is limited to Tahoe (`MinKernel 25`, `MaxKernel 25.99.99`). If this
machine is ever downgraded to Sonoma/Sequoia, disable it and use the native
`AppleHDA` path instead.

## The AppleALC patch (important)

Stock AppleALC layout 11 routes the microphone through Apple's
noise-reduction DSP (`DspNoiseReduction` / `EupDSP`). On this laptop that path
reads a missing parameter and **panics the kernel in `EupDSP::ConfigParamInt`
inside `coreaudiod` the moment anything records**.

The shipped `AppleALC.kext` has every `SignalProcessing` block removed from
layout 11:

- Headphone output is unchanged.
- Recording works.
- The DSP processing is gone (acceptable: it was crashing anyway).

The patch is reproducible. Applying
`tools/patches/patch-applealc-alc245-layout11.py` to upstream AppleALC 1.9.8
RELEASE produces exactly the shipped binary:

```
ee5ed2952138f819e4cd679649e3c3a042ed0796d4782c296fade2982e02849d
```

See `tools/patches/README.md` for the command. If AppleALC is updated, the
patch must be re-verified — it relies on the compressed layout resource
offsets of 1.9.8.

## Verifying audio

```sh
system_profiler SPAudioDataType
# Output should list "Internal Speakers" (dead, CS35L41) and "Headphones"
# Input should list "Internal Microphone"

sudo dmesg | grep -i applealc
```

Play something through the jack, then record a few seconds with QuickTime or
`voice-memos` to confirm the mic does not panic.

## Common mistakes

- **Do not** add `alcid=13` or `layout-id` in `DeviceProperties` at the same
  time as `alcid=11`; the boot argument wins and the property is confusing.
- **Do not** use the unpatched AppleALC: recording will panic.
- **Do not** expect speakers. No amount of layout changes fixes missing
  CS35L41 support.
- `SimpleHDA` and a future native `AppleHDA` must not both be enabled.
