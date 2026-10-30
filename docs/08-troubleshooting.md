# 08 — Troubleshooting

Work from evidence, not from guesses. Most "the EFI broke" reports on this
platform are one of: a payload that was not copied, a boot argument that does
not match the installed driver, or a macOS point update that invalidated a
kext. The tables below map symptoms to the specific check that distinguishes
them.

Related documents: [03-graphics.md](03-graphics.md) (the open problem),
[04-wifi-bluetooth.md](04-wifi-bluetooth.md),
[05-audio.md](05-audio.md), [06-usb-acpi-power.md](06-usb-acpi-power.md),
[07-install.md](07-install.md) (backup and rollback).

## 0. Capture evidence before changing anything

A debug build is produced with:

```sh
./scripts/build_efi.py --debug --out build/EFI-debug --force
```

It adds `-v debug=0x100` to the boot arguments and sets
`Misc/Debug/AppleDebug`, `ApplePanic`, `DisplayLevel 2147483650` and
`Target 67` (logging + console + file). OpenCore then writes a log next to
`OpenCore.efi`:

```
EFI/OC/opencore-YYYY-MM-DD-HH-MM-SS.txt
```

Copy that file off the ESP before rebooting again — it is overwritten by the
next boot.

Once macOS is up (even without graphics acceleration), collect:

```sh
mkdir -p ~/Desktop/wex-report && cd ~/Desktop/wex-report
sw_vers > sw_vers.txt
kmutil showloaded > kmutil.txt
kextstat > kextstat.txt
ioreg -l -p IODeviceTree > ioreg-devicetree.txt
ioreg -l -p IOService > ioreg-ioservice.txt
ioreg -rc IONDRVFramebuffer -d1 > iondrv.txt
ioreg -rc AppleIntelFramebuffer > aifb.txt
ioreg -rc IntelAccelerator > accel.txt
system_profiler SPHardwareDataType SPDisplaysDataType SPAudioDataType \
  SPBluetoothDataType SPUSBDataType > system-profiler.txt
log show --last 10m --predicate 'process == "kernel"' > kernel.log
pmset -g > pmset.txt
nvram -p > nvram.txt
```

`nvram -p` contains the serial number. Strip it before posting anywhere:

```sh
sed -E 's/(MLB|ROM|SystemSerialNumber|HW_MLB|HW_ROM|system-id)[^[:space:]]*/\1 <redacted>/g' \
  nvram.txt > nvram-redacted.txt
```

The local `LOGS/` folder in this workspace is an example of that bundle; it is
gitignored because it contains the identity.

## 1. The machine does not reach macOS

| Symptom | Most likely cause | Check / action |
|---|---|---|
| Firmware boots straight to Windows/Linux | Boot order or `BOOTx64.efi` not on the ESP | Select the USB/ESP entry in the firmware boot menu; confirm `EFI/BOOT/BOOTx64.efi` and `EFI/OC/OpenCore.efi` exist |
| OpenCore picker does not appear | Wrong `BOOTx64.efi`, or Secure Boot enabled | Disable Secure Boot; copy the whole `EFI` folder, not only `OC` |
| Picker appears, macOS entry missing | `HfsPlus.efi` missing/not loaded, or the volume is APFS with an unsupported `MinDate` | Confirm `HfsPlus.efi` is in `UEFI/Drivers` and enabled; `UEFI/APFS/MinDate`/`MinVersion` are `-1` in the template |
| macOS entry appears, black screen immediately | Graphics driver failed before console init | Boot the `--debug` build; if there is still no verbose text, remove `WhateverXe.kext` temporarily to prove the rest of the EFI boots |
| Verbose text stops at `[EB|#LOG:EXITBS:START]` | Booter/firmware mismatch | Try `DevirtualiseMmio` off, then `RebuildAppleMemoryMap`/`SyncRuntimePermissions` together off; one variable at a time |
| Stops after `AppleIntelTGLCompat` / `[IGFB][BRINGUP]` | Graphics bring-up, not boot | See section 2; the rest of the system is usually alive |
| Prohibited sign | SMBIOS/secure-boot/kext signature problem | `SecureBootModel = Disabled`, `csr-active-config = 03080000`, `AMFIPass.kext` enabled |
| Reboot loop after a macOS update | Kext built for the previous kernel | Boot the old EFI, update WhateverXe + Graphics together, then retry |
| Kernel panic names `EupDSP::ConfigParamInt` | Unpatched AppleALC recording path | Use the patched AppleALC from this repo ([05-audio.md](05-audio.md)) |

