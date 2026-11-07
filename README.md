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
> macOS update. Two version-gated userspace shims also need replacing:
> `scripts/macos/patch-mtl-impostor.sh` fixes the Graphics 0.3.1 Metal shim
> (Battery pane and ControlCenter crash loop), and
> `scripts/macos/patch-va-tglva.sh` fixes the VA shim (App Store/HEIC decode
> hang and dynamic wallpaper). Both gates accept only the exact build 24H32;
> this machine is 24H232.
>
> **Boot-tested on 15.8.2 from this repository (2026-11-03).** The built stick
> boots to the desktop, `TGLSequoiaMMIOGuard` entry 19 is `01`,
> `IntelAccelerator` is present, `VRAM (Dynamic, Max)` is 1536 MB and
> `system_profiler` reports **Metal 2**. The internal 2880×1800 OLED is online
> at **Looks like 1440 × 900** HiDPI. The remaining known limits are Metal 2
> (not Metal 3) and the GPU's internal "Intel(R) TGL Unknown" name. Runtime
> shader compilation **works** through the OS-native AIR converter; the
> `XeCompilerAdapter` sandbox denials in the log are expected and harmless.
> The Battery pane, ControlCenter archive crashes and App Store HEIC hang are
> **fixed** by the 0.4.0 `impostor.dylib` and `TGLVA` shims (verified
> 2026-11-04/05). Two GPU
> resets were logged while App Store previews first loaded; that is being
> watched separately. The desktop itself is GPU-composited. See
> [docs/03-graphics.md](docs/03-graphics.md#heichevc-decode-and-the-tglva-guard)
> and
> [docs/08-troubleshooting.md](docs/08-troubleshooting.md#app-store-hangs-on-screenshots-or-quick-look-tglva-guard).

## Status: what works

Tested on this exact unit unless marked otherwise. "Untested" means no attempt
was made — it is not a claim that the feature fails.

### Working

| Area | Notes |
|---|---|
| Boot and install | OpenCore 1.0.8, macOS Sequoia 15.8.2 (24H232) |
| CPU | 2 P-cores + 8 E-cores / 12 threads, XCPM 400–4700 MHz |
| Graphics | Internal 2880×1800 OLED, HiDPI **Looks like 1440×900**, Metal 2, hardware HEVC/HEIC decode |
| Wi-Fi | Intel AX211 via `AirportItlwm` 2.4.0, native menu |
| Bluetooth | Intel AX211 via `IntelBluetoothFirmware` |
| USB | USB-A and USB-C data; USB-C charging |
| Trackpad | I2C precision trackpad, full gestures (`VoodooI2C` + `VoodooI2CHID`) |
| Keyboard | Works, including brightness keys (`BrightnessKeys`) |
| Audio out | 3.5 mm jack and USB-C output both work |
| Battery | Charge/percentage/health and the Battery settings pane (after the `impostor.dylib` fix) |
| App Store / Quick Look | HEIC/HEVC previews and screenshots work (after the `TGLVA` fix) |
| Power management | XCPM P-states, `balanced`/`battery`/`performance` profiles |

### Not working

| Area | Cause | Status |
|---|---|---|
| **Internal speakers** | Cirrus Logic **CS35L41** smart amplifiers have no macOS driver. `AppleALC` layout 11 drives the ALC245 codec for the jack, not the speaker amps. | Hardware limitation; not attempted |
| **Camera** | The camera sits behind the Intel **Alder Lake Imaging Signal Processor** (`8086:465d`, IPU6) with a MIPI sensor. macOS has no IPU6/MIPI camera driver, and it is not a USB UVC device, so there is no fallback. | Not attempted; owner does not need it |
| **microSD card reader** | Realtek **RTS5288** PCIe SD UHC-I controller (`10ec:5228`) has no macOS driver. | Not attempted; not tested physically |
| **Touchscreen** | The panel glass is physically broken and touch does not work in Windows either. This is a hardware fault, not a macOS/driver problem. | Cannot be tested |
| **Sleep / wake** | HP firmware limit: the machine enters sleep but never wakes ("Sleep Wake failure in EFI"). Sleep is disabled rather than faked. | Known limit, see [docs/06](docs/06-usb-acpi-power.md#sleep--known-broken-on-this-platform) |

### Untested / partial

| Area | Notes |
|---|---|
| Internal microphone | The codec exposes an input device, but recording has not been verified on this unit |
| HDMI / external display | No cable test was recorded; USB-C video output is also untested |
| Thunderbolt / USB4 | The USB-C ports work as USB and for charging; Thunderbolt/USB4 alt modes are untested |
| Sensors | CPU temperature/voltage are exposed by `SMCProcessor`; fan RPM and board sensors are not (no `SMCSuperIO`), and the ambient-light stub is not a real sensor |
| Fingerprint / IR login | No fingerprint reader appears in the macOS USB/I2C inventory, and Windows Hello IR is unavailable for the same IPU6 reason as the camera. Not tested |

### Two numbers that look wrong but are not

- **`1,88 GHz`** in About This Mac is the invariant TSC (CPUID leaf 0x15:
  38.4 MHz × 98 / 2 = 1881.6 MHz), not the core clock. OpenCore 1.0.8 has no
  key for it, and changing it would break timekeeping. The CPU really runs
  400–4700 MHz; see [docs/08](docs/08-troubleshooting.md#cpu-speed-display-shows-188-ghz).
- **`2 Cores, 12 Threads`** in Geekbench is CpuTopologyRebuild's SMT spoof, not
  a missing-core bug. All 12 threads are online and SMBIOS reports 10 physical
  cores; see [docs/14](docs/14-measurements.md#5-hybrid-topology-looks-wrong-but-is-intentional).

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
scripts/macos/patch-mtl-impostor.sh      installs the 0.4.0 impostor.dylib
                                        (fixes Battery pane / ControlCenter)
scripts/macos/patch-va-tglva.sh         installs the 0.4.0 TGLVA shim
                                        (fixes App Store / HEIC decode hang)
scripts/macos/test-metal-runtime-compile.sh  proves on-demand Metal compilation
                                        works despite XeCompilerAdapter denials
scripts/macos/metal-archive-workaround.plist  Metal archive agent (experiment)
scripts/macos/install-metal-archive-workaround.sh  installs/removes that agent
scripts/macos/check-metal-env.sh         verifies the agent and GUI environment
scripts/macos/openmac-diag.sh            continuous per-user diagnostics collector
scripts/macos/post-install-check.sh      one-shot CPU/GPU/display/battery report
scripts/macos/power-profile.sh           apply balanced/battery/performance pmset profiles
scripts/macos/install-power-daemon.sh    re-apply the power profile at every boot
scripts/macos/power-audit.sh             measure CPU package power and XCPM state
scripts/macos/battery-watch.sh           real discharge watts and projected runtime
scripts/macos/battery-cap-compare.sh     cap-off run vs the recorded balanced baseline
scripts/macos/install-boot-capture.sh    black-screen boot capture daemon
scripts/macos/restore-opencode-migration.sh  restore chat + repo on macOS
scripts/migrate-to-macos.sh              build the Linux → macOS migration bundle
docs/                     hardware, audit, graphics, Wi-Fi, audio, install, bring-up, measurements
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

## From zero to a working install

The complete checklist — prerequisites, expected output, failure modes and
rollback — is [docs/13-bring-up.md](docs/13-bring-up.md). This is the short
version.

1. **Clone and create your identity.** Never reuse another machine's values.

   ```sh
   git clone https://github.com/lamjiidii1/OpenMac.git
   cd OpenMac
   cp private/identity.example.plist private/identity.plist
   $EDITOR private/identity.plist      # serial, MLB, UUID, ROM
   ```

2. **Build and verify.** `make build` assembles `build/EFI` and runs the
   structural checks; it fails on a blank SMBIOS identity.

   ```sh
   make build && make verify
   ```

3. **Prepare the boot medium.** Create the macOS installer USB, then copy
   `build/EFI` to its EFI System Partition. Back up any EFI you replace.
   The expected layout is `EFI/BOOT/BOOTx64.efi` and `EFI/OC/OpenCore.efi`.
   On an existing install, patch the EFI the machine actually boots from — on
   this unit that is the USB stick, not `disk0s1` (the HP/Windows ESP).

4. **Set the BIOS.** Secure Boot and Fast Boot off, VT-d on, DVMT at the HP
   default, no RAID. Record the BIOS version; a VBT change can break eDP.

5. **Install macOS** with the OpenCore picker, then complete the first boot
   checks in [docs/13 §6](docs/13-bring-up.md#6-first-boot-checks):
   WhateverXe/Compat **0.6.0**, real CPU name, 10 cores / 12 threads, panel at
   **Looks like 1440 × 900**, Metal 2, `TGLSequoiaMMIOGuard` entry 19 = `01`.

6. **Install the matching userspace package**: WhateverXe Graphics **0.3.1**
   (never 0.3.2/0.4.0 with this EFI), then restart. A fresh build already has
   the 24H232 MMIO constant; repair an older stick with
   `scripts/macos/patch-wex-sequoia-mmio.sh`.

7. **Apply the post-install fixes** in the table below, in order.

### Post-install fixes

These are the problems that appear only after acceleration works.

| Symptom | Fix | Why |
|---|---|---|
| **Battery** pane crashes System Settings; ControlCenter crash-loops | `sudo bash scripts/macos/patch-mtl-impostor.sh --test` | The 0.3.1 Metal archive shim only enables on build 24H32; this install is 24H232 |
| **App Store** hangs on screenshots/Quick Look; HEIC previews spin | `sudo bash scripts/macos/patch-va-tglva.sh --test` | The VA shim also gates on 24H32, so HEIC/HEVC decode never starts |
| Safari video freezes or Metal archive errors | `sudo bash scripts/macos/install-metal-archive-workaround.sh` (optional) | Same build-gate class |
| Hot, laggy normal use | HiDPI mode + both shims + power profile | 1× mode redraws 5.2 MP; a thrashing shim burns CPU |

The `1,88 GHz` line in About This Mac is not a bug and has no fix: it is the
invariant TSC, not the core clock. See **Two numbers that look wrong** above.

The scripts back up what they replace. The patch scripts support `--status`
and `--rollback`; the daemon installer supports `--uninstall`; the MMIO
repair supports `--dry-run`. Full reasoning is in
[docs/03](docs/03-graphics.md), [docs/06](docs/06-usb-acpi-power.md) and
[docs/08](docs/08-troubleshooting.md).

## Power, battery and thermals

The HP firmware gives macOS no fan control, so the reliable levers are XCPM
low power mode, the display mode and the idle timers.

| Profile | Battery | AC |
|---|---|---|
| `balanced` (default) | `lowpowermode 1` (cap), display sleep 5 s, TCP keepalive off | `lowpowermode 0` (uncapped), display sleep 10 s |
| `battery` | capped | also capped, display sleep 5 s |
| `performance` | uncapped | uncapped |

Apply once (it is source-aware, so macOS uses the battery values when
unplugged and the AC values when plugged in):

```sh
sudo bash scripts/macos/power-profile.sh balanced
```

To re-assert it at every boot — the battery menu's **Low Power Mode** toggle
writes the same key — install the daemon:

```sh
sudo bash scripts/macos/install-power-daemon.sh balanced
```

Measured on 2026-11-05 (AC, all-core): package power falls from **19.9 W to
10.3 W** with the cap, and sustained clock from about 3.6 GHz to 1.8 GHz.

Measured on 2026-11-07 (on battery, `balanced`, reading a PDF at 1440×900
with no background apps): **7.93 W average**, 10.51 W peak, **~6 h projected**
over 14 minutes (77 % → 74 %). That is the realistic document-reading figure;
the 1:51 projection seen under the agent UI was load, not the hardware. Full
method and caveats: [docs/14 §4](docs/14-measurements.md#4-battery-life-a-clean-run-and-why-load-dominates).

The orange battery icon **is** Low Power Mode; on battery it is expected, and
turning it off removes the cap (more heat, faster drain). Measure real runtime
with `bash scripts/macos/battery-watch.sh`; do not trust a benchmark taken
under the OpenCode desktop, whose helper and renderer keep about two cores
busy. Numbers and caveats:
[docs/06 § Measured effect](docs/06-usb-acpi-power.md#measured-effect-2026-11-05).

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
  `-vi2c-force-polling` (the touchpad works without extra polling).
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
| [docs/13-bring-up.md](docs/13-bring-up.md) | End-to-end: clone → build → install → post-install fixes → verification |
| [docs/14-measurements.md](docs/14-measurements.md) | Power, thermal, Geekbench and battery numbers with their caveats |

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
