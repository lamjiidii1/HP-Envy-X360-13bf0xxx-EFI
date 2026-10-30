# Log analysis

The machine's macOS logs show a complete, loaded driver stack that stops at
panel qualification. This document extracts the evidence, separates what it
proves from what it only suggests, and lists the data needed for the next
experiment.

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
| `WhateverXeFirmwarePanel` | `00000000 00000000 09000000 00000000 00000000` | **no usable panel record** |
| `WhateverXeFirmwareChecksum` | `0` | no checksum value reported |
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

`WhateverXeVBTRaw` is a full VBT dump. Two features matter:

1. The header is `$VBT ALDERLAKE-P`, i.e. the firmware VBT is present and the
   driver can read it.
2. In the panel-name region the dump contains the literal ASCII string
   `LFP_PanelName` repeated for hundreds of bytes, instead of a panel model
   string. The `WhateverXeFirmwarePanel` record itself is 20 bytes with a
   single non-zero 32-bit field (`0x09`) at offset 8 — no timings, no EDID-like
   payload, no port mapping.

The port table is different: `WhateverXeFirmwarePortRecords` contains entries
for several ports (including the `0x0D`–`0x11` range). So the driver parsed the
VBT's general structure; it is specifically the **internal panel descriptor**
that is empty/placeholder.

This is consistent with a BIOS VBT that does not describe the attached OLED
panel in the way the 0.6.0 `adlp-edp` patch expects. It is not consistent with
"the VBT is unreadable" or "the driver never ran".

## 5. Interpretation

The sequence the properties describe is:

```
PCI match                         OK  (DeviceSelection)
memory / GGTT admission           OK  (Admission, Preflight, GTTopologyReady)
stolen reservation                OK  (StolenReservation, NativeReservedGGTT)
display-13 bootstrap              OK  (BootReady, ComboDPReady, TrainingReady)
firmware panel record             EMPTY / PLACEHOLDER
native start                      BLOCKED (NativeStartAllowed=No,
                                           NativeKernelReady=No,
                                           NativeProbeBlocked=Yes)
```

That is a **display/panel qualification failure**, not a PCI, memory or kext
loading failure. The boot framebuffer (`IONDRVFramebuffer`) stays attached
because the native framebuffer never takes ownership, which in turn is why the
accelerator (`IntelAccelerator`) is never created and VRAM reports 19 MB.

### What this rules out

| Hypothesis | Why it is ruled out |
|---|---|
| The iGPU is not matched | `WhateverXeDeviceSelection` contains `8086:46AA` |
| Stolen memory / DVMT is wrong | `N97GTTopologyReady=Yes`, `N97NativeReservedGGTT=Yes`, `N97StolenReservation` populated |
| WhateverXe did not load | `kextstat` shows 0.6.0; bring-up properties exist |
| AMFI blocked the patched drivers | Compat is loaded and marked loadable |
| The config is wrong | Graphics-relevant config is identical to the working reference; see [config-diff.md](config-diff.md) |
| The panel is simply not connected | `WEXDisplay13BootReady=Yes`; the boot framebuffer drives 2880×1800 |

### What it supports

1. **The 0.6.0 `adlp-edp` patch does not recognise this unit's VBT.** The
   panel record is a placeholder, and the patch is a per-machine hard-coded
   set of panel/port assumptions built for the reference unit.
2. **The BIOS/macOS pair is different from the reference.** Reference:
   26.7.1/F.??; this unit: 26.7.2/F.35. Either the VBT changed (panel record)
   or the kernel ABI shifted, or both. The VBT evidence points at the former;
   the macOS point release remains a secondary suspect.
3. **0.6.1 is the right next experiment.** Its release notes add generic
   ADL-P/U eDP panel detection and brightness support, and the
   `-wex-adlp-edp` string no longer exists in the binary — the logic is
   firmware-driven instead of a per-machine patch.

### What it does not prove

- That 0.6.1 will succeed. ADL-P eDP support in 0.6.1 is described upstream as
  experimental/not yet hardware-tested on every panel.
- That the panel is a specific model. The logs contain no usable EDID from the
  internal panel; the 2880×1800 resolution comes from the boot framebuffer.
- That the Type-C port table being zero is a fault. On this laptop no external
  display is wired through the iGPU's Type-C path; all-zero can be normal.

## 6. Next capture (0.6.1 + Graphics 0.3.2)

After installing Graphics 0.3.2 and booting the `wex061` variant, capture the
same bundle plus:

```sh
ioreg -l | grep -E 'WhateverXe(VBTRaw|FirmwarePanel|FirmwareChecksum|FirmwarePortRecords)'
ioreg -l | grep -E 'N97(NativeStartAllowed|NativeKernelReady|NativeProbeBlocked|Admission|NativePreflight|GTTopologyReady)'
ioreg -l | grep -E 'WEXDisplay13(TCBootPorts|TCHooksReady|BootReady)'
ioreg -rc AppleIntelFramebuffer
ioreg -rc IntelAccelerator
system_profiler SPDisplaysDataType
```

Decision table:

| Observation | Meaning | Next step |
|---|---|---|
| `NativeStartAllowed=Yes`, AIFB/Accelerator ≥ 1 | fixed | record success, keep 0.6.1 |
| Panel record still placeholder, start still `No` | 0.6.1 did not solve panel detection | try `hp-adlp-edp` + Graphics 0.3.1 to confirm the machine can still accelerate at all |
| Panel record non-zero but start `No` | later stage fails (framebuffer/accelerator) | capture `N97NativeKernelReady` and the last `[IGFB]` lines |
| Both variants fail identically | firmware/panel or macOS ABI | report upstream with VBT + EDID; do not keep swapping kexts |

If the `hp-adlp-edp` variant works, the regression is isolated to 0.6.1's eDP
path and the machine has a usable fallback. If neither works, the problem is
below the driver variant and the VBT/EDID report is the only productive route.

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
`kmutil` rebuilding the AuxKC several times), and it still reports an empty
panel record. That rules out "the package installed incorrectly" as the cause
of the fallback and reinforces that the difference is in the driver version
and the firmware/macOS pair, not in the installation procedure.