`ocvalidate` is the authoritative config check. It needs macOS (or a built
OpenCore tree); run it before blaming the hardware:

```sh
/path/to/OpenCore/Utilities/ocvalidate/ocvalidate /Volumes/EFI/EFI/OC/config.plist
```

The repository's `scripts/verify_efi.py` is a faster pre-flight check (schema,
payloads, kext order, one Wi-Fi driver, no conflicting GPU kexts).

## 2. Graphics: the 19 MB fallback

This is the known failure state of the old install, not a new bug. The
symptom is:

```
VRAM (Total): 19 MB
Kernel Extension Info: No Kext Loaded
```

and, in IORegistry:

```
N97Admission              = Yes
N97NativePreflight        = Yes
N97GTTopologyReady        = Yes
N97NativeStartAllowed     = No
WhateverXeFirmwarePanel   = <mostly zero>
WEXDisplay13TCBootPorts   = <all zero>
IONDRVFramebuffer count   = 1
AppleIntelFramebuffer     = 0
IntelAccelerator          = 0
```

Read [03-graphics.md](03-graphics.md) for the full reasoning. The short
version: the driver loads, memory admission passes, and the native start is
blocked at display/panel qualification. Do not "fix" this by changing SMBIOS,
stolen memory or `-igfxdvmt`; those checks already passed.

Checks, in order:

1. **Version pairing.** `WhateverXe.kext` and the installed Graphics package
   must match:

   | EFI variant | WhateverXe | Graphics package | Compat |
   |---|---|---|---|
   | `wex061` | 0.6.1 | 0.3.2 | 0.6.1 |
   | `hp-adlp-edp` | 0.6.0 | 0.3.1 | 0.6.0 |

   ```sh
   kextstat | grep -Ei 'whateverxe|tgl'
   # org.b00t0x.WhateverXe (0.6.x)
   # org.b00t0x.AppleIntelTGLCompat (0.6.x)
   ```

   A 0.6.1 kext with Compat 0.6.0 (or the reverse) will load but not start.

2. **Boot arguments match the kext.** `-wex-adlp-edp`,
   `-wex-reset-restore` and `-wex-no-multicontext` exist only in the 0.6.0
   variant. The 0.6.1 build must not carry them; the build script adds them
   only for `--gpu hp-adlp-edp`. An unknown `-wex-*` argument is ignored, but
   a *partial* set is a sign that the config and kext were mixed by hand.

3. **No second graphics driver.** `WhateverGreen.kext` must not be enabled
   next to WhateverXe, and NootedGreen/NootedRed must not be present. The
   verifier fails the build if they are.

4. **The panel record.** In IORegistry, `WhateverXeFirmwarePanel` should
   contain a non-zero panel descriptor. In the failed state it is
   `00…00 09 00…00` and `WhateverXeFirmwareChecksum` is `0`. The captured
   `WhateverXeVBTRaw` also contains the literal placeholder string
   `LFP_PanelName` repeated instead of a panel model. That is firmware data,
   not something the EFI can change.

5. **Try the other driver variant**, with the same config otherwise:

   ```sh
   ./scripts/build_efi.py --gpu hp-adlp-edp --out build/EFI-hp --force
   ```

   Install Graphics 0.3.1 before booting it. If the fallback works and 0.6.1
   does not, the problem is 0.6.1's ADL-P eDP detection, not this config.

6. **Capture and report.** If neither variant starts, the useful report is the
   evidence bundle from section 0 plus:

   ```sh
   ioreg -l | grep -E 'WhateverXe(VBTRaw|FirmwarePanel|FirmwarePortRecords|FirmwareChecksum)'
   ioreg -l | grep -E 'N97(NativeStartAllowed|NativeProbeBlocked|NativeKernelReady)'
   ```

   Include the BIOS version (F.35), the panel EDID, and the macOS build
   (25G332).

### Black screen but the machine is alive

The panel is driven by the boot framebuffer before WhateverXe takes over, so
"no image" is not the same as "no boot". Test with an external display or by
checking that the caps-lock light / SSH / network still respond. Then boot
`--debug` and read the last verbose lines. Do not immediately reinstall macOS.

