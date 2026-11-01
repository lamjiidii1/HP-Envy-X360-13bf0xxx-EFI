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

The two halves must match. **This machine uses WhateverXe 0.6.0 (the
`adlp-edp` fork) with WhateverXe Graphics 0.3.1 (`AppleIntelTGLCompat` 0.6.0).**
That is the pair in the working same-model reference. Upstream WhatheverXe
0.6.1 + Graphics 0.3.2 is a different pair and is not usable here; see below.

## What the logs show

From `LOGS/macOS_Logs_20261030_180840` (macOS 26.7.2, build 25G332):

```
kextstat: org.b00t0x.WhateverXe (0.6.0)
kextstat: org.b00t0x.AppleIntelTGLCompat (0.6.0)
kextstat: com.apple.driver.AppleIntelTGLGraphicsFramebuffer (16.0.0)  0 references
kextstat: com.apple.driver.AppleIntelTGLGraphics (16.0.0)             0 references
Boot args: ... -wex-adlp-edp ... -wex-reset-restore -wex-no-multicontext ...
```

All three pieces load, but no Apple framebuffer ever attaches to the GPU:

| Property | Value | Meaning |
|---|---|---|
| `WhateverXeDeviceSelection` | `01000000 8680aa46 ...` | WhateverXe matched the iGPU (`8086:46AA`) |
| `WEXDisplay13BootReady` | `Yes` | Display 13 bootstrap ran |
| `WEXDisplay13ComboDPReady` | `Yes` | the fixed Combo A panel route was admitted |
| `WEXDisplay13TrainingReady` | `Yes` | link-training hooks installed |
| `N97Admission` / `N97NativePreflight` | `Yes` | memory/topology checks passed |
| `N97GTTopologyReady` | `Yes` | GGTT/stolen-memory layout accepted |
| **`TGLMMIOStrongUCRouted`** | **`No`** | **the MMIO user-copy hook was not installed** |
| **`TGLMMIOStrongUCPreflight`** | **`No`** | **the MMIO mapping was never made UC** |
| `N97NativeKernelReady` | `No` | `tglActive` is false |
| `N97NativeStartAllowed` | `No` | native framebuffer/accelerator start blocked |
| `N97NativeProbeBlocked` | `Yes` | WhateverXe installed its reject-probe guard |
| class counts | `IONDRVFramebuffer=1`, `AppleIntelFramebuffer=0`, `IntelAccelerator=0` | generic boot framebuffer only |
| `SPDisplaysDataType` | 19 MB VRAM, "No Kext Loaded" | consequence of the above |

The chain is explicit in the source: `tglActive = tglVM.enabled &&
tglMMIOUCRouted && tglMMIOUCReady`. With the MMIO hook missing, `tglActive`
stays false, so `processKext()` installs
`processAlderLakeNRejectedAccelerator()` and the donor driver never starts.
The panel work (`-wex-adlp-edp`, Combo A, training) already succeeded; this is
the last gate, not a display or VBT problem.

> This table is the state **before** the MMIO patch. It is kept as the record
> of the guard failure. The patched boot now passes this gate; see
> *Where the 26.7.2 bring-up stops now* below for the current failure.

## The VBT is valid

The root collector captured the real firmware table from Linux
(`LOGS/linux-evidence-2026-10-31-133508/debugfs/1-i915_vbt`):

- `$VBT ALDERLAKE-P`, version 100, BDB version **247**, 8701 bytes;
- internal DP child `0x1806` on **DDI A** (`aux 0x40`) and on **DDI B**
  (`aux 0x10`);
- a third child `0x60d2` on DVO1 that also maps to **DDI 1** — a duplicate;
- panel block 40 has `panel_type = 0xFF`, i.e. the panel is selected by PnP ID,
  so `WhateverXeFirmwarePanel.valid = false` is **expected**, not a fault.

The file is **byte-identical** to the reference fork's own fixture
`tests/fixtures/hp-envy-x360-13-bf-vbt.bin` (SHA-256
`4d790a72…fa30c`). BIOS F.35, the VBT and the panel are therefore not the
difference between this machine and the working one.

## Why 0.6.1 is not the answer

Upstream 0.6.1 (2026-10-27) added generic eDP support, but it cannot be used
on this unit:

