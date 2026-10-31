# 03 — Graphics: what is happening and how to fix it

This is the open problem. Everything else on the machine works. Read this
before changing boot arguments.

## The stack

macOS has no driver for Alder Lake Iris Xe (`8086:46AA`). WhateverXe makes
Apple's **Tiger Lake** driver accept it:

| Component | Where it lives | Role |
|---|---|---|
| `WhateverXe.kext` | EFI `Kernel/Add` (injected) | Lilu plugin; rewrites the driver's expectations at runtime (device selection, memory layout, display 13 wiring, accelerator bring-up) |
| `AppleIntelTGLCompat.kext` | installed by WhateverXe Graphics into `/Library/Extensions`, loaded from AuxKC | Provides the Compatibility ABI the patched framebuffer/accelerator link against |
| `AppleIntelTGLGraphicsFramebuffer.kext` | installed by the Graphics package into `/Library/Extensions` + AuxKC | Patched Apple framebuffer |
| `AppleIntelTGLGraphics.kext` (accelerator) | same | Patched Apple 3D driver |
| `AppleIntelTGLGraphicsVADriver.bundle` | `/Library/GPUBundles` | Hardware video decode (optional) |
| `AMFIPass.kext` (Mod) | EFI | Lets the signed Xe bundles load without disabling AMFI globally |

The two halves must match: a WhateverXe build and a Graphics package built for
the same Compat ABI. The old install is **0.6.0 + Graphics 0.3.1 (Compat
0.6.0)**. This repository's default is **0.6.1 + Graphics 0.3.2 (Compat
0.6.1)**.

## What the logs show

From `LOGS/macOS_Logs_20261030_180840` (macOS 26.7.2, build 25G332):

```
kextstat: org.b00t0x.WhateverXe (0.6.0)
kextstat: org.b00t0x.AppleIntelTGLCompat (0.6.0)
log     : AppleIntelTGLCompat: revision 0.5.0 started, physical-owner/binding selection
log     : AppleIntelTGLGraphicsFramebuffer [IGFB][WARN][BRINGUP] ...
log     : Boot args: ... -wex-adlp-edp ... -wex-reset-restore -wex-no-multicontext ...
```

So all three pieces load. But the IORegistry shows a fallback framebuffer:

| Property | Value | Meaning |
|---|---|---|
| `WhateverXeDeviceSelection` | `01000000 8680aa46 ...` | WhateverXe matched the iGPU (`8086:46AA`) |
| `WEXDisplay13BootReady` | `Yes` | Display 13 bootstrap ran |
| `WhateverXeFirmwarePanel` | 20 bytes, only field `0x09` non-zero | **no usable panel record** |
| `WhateverXeFirmwarePortRecords` | non-zero | the VBT port table **was** parsed |
| `WEXDisplay13TCBootPorts` | all zeros | **no Type-C/port routing detected** |
| `N97Admission` | `Yes` | memory/topology checks admitted the GPU |
| `N97NativePreflight` | `Yes` | preflight passed |
| `N97GTTopologyReady` | `Yes` | GGTT/stolen memory layout accepted |
| `N97NativeStartAllowed` | `No` | **the native framebuffer/accelerator start was blocked** |
| class counts | `IONDRVFramebuffer=1`, `AppleIntelFramebuffer=0`, `IntelAccelerator=0` | macOS attached the generic boot framebuffer |
| `system_profiler SPDisplaysDataType` | `VRAM (Total): 19 MB`, `Kernel Extension Info: No Kext Loaded` | consequence of the above |

`N97NativeStartAllowed` is set to `false` in WhateverXe's ADL-N/ADL-P
bootstrap (`kern_xe.cpp`, `adlnBootstrap`) and only flipped to `true` inside
the accelerator start path after every qualification succeeds. Seeing it
`No` while `N97Admission`/`N97NativePreflight` are `Yes` means the failure is
**after** memory admission and **before** the accelerator takes ownership —
consistent with display/panel qualification, not with a broken PCI device or a
wrong stolen-memory size.

The zeroed `WhateverXeFirmwarePanel` record is the strongest clue: the driver
could not find the internal panel description in the firmware VBT. With no
panel it refuses to hand the framebuffer over natively, and the boot
framebuffer stays in place.

The full `WhateverXeVBTRaw` dump shows why. The header is `$VBT
ALDERLAKE-P`, and the port table (`WhateverXeFirmwarePortRecords`) contains
real entries, so the VBT is readable and broadly parsed. But the panel-name
region is the literal placeholder string `LFP_PanelName` repeated, and the
20-byte panel record has no timings or EDID-like data. The firmware simply
does not describe the attached OLED in the form the 0.6.0 patch expects. See
[../audit/log-analysis.md](../audit/log-analysis.md) for the decoded values.

## Hypotheses, ranked

1. **The 0.6.0 `adlp-edp` patch does not recognise this unit's VBT.**
   The reference kext was built for a 13-bf0059TU on BIOS F.?? and macOS
   26.7.1. This machine runs BIOS **F.35 (2025-11-17)** and macOS **26.7.2**.
   A VBT revision change moves the panel/port records; the patch then finds
   nothing, which is exactly what the zeroed `WhateverXeFirmwarePanel` shows.
2. **Kernel ABI drift in 26.7.2.** A kext built against 26.7.1 headers can load
   but be rejected at start on 25G332. Upstream 0.6.1 was released after
   26.7.2 and explicitly targets current Tahoe.
