# Log analysis

The machine's macOS logs show a complete, loaded driver stack that stops at a
single kernel-signature check in WhateverXe's Tahoe MMIO-UC path. This document
extracts the evidence, separates what it proves from what it only suggests, and
lists the data needed for the next experiment.

The logs are local (`LOGS/`, gitignored). They contain the SMBIOS identity, so
they are not committed. The extracts below keep only graphics properties.

## 1. Environment

| Item | Value | Source |
|---|---|---|
| macOS | 26.7.2 (25G332) | `sw_vers.txt` |
| Kernel | Darwin 25.6.0, `xnu-12377.161.15.701.48~2/RELEASE_X86_64` | `sw_vers.txt` |
| BIOS | F.35 (2025-11-17) | firmware / `docs/01-hardware.md` |
| iGPU | `8086:46AA`, rev `0x0C` | `sp_displays.txt`, ioreg |
| Panel | 2880×1800 OLED over eDP | `sp_displays.txt` |
| Boot set | WhateverXe 0.6.0 + Graphics 0.3.1 (Compat 0.6.0) | `kextstat_third_party.txt` |
| Captures | 2026-10-29 22:36 and 2026-10-30 18:08 | folder names |

Two independent captures show the same state, so this is not a one-boot
glitch.

## 2. What loaded

Relevant lines from `kextstat_third_party.txt`:

```
org.b00t0x.WhateverXe (0.6.0)
org.b00t0x.AppleIntelTGLCompat (0.6.0)
as.vit9696.Lilu (1.7.2)
com.dhinakg.AMFIPass (1.4.1)
```

`WhateverXe.kext` is injected by the EFI. `AppleIntelTGLCompat` is in the
AuxKC and reports:

```
AppleIntelTGLCompat: revision 0.5.0 started, physical-owner/binding selection
```

The internal revision string is `0.5.0` even for the 0.6.0 bundle; do not use
it to decide which Compat is installed. Use the bundle version from
`kextstat`.

The kernel log also shows the AuxKC being rebuilt and the bundle becoming
loadable:

```
KextLog: AuxKC bundle org.b00t0x.AppleIntelTGLCompat marked as loadable
```

So AMFI/AMFIPass and the AuxKC path are working. The failure is after load.

`AppleIntelTGLGraphicsFramebuffer` logs:

```
[IGFB][WARN][BRINGUP] Remove this when no loner needed (nvram values persist)
```

That is an upstream diagnostic message, not an error. It means the patched
framebuffer ran its bring-up path and persisted state in NVRAM.

## 3. IORegistry: the decisive properties

From `ioreg_full.txt`, iGPU node:

| Property | Value | Reading |
|---|---|---|
| `WhateverXeDeviceSelection` | `01000000 8680aa46 0c000000 8680aa46 05000000 0d000000 06000000 01000000` | vendor `0x8086`, device `0x46AA`, rev `0x0C` selected — PCI match is correct |
| `N97Admission` | `Yes` | memory admission passed |
| `N97NativePreflight` | `Yes` | preflight passed |
| `N97GTTopologyReady` | `Yes` | GGTT/stolen layout accepted |
| `N97NativeReservedGGTT` | `Yes` | reservation taken |
| `N97StolenReservation` | non-zero | stolen memory reserved |
| `N97GTStep` | `unknown` | bring-up did not reach a named stage |
| `N97NativeStartAllowed` | **`No`** | native start blocked |
| `N97NativeKernelReady` | **`No`** | kernel-side bring-up not complete |
| `N97NativeProbeBlocked` | **`Yes`** | probe was explicitly blocked |
| `N97DisplayReadoutStatus` | `1` | display readout ran |
| `N97DisplayStep` | `unknown` | no named display stage |
| `WEXDisplay13BootReady` | `Yes` | display-13 bootstrap ran |
| `WEXDisplay13TCBootPorts` | all zero | no Type-C boot ports |
| `WEXDisplay13TCHooksReady` | `No` | TC hooks not installed |
| `WEXDisplay13ComboDPReady` | `Yes` | combo-PHY path prepared |
| `WEXDisplay13TrainingReady` | `Yes` | training hooks prepared |
| `WEXADLPPanelDP` | `01000000 01000000 01000000 …` | panel-DP flags present, not a full descriptor |
| `TGLMMIOStrongUCRouted` | **`No`** | **the MMIO user-copy hook was not installed** |
| `TGLMMIOStrongUCPreflight` | **`No`** | **the MMIO mapping was never made UC** |
| `TGLTahoeMMIOGuard` | `01 01 0x4011000000 0x1000000 0x1040600070406 1… 0 … 0` | index 16 (the `_IOProtectCacheMode+0xCC` byte match) is the only failure; index 19 (`ok`) is 0 |
| `WhateverXeFirmwarePanel` | `00000000 00000000 09000000 00000000 00000000` | `panel_type = 0xFF`: the panel is selected by PnP ID, so no inline panel record is **expected** |
| `WhateverXeFirmwareChecksum` | `0` | firmware does not publish a matching table checksum; WhateverXe admits by structure, like i915 |
| `WhateverXeFirmwarePortRecords` | long, non-zero | port table **was** parsed |
| `WhateverXeVBTRaw` | starts `24564254 20414c44 45524c41 4b452d50` | `$VBT ALDERLAKE-P` |
| `WhateverXeBacklightProfileReady` | `Yes` | backlight profile available |
| `WhateverXeDataAccess` | `Yes` | data-access hooks installed |