1. **It rejects this VBT.** 0.6.1's `kern_vbt.hpp` returns `Status::Conflict`
   on the second child for DDI 1. Only the `adlp-edp` fork keeps the first
   child per DDI (Linux semantics) and prefers DDI A. With no ports, there is
   no panel.
2. **It has no `-wex-adlp-edp`.** The option was a 0.6.0-fork feature and was
   never merged upstream.
3. **It has the same MMIO constant.** The Tahoe `protectCall` check is
   identical in 0.6.0 and 0.6.1, so it would fail on 25G332 even if the VBT
   parsed.

The 0.6.1 binary in `efi/variants/gpu-wex061` is kept only as a diagnostic
control.

## The 26.7.2 MMIO signature

`tglPrepareTahoeMMIOUC()` validates `_IOProtectCacheMode` by comparing nine
kernel byte patterns. On 25G332, eight match and only the call at
`_IOProtectCacheMode + 0xCC` differs. The published guard proves it:

```
TGLTahoeMMIOGuard = [1, 1, 0x4011000000, 0x1000000, 0x1040600070406,
                     1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, …, 0]
                                                              ^ guard[16]
```

`guard[16]` is the ninth byte match (`protect + 0xCC`); `guard[19]` is the
overall `ok`, which is zero. Everything else — the prologue, the pmap entry
sites, `kernel_map`, the PAT and the 16 MB BAR — passes.

The constant in the shipped kext is the 26.7.1 value
`E8 2F F3 02 00`. On 26.7.2 the call target moved, so the check fails even
though the function is the same.

The value appears **twice** in the kext binary, and only one copy is live:

| Offset | What it is | Referenced? |
|---|---|---|
| `0xCDF8E` | five bytes immediately before the `TGLTahoeMMIOGuard` string | no — dead data |
| `0x17907` | `imm32` of `movl $imm32,-0x58(%rbp)` at `0x17904` (`C7 45 A8 E8 2F F3 02`) | yes — the live comparison |

The next instruction, `movb $0,-0x54(%rbp)`, supplies the fifth byte, and the
`memcmp` at `0x17D7B` reads the five-byte stack array from `-0x58(%rbp)`.
Nothing loads or compares the data copy next to the string.

This distinction matters. The first version of the repair script anchored on
the string and rewrote the dead copy at `0xCDF8E`. The file hash changed and
the script reported success, but the guard after reboot was still `0x0` at
index 16. The script now finds the unique `C7 45`-prefixed immediate, requires
exactly one candidate, and rewrites only those four bytes. It also restores
the dead copy if an earlier run changed it, so every starting state converges
to the same binary.

Measured from the 25G332 KDK (`_IOProtectCacheMode` at file offset `0x19b410`,
`__TEXT` at `0xffffff8000200000`), the real bytes on this build are:

```
E8 5F F3 02 00
```

`E8` is `call rel32`; the displacement is `+0x2F35F` from the next
instruction, so the call goes to `0xffffff80003ca840`, which the KDK symbol
table names `_pmap_enter_options` — exactly the function WhateverXe resolves as
`fn` and patches at `+0x10C1`/`+0x1197`. The check therefore keeps its original
meaning; only the link-time displacement changed (26.7.1 used `+0x2F32F`, a
difference of `0x30`).

For this build, the default `WhateverXe.kext` binary goes from SHA-256
`c090b9dd35398c72e9567b38b9bb9b61415ab7fcfe22ffc78cbafc93ee67e49b`
to `d76d850e3907066df4e5facb38d8c7f2e2d7a4b5ab574ad1102acee8382f7787`
when patched for 25G332. (The intermediate hash `7fab9aa3…` from the first
attempt is **not** a valid result: it has the wrong byte patched.) The kernel
file extracted from
`Kernel_Debug_Kit_26.7.2_build_25G332.dmg` reports the same version string as
the running kernel (`root:xnu-12377.161.15.701.48~2/RELEASE_X86_64`) and has
SHA-256 `a91aad0da9d0a2f545c06859524bb048f4e2e392e46aa12da9fabe652081be53`,
so the bytes read from it apply to the booted kernel.

## The fix

