# OpenMac — HP Envy x360 13-bf0xxx (i7-1250U) OpenCore EFI

A reproducible OpenCore EFI for macOS Sequoia on the **HP ENVY x360 2-in-1
13-bf0xxx** (Alder Lake-U, Iris Xe `8086:46AA`, 2880×1800 OLED), built around
WhateverXe.

This repository is the result of auditing the machine's previous EFI, auditing
several public Xe-LP hackintosh EFIs, and rebuilding the configuration from
scratch with every payload pinned and hashed.

> **Status:** the machine now runs **macOS Sequoia 15.8.2 (24H232, Darwin
> 24.6.0)**, and the EFI has been retargeted to it. Wi-Fi uses a Sequoia build
> of `AirportItlwm`; the graphics half keeps the `adlp-edp` fork of WhateverXe
> 0.6.0 with WhateverXe Graphics 0.3.1, because upstream WhateverXe 0.7.0 —
> although it supports Sequoia and no longer needs a build-matched MMIO
> constant — cannot drive this panel: it rejects this machine's VBT with
> `Status::Conflict` and the VBT carries `panel_type = 0xFF`, so it has no
> panel record to work from. The fork's `-wex-adlp-edp` mode exists to drive
> exactly that configuration. Evidence and the reasoning are in
> [docs/03-graphics.md](docs/03-graphics.md#why-the-fork-is-still-required-on-sequoia).
>
> On Sequoia 15.8.2 (24H232) WhateverXe selects a different MMIO routine, so
> the Tahoe patch is inert. The same class of build-matched check exists there:
> the ninth Sequoia guard comparison expects `E8 71 CB 02 00` at
> `_IOProtectCacheMode+0xCA`, but 24H232 has `E8 A1 CB 02 00`. `make build`
> now applies that one-byte constant change to the **built** kext; the payload
> in `efi/variants` stays the published `197da23b…` binary.
> `scripts/macos/patch-wex-sequoia-mmio.sh` can repair a stick in place after a
> macOS update, and
> `scripts/macos/install-metal-archive-workaround.sh` installs the matching
> Metal-archive agent on this build.
>
> **Boot-tested on 15.8.2 from this repository (2026-11-03).** The built stick
> boots to the desktop, `TGLSequoiaMMIOGuard` entry 19 is `01`,
> `IntelAccelerator` is present, `VRAM (Dynamic, Max)` is 1536 MB and
> `system_profiler` reports **Metal 2**. The internal 2880×1800 OLED is online
> at **Looks like 1440 × 900** HiDPI. The remaining known limits are Metal 2
> (not Metal 3), the GPU's internal "Intel(R) TGL Unknown" name, and Metal apps
> that load precompiled archives: the Battery settings pane and App Store video
> abort/hang in `MTLLoader` / `CA::Render::prepare_image`. The desktop itself
> is GPU-composited. See
> [docs/03-graphics.md](docs/03-graphics.md#metal-archives-on-24h232) and
> [docs/08-troubleshooting.md](docs/08-troubleshooting.md#battery-settings-pane-exits-powerpreferences).

## Hardware

| Component | Model |
|---|---|
| Laptop | HP ENVY x360 2-in-1 Laptop 13-bf0xxx |
| Board | HP 8A28 (21.49), BIOS F.35 (2025-11-17) |
| CPU | Intel Core i7-1250U, 2P + 8E / 12 threads |
| iGPU | Intel Iris Xe (Alder Lake-UP4 GT2), `8086:46AA`, rev 0x0c |
| Panel | 2880×1800 OLED, eDP |
| RAM | 16 GB LPDDR5 (soldered) |
| Storage | SK hynix BC901 HFS512GEJ9X108N, 512 GB NVMe |
| Wi-Fi / BT | Intel AX211 CNVi, `8086:51F0` |
| Audio | ALC245 over Intel SST (`8086:51CC`) + CS35L41 amplifiers |
| Card reader | Realtek RTS5288 (`10ec:5228`) |
| OS | macOS Sequoia 15.8.2 (24H232, Darwin 24.6.0), OpenCore 1.0.8 |
| SMBIOS | `MacBookPro16,2` (existing activation identity preserved) |

## Repository layout

```
efi/base/                 OpenCore 1.0.8, 12 ACPI tables, common kexts, resources
efi/variants/gpu-hp-adlp-edp/     WhateverXe 0.6.0 + adlp-edp patches (default)
efi/variants/gpu-wex070/          WhateverXe 0.7.0 upstream (control experiment)
efi/variants/wifi-airportitlwm/   AirportItlwm 2.4.0, Sequoia build (native menu, default)
efi/variants/wifi-itlwm/          itlwm 2.3.0 + HeliPort (fallback)
scripts/build_efi.py      assembles an EFI, injects private identity
scripts/verify_efi.py     structural and payload checks for a built EFI
scripts/payload_inventory.py      regenerates audit/payloads.tsv
scripts/macos/patch-wex-tahoe-mmio.sh   repairs the 26.7.2 MMIO-UC signature
                                        (Tahoe history; not used on Sequoia)
scripts/macos/patch-wex-sequoia-mmio.sh repairs the 15.8.2 (24H232) signature
scripts/macos/metal-archive-workaround.plist  Metal archive crash workaround
scripts/macos/install-metal-archive-workaround.sh  installs/removes that agent
scripts/macos/check-metal-env.sh         verifies the agent and GUI environment
scripts/macos/openmac-diag.sh            continuous per-user diagnostics collector
scripts/macos/post-install-check.sh      one-shot CPU/GPU/display/battery report
scripts/macos/install-boot-capture.sh    black-screen boot capture daemon
scripts/macos/restore-opencode-migration.sh  restore chat + repo on macOS
scripts/migrate-to-macos.sh              build the Linux → macOS migration bundle
docs/                     hardware, audit, graphics, Wi-Fi, audio, install, test plan
audit/                    reference matrix, config diff, log analysis, payload hashes
private/                  identity.example.plist (committed), identity.plist (ignored)
```

## Quick start

```sh
# 1. Put your own activation values in a private file (never committed).
cp private/identity.example.plist private/identity.plist
$EDITOR private/identity.plist

# 2. Build the default EFI (WhateverXe 0.6.0 adlp-edp + AirportItlwm).
make build
make verify

# 3. Copy build/EFI to the ESP of the disk or USB stick you boot from.
#    Back up the existing EFI first. See docs/07-install.md.
```

Other combinations:

```sh
./scripts/build_efi.py --gpu wex070 --out build/EFI-wex070   # upstream control
./scripts/build_efi.py --wifi itlwm --out build/EFI-itlwm
./scripts/build_efi.py --debug --out build/EFI-debug     # -v, debug=0x100
```

| Build | GPU driver | Wi-Fi | When to use |
|---|---|---|---|
| `build/EFI` (default) | WhateverXe 0.6.0 + adlp-edp | AirportItlwm 2.4.0 (Sequoia) | The only driver that parses this VBT and drives this panel |
| `build/EFI-itlwm` | WhateverXe 0.6.0 + adlp-edp | itlwm + HeliPort | Fallback if AirportItlwm does not attach |
| `build/EFI-wex070` | WhateverXe 0.7.0 | AirportItlwm 2.4.0 (Sequoia) | Control experiment; needs Graphics 0.4.0 and is expected to leave the internal panel dark |
| `build/EFI-debug` | WhateverXe 0.6.0 + adlp-edp | AirportItlwm 2.4.0 (Sequoia) | Verbose boot and kernel logging while debugging |

## Why Sequoia, and where the Tahoe work went

The Tahoe 26.7.2 install never got past the first display modeset: the
accelerator probed and the panel was detected, but the first frame flip was
refused and WindowServer fell back to a virtual display. The trail is in
[docs/03-graphics.md](docs/03-graphics.md) and
[audit/log-analysis.md](audit/log-analysis.md) §9.2.

On 2026-11-02 upstream released WhateverXe 0.7.0, which supports Sequoia
15.8.x and no longer requires an exact OS build match for MMIO, and whose
changelog claims internal eDP for Alder Lake-H/P/U. That looked like it would
make the fork unnecessary. It does not, for two reasons that were checked by
compiling the parsers and feeding them this machine's real VBT:

- upstream's VBT parser returns `Status::Conflict` on the duplicate DDI 1
  child, so it keeps no ports at all;
- this panel is described with `panel_type = 0xFF` ("select by PnP id"), so
  even a parsed table yields no `panel` record for the upstream eDP path.

The fork handles both: `-wex-adlp-edp` parses with first-child-wins and adds
Combo A as a **fixed DP** output. That is the path the same-model reference
used to reach a working panel and Metal on Tahoe 26.7.1, and it is still the
only path that gets this panel past detection. 0.7.0 therefore ships on the
stick as `EFI-wex070` for a control experiment, not as the default. Reaching
0.7.0 would mean rebasing those two behaviours onto upstream and building from
source.

## What changed compared with the previous EFI

The old EFI was not broken by its configuration: its graphics settings are
functionally identical to the working same-model reference. The rebuild fixes
provenance and removes dead weight, but the driver stack is the real variable.

- Rebuilt from OpenCore 1.0.8 release binaries (the old `ResetNvramEntry.efi`
  did not match any official 1.0.8 build).
- Added `SSDT-USB-Reset.aml` and `SSDT-USBW.aml`; all 12 ACPI tables now match
  the same-model reference byte-for-byte (except cosmetic OEM IDs in
  `SSDT-EC.aml`).
- Removed the 13 disabled sample `Kernel/Patch` entries, the two disabled
  `ReservedMemory` entries, OpenCore's sample tools/entries, and
  `-vi2c-force-polling` (the touchpad is dead in hardware anyway).
- Removed the inert `rps-control` device property; kept the proven
  `framebuffer-stolenmem 0000c003` + `-igfxdvmt` pair for the 60 MB DVMT BIOS.
- Kext order now follows the reference: Lilu → AMFIPass → WhateverXe → …
- `WhateverGreen.kext` is gone entirely (it must never be enabled next to
  WhateverXe).
- Wi-Fi is a build-time choice; both stacks are pinned instead of carrying one
  permanent choice.
- Identity is injected at build time from `private/identity.plist`.

Full reasoning: [docs/02-audit.md](docs/02-audit.md) and
[docs/10-provenance.md](docs/10-provenance.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/01-hardware.md](docs/01-hardware.md) | Hardware inventory and how it was collected |
| [docs/02-audit.md](docs/02-audit.md) | Old EFI audit, reference-repo audit, config diff |
| [docs/03-graphics.md](docs/03-graphics.md) | Current Sequoia state, VBT/parser evidence, Tahoe history |
| [docs/04-wifi-bluetooth.md](docs/04-wifi-bluetooth.md) | Both Wi-Fi variants, Bluetooth |
| [docs/05-audio.md](docs/05-audio.md) | ALC245 layout 11, the DSP patch, SimpleHDA |
| [docs/06-usb-acpi-power.md](docs/06-usb-acpi-power.md) | USB map, ACPI tables, power management |
| [docs/07-install.md](docs/07-install.md) | Backup, build, install, upgrade, rollback |
| [docs/08-troubleshooting.md](docs/08-troubleshooting.md) | Symptom → cause → action |
| [docs/09-test-plan.md](docs/09-test-plan.md) | Ordered hardware test checklist |
| [docs/10-provenance.md](docs/10-provenance.md) | Versions, hashes, sources, modifications |
| [docs/11-diagnostics.md](docs/11-diagnostics.md) | Continuous collector: install, schedules, output, privacy, uninstall |
| [docs/12-moving-to-macos.md](docs/12-moving-to-macos.md) | Move the chat, credentials, repository and OpenCode binary to macOS |

Official references (OpenCore `Configuration.pdf`, the Dortania install and
ACPI guides, upstream driver documentation) are listed in
[docs/10-provenance.md §9](docs/10-provenance.md#9-reference-standards). Where
a public EFI disagreed with them, the official documentation was followed and
the deviation is recorded in the audit.

## Credits

- [b00t0x](https://github.com/b00t0x) — WhateverXe, WhateverXe Graphics,
  AppleIntelTGLCompat, CpuTopologyRebuild, AMFIPass Mod.
- [retropineaple/whateverxe-hp-envy-x360](https://github.com/retropineaple/whateverxe-hp-envy-x360)
  — the same laptop model, the working adlp-edp kext, ACPI set and fix notes.
- [acidanthera](https://github.com/acidanthera) — OpenCore, Lilu, VirtualSMC,
  AppleALC, NVMeFix, RestrictEvents, BrightnessKeys, VoodooPS2.
- [OpenIntelWireless](https://github.com/OpenIntelWireless) — itlwm,
  AirportItlwm, IntelBluetoothFirmware, HeliPort.
- [laobamac](https://github.com/laobamac) — SimpleHDA and the
  `AirportItlwm-Sequoia` build used here, which upstream does not release.
- [VoodooI2C](https://github.com/VoodooI2C), [USBToolBox](https://github.com/USBToolBox),
  [HoRNDIS](https://github.com/jwise/HoRNDIS), [corpnewt](https://github.com/corpnewt).
- [JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe](https://github.com/JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe),
  [labrouss/EliteBook840G8](https://github.com/labrouss/EliteBook840G8),
  [danyyok/Dell-Latitude-7420-EFI](https://github.com/danyyok/Dell-Latitude-7420-EFI),
  [daddyc00l69/Honor-MagicBook-WhateverXe-Hackintosh](https://github.com/daddyc00l69/Honor-MagicBook-WhateverXe-Hackintosh)
  — audited references; no files are copied from them except where noted in
  [docs/10-provenance.md](docs/10-provenance.md).
- [dwiwinarno911/opencore-msi-tigerlake-irisxe](https://github.com/dwiwinarno911/opencore-msi-tigerlake-irisxe)
  — first public report of WhateverXe Metal on 15.8.2 (24H232) on Tiger Lake.
  The Sequoia MMIO constant diagnosis and the Metal archive workaround are
  adapted from that repository; see [docs/10-provenance.md](docs/10-provenance.md).

## License

The documentation, scripts and configuration in this repository are released
under the MIT license (see `LICENSE`). Kexts, OpenCore binaries and Apple
payloads keep their own licenses — see `NOTICE.md` and
[docs/10-provenance.md](docs/10-provenance.md).