Class counts from the same capture:

```
IONDRVFramebuffer      1
AppleIntelFramebuffer  0
IntelAccelerator       0
```

`system_profiler SPDisplaysDataType`:

```
Chipset Model: Intel Iris Xe Graphics
VRAM (Total): 19 MB
Kernel Extension Info: No Kext Loaded
Resolution: 2880 x 1800
```

## 4. The VBT

The logs contain the raw table (`WhateverXeVBTRaw`). The same table was later
captured from Linux at `/sys/kernel/debug/dri/*/i915_vbt`; all three captures
are byte-identical (`4d790a72…fa30c`, 8704 bytes).

It parses as:

- `$VBT ALDERLAKE-P`, version 100, BDB version **247**, size 8701 bytes;
- internal DP child `0x1806` on **DDI A** (`aux 0x40`) and on **DDI B**
  (`aux 0x10`);
- a third child `0x60d2` on DVO1 that also resolves to **DDI 1** — a duplicate
  DDI, which Linux resolves by keeping the first entry;
- panel block 40 with `panel_type = 0xFF` (panel chosen by PnP ID). That is
  why `WhateverXeFirmwarePanel.valid` is false and why the record is
  `00…00 09 00…00`: the placeholder is **expected**, not a missing panel.

The file is byte-identical to the reference fork's own fixture
`tests/fixtures/hp-envy-x360-13-bf-vbt.bin`. BIOS F.35, the VBT and the panel
are therefore not the difference between this machine and the working one.

The `LFP_PanelName` strings in the raw dump are firmware placeholders, not data
WhateverXe reads. Do not chase them.

## 5. Interpretation

The sequence the properties describe is:

```
PCI match                         OK  (DeviceSelection)
memory / GGTT admission           OK  (Admission, Preflight, GTTopologyReady)
stolen reservation                OK  (StolenReservation, NativeReservedGGTT)
VBT parse and panel qualification OK  (VBT valid; panel_type 0xFF expected)
display-13 bootstrap              OK  (BootReady, ComboDPReady, TrainingReady)
Tahoe MMIO-UC signature check     FAIL (guard[16]=0, TGLMMIOStrongUCRouted=No)
native start                      BLOCKED (NativeStartAllowed=No,
                                           NativeKernelReady=No,
                                           NativeProbeBlocked=Yes)
```

That is a **kernel-signature failure on macOS 26.7.2**, not a display, VBT,
PCI, memory or kext-loading failure. The source chain is explicit:

```
tglActive = tglVM.enabled && tglMMIOUCRouted && tglMMIOUCReady
```

With `tglMMIOUCRouted = No`, `tglActive` stays false, so the driver installs
`processAlderLakeNRejectedAccelerator()` and blocks the native probe. The boot
framebuffer (`IONDRVFramebuffer`) stays attached, the accelerator
(`IntelAccelerator`) is never created, and VRAM reports 19 MB.

### What this rules out

| Hypothesis | Why it is ruled out |
|---|---|
| The iGPU is not matched | `WhateverXeDeviceSelection` contains `8086:46AA` |
| Stolen memory / DVMT is wrong | `N97GTTopologyReady=Yes`, `N97NativeReservedGGTT=Yes`, `N97StolenReservation` populated |
| WhateverXe did not load | `kextstat` shows 0.6.0; bring-up properties exist |
| AMFI blocked the patched drivers | Compat is loaded and marked loadable |
| The config is wrong | Graphics-relevant config is identical to the working reference; see [config-diff.md](config-diff.md) |
| The panel is not connected | `WEXDisplay13BootReady=Yes`; the boot framebuffer drives 2880×1800 |
| The VBT is malformed or panel-less | It is byte-identical to the reference fixture; `panel_type=0xFF` explains the empty panel record |
| 0.6.1 would fix it | 0.6.1 returns `Status::Conflict` on the duplicate DDI and carries the same MMIO constant |

