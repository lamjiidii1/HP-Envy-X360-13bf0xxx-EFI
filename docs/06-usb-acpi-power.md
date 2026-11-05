# 06 — ACPI, USB, and power

## ACPI tables (12)

All tables are enabled in `ACPI/Add` in this order. The set is the same-model
reference's set; the two additions relative to the old EFI are marked.

| # | Table | Purpose |
|---|---|---|
| 1 | `SSDT-ALS0.aml` | Ambient light sensor stub so macOS does not look for a missing device |
| 2 | `SSDT-SBUS.aml` | SMBus device for SMC keys |
| 3 | `SSDT-EC.aml` | Fake embedded controller (`ACID0001`) for Catalina+ |
| 4 | `SSDT-GPI0.aml` | Enables the GPIO controller used by I2C HID devices |
| 5 | `SSDT-MCHC.aml` | Host bridge / memory controller device |
| 6 | `SSDT-PLUG-ALT-12.aml` | `plugin-type = 1` for the 12-thread i7-1250U (XCPM) |
| 7 | `SSDT-PNLF.aml` | Backlight control for the OLED eDP panel |
| 8 | `SSDT-RTCAWAC.aml` | AWAC RTC clock fix |
| 9 | `SSDT-USB-Reset.aml` | **new** — resets USB ports on wake |
| 10 | `SSDT-USBX.aml` | USB power properties (`UsbPowerDelivery`, sleep current) |
| 11 | `SSDT-XOSI.aml` | `_OSI` → `XOSI` target for the Windows 10/11 spoof |
| 12 | `SSDT-USBW.aml` | **new** — USB wake companion for `SSDT-USB-Reset` |

`SSDT-EC.aml` is functionally identical to the old EFI's copy; only the OEM ID
(`VZPSS` vs `CORP`) and OEM table ID differ, because it was recompiled by a
different toolchain.

### ACPI patches (4)

| Patch | Find → Replace | Scope | Why |
|---|---|---|---|
| GPI0 `_STA` → `XSTA` | `14 5F 53 54 41` → `14 58 53 54 41` | all tables | The SSDT provides the real `_STA` |
| `PNLF` → `XNLF` | `50 4E 4C 46` → `58 4E 4C 46` | all tables | Prevent duplicate PNLF device |
| `_OSI` → `XOSI` | `5F 4F 53 49` → `58 4F 53 49` | all tables | Windows 10/11 spoof used by SSDT-XOSI |
| Brightness notify | `86 5E 5E 5E 2E 47 46 58 30 44 44 31 46` → `…44 44 30 32` | DSDT only, count 2 | HP notifies `GFX0.DD1F`; the panel is `DD02` |

The last patch is the only one with `TableSignature = DSDT` and `Count = 2`.
The old EFI applied it to every table with `Count = 0`; that is broader than
necessary and was tightened to match the reference.

## USB

The port map is `UTBMap.kext` 1.1, generated with USBToolBox for board 8A28:

| Controller | Ports |
|---|---|
| `TXHC` (Thunderbolt/USB4) | `SS01`, `SS02` |
| `XHCI` (PCH) | `HS01`–`HS05`, `SS01`, `SS02` |

`USBToolBox.kext` 1.2.0 loads the map. `XHCI-unsupported.kext` 0.9.2 lets
macOS attach to the PCH controller that is not in Apple's default list.

The old EFI's map is byte-identical to the reference's, so it was kept as-is.
If a port ever misbehaves, regenerate the map with USBToolBox rather than
editing the plist by hand.

## Power management

| Component | Role |
|---|---|
| `SSDT-PLUG-ALT-12.aml` | Declares 12 logical CPUs (2 P-cores + 8 E-cores, 12 threads) and `plugin-type=1` so XCPM manages P/E cores |
| `CpuTopologyRebuild.kext` 2.0.2 | Rebuilds the cache topology so P-cores are not misclassified as E-cores |
| `SMCProcessor.kext` | CPU temperature/voltage sensors |
| `SMCBatteryManager.kext` | Battery status and charge threshold |
| `VirtualSMC.kext` 1.3.9 | SMC emulation |
| `NVMeFix.kext` 1.1.4 | NVMe power management and quirks (MinKernel 18) |
| `RestrictEvents.kext` 1.1.7 | CPU name (`revpatch=cpuname`), no board-id patch |

