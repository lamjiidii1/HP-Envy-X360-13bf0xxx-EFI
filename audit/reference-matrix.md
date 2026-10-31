# Reference matrix

This is the audit trail for the reference repositories used while rebuilding
this EFI. All repositories were cloned and read; **no config was copied
wholesale**. Each table records what was actually inspected, what was adopted,
and what was rejected and why.

Commits are the ones inspected on 2026-10-29/30. If a repository has moved
since, the commit in the table is still the evidence for the decisions in this
repository.

## 1. Overview

| Repository | Commit | Hardware | macOS target | Graphics stack | Wi-Fi | Role here |
|---|---|---|---|---|---|---|
| [retropineaple/whateverxe-hp-envy-x360](https://github.com/retropineaple/whateverxe-hp-envy-x360) | `9809987` | **HP Envy x360 13-bf0059TU**, i7-1250U, `0x46AA`, 2880×1800 OLED | 26.7.1 (25G241) | WhateverXe 0.6.0 + 47 `adlp-edp` patches, Graphics 0.3.1 | AirportItlwm | Primary same-model reference |
| [b00t0x/WhateverXe](https://github.com/b00t0x/WhateverXe) | 0.6.1 tag | TGL, ADL-N, ADL/RPL-H/P/U | current Tahoe | upstream driver | — | Default GPU driver; boot-arg and pairing rules |
| [b00t0x/WhateverXe-Graphics](https://github.com/b00t0x/WhateverXe-Graphics) | `b4d3889` (0.3.2) | same | current Tahoe | Apple payloads + `AppleIntelTGLCompat` | — | Pinned Graphics package; AMFIPass Mod |
| [JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe](https://github.com/JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe) | `6f03560` | Dell XPS 13 Plus 9320, i7-1360P, `0xA7A0` | Tahoe | NootedGreen + user-space Metal patches | — | Debug methodology; VA-driver caveat |
| [labrouss/EliteBook840G8](https://github.com/labrouss/EliteBook840G8) | `8610a1a` | HP EliteBook 840 G8, i7-1165G7 | Tahoe | WhateverXe 0.6.1 + Graphics 0.3.2 | — | Proof the 0.6.1 pair runs on Tahoe; HP sleep findings |
| [danyyok/Dell-Latitude-7420-EFI](https://github.com/danyyok/Dell-Latitude-7420-EFI) | `aff2051` | Dell Latitude 7420, i7-1165G7 | Tahoe | WhateverXe | — | Recovery-profile idea; 11-SSDT layout |
| [daddyc00l69/Honor-MagicBook-WhateverXe-Hackintosh](https://github.com/daddyc00l69/Honor-MagicBook-WhateverXe-Hackintosh) | `690146e` | Honor MagicBook `BRN-FXX`, i5-12450H, `0x46A3` | Sonoma/Sequoia | WhateverXe 0.6.1 | itlwm + HeliPort | Confirms itlwm on ADL; HWP/topology notes |
| [Heitorpoggi/ASUS-VivoBook-16X-Hackintosh-](https://github.com/Heitorpoggi/ASUS-VivoBook-16X-Hackintosh-) | `ee1a58b` | ASUS VivoBook 16X, i5-12500H | claims Tahoe | claims NootedGreen/WhateverGreen | AirportItlwm | **README only — no EFI, nothing adopted** |

## 2. Same-model reference: retropineaple/whateverxe-hp-envy-x360

Files inspected: `README.md`, `docs/EFI.md`, `docs/FIXES.md`,
`docs/INSTALL.md`, `docs/WHATEVERXE-CHANGES.md`, `EFI/OC/config.plist`,
`EFI/OC/ACPI/*`, `EFI/OC/Kexts/*`, `whateverxe/patches/*`,
`tools/patch-applealc-alc245-layout11.py`.

### Facts that matter

- Same board family (`8A28`), same CPU (i7-1250U), same iGPU (`0x46AA`), same
  2880×1800 OLED. This is the only reference that is hardware-identical.
- Its own documentation says the OLED has no driver without `-wex-adlp-edp`
  and that the 47-patch kext is required because 0.6.0 does not support ADL-P
  internal panels.
- Tested on **26.7.1 (25G241)**, one point release older than this machine
  (26.7.2 / 25G332).
- The published `config.plist` has an **empty PlatformInfo identity**. It
  cannot be booted as-is on a machine that needs activation.
- Its EFI has 12 ACPI tables; the old EFI on this machine had 10 (missing
  `SSDT-USB-Reset.aml` and `SSDT-USBW.aml`).
- Its Graphics package is 0.3.1 (Compat 0.6.0).
- Its AppleALC is patched with the same layout-11 DSP removal used here.

### Adopted

- The 12-table ACPI set, including the two USB tables.
- iGPU `DeviceProperties`: `AAPL,backlight-control`, `built-in`,
  `framebuffer-patch-enable`, `framebuffer-stolenmem = 0000c003`,
  `hda-gfx = onboard-1`, `model`.
- The `-igfxdvmt` boot argument (BIOS leaves 60 MB DVMT).
- The AppleALC layout-11 patch (reproduced, hashed).
- The USB port map for `8A28`.
- The general EFI shape and kext order (Lilu → AMFIPass → WhateverXe → …).
- The 0.6.0 `adlp-edp` kext as a **fallback variant**.

### Rejected or changed

- **Not used as the default GPU driver.** It only proves 0.6.0 on 26.7.1;
  on this machine the identical config and kext produce the 19 MB fallback.
- **Not used as the config base.** The config was rebuilt from the OpenCore
  1.0.8 schema and the findings, not patched out of the reference file.
- `AirportItlwm` is the default because it gives the native Wi-Fi UI and matches
  the reference; `itlwm` + HeliPort remains the proven fallback for this
  install.
- The published empty SMBIOS is not usable; the identity comes from
  `private/identity.plist`.
- The ACPI brightness patch is scoped to `DSDT`, `Count 2`; the old EFI had it
  global with `Count 0`.

### Open question inherited from it

Why does the same kext/config work on the reference's 26.7.1/F.?? unit and
fail on this 26.7.2/F.35 unit? The two candidate explanations are the macOS
point update (kernel ABI) and a BIOS/VBT change (panel record). The logs
support the second: the VBT panel record is a placeholder, not a panel
descriptor. See [../audit/log-analysis.md](log-analysis.md).

## 3. Upstream: b00t0x/WhateverXe (0.6.1)

- 0.6.1 (2026-10-27) adds experimental internal display (eDP) and brightness
  support for ADL-N/Twin Lake and ADL/RPL-H/P/U.
- The string `-wex-adlp-edp` exists in the 0.6.0 binary and **does not exist**
  in 0.6.1: the feature became automatic/firmware-driven rather than a
  per-machine patch.
- 0.6.1 also fixes DEBUG boot stack overflows.
- 0.6.1 no longer documents `-wex-reset-restore` / `-wex-no-multicontext`; the
  build script adds them only for the 0.6.0 variant.
- Requires `-allow3d`, `-disablegfxfirmware`, `-igfxdvmt`; never combine with
  WhateverGreen.

Adopted: the 0.6.1 kext as the default variant, the boot-argument vocabulary,
and the version-pairing rule with Graphics 0.3.2.

Not adopted: experimental flags unrelated to this GPU. The repository does not
speculate with `-wex-noaccel` (it would guarantee the current fallback) or with
`-wex-*` flags that 0.6.1 does not define.

## 4. Upstream: b00t0x/WhateverXe-Graphics (0.3.2)

- Ships the patched Apple Tiger Lake framebuffer/accelerator, the VA bundle,
  `AppleIntelTGLCompat`, and the `AMFIPass` Mod.
- 0.3.2 pairs with WhateverXe 0.6.1 / Compat 0.6.1; 0.3.1 pairs with 0.6.0 /
  Compat 0.6.0.
- Installed inside macOS, rebuilds AuxKC; not an EFI payload.

Adopted: the 0.3.2 package (pinned hash) and the AMFIPass Mod build.
Rejected: vendoring Apple-derived payloads into this repository.

## 5. EliteBook840G8 — labrouss/EliteBook840G8

Files inspected: `README.md`, `docs/SLEEP.md`, `ACPI-src/*.dsl`,
`Tools/collect-*.sh`, config/kext list.

Adopted as evidence:

- WhateverXe **0.6.1 + Graphics 0.3.2** runs on Tahoe on a Tiger Lake HP.
  This is the strongest argument that the 0.6.1 pair is viable on 26.7.x.
- HP firmware sleep does not resume; the project patches `_S3` to soft-off and
  adds `RTCMemoryFixup` + `rtcfx_exclude=80-AB`.
- The VA bundle can crash the camera/video path; moving
  `AppleIntelTGLGraphicsVADriver.bundle` to `/Library/GPUBundles.disabled`
  forces CPU decode.
- `SSDT-BTEN` power-cycles Bluetooth when it comes from another OS with stale
  firmware.

Not adopted:

- The sleep workaround. This machine also does not wake, but the workaround
  changes sleep into shutdown and needs validation on F.35. Documented as a
  future experiment in [../docs/06-usb-acpi-power.md](../docs/06-usb-acpi-power.md).
- `SSDT-BTEN`: Bluetooth already works here.
- Dell/HP-specific sensors and Thunderbolt ACPI that do not exist on `8A28`.

## 6. XPS13Plus — JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe

Files inspected: `README.md`, `docs/STATUS.md`, `docs/METAL.md`,
`docs/KERNEL-PATCHES.md`, `docs/EXPERIMENTS.md`, `docs/CATALOG.md`,
`patches/*`, `macos/*`, `tools/xe-*`.

Adopted:

- Debugging discipline: one variable per boot, capture ioreg + kernel log,
  separate "driver loaded" from "accelerator started".
- The VA-driver caveat and the `/Library/GPUBundles.disabled` workaround.
- The distinction between Metal bring-up and user-space shader/compiler
  patches.

Not adopted:

- **NootedGreen.** Different driver, different GPU support matrix, not
  validated for `0x46AA`. Mixing it with WhateverXe would make both
  investigations unusable.
- Its user-space Metal patches and shader compiler work; those target Raptor
  Lake (`0xA7A0`) and a different failure mode.
- Its ACPI and SMBIOS.

## 7. Dell Latitude 7420 — danyyok/Dell-Latitude-7420-EFI

Adopted:

- The idea of keeping a minimal recovery profile/EFI separate from the daily
  one (documented in [../docs/07-install.md](../docs/07-install.md)).
- Confirmation that an 11–12 table ACPI set is normal for this generation.
- The note that `-ibtcompatbeta` is for a different Bluetooth generation and
  must not be added blindly.

Not adopted: Dell sensors (`SMCDellSensors`), its ACPI tables, its USB map.

## 8. Honor MagicBook — daddyc00l69/Honor-MagicBook-WhateverXe-Hackintosh

Files inspected: `README.md`, `INSTRUCTIONS.md`, `RELEASE_NOTES.md`,
`docs/USB_BOOT_GUIDE.md`.

Adopted:

- Confirmation that `itlwm` + HeliPort works on Alder Lake, not only
  `AirportItlwm`.
- The warning that WhateverGreen must not be used with WhateverXe.
- HWP/topology notes consistent with `SSDT-PLUG-ALT-12` +
  `CpuTopologyRebuild`.

Not adopted:

- `AAPL,GfxYTile` — obsolete since WhateverXe 0.4.
- Its CPUID spoof and ACPI (Alder Lake-H, different board).
- Its `-v debug=0x100` as a permanent setting; here they belong to the debug
  variant only.

## 9. ASUS VivoBook 16X — Heitorpoggi/ASUS-VivoBook-16X-Hackintosh-

The repository contains **only `README.md`** at commit `ee1a58b`. There is no
EFI, no config, no ACPI and no kext to inspect. Its claims (full Metal via
NootedGreen/WhateverGreen, 120 Hz, sleep/wake) cannot be verified from the
repository.

Nothing was adopted. In particular, its WhateverGreen recommendation
contradicts the upstream WhateverXe rule and would break this machine.

## 10. Decision matrix

| Decision | Same-model HP | WhateverXe upstream | EliteBook | XPS13+ | Honor | Dell 7420 | This repo |
|---|---|---|---|---|---|---|---|
| GPU driver | WEX 0.6.0 + adlp-edp | WEX 0.6.1 | WEX 0.6.1 | NootedGreen | WEX 0.6.1 | WEX | **0.6.1 default, 0.6.0 fallback** |
| Graphics package | 0.3.1 | — | 0.3.2 | user-space patches | 0.3.x | — | **0.3.2** |
| WhateverGreen | absent/disabled | forbidden | absent | replaced | forbidden | absent | **absent** |
| Wi-Fi | AirportItlwm | — | — | — | itlwm | — | **AirportItlwm default, itlwm fallback** |
| SMBIOS | empty (published) | — | MacBookPro16,x | MacBookPro16,x | MacBookPro16,x | MacBookPro16,x | **MacBookPro16,2 (existing identity)** |
| `csr-active-config` | `03080000` | `03080000` | `03080000` | `03080000` | `03080000` | `03080000` | **`03080000`** |
| Sleep | disabled (firmware) | — | `_S3`→S5 workaround | — | working | — | **disabled, no patch** |
| VA bundle | present | — | optional disable | patched | present | — | **present; workaround documented** |
| ACPI tables | 12 | — | 11+ | many | 8 | 11 | **12** |

## 11. Verification notes

- Configs were compared with a recursive, type-aware plist walk
  (`audit/config-diff.md`), not by eye.
- Kext payloads were hashed and compared with the upstream releases; the
  result is `audit/payloads.tsv`.
- The same-model reference's kext was byte-identical to the old EFI's
  WhateverXe; that is why the old failure cannot be explained by a corrupted
  kext.
- Claims that could not be reproduced from files (ASUS acceleration, XPS
  user-space Metal) are recorded as claims, not as evidence.

## 12. What was not copied

No config, ACPI table, kext, script or documentation text was copied from any
reference except:

- the 12 ACPI tables (configuration data for the same board),
- the USB port map (generated for `8A28`),
- the AppleALC patch script (used with attribution; the output is reproduced
  and hashed),
- the 0.6.0 `adlp-edp` kext (fallback variant only).

Everything else was rebuilt and is explained in
[../docs/02-audit.md](../docs/02-audit.md),
[../docs/10-provenance.md](../docs/10-provenance.md) and the Git history.