`scripts/macos/patch-wex-tahoe-mmio.sh` reads the real five bytes from the
kernel Mach-O and replaces the stale four-byte immediate in the injected
WhateverXe binary. It keeps a `.orig` backup, matches the unique
`C7 45`-prefixed initialiser rather than the dead data copy, and does not touch
the kernel or the installed graphics package.

The system kernel on disk is usually stripped, so the script needs the
**Kernel Debug Kit for this exact macOS build** (25G332 here). The KDK provides
`_IOProtectCacheMode` with symbols; the script parses that Mach-O with perl,
so Xcode Command Line Tools, `nm` and `otool` are **not** needed.

```sh
# On macOS, with the ESP mounted at /Volumes/EFI:
ls /Library/Developer/KDKs/          # KDK_26.7.2_25G332.kdk expected

sudo ./scripts/macos/patch-wex-tahoe-mmio.sh \
  --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext \
  --kernel /Library/Developer/KDKs/KDK_26.7.2_25G332.kdk/System/Library/Kernels/kernel
sudo reboot
```

Without `--kernel` the script searches the KDK directories and the system
kernel paths and prints the candidate paths it tried. It prints the old and new
signatures, the kext SHA-256 before and after, then verifies the patched bytes.
`--dry-run` only reports; `--restore` puts the backup back.

If the script prints nothing at all, it exited before patching: update to this
version, because the older one depended on `nm` from the Command Line Tools and
could stop silently when that prompt was cancelled. If it reports
`patched`/`verify: e85ff302` but `guard[16]` is still `0` after the reboot,
check the two things in [docs/08-troubleshooting.md](08-troubleshooting.md):
the on-disk bytes at `0x17907`, and which ESP OpenCore actually booted.

This is a local binary change to an OpenCore-injected kext, not to a signed
system extension. Keep the backup; if the machine behaves worse, restore it
and boot the old EFI.

### Verify after the reboot

```sh
ioreg -l | grep -E 'TGLMMIOStrongUC|TGLTahoeMMIOGuard'
ioreg -l | grep -E 'N97Native(StartAllowed|KernelReady|ProbeBlocked)'
ioreg -rc AppleIntelFramebuffer        # count 1
ioreg -rc IntelAccelerator             # count 1
system_profiler SPDisplaysDataType     # GB-range VRAM, Metal support
```

Success looks like `TGLMMIOStrongUCRouted = Yes`,
`TGLMMIOStrongUCPreflight = Yes`, `N97NativeStartAllowed = Yes`,
`N97NativeKernelReady = Yes`, `N97NativeProbeBlocked` absent or `No`. In
`TGLTahoeMMIOGuard`, the ninth byte pattern (index 16) must now be `1`; if it
is still `0`, the firmware loaded an unpatched kext — check that you patched
the ESP OpenCore actually booted.

If `UCRouted` becomes `Yes` but `UCPreflight` stays `No`, the pmap check found
a different mapping; collect the new `TGLMMIOMappingEvidence` blob and stop.

## Where the 26.7.2 bring-up stops now (2026-11-01)

The corrected MMIO patch works, and the boot captured in
`LOGS/macOS_Logs_20261031_191812` runs further than the table at the top of
this document. The chain, in order:

| Time | Event |
|---|---|
| 19:13:49.042 | `IntelAccelerator::probe`: device `0x46aa8086`, revision `0xc` |
| 19:13:49.419 | TGL HWCAPS, host-preemptive scheduler, multi-context disabled |
| 19:13:49.450 | `IntelAccelerator` published |
| 19:13:50.44 | framebuffer `start`; Combo A AUX reads OK; AGDP `Framebuffer` events |
| 19:14:01.18 | AGDP validates 2880 x 1800 at 329.63 MHz (8 bpc accepted) |
| 19:14:02–38 | `FB0: This fb does not have FB memory`, `FB has no memory allocated, err = 0xe00002bc`, `Surface mode contains bad bits`, `Flip called without enabling VBL` |
| 19:14:38.49 | WindowServer tears down its virtual display; loginwindow and SecurityAgent exit |
| 19:14:38.68 | `kAGDCRegisterLinkModesetCallback`: FB0 -> 2880 x 1800, 329630000 Hz |
| 19:15:47 | next boot (safe mode) |