### What it supports

1. **The difference from the reference is the macOS build.** The reference runs
   26.7.1 (25G241); this unit runs 26.7.2 (25G332). Eight of the nine
   `_IOProtectCacheMode` patterns still match; only the `+0xCC` call moved.
   On 25G332 those bytes are `E8 5F F3 02 00`, and the displacement resolves to
   `_pmap_enter_options` — the same function WhateverXe resolves as `fn` and
   patches at `+0x10C1`/`+0x1197`. The 26.7.1 constant (`+0x2F32F`) and the
   25G332 one (`+0x2F35F`) differ by `0x30`, a link-time layout change.
2. **The fix is one four-byte immediate.** The kext stores the constant twice:
   a dead five-byte copy at `0xCDF8E` (immediately before the
   `TGLTahoeMMIOGuard` string, with no code or pointer reference) and the live
   `imm32` at `0x17907`, inside `movl $imm32,-0x58(%rbp)` at `0x17904`. The
   `memcmp` at `0x17D7B` reads that stack array. `scripts/macos/patch-wex-tahoe-mmio.sh`
   reads the real call from the kernel on the machine and rewrites the live
   four bytes; it requires exactly one `C7 45`-prefixed candidate. The 25G332
   KDK kernel was checked against the running build: both report
   `root:xnu-12377.161.15.701.48~2/RELEASE_X86_64`.
   The first attempt (hash `7fab9aa3…`) anchored on the string and patched the
   dead copy; the guard stayed at `0`, which confirms the distinction. The
   corrected binary is `d76d850e…`.
3. **A downgrade to 26.7.1 is the guaranteed fallback.** The same kext, same
   Graphics 0.3.1 and same VBT are proven there.

### What it does not prove

- That patching the signature is sufficient. `tglMMIOUCReady` also depends on
  the pmap mapping check; the old capture shows the mapping probes at
  `0x2510/0x190030/0xFFF000` never ran because routing failed first.
- That the panel will then light at native resolution on 26.7.2. That needs a
  boot and an ioreg capture after the patch.

## 6. Next capture (patched 0.6.0 + Graphics 0.3.1)

Run the signature patch, reboot, and capture the same bundle plus:

```sh
sudo scripts/macos/patch-wex-tahoe-mmio.sh \
  --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext \
  --kernel /Library/Developer/KDKs/KDK_26.7.2_25G332.kdk/System/Library/Kernels/kernel
sudo reboot

ioreg -l | grep -E 'TGLMMIOStrongUC|TGLTahoeMMIOGuard|TGLMMIOMappingEvidence'
ioreg -l | grep -E 'N97(NativeStartAllowed|NativeKernelReady|NativeProbeBlocked)'
ioreg -rc AppleIntelFramebuffer
ioreg -rc IntelAccelerator
system_profiler SPDisplaysDataType
```

Decision table:

| Observation | Meaning | Next step |
|---|---|---|
| `UCRouted=Yes`, `UCPreflight=Yes`, `StartAllowed=Yes`, AIFB/Accelerator ≥ 1 | fixed | record success; fold the corrected constant into the default variant |
| `UCRouted` stays `No`, `TGLTahoeMMIOGuard` still shows another zero | the booted ESP has an unpatched or wrongly patched kext, or the kernel differs from what the script expects | verify `0x17907`=`e85ff302` and `0xCDF8E`=`e82ff30200` on that ESP; then collect the guard and the build number |
| `UCRouted=Yes` but `UCPreflight=No` | pmap mapping check failed | collect the new `TGLMMIOMappingEvidence`; do not change DVMT/SMBIOS |
| `UCRouted=Yes`, `Preflight=Yes`, `StartAllowed` still `No` | a later gate blocks the probe | capture `N97NativeKernelReady`, `N97DisplayStep`, the last `[IGFB]` lines |
| Patch cannot be applied (no `_IOProtectCacheMode` in the kernel) | no KDK/kernel symbols on the machine | install the matching Kernel Debug Kit or downgrade to 26.7.1 |

Do not re-test 0.6.1 on this unit: the VBT conflict is deterministic and the
MMIO constant is the same.

## 7. Reproducing this analysis

