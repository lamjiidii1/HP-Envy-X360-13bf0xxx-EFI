# 02 — Audit: previous EFI, references, and decisions

This document records what was inspected, what was found, and why the new EFI
differs from the old one. It is intentionally repetitive with the Git history:
the point is that every change can be traced to a finding.

## 1. The previous EFI (`mine/`, local only)

The old EFI was treated as **read-only evidence**. It is not the base of this
repository. It lives in the workspace as `mine/` and is excluded from Git
because `config.plist` contains the machine's activation identity.

### Identity to preserve

| Key | Value (kept out of Git) |
|---|---|
| `SystemProductName` | `MacBookPro16,2` |
| `SystemSerialNumber` | redacted — in `private/identity.plist` |
| `MLB` | redacted — in `private/identity.plist` |
| `SystemUUID` | redacted — in `private/identity.plist` |
| `ROM` | redacted — in `private/identity.plist` |
| `ProcessorType` | old `1793`, now `3841` (see below) |
| `SystemMemoryStatus` | `Soldered` |
| `csr-active-config` | `03080000` |
| `revpatch` | `sbvmm,cpuname` |

The concrete values are stored in `private/identity.plist` (gitignored) and
injected by `scripts/build_efi.py`. The committed
`private/identity.example.plist` shows the schema. Nothing else from the old
EFI is reused.

