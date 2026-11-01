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
   | `hp-adlp-edp` (default) | 0.6.0 | 0.3.1 | 0.6.0 |
   | `wex061` (diagnostic) | 0.6.1 | 0.3.2 | 0.6.1 |

   ```sh
   kextstat | grep -Ei 'whateverxe|tgl'
   # org.b00t0x.WhateverXe (0.6.x)
   # org.b00t0x.AppleIntelTGLCompat (0.6.x)
   ```

   A 0.6.1 kext with Compat 0.6.0 (or the reverse) will load but not start.
   The 0.6.1 variant is only a control; it cannot parse this unit's VBT.

2. **Boot arguments match the kext.** `-wex-adlp-edp`,
   `-wex-reset-restore` and `-wex-no-multicontext` exist only in the 0.6.0
   variant. The 0.6.1 build must not carry them; the build script adds them
   only for `--gpu hp-adlp-edp`. An unknown `-wex-*` argument is ignored, but
   a *partial* set is a sign that the config and kext were mixed by hand.

3. **No second graphics driver.** `WhateverGreen.kext` must not be enabled
   next to WhateverXe, and NootedGreen/NootedRed must not be present. The
   verifier fails the build if they are.

4. **The 26.7.2 MMIO gate.** This is the known failure on 25G332:

   ```sh
   ioreg -l | grep -E 'TGLMMIOStrongUCRouted|TGLMMIOStrongUCPreflight'
   ioreg -l | grep -E 'N97NativeStartAllowed|N97NativeProbeBlocked'
   ioreg -l | grep TGLTahoeMMIOGuard
   ```

   In the broken state `TGLMMIOStrongUCRouted = No`,
   `TGLMMIOStrongUCPreflight = No`, `N97NativeStartAllowed = No` and
   `N97NativeProbeBlocked = Yes`. Run

   ```sh
   sudo scripts/macos/patch-wex-tahoe-mmio.sh \
     --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext \
     --kernel /Library/Developer/KDKs/KDK_26.7.2_25G332.kdk/System/Library/Kernels/kernel
   ```

   and reboot. The script needs the KDK that matches the running build; it
   parses the kernel Mach-O with perl, so no Command Line Tools are required.
   It must print `old const`, `real call`, `patched` and `verify`. **No output
   means it never reached the patch**: update the script and check the kernel
   candidates it prints. After the reboot `TGLTahoeMMIOGuard` must show the
   ninth byte check (index 16) as `1`; a remaining `0` means the ESP you
   patched is not the ESP that booted. See [docs/03-graphics.md](03-graphics.md).

   If the script said `verify: e85ff302` but index 16 is still `0`, inspect the
   binary that is actually on the ESP before rerunning anything:

   ```sh
   K=/Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext/Contents/MacOS/WhateverXe
   xxd -s 0x17904 -l 8 "$K"    # c745 a8e8 5ff3 02b9  <- live immediate patched
   xxd -s 0xcdf8e -l 5 "$K"    # e82f f302 00        <- dead copy stays original
   ```

   `e82f…` at `0x17907` means this ESP is not the one that booted. `e85f…` at
   `0xCDF8E` means the older script patched the dead copy next to the
   `TGLTahoeMMIOGuard` string; rerun the current script, which restores it and
   patches the real `movl` immediate. Reboot explicitly from the USB with F9
   if the internal ESP also holds an OpenCore copy.

5. **The panel record is not the problem.** `WhateverXeFirmwarePanel` is
   `[0, 0, 9, 0, 0]` on this unit because the VBT sets `panel_type = 0xFF`
   (panel chosen by PnP ID). That is expected and patch 0004 admits the Combo A
   DP route without it. Do not chase the placeholder `LFP_PanelName` strings;
   WhateverXe does not read them.

