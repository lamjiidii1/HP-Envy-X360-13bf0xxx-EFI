# 05 — Audio

## Hardware chain

```
ALC245 codec  →  Intel Smart Sound Technology controller (8086:51CC)
              →  headphone jack / internal microphone
              →  CS35L41 smart amplifiers  →  speakers
```

macOS has no driver for the CS35L41 amplifiers, so **the speakers cannot
work**. Headphone output and USB-C output work. The internal microphone is
untested: the codec exposes an input device and the DSP patch prevents the
known panic, but recording has not been verified on this unit. This is a
hardware limitation, not a configuration problem, and the reference laptop
reports the same speaker behaviour.

## What runs on Sequoia today

Sequoia still ships `AppleHDA`, so audio uses the normal AppleALC path. The
Tahoe-only pieces are present in the config but do not load:

| Component | Setting | Effect on Sequoia 15.8.2 |
|---|---|---|
| `SimpleHDA.kext` 1.0.0 | `MinKernel 25.0.0`, `MaxKernel 25.99.99` | **Not injected.** OpenCore skips it on Darwin 24; it exists only for a future Tahoe boot |
| `AppleALC.kext` 1.9.8 (patched) | `alcid=11` | ALC245 layout 11 on the native `AppleHDA`; headphone output works, mic untested |
| `DeviceProperties` `PciRoot(0x0)/Pci(0x1F,0x3)` | `device-id = C8510000` | AppleALC's controller table lacks `0x51CC`; `0x51C8` is the same controller family |
| boot arg | `shda-lang=en` | Inert here (it belongs to SimpleHDA); harmless, kept so the same config can still boot Tahoe |

Two consequences of the downgrade:

- There is **no** `SimpleHDA` step to perform on Sequoia, and no `shda-lang`
  effect to verify. If audio is broken, the fault is in AppleALC, the layout,
  or the controller `device-id` — not in the missing Tahoe shim.
- The `SimpleHDA` entry can be disabled in `Kernel/Add` with no effect today. It
  is left enabled on purpose so one EFI can boot both OS families; OpenCore's
  `MinKernel`/`MaxKernel` gate is what makes that safe.

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
- `SimpleHDA` and a future native `AppleHDA` must not both be enabled. On
  Sequoia the `MinKernel`/`MaxKernel` gate already prevents that; if the gate is
  ever removed, disable `SimpleHDA` before booting 15.x.