`ProcessorType` is not an activation value. The old EFI used `1793`
(`0x0701`, `AppleProcessorTypeCorei7Type1`), which Sequoia renders as
`Processor Name: Unknown` on this Alder Lake CPU; the new build uses `3841`
(`0x0F01`, Xeon W). The evidence is in
[08-troubleshooting.md § CPU name and thread count](08-troubleshooting.md#cpu-name-and-thread-count).

### Old EFI contents

- OpenCore 1.0.8 (config format), picker `Builtin`, `UIScale 0`.
- 10 ACPI tables: ALS0, EC, GPI0, MCHC, PLUG-ALT-12, PNLF, RTCAWAC, SBUS,
  USBX, XOSI.
- Kexts: Lilu, VirtualSMC, AMFIPass, WhateverXe (0.6.0 + adlp-edp, byte
  identical to the reference repo), SMCProcessor, SMCBatteryManager,
  RestrictEvents, CpuTopologyRebuild, NVMeFix, SimpleHDA, AppleALC,
  BrightnessKeys, XHCI-unsupported, USBToolBox, UTBMap, VoodooI2C(+plugins),
  VoodooI2CHID, VoodooPS2Controller(+plugins), itlwm, HoRNDIS,
  IntelBluetoothFirmware, IntelBTPatcher, BlueToolFixup.
- `WhateverGreen.kext` was present but disabled — inert, but a trap for future
  edits.
- 13 `Kernel/Patch` entries, all disabled (OpenCore sample leftovers: AppleRTC,
  ACPI logging, BCM5701, e1000, Bluetooth kill, serial panic, SurPlus, QEMU).
- 2 `ReservedMemory` entries, both disabled (HD3000 errata, T490 hibernation).
- Boot args: `-allow3d -disablegfxfirmware -igfxdvmt -wex-adlp-edp
  -wex-reset-restore -wex-no-multicontext keepsyms=1 msgbuf=4194304
  shda-lang=en alcid=11 -vi2c-force-polling`.
- `DeviceProperties` for the iGPU: `AAPL,backlight-control`, `AAPL,slot-name`,
  `built-in`, `framebuffer-patch-enable`, `framebuffer-stolenmem 0000c003`,
  `hda-gfx`, `model`, `rps-control`.

### What was wrong (as opposed to merely different)

Nothing that explains the graphics failure. The EFI booted and every
non-graphics subsystem worked. The real findings were hygiene and provenance:

1. `ResetNvramEntry.efi` did not match any official OpenCore 1.0.8 build
   (SHA-256 differs from the release; the other OpenCore binaries match).
2. `WhateverGreen.kext` shipped disabled next to WhateverXe.
3. 13 dead `Kernel/Patch` entries and 2 dead `ReservedMemory` entries.
4. `rps-control` was an extra iGPU property not present in the known-working
   same-model config.
5. Missing `SSDT-USB-Reset.aml` and `SSDT-USBW.aml` relative to the reference.
6. The kext order put VirtualSMC between Lilu and AMFIPass/WhateverXe.
7. Wi-Fi used `itlwm` + HeliPort while the reference used `AirportItlwm`.
8. No documentation, no pinned versions, no hashes.

## 2. Config diff: old EFI vs same-model reference

A recursive plist comparison was run against
`retropineaple/whateverxe-hp-envy-x360` `config.plist`. The graphics-relevant
sections are **identical**:

| Section | Result |
|---|---|
| iGPU `DeviceProperties` | identical except old config adds `rps-control` |
| Boot args | identical except old config adds `-vi2c-force-polling` |
| `Kernel/Quirks` | identical |
| `Booter/Quirks` | identical |
| `Booter/MmioWhitelist` | identical (5 entries) |
| `ACPI/Add` | old has 10, reference has 12 (missing USB-Reset, USBW) |
| `ACPI/Delete` | both empty |
| SMBIOS model | both `MacBookPro16,2` |
| `csr-active-config` | both `03080000` |
| `SecureBootModel` | both `Disabled` |

The remaining differences are cosmetic or unrelated:

- `Kernel/Add` order and `Arch` (`x86_64` vs `Any`), plus the Wi-Fi kext.
- `Kernel/Patch`: 13 disabled entries vs none.
- `Misc/Boot`: builtin picker vs OpenCanopy, `UIScale 0` vs `2`,
  `Resolution ""` vs `Max`.
- `Misc/Debug`: verbose logging enabled in the old config (`Target 67`,
  `AppleDebug`, `ApplePanic`), defaults in the reference.
- `Misc/Security/DmgLoading`: `Any` vs `Signed`.
- `NVRAM/Delete`: list order and `ForceDisplayRotationInEFI`.
- `UEFI/Drivers`: `OpenHfsPlus`/no OpenCanopy vs `HfsPlus` + OpenCanopy + ext4
  + OpenLinuxBoot.
- `UEFI/Quirks`: `EnableVectorAcceleration` and `UnblockFsConnect` enabled in
  the old config.
- `UEFI/APFS`: `MinDate`/`MinVersion` 0 vs -1.
- `PlatformInfo`: identity present vs empty in the published reference;
  `ProcessorType` 1793 (old) vs 3841 (new build and reference). The old value
  is `AppleProcessorTypeCorei7Type1` and renders as `Processor Name: Unknown`
  on Sequoia; see [08 § CPU name](08-troubleshooting.md#cpu-name-and-thread-count).

**Conclusion:** rebuilding the config cannot by itself turn acceleration on.
The difference must be in the driver binaries, the macOS build, or the
firmware/VBT. This is why the new repository keeps two GPU variants and a
debug build instead of pretending the config was the problem.

## 3. Reference repositories

All repositories were cloned and read; configs were compared key by key, not
copied. Commits are the ones actually inspected.

| Repository | Hardware | Graphics approach | What was taken | What was rejected |
|---|---|---|---|---|
| [retropineaple/whateverxe-hp-envy-x360](https://github.com/retropineaple/whateverxe-hp-envy-x360) `8100282` (was `9809987`) | **Exact model**: HP Envy x360 13-bf0059TU, i7-1250U, 0x46AA, 2880×1800 OLED | WhateverXe 0.6.0 + 54 `adlp-edp` patches; Graphics 0.3.1 | Its published WhateverXe binary as default (`197da23b…`, patch series 54; stored unmodified, the build patches the 24H232 Sequoia constant), ACPI set, iGPU properties, `-wex-*` args, AppleALC DSP patch, USB map, overall EFI shape | Its published SMBIOS (blank) |
| [b00t0x/WhateverXe](https://github.com/b00t0x/WhateverXe) `68a2427` (0.6.1) | TGL, ADL-N, ADL/RPL-H/P/U | Upstream driver + 0.6.1 generic ADL-P/U eDP support | Boot-arg vocabulary, compatibility rules, diagnostic variant | Rejects this unit's VBT (`Status::Conflict`) and has no `-wex-adlp-edp` |
| [b00t0x/WhateverXe-Graphics](https://github.com/b00t0x/WhateverXe-Graphics) `v0.3.1` (0.3.1) and `v0.4.1` (0.4.1) | Same | Signed Apple payloads + `AppleIntelTGLCompat` 0.6.0 / 0.8.0 | Pinned install package (0.3.1, retained for rollback) and the 0.4.1 package now installed for the 0.8.0-adlp port; AMFIPass 1.4.1 Mod | Bundling Apple payloads in Git |
| [JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe](https://github.com/JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe) `6f03560` | Dell XPS 13 Plus 9320, i7-1360P, 0xA7A0 | NootedGreen + user-space Metal patches | Debugging methodology, Raptor Lake notes, VA-driver caveats | The NootedGreen stack — different driver, higher risk, not validated for 0x46AA |
| [labrouss/EliteBook840G8](https://github.com/labrouss/EliteBook840G8) `8610a1a` | HP EliteBook 840 G8, TGL i7-1165G7 | WhateverXe 0.6.1 + Graphics 0.3.2 | Confirmation that 0.6.1 works on Tahoe; BT power-cycle notes; HP S3/CMOS findings; VA-bundle workaround | Its SMCDellSensors/Thunderbolt ACPI (Dell/HP-specific, not this board) |
| [danyyok/Dell-Latitude-7420-EFI](https://github.com/danyyok/Dell-Latitude-7420-EFI) `aff2051` | Dell Latitude 7420, TGL i7-1165G7 | WhateverXe | Recovery-profile idea, 11-SSDT layout, `-ibtcompatbeta` note | Dell sensors, `SMCDellSensors`, its ACPI tables |
| [daddyc00l69/Honor-MagicBook-WhateverXe-Hackintosh](https://github.com/daddyc00l69/Honor-MagicBook-WhateverXe-Hackintosh) | Honor MagicBook, i5-12450H, 0x46A3 | WhateverXe 0.6.1 | Confirmation of `itlwm` + HeliPort on ADL; HWP/topology notes | `AAPL,GfxYTile` (obsolete since WEX 0.4), its ACPI |
| [Heitorpoggi/ASUS-VivoBook-16X-Hackintosh-](https://github.com/Heitorpoggi/ASUS-VivoBook-16X-Hackintosh-) `ee1a58b` | ASUS VivoBook 16X, i5-12500H | Claims NootedGreen/WhateverGreen acceleration | Nothing — **the repository contains only a README, no EFI** | Its claims (unverifiable, and it recommends WhateverGreen) |
| [dwiwinarno911/opencore-msi-tigerlake-irisxe](https://github.com/dwiwinarno911/opencore-msi-tigerlake-irisxe) `b823e383` | MSI Tiger Lake-U, i7-1195G7, 0x9A49 | WhateverXe 0.6.1 **patched** + Graphics 0.3.1/0.3.2, **Sequoia 15.8.2 (24H232)** | The 24H232 Sequoia MMIO constant, the expected guard checks, and the Metal archive LaunchAgent | Its 0.6.1 binary (rejects this VBT), zeroed SMBIOS, MSI-specific ACPI/EC and trackpad findings |

### Details worth keeping

- The HP reference's own documentation states that without `-wex-adlp-edp` the
  OLED has no driver, and that the patch is required because 0.6.0 does not
  support ADL-P internal panels. Upstream 0.6.1's generic path exists, but it
  returns `Status::Conflict` on this unit's duplicate DDI child, so it is not a
  drop-in replacement here.
- The HP reference was tested on **macOS 26.7.1 (25G241)**; at the time of the
  audit this machine ran **26.7.2 (25G332)**, and that difference was the Tahoe
  kernel/MMIO problem (see `docs/03-graphics.md`). **The machine has since been
  downgraded to Sequoia 15.8.2 (24H232)**. The Tahoe routine does not run
  there, but Sequoia has its own build-matched check: 24H232 changed
  `_IOProtectCacheMode+0xCA` by `+0x30`, so the published 0.6.0 constant is
  stale. The default build patches it; the stored payload is unchanged. The
  VBT evidence is unaffected: the captured VBT is byte-identical to the
  reference's fixture.
- EliteBook840G8 runs WhateverXe 0.6.1 + Graphics 0.3.2 on Tahoe, so that pair
  is viable for Tiger Lake. It is not evidence for ADL-P eDP on this VBT, and
  this repository does not use it.
- EliteBook840G8 documents that on HP firmware, real S3 resume hangs and that
  AppleRTC can corrupt BIOS settings; its workaround is a `_S3`-to-`_S5` ACPI
  patch plus `RTCMemoryFixup` + `rtcfx_exclude=80-AB`. **Not applied here**
  because this machine currently does not wake from sleep either and the
  workaround changes shutdown/sleep semantics; it is recorded as a future
  option in [docs/08-troubleshooting.md](08-troubleshooting.md).
- EliteBook840G8 and XPS13Plus both warn that the WhateverXe VA bundle can
  crash the camera and some video paths; moving
  `AppleIntelTGLGraphicsVADriver.bundle` to `/Library/GPUBundles.disabled`
  forces CPU decode. This is an optional trade-off, not part of the default
  install (hardware decode is one of the features we want).

## 4. Decisions in this repository

| Decision | Reason |
|---|---|
| Default GPU variant = WhateverXe 0.6.0 + `adlp-edp` | The firmware VBT has two internal DP children plus a duplicate DDI entry; upstream 0.6.1 **and 0.7.0** return `Status::Conflict` for it and cannot drive the panel. The 0.6.0 fork keeps the first child per DDI and is the only stack proven on this exact model |
| Keep 0.7.0 as a control variant | It tests upstream behaviour on Sequoia and is the only build without the exact-build MMIO requirement; its parser was measured against this VBT and is not expected to reach the panel |
| Patch the 24H232 Sequoia constant in the **build output**, not in Git | The published 0.6.0 binary is the only known driver for this panel, but its ninth Sequoia guard expects the 24H32 call. Patching the output keeps the payload hash meaningful and makes the change reproducible; `patch-wex-sequoia-mmio.sh` repairs a stick without rebuilding |
| Ship the Metal archive LaunchAgent as an opt-in tool | It is only needed after the accelerator starts on 24H232; installing it by default would mask the difference between "Metal absent" and "Metal crashing on archives" |
| Two Wi-Fi variants | `AirportItlwm` 2.4.0 (Sequoia build) is the default; `itlwm` + HeliPort stays as the proven, OS-independent fallback if the alpha build does not attach. Build-time choice avoids two kexts fighting |
| Keep `-igfxdvmt` + `framebuffer-stolenmem 0000c003` | BIOS leaves 60 MB DVMT; both the reference and this unit need the pair |
| Drop `-vi2c-force-polling` | Only affects VoodooI2C; the reference does not use it, and the touchpad works without the extra polling |
| Drop `rps-control` | Extra property relative to the working reference; not needed and can alter RPS behaviour |
| Add USB-Reset + USBW | Part of the reference's 12-table set; fixes USB behaviour after wake |
| OpenCanopy + `Resolution Max` + `UIScale 2` | Reference-proven on the 2880×1800 panel; nicer and avoids text-mode scaling |
| Remove dead `Kernel/Patch`, `ReservedMemory`, sample tools | They were disabled, but they are noise and a future foot-gun |
| Keep `SecureBootModel Disabled`, `csr-active-config 03080000` | Required by the WhateverXe/AMFIPass stack and already working |
| Change `ProcessorType` 1793 → 3841 and `revpatch` to `sbvmm,cpuname` | 1793 is `AppleProcessorTypeCorei7Type1`; the 18:54 report shows `cpu-type = <0107>` and `Processor Name: Unknown`. 3841 (`Xeon W`) is the documented value for 8+ cores and the reference value. Keeping `sbvmm` in the boot-arg prevents it from overriding the NVRAM value |
| Identity in `private/` | The machine is already activated; committing serial/MLB/UUID would leak it permanently |
