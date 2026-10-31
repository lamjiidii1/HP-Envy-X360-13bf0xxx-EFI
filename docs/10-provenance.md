# 10 — Provenance

Every binary in this repository is pinned to a version and a SHA-256. Nothing
is fetched at build time. If a file here does not match the table, the
repository has been modified and the change must be explained.

`audit/payloads.tsv` is the generated, machine-readable form of most of this
document; `make inventory` regenerates it.

```sh
make inventory
git diff --exit-code audit/payloads.tsv   # expected: no output
```

## 1. OpenCore and UEFI drivers

Source: [acidanthera/OpenCorePkg](https://github.com/acidanthera/OpenCorePkg)
release **1.0.8**, archive
`OpenCore-1.0.8-RELEASE.zip`, SHA-256
`2011e8b7216ecb2645d97ea710df965947edd406846e92050b9bc4190be6d27b`.

| File | SHA-256 | Modification |
|---|---|---|
| `BOOT/BOOTx64.efi` | `d0163dfbe5d2ea46aececd7d7349acfa5b75dfed2993e8489816f3dda71914c8` | none |
| `OC/OpenCore.efi` | `9ef21f9d846a992c030fa5858736a6d9efa70a3b4ad88b8d747338bb457b14d4` | none |
| `OC/Drivers/OpenRuntime.efi` | `c67be56660047237360df5eb7f080a2b13129d68e829bee9ad0230e45d516be8` | none |
| `OC/Drivers/OpenCanopy.efi` | `a92af4a7f6bbafb30abe0605a02d8746cafd7aa3006cf5fbc0b0ee9e795da879` | none |
| `OC/Drivers/ResetNvramEntry.efi` | `3c34cd3a6cdfbbaf9c548c59058e9537dbd527f8e9b82261153386e49329879d` | none |
| `OC/Drivers/ext4_x64.efi` | `1e0d1597f162593f2e12b07724cc3979ac9496dae7504234b3165cd10021f27f` | none |
| `OC/Drivers/OpenLinuxBoot.efi` | `41427ae9f78dbd53dcfbf9021d77f4675092c5774bffd533a46928d73ddf3adb` | none |
| `OC/Drivers/HfsPlus.efi` | `a55b5fff36578864ba6792c4c6369c71f6f35b61dd5a853ddf8583cd36c31d8f` | none |

`HfsPlus.efi` comes from
[acidanthera/OcBinaryData](https://github.com/acidanthera/OcBinaryData), not
from the OpenCore archive.

The old EFI shipped a `ResetNvramEntry.efi` that did not match any official
1.0.8 build. That is why this repository rebuilds the OpenCore layer from the
release archive instead of reusing it. The hash above is the reference value.

`OC/Resources/` contains the OpenCanopy themes (`Acidanthera/Chardonnay` and
`Acidanthera/Syrah`) from the same OpenCore release. They are assets, not code,
and are not individually hashed here; replacing them changes only the picker.

## 2. ACPI tables

Twelve tables, all taken from the same-model reference
[retropineaple/whateverxe-hp-envy-x360](https://github.com/retropineaple/whateverxe-hp-envy-x360)
(commit `9809987`) and pinned by hash. They are `aml` configuration data for
this board (`8A28`), not generic upstream files.

| Table | SHA-256 | Note |
|---|---|---|
| `SSDT-ALS0.aml` | `ed4a1ad31606251b7b3359b58ec6567aeb82aa8a23c105d731298e690c34b029` | ambient light stub |
| `SSDT-SBUS.aml` | `62bf1bab54e822f5a5f565c00de4677df66db7838d204a2261048c69fbf9f0c1` | SMBus |
| `SSDT-EC.aml` | `46b8ead0b1855a16bc85454e664ae2f8dac0d779859f4a47a7e65c0ff1a0f44e` | same functionality as the reference; OEM ID/table ID differ because it was rebuilt |
| `SSDT-GPI0.aml` | `1e55d68cbaf2f9e81629bc0845f45880801ba865e0ef879ea06313130ee4939f` | GPIO for I2C |
| `SSDT-MCHC.aml` | `06e64ff305bfa0e7b575923dbb139ad47b9acecdf5aa20cb22e6158a4c01533d` | memory controller |
| `SSDT-PLUG-ALT-12.aml` | `f1c91142d2b1e8c048ffc7c3778a142b22a0beed7b33f80230ade5f40036872c` | 12-thread XCPM declaration |
| `SSDT-PNLF.aml` | `120eb3200cf954bbe5c63c3afa2ad10044ac48bf340594ca4ac2b3280e174af7` | backlight |
| `SSDT-RTCAWAC.aml` | `a56aeb22ecebb218d5d467dd753b6d580c57e5cd526d275a7b680d743fefc0fe` | AWAC RTC |
| `SSDT-USB-Reset.aml` | `724e382da26c16a8960654b89d6657dc6c86382019ac847a7d58891285d0d172` | new relative to the old EFI |
| `SSDT-USBX.aml` | `5ac27370e7424f63058cd6399e24c397172835bb903ea2a060c0404a0083221e` | USB power |
| `SSDT-XOSI.aml` | `e1bfcd65ee233d46170083ae62bdd5da3564f91ae29d6e2263695b4d7195e9b6` | `_OSI` spoof |
| `SSDT-USBW.aml` | `a37a68da1f9b2bd0d6ea07055554f779a537c578abe716da8849ed8092c5f259` | new relative to the old EFI |

The four ACPI patches (`ACPI/Patch`) are configuration, not payloads. Their
reasoning is in [06-usb-acpi-power.md](06-usb-acpi-power.md).

## 3. Common kexts (`efi/base/OC/Kexts`)

`payloads.tsv` records the bundle identifier, version and SHA-256 of the
executable. `-` means the bundle has no executable (a pure plist injector).

| Kext | Version | Upstream | SHA-256 | Modification |
|---|---|---|---|---|
| `Lilu.kext` | 1.7.2 | [acidanthera/Lilu](https://github.com/acidanthera/Lilu) | `ff98508b40a1eb5fb477029db8886412520f8e39965279ea331c99e3d2e3b274` | none |
| `AMFIPass.kext` | 1.4.1 | [dhinakg/AMFIPass](https://github.com/dhinakg/AMFIPass) | `2d36aeca1740b258e6bb0b66844b5bfb59a0edb7cdd9ef78206689e5d223d8dc` | "Mod" build from WhateverXe Graphics: trust anchor changed for Xe bundles |
| `WhateverXe.kext` | 0.6.0 | b00t0x + [retropineaple adlp-edp](https://github.com/retropineaple/WhateverXe/tree/adlp-edp) | `c090b9dd35398c72e9567b38b9bb9b61415ab7fcfe22ffc78cbafc93ee67e49b` | 47 `adlp-edp` patches; **default** (variant `gpu-hp-adlp-edp`) |
| `WhateverXe.kext` | 0.6.1 | [b00t0x/WhateverXe](https://github.com/b00t0x/WhateverXe) | `e92b65b0cce5964aacb0e7674a762fb8bd85dee5a931d15bd80b0edcafd1c39b` | none; diagnostic only, rejects this VBT (variant `gpu-wex061`) |
| `VirtualSMC.kext` | 1.3.9 | [acidanthera/VirtualSMC](https://github.com/acidanthera/VirtualSMC) | `bf91e9542b86c20acaf210353a93742291c49328e2d14b03fa0fa4fc52b3b5ce` | none |
| `SMCProcessor.kext` | 1.3.9 | acidanthera/VirtualSMC | `dcf738671431721692f752e3df43acaaa02c93788ae7b21153504b07db01be32` | none |
| `SMCBatteryManager.kext` | 1.3.9 | acidanthera/VirtualSMC | `791d81018a5374ddc63b8d97ba976e03bab6d241fec08ec3487e4c4e74fc24e4` | none |
| `AppleALC.kext` | 1.9.8 | [acidanthera/AppleALC](https://github.com/acidanthera/AppleALC) | `ee5ed2952138f819e4cd679649e3c3a042ed0796d4782c296fade2982e02849d` | ALC245 layout 11 DSP removal, see §6 |
| `RestrictEvents.kext` | 1.1.7 | [acidanthera/RestrictEvents](https://github.com/acidanthera/RestrictEvents) | `8a244c696234c4ae1dec7c318664c57b685f9d2501e8bb6649ec805b21e9fa3a` | none |
| `NVMeFix.kext` | 1.1.4 | [acidanthera/NVMeFix](https://github.com/acidanthera/NVMeFix) | `d32c743220011f162ac104cdf73b1bce71cca77459a54553e461b89b9837a4d6` | none |
| `BrightnessKeys.kext` | 1.0.4 | [acidanthera/BrightnessKeys](https://github.com/acidanthera/BrightnessKeys) | `f47210181030a6005ccb17c125dbe81b359c2c9fd74c12b99b860b8b5f44a72a` | none |
| `VoodooPS2Controller.kext` | 2.3.8 | [acidanthera/VoodooPS2](https://github.com/acidanthera/VoodooPS2) | `be6f3aa9dc88954462e422df78d8d7d129cb91b8fd03c4018ef04cc9f472e8f0` | none |
| `VoodooPS2Keyboard`/`Mouse`/`Trackpad` | 2.3.8 | same | see `payloads.tsv` | none |
| `VoodooI2C.kext` | 2.9.1 | [VoodooI2C/VoodooI2C](https://github.com/VoodooI2C/VoodooI2C) | `dbb7865eec4eeb0ea4e303789407c8cbbbfa3a944780191bd9943279c64ebe9f` | none |
| `VoodooGPIO`/`I2CServices`/`Input`/`I2CHID` | bundled | same | see `payloads.tsv` | none |
| `CpuTopologyRebuild.kext` | 2.0.2 | [b00t0x/CpuTopologyRebuild](https://github.com/b00t0x/CpuTopologyRebuild) | `0e36496ff627db53002ad04bd8e1e910909e083e587609fb9b472d5f2d7bde07` | none |
| `SimpleHDA.kext` | 1.0.0 | [laobamac/SimpleHDA](https://github.com/laobamac/SimpleHDA) | `f74c9dbddf43266c97c5f72cd76498bce1d6b5bd3731a947be62f1378b4c7954` | none |
| `USBToolBox.kext` | 1.2.0 | [USBToolBox/kext](https://github.com/USBToolBox/kext) | `c5c8dc205a079ee3f90b7875fb5ff622e4f15d32f29cf519123dab2822c422b7` | none |
| `UTBMap.kext` | 1.1 | generated by USBToolBox | `-` | port map for board `8A28` |
| `XHCI-unsupported.kext` | 0.9.2 | [RehabMan/OS-X-USB-Inject-All](https://github.com/RehabMan/OS-X-USB-Inject-All) | `-` | injector only |
| `IntelBluetoothFirmware.kext` | 2.5.1 | [OpenIntelWireless/IntelBluetoothFirmware](https://github.com/OpenIntelWireless/IntelBluetoothFirmware) | `2da7a9d1213fbb0ba1a6b11396ea416fd06ba4597dfca569aa1c6f53ada25617` | none |
| `IntelBTPatcher.kext` | 2.5.1 | same | `f3e2547873c7505d3a83e8d60452f9f09dc0858495934201ff5ade52aee174b3` | none |
| `BlueToolFixup.kext` | 2.7.3 | [acidanthera/BrcmPatchRAM](https://github.com/acidanthera/BrcmPatchRAM) | `e11fc0299c230e716fbbb9d2eb6df54c1494338a9201f903bab22c410ff57f0b` | none |
| `HoRNDIS.kext` | — | [jwise/HoRNDIS](https://github.com/jwise/HoRNDIS) | `1a24f71a23a11b10f3c3419d55ad4b08fcf4ea86048988e6126d9ba577f30890` | none |

`payloads.tsv` is authoritative if a version string here and there disagree;
the table is a summary of that file, not a second source.

## 4. Wi-Fi variants

| Kext | Version | Source | SHA-256 | Notes |
|---|---|---|---|---|
| `AirportItlwm.kext` | 2.4.1 | downstream Tahoe/VTD build, byte-identical to the copy in the same-model reference | `cf11f2da43a7a98513417e059dcbd6e1800bb28bf5e821ff950794901e0c65dc` | default; native menu; **not** an official OpenIntelWireless release |
| `itlwm.kext` | 2.3.0 | [OpenIntelWireless/itlwm](https://github.com/OpenIntelWireless/itlwm) release `v2.3.0` | `63952b0b7373e6a7e75a9a4f8ab0789a52a48ceb99bb0c8d0f387004d487690b` | fallback; needs HeliPort |

Only one is copied into a built EFI. The config template contains a single
placeholder entry (`WIFI_BUNDLE.kext`) that the build script rewrites.

### AirportItlwm 2.4.1 provenance

This needs to be stated precisely, because the version number suggests an
upstream release that does not exist:

- OpenIntelWireless's newest official release is **2.3.0**, published
  2024-06-09. It predates Tahoe and has no Tahoe asset; `master` and `pending`
  are source branches, not released binaries. There is no official 2.4.1.
- The bundled executable reports `2.4.1` and embeds
  `AirportItlwm-Tahoe.build` and `tahoe-vtd-1`. It declares
  `com.apple.iokit.IOSkywalkFamily 1.0` and AirPort personalities, which is
  consistent with a Tahoe/VTD fork build made with GitHub Actions.
- It is **byte-identical** to the `AirportItlwm.kext` shipped by
  [retropineaple/whateverxe-hp-envy-x360](https://github.com/retropineaple/whateverxe-hp-envy-x360)
  commit `9809987`. That repository is the same laptop model and reports it
  working on Tahoe 26.7.1.
- The binary alone does not identify the fork or commit it was built from, so
  this repository pins it by SHA-256 and treats it as a third-party payload.
  Do not silently replace it; if a newer build is used, record its source and
  hash here first.
- Validation status: proven by the reference on 26.7.1; **not yet validated on
  26.7.2**. If it does not attach, use the `itlwm` variant rather than mixing
  drivers.

`itlwm` 2.3.0 is the official release and is independent of the macOS
networking stack, which is why it remains the fallback.

## 5. WhateverXe Graphics (not in this repository)

The patched Apple framebuffer/accelerator, `AppleIntelTGLCompat` and the
`AMFIPass` Mod build are installed **inside macOS** by the upstream package.
They are Apple/Intel-derived and are deliberately not vendored here.

| Item | Value |
|---|---|
| Package | `WhateverXe-Graphics-0.3.1.pkg` |
| Upstream | [b00t0x/WhateverXe-Graphics](https://github.com/b00t0x/WhateverXe-Graphics) release 0.3.1 |
| SHA-256 | `bd8b449431b1bf3815f9011ad3e13c7038012d17aed54dfb2aecfce6b9089623` |
| Pairs with | WhateverXe 0.6.0 (`adlp-edp` fork), `AppleIntelTGLCompat` 0.6.0 |
| Installs to | `/Library/Extensions` and `/Library/GPUBundles`, then AuxKC |

The same-model reference was tested with 0.3.1, and its installed
`AppleIntelTGLCompat` is 0.6.0 (the identifier this machine's logs show).
Graphics 0.3.2 ships Compat 0.6.1 and pairs with upstream 0.6.1; it is not
used here. Do not mix the two pairs.

One local change is applied on top of the injected 0.6.0 kext after
installation: `scripts/macos/patch-wex-tahoe-mmio.sh` updates the five-byte
`_IOProtectCacheMode+0xCC` signature for macOS 26.7.2 (25G332). It changes only
that constant in `WhateverXe.kext` and keeps a backup; see
[docs/03-graphics.md](03-graphics.md).

Citation: the 0.6.1 release notes add "experimental internal display (eDP) and
brightness support for Alder Lake-N / Twin Lake and Alder Lake-H/P/U / Raptor
Lake-H/P/U GPUs"; Graphics 0.3.2's changelog pairs it with 0.6.1. The same
release notes do not change the VBT parser's duplicate-DDI behaviour.

## 6. AppleALC patch

The only binary in the repository that is not byte-identical to an upstream
release is `AppleALC.kext`.

- Upstream: AppleALC 1.9.8 RELEASE.
- Patch: `tools/patches/patch-applealc-alc245-layout11.py`, adapted with
  attribution from the same-model reference repository.
- Effect: removes every `SignalProcessing` block from layout 11, avoiding a
  kernel panic in `EupDSP::ConfigParamInt` when recording.
- Reproducible result: SHA-256
  `ee5ed2952138f819e4cd679649e3c3a042ed0796d4782c296fade2982e02849d`.
- Tested only against 1.9.8; the patch depends on that release's compressed
  layout offsets.

`tools/patches/README.md` has the exact commands. If the shipped hash and the
reproduced hash differ, the patch or the upstream archive changed; do not ship
the result until the difference is explained.

## 7. Pinned archives

The release archives used to populate the repository:

| Archive | SHA-256 | Used for |
|---|---|---|
| `OpenCore-1.0.8-RELEASE.zip` | `2011e8b7216ecb2645d97ea710df965947edd406846e92050b9bc4190be6d27b` | OpenCore, drivers, resources |
| WhateverXe 0.6.1 RELEASE zip | `46c8cd684461db7f84a971e7479770c423f73d52d45addfb48242176b9eb04fc` | `efi/variants/gpu-wex061` (diagnostic) |
| `WhateverXe-Graphics-0.3.1.pkg` | `bd8b449431b1bf3815f9011ad3e13c7038012d17aed54dfb2aecfce6b9089623` | installed separately, not in Git |

The other kexts were taken from their named upstream releases; their
individual hashes in `payloads.tsv` are the authority.

## 8. What is deliberately not included

| Item | Why |
|---|---|
| Apple's patched Xe drivers and `AppleIntelTGLCompat` | Installed by the upstream Graphics package; Apple-derived, not redistributable under this repository's license |
| `private/identity.plist` | Contains the machine's activated serial/MLB/UUID/ROM |
| `mine/EFI` | The previous EFI, kept as local evidence only |
| `LOGS/` | Machine logs and ioreg contain the identity |
| `WhateverGreen.kext` | Must never be enabled next to WhateverXe |
| `NootedGreen` | Different driver, different support matrix; not validated for `0x46AA` |
| `RTCMemoryFixup` and the `_S3` patch | Sleep workaround that changes semantics; deferred, see [06](06-usb-acpi-power.md) |
| `SSDT-BTEN` | Bluetooth power-cycle workaround; Bluetooth already works |

The absence of a file is a decision, not an omission. If one of these is added
later, add the hash, the reason and the test that justified it here.

## 9. Reference standards

Official documentation is the primary source for every schema-level or
quirk-level decision. Where a public EFI and the official documentation
disagree, the official documentation wins; the deviation is recorded in
[02-audit.md](02-audit.md).

| Topic | Reference |
|---|---|
| Config schema, keys, types, quirks | OpenCorePkg 1.0.8 `Docs/Configuration.pdf` and `Docs/Sample.plist` |
| Debug/`Target`/logging | OpenCorePkg `Docs/Configuration.pdf`, `Misc/Debug` |
| UEFI drivers and OpenCanopy | OpenCorePkg `Docs/Configuration.pdf`, `UEFI/Drivers`, `Misc/Boot` |
| ACPI hot patches | [Dortania Getting Started With ACPI](https://dortania.github.io/Getting-Started-With-ACPI/) |
| Laptop install and SMBIOS | [Dortania OpenCore Install Guide](https://dortania.github.io/OpenCore-Install-Guide/) |
| Post-install (USB map, power) | [Dortania OpenCore Post-Install](https://dortania.github.io/OpenCore-Post-Install/) |
| WhateverXe behaviour and arguments | [b00t0x/WhateverXe](https://github.com/b00t0x/WhateverXe) README/CHANGELOG |
| Graphics package contents/licensing | [b00t0x/WhateverXe-Graphics](https://github.com/b00t0x/WhateverXe-Graphics) `THIRD_PARTY.md` |
| AppleALC layouts | [AppleALC supported codecs](https://github.com/acidanthera/AppleALC/wiki/Supported-codecs) |
| USB mapping | [USBToolBox](https://github.com/USBToolBox/tool) |
| Intel Wi-Fi/Bluetooth | [OpenIntelWireless docs](https://openintelwireless.github.io/) |

`audit/config-schema.json` is the machine-readable extract of the OpenCore
1.0.8 config structure used by the verifier; it is not a replacement for
`ocvalidate`.

## 10. Updating a payload

1. Download the upstream release and record its archive hash.
2. Replace the payload in `efi/base` or `efi/variants`.
3. Run `make inventory` and inspect the diff; every changed hash must be
   intentional.
4. Update the table above, `NOTICE.md`, and (if the version pairing changed)
   [03-graphics.md](03-graphics.md) and [07-install.md](07-install.md).
5. `make variants` must pass for all five combinations.
6. Boot the machine and record the result. An update that was not booted is
   not a verified update.

Do not update several unrelated payloads in one commit. The Git history is
part of the provenance: one version change, one explanation.