`ProvideCurrentCpuInfo` is enabled in `Kernel/Quirks`; `revcpu=1` and
`revpatch=cpuname` are on the boot-args line, and the custom CPU name comes from
`revcpuname` in NVRAM (boot-args cannot carry a name with spaces reliably).

## Sleep — known broken on this platform

The reference laptop reports:

> Sleep: the laptop enters sleep but never wakes ("Sleep Wake failure in EFI"),
> even without graphics drivers. It's a firmware limit; sleep is turned off
> instead.

The EliteBook840G8 project documents the same HP firmware behaviour and offers
a workaround:

- Patch `_S3` (`5F 53 33 5F 12 07 04 0A 05`) to soft-off (`…07`) so macOS
  "sleep" powers the machine off cleanly. Open applications are lost.
- Add `RTCMemoryFixup.kext` and `rtcfx_exclude=80-AB` to stop AppleRTC from
  corrupting BIOS settings, plus `DisableRtcChecksum`.

**This repository does not apply that workaround by default.** It changes what
"sleep" means and needs hardware validation on this exact BIOS. It is recorded
here as the next experiment if sleep matters more than fast wake. Do not apply
it blindly together with the graphics debugging: one variable at a time.

Recommended macOS settings until then:

```sh
sudo pmset -a hibernatemode 0 standby 0
sudo rm -f /var/vm/sleepimage
sudo pmset -a sleep 0
sudo pmset -a displaysleep 10
```

### Observed on this machine (2026-11-05)

The failure is not hypothetical. With the default settings the machine entered
idle sleep at 14:19 and produced:

```text
/Library/Logs/DiagnosticReports/Sleep Wake Failure_2026-11-05-142031_MacBook-Pro.diag

Sleep Wake failure in EFI
Failure code:: 0x00000000 0x0000001f
Time Awake Since Boot: 25s
```

The only way back was a forced power-off, which is also why that boot lost the
temporary test script. The settings above (`sleep 0`, `hibernatemode 0`,
`standby 0`, `displaysleep 10`) are now applied and survived the reboot;
`/var/vm/sleepimage` is absent.

**`sleep 0` does not disable lid-close sleep.** Closing the lid still puts the
machine into S3 and it will not wake. Either shut down before carrying it
closed, or use:

```sh
sudo pmset -a disablesleep 1   # lid close keeps running; machine stays warm
sudo pmset -a disablesleep 0   # undo
```

## Booter and kernel quirks that matter

| Quirk | Value | Why |
|---|---|---|
| `AvoidRuntimeDefrag` | true | Standard for modern firmware |
| `DevirtualiseMmio` | true | Needed for this firmware's MMIO layout |
| `MmioWhitelist` (5 entries) | ECAM `0xC0000000`, `0xF9000000`, `0xFF000000`, `0xFF700000`, `0xFE010000` | Keep firmware regions mapped |
| `RebuildAppleMemoryMap` | true | Required with DevirtualiseMmio |
| `SyncRuntimePermissions` | true | Required with RebuildAppleMemoryMap |
| `ResizeAppleGpuBars` | -1 | Do not resize GPU BARs; 0 can hang this firmware |
| `FixupAppleEfiImages` | true | OpenCore 1.0.x image fixups |
| `ProvideCurrentCpuInfo` | true | Hybrid CPU topology |
| `AppleXcpmCfgLock` | true | BIOS does not expose CFG lock |
| `DisableLinkeditJettison` | true | Required by Lilu on modern macOS |
| `SetApfsTrimTimeout` | -1 | Leave TRIM to the firmware/SSD |

These values are the reference's; the old EFI used the same ones (except the
debug-related `Misc` settings, which are unrelated).