### External display works, internal panel does not

That isolates the eDP path: the accelerator can be alive while the internal
panel qualification fails. Record `WEXDisplay13BootReady`,
`WEXDisplay13TCBootPorts` and `WEXADLPPanelDP`, then report upstream. The
Type-C port table being all zero is expected on a laptop with no Type-C
display output wired through the iGPU.

### Backlight

`SSDT-PNLF.aml`, `AAPL,backlight-control` and the DSDT `GFX0.DD1F` → `DD02`
notify patch are all present. If brightness keys do nothing but the panel is
on, check `BrightnessKeys.kext` is loaded and that the patch count is 2 (not
0). If the panel is black at full brightness, this is the panel-record problem
above, not the backlight table.

### Video playback / camera crashes

Both the EliteBook840G8 and XPS13Plus projects report crashes in the
WhateverXe VA path and move Apple's bundle aside:

```sh
sudo mkdir -p /Library/GPUBundles.disabled
sudo mv /Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle \
        /Library/GPUBundles.disabled/
sudo killall UVCAssistant VTDecoderXPCService
```

This forces CPU decode. It is a trade-off, not a fix; keep hardware decode if
it works.

## 3. Wi-Fi and Bluetooth

| Symptom | Check |
|---|---|
| No Wi-Fi interface | Exactly one of `itlwm.kext` / `AirportItlwm.kext` in `OC/Kexts` and in `Kernel/Add` |
| `itlwm` loaded, no networks | HeliPort installed and running; `ifconfig` shows the `en` interface |
| Native menu missing with AirportItlwm | AirportItlwm build does not match this macOS; it is tied to the networking stack |
| Both drivers present | Rebuild with one `--wifi` choice; never merge the variants |
| Bluetooth greyed out | `kmutil showloaded \| grep -i bluetooth`; confirm the two NVRAM variables are cleared on boot; power-cycle the module |
| Wi-Fi dies after sleep | Known Intel limitation on this generation; reboot is the reliable recovery |
| Wi-Fi works, iMessage does not | Identity/NVRAM problem, not Wi-Fi; see section 6 |

The two required Bluetooth NVRAM values are in `NVRAM/Add` and `NVRAM/Delete`:

```
bluetoothExternalDongleFailed    = 00
bluetoothInternalControllerInfo  = 0000000000000000000000000000
```

Do not add Broadcom/OCLP blockers (`IOSkywalkFamily`,
`com.apple.iokit.IO80211Family`) to this machine.

## 4. Audio

Speakers are silent by design: the CS35L41 amplifiers have no macOS driver.
Headphones and the internal microphone are the working paths.

| Symptom | Check |
|---|---|
| No audio devices at all | `SimpleHDA.kext` enabled and `MinKernel 25.0.0`; `AppleALC.kext` loaded |
| Headphones work, mic panics the machine | Unpatched AppleALC; use the shipped kext |
| Wrong device names | `shda-lang=en` present |
| No audio after update | SimpleHDA is Tahoe-only; re-check `MinKernel`/`MaxKernel` |
| `alcid` ignored | Remove any `layout-id` from `DeviceProperties`; the boot argument wins and duplicates confuse the lookup |

The controller is `8086:51CC`, which AppleALC does not list; the config injects
`device-id = C8510000` (`0x51C8`, same family). Removing that property makes
audio disappear even though the codec is correct.

## 5. USB, input, camera

| Symptom | Check |
|---|---|
| USB ports dead after wake | `SSDT-USB-Reset.aml` + `SSDT-USBW.aml` present; `USBToolBox.kext` + `UTBMap.kext` loaded |
| Some ports missing | The map is board-specific (`8A28`); regenerate with USBToolBox instead of editing |
| USB installer not visible | `HfsPlus.efi` (or `OpenHfsPlus.efi`) loaded |
| Touchpad dead | Expected on this unit: the I2C touchpad is dead in hardware (Windows/Linux too) |
| Touchscreen dead | Known; VoodooI2C attaches but the panel is not calibrated/supported |
| Camera dead | Known on this platform; check `system_profiler SPCameraDataType` and USB topology before changing kexts |
| Keyboard works, trackpad does not | VoodooPS2 trackpad plugin is for the PS/2 path; the I2C touchpad needs VoodooI2C and working GPIO |