```sh
# Where the bundle lives (local only)
ls LOGS/macOS_Logs_*/

# Loaded graphics drivers
grep -Ei 'whateverxe|tgl' LOGS/macOS_Logs_*/kextstat_third_party.txt

# Decisive properties
grep -oE '"(N97|WEX|WhateverXe)[A-Za-z0-9]*" = [^;]*' \
  LOGS/macOS_Logs_*/ioreg_full.txt | sort -u

# Class counts
grep -c 'class IONDRVFramebuffer'    LOGS/macOS_Logs_*/ioreg_full.txt
grep -c 'class AppleIntelFramebuffer' LOGS/macOS_Logs_*/ioreg_full.txt
grep -c 'class IntelAccelerator'     LOGS/macOS_Logs_*/ioreg_full.txt

# The VBT and the panel record
grep -oE '"WhateverXe(VBTRaw|FirmwarePanel|FirmwarePortRecords|FirmwareChecksum)" = [^;]*' \
  LOGS/macOS_Logs_*/ioreg_full.txt
```

`plutil`/`PlistBuddy` are not needed; the properties are plain text in the
`ioreg -l` dump.

## 8. Note on the two captures

Both captures are the same EFI and the same installed package. The second one
was taken after the Graphics package was reinstalled (the kernel log shows
`kmutil` rebuilding the AuxKC several times), and it still reports the same
MMIO failure and the same expected empty panel record. That rules out "the
package installed incorrectly" as the cause of the fallback: the difference is
the macOS build, not the installation procedure.

## 9. 2026-10-31 patched boot: gate cleared, session dies at the first modeset

`LOGS/macOS_Logs_20261031_191812/kernel_last_20m.log` (lines 7–5944) is the
first normal boot with the corrected MMIO immediate. It answers the previous
section and opens a new one:

| Evidence | Reading |
|---|---|
| `IntelAccelerator::probe` at 19:13:49.042, HWCAPS and host-preemptive scheduler at 19:13:49.42, `IntelAccelerator` published at 19:13:49.45 | the guard, the UC routing and the preflight passed; the accelerator starts |
| AGDP validates 2880 x 1800 at 329.63 MHz at 19:14:01.18 (8 bpc accepted) | the panel mode is described and accepted |
| 19:14:02–38: `FB0: This fb does not have FB memory`, `FB has no memory allocated, err = 0xe00002bc`, `Surface mode contains bad bits`, `Flip called without enabling VBL` | FB0 has no scanout memory; IOAccel surfaces are rejected, so every flip fails |
| WindowServer deallocates its virtual display at 19:14:38.49; loginwindow/SecurityAgent exit | the graphics session dies at the first modeset |
| `kAGDCRegisterLinkModesetCallback` 2880 x 1800 at 19:14:38.68 | last kernel message; no panic, no WEX log |
| `LOGS/macOS_Logs_20261031_184517` has zero FB-memory errors | this failure mode appears only after the accelerator starts, not before the patch |

The messages are not new to this fork: patches 18, 21 and 22 exist precisely
for them. Hence the binary is not obviously missing the fix; the question is
which live check refuses the scanout memory. A safe-mode `ioreg` cannot answer
that (WEX stays passive and publishes no `TGL*`/`N97FB*` keys). The capture must
come from a normal boot, before WindowServer dies.

Decision table for the next capture:

| Observation | Meaning | Next step |
|---|---|---|
| heartbeat stops before `t000/summary.txt` exists | the kernel or the disk I/O died in the daemon's first second | isolate with `-wex-noaccel`, then `-wex-display13-offline` |
| `t000/` exists, heartbeat stops before `t003/` | the first framebuffer/accelerator read hangs inside the FB path | `run.log` names the hung command; boot `-wex-noaccel` |
| heartbeat stops between two snapshots | deadlock at/after the first modeset | compare `t000/ioreg_wex.txt`; focus on the display pipe, not the accelerator probe |
| heartbeat reaches `DONE` | kernel alive; only WindowServer died | follow FB memory and IOAccel surface creation |
| `N97FBApertureNotReady` present, `N97FBApertureFirstFailure`=0 | aperture deferred because the range was empty | check `N97FBScanoutAllocate`: if it never appears, allocation never ran |
| `N97FBApertureFirstFailure` non-zero or `N97FBMemory` faulted | a real validation failure, not deferral | compare the pool layout with `Display13FBMemory::poolLayout` invariants |
| `TGLMMIOStrongUCPreflight = No` | the pmap check refused the mapping | collect `TGLMMIOMappingEvidence`; the pgtable/NX attributes are the suspect |

### 9.1 The 21:00 capture produced no dump at all

The first real run of the daemon (2026-11-01, `wex-capture-20261101-210027`)
left only:

```
2026-11-01 21:00:27 uptime=0 load= 5.58 1.32 0.47
2026-11-01 21:00:33 uptime=0 load= 5.21 1.31 0.48
```