3. **Panel batch difference.** Same resolution does not guarantee the same
   EDID/VBT entry (Samsung vs BOE). If the panel descriptor differs, a
   hard-coded patch cannot work.
4. **Configuration.** Ruled out: the graphics-relevant config sections are
   identical to the known-working reference (see
   [docs/02-audit.md](02-audit.md)).
5. **Stolen memory / DVMT.** Ruled out: `N97GTTopologyReady=Yes`,
   `N97StolenReservation` is populated, and the reference uses the same
   `0000c003` + `-igfxdvmt` pair.

## Why 0.6.1 is the next step

Upstream 0.6.1 (2026-10-27) added:

> experimental internal display (eDP) and brightness support for Alder Lake-N /
> Twin Lake and Alder Lake-H/P/U / Raptor Lake-H/P/U GPUs

and the matching Graphics 0.3.2 ships `AppleIntelTGLCompat 0.6.1`. The 0.6.1
binary contains no `-wex-adlp-edp` string at all; the feature is now automatic
and firmware-driven instead of a per-machine patch. That is precisely the
failure mode observed here.

0.6.1 also contains the 0.6.1 fix for DEBUG boot stack overflows, which matters
if we need to debug the bring-up.

## Boot arguments

| Argument | Why it is there |
|---|---|
| `-allow3d` | Allows the accelerator path to be considered |
| `-disablegfxfirmware` | Skips GuC firmware loading, which Apple's driver cannot do here |
| `-igfxdvmt` | Compensates for the BIOS's 60 MB DVMT pre-allocation |
| `keepsyms=1` | Keeps symbols in panics |
| `msgbuf=4194304` | Larger kernel log buffer for bring-up diagnostics |
| `shda-lang=en` | SimpleHDA language |
| `alcid=11` | AppleALC layout 11 (ALC245) |
| `-wex-adlp-edp` | **0.6.0 variant only** — force the ADL-P eDP path |
| `-wex-reset-restore` | **0.6.0 variant only** — restore display state after reset |
| `-wex-no-multicontext` | **0.6.0 variant only** — avoid multi-context submission on this GPU |
| `-v`, `debug=0x100` | `--debug` builds only |

Do not add `-wex-noaccel`: it deliberately disables the accelerator and would
guarantee the current 19 MB fallback.

## How to test the new variant

Upstream order matters: **boot the target macOS with the latest WhateverXe
before installing the latest graphics package.** The package updates Compat
and AuxKC; the EFI provides the matching WEX binary.

1. Copy `build/EFI` (default variant) to the ESP, replacing the old EFI. Keep
   the old EFI on a USB stick. Do **not** install the graphics package yet.
2. Boot macOS with the new EFI. The internal panel may remain on the
   software-rendered fallback at this stage; that is expected. Confirm the
   driver loaded:
   ```sh
   kmutil showloaded | grep -i whateverxe   # expect 0.6.1
   ```
3. On macOS, install **WhateverXe Graphics 0.3.2** (it replaces Compat 0.6.0
   with 0.6.1 and updates the patched Apple kexts in AuxKC):
   `WhateverXe-Graphics-0.3.2.pkg`, SHA-256
   `7ac6c7149248c483efbd93555294d587a93d81392421f3af8a4f5b1b5fcc0101`
   (see [docs/10-provenance.md](10-provenance.md)). Restart when it finishes.
4. After the restart, check acceleration. If it works, stop. If it does not:
5. Reboot the `--debug` build, let it reach the desktop, and collect:
   ```sh
   ioreg -l -p IODeviceTree > ioreg.txt
   ioreg -rc IONDRVFramebuffer -d1 > iondrv.txt
   kmutil showloaded | grep -Ei 'whateverxe|tgl' > kexts.txt
   log show --last 5m --predicate 'process == "kernel"' > kernel.log
   system_profiler SPDisplaysDataType
   ```
6. Try the fallback variant (`--gpu hp-adlp-edp`) with the same EFI otherwise.

### Success criteria

```
ioreg -rc AppleIntelFramebuffer        # count 1
ioreg -rc IntelAccelerator             # count 1
system_profiler SPDisplaysDataType     # VRAM (Total) in GB range, Metal support listed
```

and in IORegistry, `N97NativeStartAllowed = Yes`, `WhateverXeFirmwarePanel`
non-zero, `WEXDisplay13BootReady = Yes`.

### If 0.6.1 still refuses

The next diagnostic is the firmware panel record itself. Capture the VBT
(`ioreg -l | grep TGLVBT`) and the full `WhateverXeFirmwarePanel` value, then
report them to the WhateverXe issue tracker with the exact BIOS version and
panel EDID. A patch cannot be written reliably without that record.

Do **not** fall back to NootedGreen as a first move: it is a different driver
with a different GPU support matrix, and this machine's 0x46AA is not its
validated target.

## Rollback

The old working EFI is preserved at `mine/EFI` (local, not in Git). Copying it
back to the ESP and reinstalling Graphics 0.3.1 restores the exact previous
state. The display works in both states; only acceleration differs.

## Optional: disable the VA bundle

If video playback or the camera crashes, the EliteBook and XPS projects both
move Apple's video-acceleration bundle out of the way to force CPU decode:

```sh
sudo mkdir -p /Library/GPUBundles.disabled
sudo mv /Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle /Library/GPUBundles.disabled/
sudo killall UVCAssistant VTDecoderXPCService
```

This costs hardware decode. Keep it as a troubleshooting step, not a default.