6. **Try the other driver variant**, with the same config otherwise:

   ```sh
   ./scripts/build_efi.py --gpu wex061 --out build/EFI-wex061 --force
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
| `AirportItlwm` loaded, no networks | Check `kmutil showloaded \| grep -i airport`; if absent on 26.7.2, rebuild with `--wifi itlwm` |
| `itlwm` loaded, no networks | HeliPort installed and running; `ifconfig` shows the `en` interface |
| Native menu missing with AirportItlwm | AirportItlwm build does not match this macOS; it is tied to the networking stack. Switch to the `itlwm` fallback |
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

## 9. Capturing a boot that dies with a black screen

After the 26.7.2 MMIO patch the machine reaches the accelerator but
WindowServer dies at the first panel modeset (see
[03-graphics.md](03-graphics.md#where-the-2672-bring-up-stops-now-2026-11-01)).
Nothing can be typed on that screen, and a safe-mode capture has none of the
live `N97FB*` properties. Record the boot from inside macOS instead.

On a boot that works (safe mode is fine), from the USB stick:

```sh
sudo /Volumes/MACUSB/install-boot-capture.sh --volume MACUSB
```

The installer writes `/usr/local/bin/openmac-wex-capture.sh` and a root
LaunchDaemon `org.openmac.wex-capture`. It does not touch the EFI, the kernel
or any kext. Remove it later with `--uninstall`.

Reboot normally. The daemon runs at load, before login, waits for
`/Volumes/MACUSB`, and then:

1. takes the **first snapshot immediately** (`t000/`) — the previous version
   waited 25 s and the machine died first;
2. runs a 1 Hz heartbeat next to it, written to the stick and synced every ten
   beats;
3. repeats a cheap snapshot at 3 s, 8 s, 15 s, 30 s and 60 s, and a full one at
   120 s;
4. writes `status.txt`, `DONE` and only then the one-shot sentinel.

Every capture command is bracketed in `run.log` by `begin <name>` / `end
<name>`. If a line has a `begin` without its `end`, that command is what hung.

| Time after daemon start | Content |
|---|---|
| 0 s | `t000/`: framebuffer, accelerator and display ioreg, boot args |
| 3-60 s | `t003/` … `t060/`: the same three ioreg dumps |
| 120 s | `t120/`: the same plus `ioreg -l`, kextstat, `kmutil`, dmesg, `system_profiler`, `ps` |
| after 120 s | `t120/`: plus `log show` for kernel/WindowServer, `nvram` (identity redacted), new `DiagnosticReports` |

It then reboots the machine (`--no-reboot` keeps it off), so no power-button
hold is needed. The sentinel at `/var/db/openmac-wex-capture.done` is written
**after** `DONE`: a boot that dies early leaves no sentinel, so the next boot
captures again instead of leaving you blind. Delete that file (or rerun the
installer) to re-arm manually. To stop the capture for good, `--uninstall`.

Read `/Volumes/MACUSB/wex-capture-YYYYmmdd-HHMMSS/` on another machine,
starting with `status.txt`, `run.log` and `heartbeat.txt`.

Interpretation:

| Observation | Meaning | Next step |
|---|---|---|
| `heartbeat.txt` stops before `t000/summary.txt` exists | not the display path: the kernel or the disk I/O died during the daemon's first second | boot with `-wex-noaccel`, then with `-wex-display13-offline` |
| `t000/` exists, heartbeat stops before `t003/` | the material hangs on the first framebuffer/accelerator read, i.e. inside the FB path | `run.log` names the hung command; boot `-wex-noaccel` next |
| heartbeat stops between two snapshots | the kernel wedged at/after the first modeset | same, plus compare `t000/ioreg_wex.txt` with the reference values |
| heartbeat reaches `DONE` | only the graphics session died; the kernel is alive | focus on FB memory and IOAccel surfaces; the snapshots bracket the event |
| `N97FBApertureNotReady` present | the aperture path returned "not ready" before allocation | read `N97FBApertureFirstFailure` and `N97FBMemory`; do not change DVMT |
| `N97FBScanoutAllocate` absent while `N97FBApertureFirstFailure` is non-zero | allocation refused, not deferred | capture the pool layout (`N97GTTopologyReady`, `N97Memory*`) and stop |
| `TGLMMIOStrongUCPreflight = No` with `UCRouted = Yes` | the pmap check found another mapping | collect `TGLMMIOMappingEvidence` |

Do not add the capture daemon to the EFI: it is a one-shot diagnostic for the
installed system, not part of the boot payload.

## 10. Emergency recovery

1. Boot the backup EFI from a USB stick. The internal ESP is not required.
2. If the picker is unreachable, boot Linux and restore the backed-up `EFI`
   folder (see [07-install.md](07-install.md)).
3. If macOS itself is damaged, boot Recovery and reinstall the Graphics
   package with `installer -pkg … -target /Volumes/…`; the EFI is independent
   of the installed system.
4. `mine/EFI` is the exact previous working EFI on this machine. It is local,
   gitignored, and is the last-resort rollback.

Never delete the only working EFI before the new one has booted at least once.

## 11. Reporting a graphics bug upstream

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