`SSDT-GPI0.aml` and the four ACPI patches (GPI0 `_STA`, PNLF, `_OSI`, brightness
notify) must stay enabled; disabling them breaks I2C and backlight together.

## 6. Identity, activation and SIP

The identity is injected into `build/EFI/OC/config.plist` from
`private/identity.plist`. If iCloud/iMessage asks to sign in again after a
rebuild, one of these changed:

```sh
# On macOS, compare with the values in private/identity.plist:
ioreg -l | grep -E 'IOPlatformSerialNumber|IOPlatformUUID'
nvram -p | grep -E 'MLB|ROM|SystemSerialNumber'
```

Checklist:

- `SystemProductName` is `MacBookPro16,2`.
- `SystemSerialNumber`, `MLB`, `SystemUUID`, `ROM` are the original values,
  not blanks and not regenerated.
- `PlatformInfo/UpdateSMBIOSMode` is `Custom`.
- `csr-active-config` is `03080000` (required by the graphics stack).
- `SecureBootModel` is `Disabled`.
- NVRAM was reset after a change (`ResetNvramEntry.efi` in the picker), then
  the machine rebooted once so OpenCore can write the values back.

A blank SMBIOS is the most common cause: `scripts/verify_efi.py` fails the
build unless the identity was injected. If you built on another machine, copy
`private/identity.plist` there too; it is never in Git.

Do not sign out of iCloud to "test" activation. Changing the serial after
activation can require Apple to re-validate the machine.

## 7. Battery, power and thermals

| Symptom | Check |
|---|---|
| No battery percentage | `SMCBatteryManager.kext` loaded; `SSDT-SBUS.aml` present |
| Battery drains in sleep | Sleep is broken on this firmware; disable sleep (below) |
| High idle temperature | `CpuTopologyRebuild.kext` loaded; `SSDT-PLUG-ALT-12.aml` present; check `pmset -g therm` |
| CPU name wrong | `revpatch=cpuname` in NVRAM (written by the config) and `RestrictEvents.kext` loaded |
| Fan always on | Expected under sustained load without GPU acceleration; the CPU renders the UI |

Recommended power settings while graphics is unresolved:

```sh
sudo pmset -a hibernatemode 0 standby 0 sleep 0
sudo pmset -a displaysleep 10
sudo rm -f /var/vm/sleepimage
```

## 8. Sleep and wake

The HP firmware enters sleep and never wakes; this is documented by the
same-model reference and by EliteBook840G8, and it happens with or without
WhateverXe. The workaround (patch `_S3` to soft-off, add `RTCMemoryFixup` and
`rtcfx_exclude=80-AB`) is described in
[06-usb-acpi-power.md](06-usb-acpi-power.md) but deliberately **not applied**:
it changes sleep into shutdown and needs validation on this BIOS.

Do not debug sleep at the same time as graphics. One variable at a time.

## 9. Emergency recovery

1. Boot the backup EFI from a USB stick. The internal ESP is not required.
2. If the picker is unreachable, boot Linux and restore the backed-up `EFI`
   folder (see [07-install.md](07-install.md)).
3. If macOS itself is damaged, boot Recovery and reinstall the Graphics
   package with `installer -pkg … -target /Volumes/…`; the EFI is independent
   of the installed system.
4. `mine/EFI` is the exact previous working EFI on this machine. It is local,
   gitignored, and is the last-resort rollback.

Never delete the only working EFI before the new one has booted at least once.

## 10. Reporting a graphics bug upstream

A report that can be acted on contains:

- WhateverXe version and hash (`shasum -a 256 WhateverXe.kext/Contents/MacOS/WhateverXe`).
- Graphics package version and Compat version.
- macOS build (`sw_vers`) and BIOS version/date.
- `ioreg -l` for the iGPU node: `WhateverXeVBTRaw`,
  `WhateverXeFirmwarePanel`, `WhateverXeFirmwarePortRecords`,
  `WhateverXeFirmwareChecksum`, the `N97*` keys and `WEXDisplay13*`.
- The panel EDID (from Windows/Linux or `ioreg -l | grep -i edid`).
- Whether the same machine works with the 0.6.0 `adlp-edp` variant.
- The OpenCore log and `kernel.log` from a `--debug` boot.

Do not open an issue that only says "no acceleration" without the VBT and the
`N97*` values: those two determine whether the failure is panel detection or
something else entirely.