and nothing else: no `first/` directory, no `second/`, no `DONE`. Two facts
follow:

- The daemon definitely started, mounted the stick and wrote to it, so the
  capture channel works and `/Volumes/MACUSB` appears early in boot. The
  failed LOGS boot reached AGDP at ~+18 s, so the process survived past the
  accelerator probe.
- With `FIRST_DELAY=25` the old script had no dump before the point where the
  heartbeat stopped (~6 s). That is why the run is empty.

At the time it was not known whether the kernel wedged (the second heartbeat
line was written at +6 s and the third, at +11 s, never was) or whether the
process was killed while the machine stayed alive until its own reset. §9.2
answers it: neither. The dumps did run, the heartbeat writes failed, and the
reset was the daemon's own.

`uptime=0` in both lines is the other bug: `sysctl -n kern.boottime` was parsed
with `sed 's/.*sec = \([0-9]*\).*/\1/'`, which yields `0` for the
`{ sec = 1762…, usec = … } 2026-…` form. The heartbeat no longer calls `sysctl`
at all; it reports `$SECONDS` plus a wall-clock `date` every ten beats.

The capture daemon in
[docs/08](../docs/08-troubleshooting.md#9-capturing-a-boot-that-dies-with-a-black-screen)
produces these dumps without a working screen.

### 9.2 The 21:22 capture: the kernel is fine, the display hand-off is not

`wex-capture-20261101-212217` is the first normal boot recorded from inside
macOS. Its `run.log` shows 136 s of healthy operation: 135 heartbeats, `t000`
at 14 s, `t120` complete, `DONE` at 136 s. The reboot that ended the run was
the daemon's `shutdown -r now`, not a firmware reset. **The kernel does not
wedge and the machine never resets by itself.**

The daemon's own `daemon.log`, copied to the stick, also explains §9.1: the
21:00 run *did* finish all three dumps, but every heartbeat write after the
second line failed with `No such file or directory` on the stick while the
dumps into the same directory succeeded. The volume was still there; the
message is a FAT32/macOS `msdos` write failure, not a dead process. A later
attempt (`--volume MACUSB 1`) never found a volume at all, because the
installer had written that literal label into the script.

State at 120 s (`t120/ioreg_full.txt`, `t120/kernel.txt`):

| Evidence | Reading |
|---|---|
| `IntelAccelerator::probe` 21:22:17.162, published 21:22:17.553 | the accelerator starts on the patched MMIO constant |
| `N97NativeStartAllowed = Yes`, `N97NativeKernelReady = Yes`, `N97FBManagersBound = Yes`, `TGLMMIOStrongUCPreflight = Yes` | no gate is refusing; the earlier hypotheses are dead |
| `N97FBApertureNotReady` = 2-entry record, `N97FBMemory` = configured/enabled, `N97FBScanoutAllocate` and `ScanoutMemoryOwner` carry live pointers | the aperture/scanout path ran and produced memory |
| `AppleBacklightDisplay` present, EDID `4c83:4166`, brightness 17497 | the panel is detected and the backlight is set |
| 21:22:28.711 plane update, 21:22:29.762 scaler update | partial modesets succeed |
| 21:22:28.95 `IOAccelLegacySurface::set_id_mode`: `Surface mode contains bad bits` | the accelerated scanout surface is rejected |
| 21:22:30.834 `FB0: Flip called without enabling VBL` | the first flip has no VBL — the dropped enable the reference documents |
| 21:22:30.232 WindowServer `com.apple.VirtualDisplay`, "Can't run fallback without surface" | WindowServer stops trying to drive the panel |
| 21:22:33.714 `This fb does not have FB memory`, `err = 0xe00002bc` | consequence: by the next modeset the FB has lost its memory |

Nothing implicates DVMT, the MMIO gate or the accelerator probe. The missing
piece is the display hand-off: a dropped vertical-blank enable, which is the
fix the same-model reference lists as *"Frame flips failing, picture stuck"*,
and which the later patch series (49-54) of the same `adlp-edp` branch
carries.

`system_profiler SPDisplaysDataType` in `t120` lists the Iris Xe with 1536 MB
and Metal 2 but no `Displays:` section — consistent with WindowServer having
fallen back to a virtual display.

Two side findings:

- `MTLCompilerService` is denied read/map of
  `XeCompilerAdapter.bundle/.../adapter.dylib` and `libigc-tgl.dylib`. Metal
  shader compilation is a separate failure from the framebuffer one.
- `AppleIntelTGLCompat` prints `revision 0.5.0` while the package is 0.6.0;
  this is the internal ABI string, not a mixed installation.
