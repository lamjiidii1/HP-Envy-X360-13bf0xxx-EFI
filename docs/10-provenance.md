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
| `OC/Drivers/btrfs_x64.efi` | `d675d680eab57ddf8822527e950aada47ba0ddbb101e4a62f8493f4425c72b70` | none; rEFInd 0.14.1 btrfs filesystem driver |
| `OC/Drivers/HfsPlus.efi` | `a55b5fff36578864ba6792c4c6369c71f6f35b61dd5a853ddf8583cd36c31d8f` | none |

`HfsPlus.efi` comes from
[acidanthera/OcBinaryData](https://github.com/acidanthera/OcBinaryData), not
from the OpenCore archive. `btrfs_x64.efi` comes from rEFInd 0.14.1
(`RefindPkg/filesystems/btrfs`), not from OpenCorePkg, and keeps rEFInd's
GPL-3.0 license.

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
| `WhateverXe.kext` | 0.6.0 | b00t0x + [retropineaple adlp-edp](https://github.com/retropineaple/WhateverXe/tree/adlp-edp), prebuilt in [whateverxe-hp-envy-x360](https://github.com/retropineaple/whateverxe-hp-envy-x360) commit `8100282` | `197da23bbe5a09731ef9517a0a6f9dabe52ab1f9b0c885a841a064190770288c` | unmodified published binary (patch series 54); the build applies the 24H232 Sequoia constant (§5); Sequoia build (variant `gpu-hp-adlp-edp`) |
| `WhateverXe.kext` | 0.8.0 | b00t0x + [lamjiidii1/WhateverXe](https://github.com/lamjiidii1/WhateverXe) `main` @ `dffff32` + XE-PM cap patch | `fa7dcf28a516b084dd94fdea63e1ecdfe9d8e6e0c26054290e58900a72d468e7` | Dynamic MMIO; first-child-wins VBT parsing; fixed Combo A DP route; masked speculative Type-C routes; Metal POSH leak fix and flip deduplication; XE-PM honors `lowpowermode` caps (variant `gpu-wex080-adlp`) |
| `WhateverXe.kext` | 0.7.0 | [b00t0x/WhateverXe](https://github.com/b00t0x/WhateverXe) | `ea156ad48ce7e29b2b409232b4d0623abd492935428b43da79239899fa2b0f3f` | none; control only, rejects this VBT (variant `gpu-wex070`) |
| `VirtualSMC.kext` | 1.3.9 | [acidanthera/VirtualSMC](https://github.com/acidanthera/VirtualSMC) | `bf91e9542b86c20acaf210353a93742291c49328e2d14b03fa0fa4fc52b3b5ce` | none |
| `SMCProcessor.kext` | 1.3.9 | acidanthera/VirtualSMC | `dcf738671431721692f752e3df43acaaa02c93788ae7b21153504b07db01be32` | none |
| `SMCBatteryManager.kext` | 1.3.9 | acidanthera/VirtualSMC | `791d81018a5374ddc63b8d97ba976e03bab6d241fec08ec3487e4c4e74fc24e4` | none |
| `AppleALC.kext` | 1.9.8 | [acidanthera/AppleALC](https://github.com/acidanthera/AppleALC) | `ee5ed2952138f819e4cd679649e3c3a042ed0796d4782c296fade2982e02849d` | ALC245 layout 13 active; the 1.9.8 binary retains the layout 11 DSP removal, see §6 |
| `RestrictEvents.kext` | 1.1.7 | [acidanthera/RestrictEvents](https://github.com/acidanthera/RestrictEvents) | `8a244c696234c4ae1dec7c318664c57b685f9d2501e8bb6649ec805b21e9fa3a` | none |
| `NVMeFix.kext` | 1.1.4 | [acidanthera/NVMeFix](https://github.com/acidanthera/NVMeFix) | `d32c743220011f162ac104cdf73b1bce71cca77459a54553e461b89b9837a4d6` | none |
| `BrightnessKeys.kext` | 1.0.4 | [acidanthera/BrightnessKeys](https://github.com/acidanthera/BrightnessKeys) | `f47210181030a6005ccb17c125dbe81b359c2c9fd74c12b99b860b8b5f44a72a` | none |
| `VoodooPS2Controller.kext` | 2.3.8 | [acidanthera/VoodooPS2](https://github.com/acidanthera/VoodooPS2) | `be6f3aa9dc88954462e422df78d8d7d129cb91b8fd03c4018ef04cc9f472e8f0` | none |
| `VoodooPS2Keyboard`/`Mouse`/`Trackpad` | 2.3.8 | same | see `payloads.tsv` | none |
| `VoodooI2C.kext` | 2.9.2 | [VoodooI2C/VoodooI2C](https://github.com/VoodooI2C/VoodooI2C), patched fork [lamjiidii1/VoodooI2C](https://github.com/lamjiidii1/VoodooI2C) | `28fa3a0cb332572c32ef0bce5ba6a53191dc4a819880cb39526c91e4be04d011` | Alder Lake-LP `0x51E8` personality and `transferI2CToAddress` bridge |
| `ITHC.kext` | 0.1.0 | [quo/ithc-linux](https://github.com/quo/ithc-linux) port, sources in `drivers/ithc` | `b47a4b7d5c89c25e39718c7225c48deb24b36f6387df31115677eefbb001210f` | Intel THC touchscreen; BSD-2-Clause; verified on the undamaged half of this unit's cracked panel (2026-11-11); `-ithcoff` disables it, `-ithcpoll` polls instead of using MSI |
| `CirrusAudioFixup.kext` | 1.2.1 | [lamjiidii1/CirrusAudioFixup](https://github.com/lamjiidii1/CirrusAudioFixup), upstream author hoaugtr | `1f0b6df9c01c9c7482e9677300d63216753c3771a2e3955239e7681e0b78ce99` | HP Envy CS35L41 DSP tuning and EFI calibration; Cirrus Logic license in the bundle |
| `TGLDmic.kext` / `TGLDmic.driver` | 0.6.0 | [labrouss/TGLDmic](https://github.com/labrouss/TGLDmic), fork [lamjiidii1/TGLDmic](https://github.com/lamjiidii1/TGLDmic) | `c9d980d6f1768eb79aba28ebea6cf59b8ee459645be16009e8553f7e6f6e57af` kext, `6e75f82f6a0237a40f20810df591b90e9c2161e34c389c5eb5e7534180eddca0` HAL | Intel-signed `sof-adl.ri` embedded; HAL installed from `scripts/macos/TGLDmic.driver` |
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
| `AirportItlwm.kext` (Tahoe) | 2.4.1 | downstream Tahoe/VTD build, `tahoe-vtd-1`; published as the `AirportItlwm-Tahoe` asset of [laobamac/itlwm](https://github.com/laobamac/itlwm) `v2.4.0-alpha` | `cf11f2da43a7a98513417e059dcbd6e1800bb28bf5e821ff950794901e0c65dc` | default for macOS 26; native menu; **alpha**, not an OpenIntelWireless release |
| `AirportItlwm.kext` (Sequoia) | 2.4.0 | [laobamac/itlwm](https://github.com/laobamac/itlwm) `v2.4.0-alpha`, `sequoia-vtd-1` build | `c3b95b3b8b54f9efbb9362d9dd3c29a354bb45e2dbc50a2ca3ec54f0f94bfc58` | macOS 15 build; native menu; **alpha** |
| `itlwm.kext` | 2.3.0 | [OpenIntelWireless/itlwm](https://github.com/OpenIntelWireless/itlwm) release `v2.3.0` | `63952b0b7373e6a7e75a9a4f8ab0789a52a48ceb99bb0c8d0f387004d487690b` | fallback; needs HeliPort |

Only one is copied into a built EFI. The config template contains a single
placeholder entry (`WIFI_BUNDLE.kext`) that the build script rewrites.

### AirportItlwm provenance

This needs to be stated precisely, because the version numbers do not come
from an OpenIntelWireless release:

- OpenIntelWireless's newest official release is **2.3.0**, published
  2024-06-09, and stops at Sonoma 14.4. There is no official 2.4.0 or 2.4.1.
- `AirportItlwm` links against `IO80211Family`/`IOSkywalkFamily`, so a build is
  tied to one macOS family. The Tahoe binary (`2.4.1`, `tahoe-vtd-1`) cannot
  attach on Sequoia, and the Sequoia binary (`2.4.0`, `sequoia-vtd-1`) cannot
  attach on Tahoe.
- **Tahoe build:** reports `2.4.1`, embeds `AirportItlwm-Tahoe.build` /
  `tahoe-vtd-1`, declares `IOSkywalkFamily 1.0`, and is byte-identical to the
  `AirportItlwm.kext` shipped by the same-model reference
  [retropineaple/whateverxe-hp-envy-x360](https://github.com/retropineaple/whateverxe-hp-envy-x360)
  at commit `9809987`. The [laobamac/itlwm](https://github.com/laobamac/itlwm)
  `v2.4.0-alpha` release publishes a Tahoe asset with the same version and
  build tag. The binary alone does not identify its fork or commit, so it is
  pinned by SHA-256.
- **Sequoia build:** the **Sequoia** asset of
  [laobamac/itlwm](https://github.com/laobamac/itlwm) release `v2.4.0-alpha`
  (`AirportItlwm-Sequoia-v2.4.0-RELEASE-alpha-7204c69.zip`, SHA-256
  `263d35e5954808f43bde17b9695b675aefc2f6d4cded71306b1b6575aea61a82`).
  It reports `2.4.0` and embeds `AirportItlwm-Sequoia.build` / `sequoia-vtd-1`.
  The fork documents it for Darwin 24.2.0–24.99.99, i.e. Sequoia.
- Both are pinned by SHA-256 and treated as third-party payloads. Do not
  silently replace them; if a newer build is used, record its source and hash
  here first.
- Validation status: the Sequoia build is **boot-tested on 15.8.2 (24H232),
  2026-11-03**; the Tahoe build boots the macOS 26 install on this machine.
  If either fails to attach, use the `itlwm` variant rather than mixing
  drivers.

`itlwm` 2.3.0 is the official release and is independent of the macOS
networking stack, which is why it remains the fallback.

## 5. WhateverXe Graphics (not in this repository)

The patched Apple framebuffer/accelerator, `AppleIntelTGLCompat` and the
`AMFIPass` Mod build are installed **inside macOS** by the upstream package.
They are Apple/Intel-derived and are deliberately not vendored here.

| Item | Value |
|---|---|
| Package (installed) | `WhateverXe-Graphics-0.4.1.pkg`, installed 2026-11-09 |
| Upstream | [b00t0x/WhateverXe-Graphics](https://github.com/b00t0x/WhateverXe-Graphics) release 0.4.1 (2026-11-07) |
| SHA-256 | `7f7ce3b924ad421cff0c4f30534598858474b8c9539c4b889a461bc1d5fed02c` (matches upstream `SHA256SUMS`) |
| Pairs with | WhateverXe 0.8.0-adlp (`wex080-adlp`), `AppleIntelTGLCompat` 0.8.0 |
| Installs to | `/Library/Extensions` and `/Library/GPUBundles`, then AuxKC |
| Payload | `AppleIntelTGLCompat` 0.8.0; Apple TGL kexts and GPUBundles `16.0.32` / `16.0.0` |
| Rollback package | `WhateverXe-Graphics-0.3.1.pkg`, SHA-256 `bd8b449431b1bf3815f9011ad3e13c7038012d17aed54dfb2aecfce6b9089623`; pairs with the 0.6.0 Sequoia build and Compat 0.6.0 |
| Control package | `WhateverXe-Graphics-0.4.0.pkg`, SHA-256 `7a1b5015b3e6e8b522f26c25df85c313471c9142564a0b57356cddd2c88b9510` (95,200,795 bytes), pairs with WEX 0.7.0 / Compat 0.7.0 |
| Included shim | `impostor.dylib` for Sequoia, SHA-256 `1cc38c7941333d3f4b88316795c78ca0095addf945fa35b6ff8634ecc93a1060`, from `payloads/Sequoia/Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle/Contents/MacOS/`; replaces the 0.3.1 shim (`53c93a6e…fb57b`) named in `scripts/macos/patch-mtl-impostor.sh` |
| Included shim | `TGLVA` for Sequoia, SHA-256 `db879dbae1c708b5fcdb3c39e251e63e635016d19885e9186fdc6baca68414aa`, from `payloads/Sequoia/Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle/Contents/MacOS/TGLVA`; replaces the 0.3.1 shim (`0c4df393…e35ac`) named in `scripts/macos/patch-va-tglva.sh`. The adjacent `AppleIntelTGLGraphicsVADriver` differs only in its PCI device-ID dispatch table |

0.4.1 was verified before installation rather than assumed from the version
number. Its Compat reports `OSBundleCompatibleVersion = 0.5.0` and exports the
same 14 symbols as 0.6.0. The two Apple TGL kexts and the Metal and VA bundle
executables have byte-identical `__TEXT,__text` to the 0.3.1 payload installed
here, so every hard-coded symbol offset WhateverXe validates is unchanged. The
OpenGL driver was rebuilt in 0.4.0 for the extra GPU IDs. The package
provenance lists source hashes that match this repository's fork exactly:
`AppleIntelTGLCompat.cpp` `2a5f7622…`, `GraphicsPolicy.plist` `dd955549…`,
`kern_xelp_os.hpp` `0a1e96c4…` and `kern_xelp_devices.hpp` `7df14948…`.

The functional difference is the 0.4.0/0.4.1 servicing fix: Compat accepts
compatible macOS kernel updates by OS family and ABI instead of an exact build
string. The package also already contains the 0.4.0 Metal and VA shims, so
`patch-mtl-impostor.sh` and `patch-va-tglva.sh` are only needed after a
deliberate rollback to 0.3.1. Installation rebuilt the AuxKC with Compat 0.8.0
(UUID `F6997294-0598-30BD-98B3-38E0EEB2FA7E`); the new version loads on the
next reboot.

Graphics 0.3.1 is no longer installed on the machine but is kept in
`~/MacOS/PostInstall` for rollback. It remains the validated pair for the
0.6.0 Sequoia build; 0.4.1's identical ABI makes that pairing plausible, but
it has not been boot-tested with 0.6.0 and is not claimed here. The 0.4.0
package remains the control for `EFI-wex070`. Do not mix a 0.7.0 kext with a
0.6.0 or 0.8.0 package.

**The stored payload is unmodified; the built kext is not.** The file in
`efi/variants/gpu-hp-adlp-edp` is the published `197da23b…` binary. On Sequoia
15.8.2 (24H232) the `--gpu hp-adlp-edp` build rewrites its ninth Sequoia MMIO
constant from `E8 71 CB 02` to `E8 A1 CB 02` in the output, so that build's
`OC/Kexts/WhateverXe.kext` executable is `6bf93338…`
(`6bf9333808658eb6a5e828fbd2413a1ca33b6553380fa8a3af49e6dd3bea60ba`).
`BUILD-INFO.plist` records the patch, and `verify_efi.py` checks the output.
The transformation is one byte at `0x16FCF` (plus the literal-pool copy at
`0xCF212`): `71` → `a1`. `--skip-sequoia-mmio-patch` builds the unmodified
binary for another macOS build.

Two tools describe or reproduce the change:

- `scripts/macos/patch-wex-sequoia-mmio.sh` applies it to a stick in place and
  can read the real kernel bytes from a KDK.
- The Tahoe-era `scripts/macos/patch-wex-tahoe-mmio.sh` patches a different
  routine that Sequoia never executes; it is kept for a future Tahoe boot.

The Sequoia diagnosis and the first working patched binary come from
[dwiwinarno911/opencore-msi-tigerlake-irisxe](https://github.com/dwiwinarno911/opencore-msi-tigerlake-irisxe)
(WhateverXe 0.6.1, same 24H232 build). That repository also supplies the
Metal-archive LaunchAgent, redistributed here as
`scripts/macos/metal-archive-workaround.plist` with no functional change.
`scripts/macos/install-metal-archive-workaround.sh` is local glue that installs
it under the label filename, verifies the environment and removes it again; it
is not upstream code. The agent is retained as a **negative result**: it was
measured not to fix the Battery pane on 24H232 (see
[docs/03-graphics.md](03-graphics.md#metal-archives-on-24h232)). The actual
fix, `scripts/macos/patch-mtl-impostor.sh`, pins the 0.4.0 `impostor.dylib`
from b00t0x/WhateverXe-Graphics and is described in §5.
See [docs/03-graphics.md](03-graphics.md#the-24h232-mmio-signature) and
[docs/08-troubleshooting.md](08-troubleshooting.md#metal-apps-crash-or-safari-video-freezes-24h232).

Citation: the 0.6.1/0.7.0 release notes add internal eDP/brightness support for
Alder Lake-H/P/U, but the same release notes do not change the VBT parser's
duplicate-DDI behaviour, and 0.7.0 still rejects this machine's VBT (measured,
not assumed). That is why the 0.6.0 `adlp-edp` fork remains the default.

## 6. AppleALC patch

The only *stored* binary in the repository that is not byte-identical to an
upstream release is `AppleALC.kext`. (`WhateverXe.kext` is stored unmodified
and patched only in the build output; see §5.)

- Upstream: AppleALC 1.9.8 RELEASE.
- Patch: `tools/patches/patch-applealc-alc245-layout11.py`, adapted with
  attribution from the same-model reference repository.
- Effect: removes every `SignalProcessing` block from layout 11, avoiding a
  kernel panic in `EupDSP::ConfigParamInt` when recording.
- Active layout: **13** (`alcid=13`). The stored binary still contains the
  layout 11 patch, but that layout is no longer selected; the layout 13 path
  does not use those DSP blocks.
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
| WhateverXe 0.7.0 RELEASE zip | `5548c78f687134580913b9f600fb8b0f16bb49f7d430bcc82de7fa9761d4f62b` | `efi/variants/gpu-wex070` (control) |
| `WhateverXe.kext` (0.8.0-adlp, XE-PM cap fix) | `fa7dcf28a516b084dd94fdea63e1ecdfe9d8e6e0c26054290e58900a72d468e7` | `efi/variants/gpu-wex080-adlp` (built from `lamjiidii1/WhateverXe` `main` @ `dffff32` + `tools/patches/whateverxe-xepm-hwp-caps.patch`; default) |
| AirportItlwm Tahoe build (2.4.1, `tahoe-vtd-1`) | `cf11f2da43a7a98513417e059dcbd6e1800bb28bf5e821ff950794901e0c65dc` | `efi/variants/wifi-airportitlwm-tahoe` (default for macOS 26) |
| `AirportItlwm-Sequoia-v2.4.0-RELEASE-alpha-7204c69.zip` | `263d35e5954808f43bde17b9695b675aefc2f6d4cded71306b1b6575aea61a82` | `efi/variants/wifi-airportitlwm` |
| `WhateverXe-Graphics-0.4.1.pkg` | `7f7ce3b924ad421cff0c4f30534598858474b8c9539c4b889a461bc1d5fed02c` | installed 2026-11-09; pairs with the 0.8.0-adlp default, not in Git |
| `WhateverXe-Graphics-0.3.1.pkg` | `bd8b449431b1bf3815f9011ad3e13c7038012d17aed54dfb2aecfce6b9089623` | rollback for the 0.6.0 Sequoia build, not in Git |
| `WhateverXe-Graphics-0.4.0.pkg` | `7a1b5015b3e6e8b522f26c25df85c313471c9142564a0b57356cddd2c88b9510` | control only; pairs with 0.7.0, not in Git |

The 0.6.0 `adlp-edp` binary is taken from the same-model reference
(`retropineaple/whateverxe-hp-envy-x360` commit `8100282`, 2026-11-01) and
pinned by its executable hash `197da23b…`. It is the published patch-series-54
binary, with no local modification in Git; the `hp-adlp-edp` Sequoia build
patches its 24H232 Sequoia constant as described in §5. The older commit
`9809987` shipped
`c090b9dd…`; that is the binary the previous EFI used, and it remains in Git
history of this repository.

The 0.8.0 default is rebuilt from the `main` tip of
[lamjiidii1/WhateverXe](https://github.com/lamjiidii1/WhateverXe) at `dffff32`
(which already carries the `adlp-edp` patchset, the Display 13 Type-C route
mask, `-wex-mtl-poshfix` and `-wex-flip-dedupe`) plus
`tools/patches/whateverxe-xepm-hwp-caps.patch`. The patch changes XE-PM's
`xpSetMult` so it converts XCPM's 100 MHz request into the current core's HWP
units (78.741 MHz on P-cores, 100 MHz on E-cores; core type from CPUID leaf
`1AH`) instead of rewriting every lower request to the core's highest. That
restores the `lowpowermode` cap while keeping turbo. The result is pinned as
`fa7dcf28…`. It replaces the earlier `cc7b83a2…` binary, which remains in Git
history and in the live ESP at `EFI/OC/Kexts-backup/`. The rebuild is not
byte-identical to that binary (21 fewer symbols, ~8 KB less text) because it
is built from a later source tip; it was boot-tested on 2026-11-11 and the
cap fix was measured on that boot.

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
5. `make variants` must pass for all four combinations.
6. Boot the machine and record the result. An update that was not booted is
   not a verified update.

Do not update several unrelated payloads in one commit. The Git history is
part of the provenance: one version change, one explanation.