The old `guard[16]`/`UCPreflight` gate and the accelerator probe are resolved.
The failure is now in the framebuffer/WindowServer hand-off: FB0 has no scanout
memory, accelerated surfaces are rejected, the VBL enable is lost, and the
session dies at the first modeset. There is no panic and no WhateverXe message:
the last kernel line is the AGDP modeset callback itself.

WhateverXe 0.6.0 already contains the fork's fixes for these exact messages
(patches 18, 21 and 22 replay the dropped VBL request and treat an empty
aperture as "not ready"). Their presence does not prove the path ran. The live
properties are the only way to see which check refused the mapping:

```
N97FBApertureNotReady, N97FBApertureFirstFailure, N97FBMemory,
N97FBScanoutAllocate, N97FBBinding, N97FBBacking
```

The 2026-10-31 capture was taken in safe mode, so it contains none of them. A
black-screen boot cannot be typed into, so use the boot-capture daemon in
[docs/08-troubleshooting.md](08-troubleshooting.md#9-capturing-a-boot-that-dies-with-a-black-screen)
to record them at 25 s, 65 s and 110 s after boot.

Two separate findings in the same boot:

- `MTLCompilerService` is sandbox-denied `file-read-data` and
  `file-map-executable` for
  `/Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/adapter.dylib`
  and `libigc-tgl.dylib`. Metal shader compilation cannot work until that
  bundle is visible to the service. Fix it after the display is up.
- `AppleIntelTGLCompat` logs `revision 0.5.0 started` while `kextstat` reports
  package 0.6.0. That is the internal ABI string, not a package mismatch.

## Fallback: stay on 26.7.1

The same kext, same Graphics 0.3.1 and same VBT are proven to give Metal on
macOS 26.7.1 (25G241). If the signature patch does not unlock the accelerator,
the reliable path is a 26.7.1 install (back up first; macOS does not install
an older build over a newer one). Do not combine 26.7.1 with a 0.6.1 EFI.

## Boot arguments

| Argument | Why it is there |
|---|---|
| `-allow3d` | Allows the accelerator path to be considered |
| `-disablegfxfirmware` | Skips GuC firmware loading, which Apple's driver cannot do here |
| `-igfxdvmt` | Compensates for the BIOS's 64 MB DVMT pre-allocation |
| `keepsyms=1` | Keeps symbols in panics |
| `msgbuf=4194304` | Larger kernel log buffer for bring-up diagnostics |
| `shda-lang=en` | SimpleHDA language |
| `alcid=11` | AppleALC layout 11 (ALC245) |
| `-wex-adlp-edp` | Force the ADL-P eDP path (0.6.0 fork only) |
| `-wex-reset-restore` | Restore display/render state after a GPU reset |
| `-wex-no-multicontext` | Avoid the second compute ring that deadlocks on recovery |
| `-v`, `debug=0x100` | `--debug` builds only |

Do not add `-wex-noaccel`: it deliberately disables the accelerator and would
guarantee the 19 MB fallback.

## Install order

1. Boot the target macOS with this EFI **before** changing the graphics
   package. The panel may stay on the software fallback; that is expected.
2. Confirm the injected kext:
   ```sh
   kmutil showloaded | grep -i whateverxe    # expect 0.6.0
   ```
3. If `AppleIntelTGLCompat` is not 0.6.0, install **WhateverXe Graphics
   0.3.1** (not 0.3.2) and restart. 0.3.1 is the package tested with the
   `adlp-edp` fork.
4. Apply the 26.7.2 signature patch (above) and restart.
5. Check acceleration with the commands in *Verify after the reboot*.

## Rollback

The previous EFI is preserved at `mine/EFI` (local, not in Git). Copying it
back to the ESP restores the exact previous state. The display works in both
states; only acceleration differs. Reinstalling Graphics 0.3.1 restores the
matching Compat/patched Apple kexts.

## Optional: disable the VA bundle

If video playback or the camera crashes, the EliteBook and XPS projects both
move Apple's video-acceleration bundle out of the way to force CPU decode:

```sh
sudo mkdir -p /Library/GPUBundles.disabled
sudo mv /Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle /Library/GPUBundles.disabled/
sudo killall UVCAssistant VTDecoderXPCService
```

This costs hardware decode. Keep it as a troubleshooting step, not a default.
