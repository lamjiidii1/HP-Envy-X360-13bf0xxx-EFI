# OpenMac — HP Envy x360 13-bf0xxx (i7-1250U) OpenCore EFI

A reproducible OpenCore EFI for macOS Tahoe on the **HP ENVY x360 2-in-1
13-bf0xxx** (Alder Lake-U, Iris Xe `8086:46AA`, 2880×1800 OLED), built around
WhateverXe.

This repository is the result of auditing the machine's previous EFI, auditing
several public Xe-LP hackintosh EFIs, and rebuilding the configuration from
scratch with every payload pinned and hashed.

> **Status:** macOS Tahoe 26.7.2 boots and is usable, Wi-Fi/Bluetooth/audio/
> battery/keyboard/USB work, but the iGPU currently falls back to
> `IONDRVFramebuffer` (19 MB VRAM, no Metal). The repository's primary variant
> moves from the reference laptop's patched WhateverXe 0.6.0 to upstream
> WhateverXe **0.6.1** + WhateverXe Graphics **0.3.2**, which added generic
> Alder Lake-P/U eDP panel detection. That is the next thing to test on
> hardware. See [docs/03-graphics.md](docs/03-graphics.md).

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
| OS | macOS Tahoe 26.7.2 (25G332), OpenCore 1.0.8 |
| SMBIOS | `MacBookPro16,2` (existing activation identity preserved) |

## Repository layout

```
efi/base/                 OpenCore 1.0.8, 12 ACPI tables, common kexts, resources
efi/variants/gpu-wex061/          WhateverXe 0.6.1 (default)
efi/variants/gpu-hp-adlp-edp/     WhateverXe 0.6.0 + retropineaple adlp-edp patches (fallback)
efi/variants/wifi-itlwm/          itlwm 2.3.0 + HeliPort (default, currently working)
efi/variants/wifi-airportitlwm/   AirportItlwm 2.4.1 (native Wi-Fi menu)
scripts/build_efi.py      assembles an EFI, injects private identity
scripts/verify_efi.py     structural and payload checks for a built EFI
scripts/payload_inventory.py      regenerates audit/payloads.tsv
docs/                     hardware, audit, graphics, Wi-Fi, audio, install, test plan
audit/                    reference matrix, config diff, log analysis, payload hashes
private/                  identity.example.plist (committed), identity.plist (ignored)
```

## Quick start

```sh
# 1. Put your own activation values in a private file (never committed).
cp private/identity.example.plist private/identity.plist
$EDITOR private/identity.plist

# 2. Build the default EFI (WhateverXe 0.6.1 + itlwm).
make build
make verify

# 3. Copy build/EFI to the ESP of the disk or USB stick you boot from.
#    Back up the existing EFI first. See docs/07-install.md.
```

Other combinations:

```sh
./scripts/build_efi.py --gpu hp-adlp-edp --wifi airportitlwm --out build/EFI-hp
./scripts/build_efi.py --debug --out build/EFI-debug     # -v, debug=0x100
```

| Variant | GPU driver | Wi-Fi | When to use |
|---|---|---|---|
| `wex061` (default) | WhateverXe 0.6.1 | itlwm + HeliPort | First try; upstream generic ADL-P/U eDP support |
| `hp-adlp-edp` | WhateverXe 0.6.0 + adlp-edp | itlwm | Fallback: exactly what the same-model reference repo ships |
| `wifi-airportitlwm` | any | AirportItlwm 2.4.1 | Only if you want native Wi-Fi and accept losing the working stack |
| `--debug` | any | any | Verbose boot and kernel logging while debugging |

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
| [docs/03-graphics.md](docs/03-graphics.md) | Why the iGPU does not accelerate, and the fix plan |
| [docs/04-wifi-bluetooth.md](docs/04-wifi-bluetooth.md) | Both Wi-Fi variants, Bluetooth |
| [docs/05-audio.md](docs/05-audio.md) | ALC245 layout 11, the DSP patch, SimpleHDA |
| [docs/06-usb-acpi-power.md](docs/06-usb-acpi-power.md) | USB map, ACPI tables, power management |
| [docs/07-install.md](docs/07-install.md) | Backup, build, install, upgrade, rollback |
| [docs/08-troubleshooting.md](docs/08-troubleshooting.md) | Symptom → cause → action |
| [docs/09-test-plan.md](docs/09-test-plan.md) | Ordered hardware test checklist |
| [docs/10-provenance.md](docs/10-provenance.md) | Versions, hashes, sources, modifications |

## Credits

- [b00t0x](https://github.com/b00t0x) — WhateverXe, WhateverXe Graphics,
  AppleIntelTGLCompat, CpuTopologyRebuild, AMFIPass Mod.
- [retropineaple/whateverxe-hp-envy-x360](https://github.com/retropineaple/whateverxe-hp-envy-x360)
  — the same laptop model, the working adlp-edp kext, ACPI set and fix notes.
- [acidanthera](https://github.com/acidanthera) — OpenCore, Lilu, VirtualSMC,
  AppleALC, NVMeFix, RestrictEvents, BrightnessKeys, VoodooPS2.
- [OpenIntelWireless](https://github.com/OpenIntelWireless) — itlwm,
  AirportItlwm, IntelBluetoothFirmware, HeliPort.
- [laobamac](https://github.com/laobamac) — SimpleHDA.
- [VoodooI2C](https://github.com/VoodooI2C), [USBToolBox](https://github.com/USBToolBox),
  [HoRNDIS](https://github.com/jwise/HoRNDIS), [corpnewt](https://github.com/corpnewt).
- [JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe](https://github.com/JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe),
  [labrouss/EliteBook840G8](https://github.com/labrouss/EliteBook840G8),
  [danyyok/Dell-Latitude-7420-EFI](https://github.com/danyyok/Dell-Latitude-7420-EFI),
  [daddyc00l69/Honor-MagicBook-WhateverXe-Hackintosh](https://github.com/daddyc00l69/Honor-MagicBook-WhateverXe-Hackintosh)
  — audited references; no files are copied from them except where noted in
  [docs/10-provenance.md](docs/10-provenance.md).

## License

The documentation, scripts and configuration in this repository are released
under the MIT license (see `LICENSE`). Kexts, OpenCore binaries and Apple
payloads keep their own licenses — see `NOTICE.md` and
[docs/10-provenance.md](docs/10-provenance.md).
