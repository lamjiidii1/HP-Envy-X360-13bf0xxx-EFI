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

For the six post-install questions (Metal version, CPU name, scaling, battery
pane, colour, heat), the shorter one-shot report is enough:

```sh
./scripts/macos/post-install-check.sh
# or: ./scripts/macos/post-install-check.sh /Volumes/MACUSB/wex-check.txt
```

It collects `sw_vers`, CPU counts, display modes, Metal/accelerator state,
RestrictEvents NVRAM, `pmset`, a `top` sample, recent Metal sandbox denials and
the compiler-bundle permissions, and writes one text file to the Desktop.

For a problem that comes and goes — the battery pane closing, an App Store
hang, a lag spike after a crash — a single report is not enough. Install the
continuous collector once:

```sh
./scripts/macos/openmac-diag.sh install
```

It keeps 60-second CPU/GPU/thermal samples, a filtered live log, 15-minute
snapshots, crash-triggered snapshots and hourly error extracts, all per-user and
with identity fields redacted. Send the bundle from
`./scripts/macos/openmac-diag.sh report`. See
[11-diagnostics.md](11-diagnostics.md) for what it records and how to read it.

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
   | `wex070` (control) | 0.7.0 | 0.4.0 | 0.7.0 |

   ```sh
   kextstat | grep -Ei 'whateverxe|tgl'
   # org.b00t0x.WhateverXe (0.6.x)
   # org.b00t0x.AppleIntelTGLCompat (0.6.x)
   ```

   A 0.6.0 kext with Compat 0.7.0 (or the reverse) will load but not start.
   The `wex070` variant is only a control; it cannot parse this unit's VBT and
   is expected to leave the panel dark.

2. **Boot arguments match the kext.** `-wex-adlp-edp`,
   `-wex-reset-restore`, `-wex-no-multicontext`, `-wex-scanout-coherent` and
   `-wex-pm` exist only in the 0.6.0 fork. The `wex070` build must not carry
   them; the build script adds them only for `--gpu hp-adlp-edp`. An unknown
   `-wex-*` argument is ignored, but a *partial* set is a sign that the config
   and kext were mixed by hand.

3. **No second graphics driver.** `WhateverGreen.kext` must not be enabled
   next to WhateverXe, and NootedGreen/NootedRed must not be present. The
   verifier fails the build if they are.

4. **The Sequoia MMIO gate.** WhateverXe 0.6.0 selects its MMIO-protection
   routine by OS family. On Sequoia the relevant properties are:

   ```sh
   ioreg -l | grep -o '"TGLSequoiaMMIOGuard" = <[^>]*>'
   ioreg -l | grep -o '"TGLSequoiaMMIOInspection" = <[^>]*>'
   ioreg -l | grep -E 'N97NativeStartAllowed|N97NativeProbeBlocked'
   ```

   `TGLSequoiaMMIOGuard` is a 20-entry array; entry **19** is the overall
   verdict and entries 8–16 are the individual byte comparisons. Entry 19 =
   `01` means the kernel matches the constants in WhateverXe. On 24H232 the
   published binary has a stale ninth constant, so the **default build
   patches it** (`E8 71 CB 02` → `E8 A1 CB 02`); entry 19 should therefore be
   `01` on the default `build/EFI`. The details are in
   [03-graphics.md § The 24H232 MMIO signature](03-graphics.md#the-24h232-mmio-signature).

   If entry 19 is `00`:

   - confirm the stick/ESP really contains the patched binary; check
     `EFI/BUILD-INFO.plist` for `gpu_patches.sequoia_mmio`, or compare the
     executable hash with `6bf93338…` (patched) rather than `197da23b…`
     (published);
   - repair it in place with
     `sudo scripts/macos/patch-wex-sequoia-mmio.sh --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext`
     (add `--kernel` with the matching KDK to read the real bytes);
   - if the value changed after a macOS update, decode entry 16 and use the
     script rather than editing bytes by hand.

   The Tahoe-era properties (`TGLMMIOStrongUCRouted`, `TGLTahoeMMIOGuard`) do
   not apply here; the Tahoe patch script modifies bytes that Sequoia never
   executes. Do not run the Tahoe script on Sequoia and expect a change.

5. **The panel record is not the problem.** `WhateverXeFirmwarePanel` is
   `[0, 0, 9, 0, 0]` on this unit because the VBT sets `panel_type = 0xFF`
   (panel chosen by PnP ID). That is expected: the fork's `-wex-adlp-edp` mode
   admits the Combo A DP route without a panel record. Do not chase the
   placeholder `LFP_PanelName` strings; WhateverXe does not read them.

6. **Try the other driver variant**, with the same config otherwise:

   ```sh
   ./scripts/build_efi.py --gpu wex070 --out build/EFI-wex070 --force
   ```

   Install Graphics **0.4.0** before booting it, and expect a dark internal
   panel: upstream 0.7.0 rejects this VBT (`Status::Conflict`). If the panel
   lights with 0.7.0 anyway, that is new information worth recording; if it
   stays dark while an external display works, the fork's parser is confirmed
   as the reason.

7. **Capture and report.** If neither variant starts, the useful report is the
   evidence bundle from section 0 plus:

   ```sh
   ioreg -l | grep -E 'WhateverXe(VBTRaw|FirmwarePanel|FirmwarePortRecords|FirmwareChecksum)'
   ioreg -l | grep -E 'N97(NativeStartAllowed|NativeProbeBlocked|NativeKernelReady)'
   ioreg -l | grep -o '"TGLSequoiaMMIOGuard" = <[^>]*>'
   ```

   Include the BIOS version (F.35), the panel EDID, and the macOS build
   (24H232 / Darwin 24.6.0).

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

### Metal apps crash or Safari video freezes (24H232)

This is the failure **after** the accelerator starts, not the 19 MB fallback.
Typical evidence:

- ControlCenter crash-loops; the report points at
  `MTLLoader sliceIDForDevice:…` and an assert inside
  `RB::load_library_archive`;
- the **Battery settings pane exits immediately** with the same
  `MTLLoader` assertion (confirmed 2026-11-03, see
  [§ Battery settings pane](#battery-settings-pane-exits-powerpreferences));
- Safari video freezes the GPU or the window, and the App Store hangs while
  loading video;
- `IntelAccelerator` is present and `system_profiler` reports Metal 2.

Cause: the Metal driver in WhateverXe Graphics 0.3.1 was built for 24H32 and
does not match Apple's precompiled Metal archives on 24H232. The assertion text
is:

```text
+[MTLLoader sliceIDForDevice:legacyDriverVersion:airntDriverVersion:]:685:
  failed assertion `Target device architecture is nil'
```

The same class of failure appears in `CA::Render::prepare_image`, which is why
the App Store and SwiftUI panes that precompile Metal libraries abort instead of
painting. Upstream lists both "some image-conversion operations can crash
applications" and "App Store video can freeze the GPU on Sequoia" as known
issues for this generation of the package. The fix is a per-user LaunchAgent
that makes Metal ignore the archives and compile from source:

```sh
cp scripts/macos/metal-archive-workaround.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/local.wex.metal-archive-workaround.plist
```

It sets `RB_USE_BINARY_ARCHIVE=0`,
`MTL_DEBUG_IGNORE_PRECOMPILED_BINARIES=1` and
`MTL_DEBUG_IGNORE_PSO_FAIL_ON_MISS=1`, then restarts ControlCenter. To undo:

```sh
launchctl bootout gui/$(id -u) \
  ~/Library/LaunchAgents/local.wex.metal-archive-workaround.plist
rm ~/Library/LaunchAgents/local.wex.metal-archive-workaround.plist
```

The workaround is adapted from
[dwiwinarno911/opencore-msi-tigerlake-irisxe](https://github.com/dwiwinarno911/opencore-msi-tigerlake-irisxe),
where it fixed the same crash on the same build. Install it, clear the Metal
caches once, and log out/in (or reboot) before judging it:

```sh
rm -rf ~/Library/Caches/com.apple.Metal ~/Library/Caches/com.apple.MetalShaderCache
```

If the crash persists, capture the `.ips` report and note whether the process is
ControlCenter, PowerPreferences, WindowServer or Safari; a WindowServer crash is
not this bug. Use
[11-diagnostics.md](11-diagnostics.md) to keep the seconds before the abort.

One message is **not** evidence of CPU rendering:

```text
runningboardd: setGPURole:pid: failed due to nil IOGPU device ref
```

It appears on almost every process launch on this Intel `IOAccelerator` device.
It is RunningBoard/IOGPU bookkeeping, not a statement that the app fell back to
the CPU; the compositor is still using `IntelAccelerator`.

### Metal 2 versus Metal 3

`system_profiler SPDisplaysDataType` reports **`Metal Support: Metal 2`** on the
working Sequoia install. That is the ceiling of the patched driver, not a
configuration mistake:

- WhateverXe Graphics 0.3.1 contains a Tiger Lake Metal driver derived from an
  older Apple driver. It advertises the Metal 2 feature set and does not
  implement the Metal 3 API surface.
- macOS shows `Metal Family` when a driver supports Metal 2 and earlier, and
  `Metal Support: Metal <version>` when it advertises a specific version. Here
  the driver explicitly advertises Metal 2.
- There is **no OpenCore, NVRAM or `-wex-*` switch** that turns Metal 2 into
  Metal 3. It needs a driver-side change in WhateverXe Graphics. Booting the
  upstream 0.7.0 + Graphics 0.4.0 control (`EFI-wex070`) does not help on this
  panel, because 0.7.0 rejects the VBT and the panel stays dark.

Apps that require Metal 3 (some newer games and GPU renderers) will therefore
refuse to start or fall back to CPU. Metal 2 apps, the desktop, Safari video,
Maps and Photos work. Check the actual capability with:

```sh
system_profiler SPDisplaysDataType | grep -i 'Metal'
ioreg -rc IntelAccelerator | grep -i 'Metal'
```

### Does the GPU render the desktop, or is the CPU doing it?

The desktop, windows, menus, scrolling and video scanout are **GPU-composited**.
On this install WindowServer owns an `IntelAccelerator` with 1536 MB of dynamic
VRAM, the internal panel is driven by `AppleIntelFramebuffer`, and
`system_profiler` reports Metal 2. If that were a CPU fallback, the accelerator
would be absent, the panel would show the 19 MB generic framebuffer, and Metal
would not be advertised at all.

What does *not* work is the **shader and archive half of Metal**:

| Layer | State | Evidence |
|---|---|---|
| Framebuffer/modeset | working | internal panel 2880×1800, `AppleIntelFramebuffer` present |
| Compositor | working (GPU) | `IntelAccelerator`, `WindowServer` surfaces, Metal 2 |
| Precompiled Metal archives | broken | `MTLLoader … Target device architecture is nil` |
| Runtime shader compilation | blocked | `MTLCompilerService` sandbox denies `XeCompilerAdapter.bundle` |
| Video decode | partially working | depends on the VA path; see the video section |

So the "slowness" is not "everything is drawn by the CPU". It is that an app
which asks Metal for a precompiled library (ControlCenter, the Battery pane,
App Store) aborts, and an app that asks for runtime compilation waits on a
sandbox-denied compiler and burns CPU while it retries. Fixing the archive
mismatch removes the first class; the compiler-bundle denial is a driver
packaging issue and needs a newer WhateverXe Graphics package, which in turn
needs a WhateverXe build that accepts this panel's VBT.

### The GPU name says "Intel(R) TGL Unknown"

This line comes from the graphics driver, not from the CPU:

```text
Device PreExisted [000000010000052f] Intel(R) TGL Unknown
```

`TGL` is Tiger Lake, the GPU family. WhateverXe's patched driver does not
publish a marketing name, so the fallback string is `Intel(R) TGL Unknown`.
`system_profiler` still shows the useful part:

```text
Chipset Model: Intel Iris Xe Graphics
Device ID: 0x46aa
VRAM (Dynamic, Max): 1536 MB
```

This is cosmetic. Changing `device-id`, the SMBIOS or `model` properties will
not rename it and can break acceleration. The CPU name is separate and is
covered in [§7](#cpu-name-and-thread-count).

### Apps hang after a few minutes (MTLCompilerService sandbox)

The collected log shows repeated denials while Metal compiles shaders:

```text
Sandbox: MTLCompilerService(1958) deny(1) file-read-data
  /Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/adapter.dylib
Sandbox: MTLCompilerService(1958) deny(1) file-map-executable
  /Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/libigc-tgl.dylib
```

`MTLCompilerService` is Apple's sandboxed shader compiler. On this build it
does not have a rule allowing the WhateverXe compiler bundle in
`/Library/GPUBundles`, so source compilation fails and the request can hang or
fall back. This matches the App Store hang in `QuartzCore`
(`CA::Render::prepare_image`) and adds CPU load and heat.

Do not "fix" this by disabling SIP completely or by moving system bundles.
Instead:

1. Install the Metal archive workaround first (previous section). It is
   recommended on 24H232; it reduces how often the compiler is invoked.
2. Clear the Metal caches once, then reboot:
   ```sh
   rm -rf ~/Library/Caches/com.apple.Metal
   rm -rf ~/Library/Caches/com.apple.MetalShaderCache
   ```
3. Reproduce with only one app open and capture the last two minutes:
   ```sh
   log show --last 2m --style compact \
     --predicate 'process == "MTLCompilerService" OR eventMessage CONTAINS "XeCompilerAdapter" OR eventMessage CONTAINS "libigc"'
   ```
4. If the denials continue, note the exact bundle path and whether the file is
   readable by your user:
   ```sh
   ls -l /Library/GPUBundles/XeCompilerAdapter.bundle/Contents/MacOS/
   codesign -dv --verbose=4 /Library/GPUBundles/XeCompilerAdapter.bundle 2>&1
   ```
   A missing or unreadable `libigc-tgl.dylib` is a package-install problem;
   reinstall WhateverXe Graphics 0.3.1. A readable but denied file is the
   sandbox issue above and needs a driver/package update, not an EFI change.

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
| `AirportItlwm` loaded, no networks | Check `kmutil showloaded \| grep -i airport`; if absent on 15.8.2, rebuild with `--wifi itlwm` |
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
| No audio devices at all | On Sequoia: `AppleALC.kext` loaded, controller `device-id` injected. `SimpleHDA` is gated to Tahoe and does not load here |
| Headphones work, mic panics the machine | Unpatched AppleALC; use the shipped kext |
| Wrong device names | On Tahoe: `shda-lang=en` present. On Sequoia the native `AppleHDA` names apply; `shda-lang` is inert |
| No audio after update | On Sequoia check AppleALC/layout first; `SimpleHDA` only matters on Tahoe (`MinKernel`/`MaxKernel`) |
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

## 7. Battery, power, CPU and display

| Symptom | Check |
|---|---|
| No battery percentage | `SMCBatteryManager.kext` loaded; `SSDT-SBUS.aml` present |
| Battery drains in sleep | Sleep is broken on this firmware; disable sleep (below) |
| High idle temperature | `CpuTopologyRebuild.kext` loaded; `SSDT-PLUG-ALT-12.aml` present; check `pmset -g therm`; confirm the display is in 1440×900 HiDPI, not 1× |
| CPU name wrong | `revcpu=1` and `revpatch=cpuname` in boot-args, `revcpuname` in NVRAM, and `RestrictEvents.kext` loaded |
| Fan always on / UI slow | `MTLCompilerService` shader denials, an archive crash-loop, or a hung app; see below |
| Battery settings pane exits | confirmed `MTLLoader` / Metal archive crash in `PowerPreferences`, not battery data; see below |

Recommended power settings (sleep is broken on this firmware):

```sh
sudo pmset -a hibernatemode 0 standby 0 sleep 0
sudo pmset -a displaysleep 10
sudo rm -f /var/vm/sleepimage
```

### CPU name and thread count

`wex-post-install-20261103-185409.txt` reports several values that look
contradictory until they are separated:

| Query | Value | Meaning |
|---|---|---|
| `machdep.cpu.brand_string` | `12th Gen Intel(R) Core(TM) i7-1250U` | Real brand string; already correct |
| `system_profiler` → `Processor Name` | `Unknown` | Marketing name in System Information; **this is the broken one** |
| `hw.ncpu`, `hw.logicalcpu`, `machdep.cpu.thread_count` | `12` | Every hardware thread is online |
| `hw.physicalcpu` | `2` | CpuTopologyRebuild's default SMT spoof: 2 P-cores with the E-cores folded in as SMT siblings |
| `machdep.cpu.core_count` | `12` | CTR counts threads as cores unless `-ctrfixcnt` is set |
| `system_profiler` → `Total Number of Cores` | `10` | True P+E physical core count, from SMBIOS type 4 |

There is **no missing-thread or wrong-topology bug**. Twelve threads are
present, and 10 is the physical P+E count. `hw.physicalcpu=2` is
CpuTopologyRebuild's documented default: it merges each E-core into a P-core
as an extra SMT thread so macOS schedules the hybrid CPU better. `ctrsmt=off`
restores the literal topology, but the kext author warns that performance can
drop.

`Processor Name: Unknown` is a separate defect. The deciding line is in the
report's device-tree dump:

```
"cpu-type" = <0107>
```

That is little-endian `0x0701` = `AppleProcessorTypeCorei7Type1`, inherited
from the old EFI's `PlatformInfo/Generic/ProcessorType = 1793`. It describes an
old dual-core Core i7, not a 10-core Alder Lake. macOS cannot map it to a
product name and falls back to `Unknown`; RestrictEvents' `cpuname` patch then
looks for an existing marketing string such as `12-Core Intel Xeon W`, finds
none, and leaves the fallback in place. The boot arguments, the `revcpuname`
NVRAM variable, and RestrictEvents 1.1.7 were all present and loaded — the
processor type was the blocker.

The repository now sets `ProcessorType = 3841` (`0x0F01`,
`AppleProcessorTypeXeonW`), the value used by the reference configuration and
documented by RestrictEvents for CPUs with 8 or more cores. It is not part of
the activation identity (serial, MLB, UUID, ROM), so iCloud/iMessage are not
affected.

After the next boot:

```sh
system_profiler SPHardwareDataType | grep -E 'Processor Name|Total Number of Cores'
ioreg -lw0 -p IODeviceTree | grep -o '"cpu-type" = <[^>]*>' | head -n 1
sysctl -n machdep.cpu.brand_string hw.ncpu hw.physicalcpu hw.logicalcpu \
             machdep.cpu.core_count machdep.cpu.thread_count
```

Expected: `Processor Name: 12th Gen Intel(R) Core(TM) i7-1250U`,
`cpu-type = <010f>`, 12 threads, `Total Number of Cores: 10`. If the name is
still `Unknown`, the remaining variable is RestrictEvents' find string: it
derives a `<core_count>-Core ...` name from `machdep.cpu.core_count`, which is
currently 12. `-ctrfixcnt` changes that to 10 but needs
`AppleMCEReporterDisabler.kext`; `ctrsmt=off` also changes the accounting but
loses the scheduling optimisation. Do not add either until the next report
shows the actual `cpu-type` and displayed name.

The default boot arguments now carry `revpatch=sbvmm,cpuname`. The earlier
`revpatch=cpuname` overrode the NVRAM value and silently disabled `sbvmm`,
which keeps OTA updates working on an unsupported model. Keep both words.

`Intel(R) TGL Unknown` in `system_profiler SPDisplaysDataType` is the **GPU**
fallback name, not the CPU; see
[the GPU-name section](#the-gpu-name-says-intelr-tgl-unknown).

### Display scaling (HiDPI)

A 2880×1800 panel in **1×** mode (`UI Looks like: 2880 x 1800`) gives a very
small UI and makes WindowServer render every one of the 5.2 million pixels.
That is both uncomfortable and heavier than it needs to be. macOS calls the
scaled modes **"Looks like"**, and they render at 2× (or another factor) while
reporting a smaller logical size:

| System Settings > Displays | Render buffer | Equivalent GNOME scaling | Notes |
|---|---|---|---|
| Looks like **1440 × 900** | 2880 × 1800 | **200 %** | Recommended: sharp native panel, comfortable UI |
| Looks like 1920 × 1200 | 3840 × 2400 then downscaled | 150 % | More desktop space, more GPU load, slightly softer |
| Looks like 2880 × 1800 | 2880 × 1800 | 100 % | Current mode: tiny UI, highest GPU cost per frame |

Choose **1440 × 900** first. It is the GNOME-200 % equivalent and the mode the
fork's `-wex-scanout-coherent` argument was added to support. If text is still
too small, choose 1280 × 800; if you need more space and accept the trade-off,
try 1920 × 1200 and compare heat and sharpness. Do not use a third-party
"resolution unlock" tool before the stock list has been tried.

### Display colour profile

The panel's EDID primaries are:

| Primary | x | y |
|---|---|---|
| Red | 0.680 | 0.320 |
| Green | 0.237 | 0.723 |
| Blue | 0.140 | 0.050 |
| White | 0.3125 | 0.3291 (D65) |

That gamut is about **110 % of Display P3** by area and about 150 % of sRGB.
The panel is a wide-gamut OLED, so **Display P3 is the right stock profile**;
sRGB would clip the red/green end. Keep P3 selected. If colours look
over-saturated after switching, choose the panel's default "Color LCD"
profile instead, or make a custom ICC profile with a colorimeter (DisplayCAL
or Argyl). "Generic RGB" and "Adobe RGB" are not appropriate defaults.

### Battery settings pane exits (PowerPreferences)

**Confirmed 2026-11-03: this is a Metal crash, not a battery-data problem.**

Opening **System Settings > Battery** launches the ExtensionKit process
`PowerPreferences`, which aborts about one second later. `ReportCrash` extracts
the actual assertion from the corpse:

```text
PowerPreferences: (Metal) +[MTLLoader sliceIDForDevice:legacyDriverVersion:airntDriverVersion:]:685: error
ReportCrash: ASI found [libsystem_c.dylib] (sensitive)
  '+[MTLLoader sliceIDForDevice:legacyDriverVersion:airntDriverVersion:]:685:
   failed assertion `Target device architecture is nil'
```

The sequence in the captured log is:

1. `runningboardd` starts `PowerPreferences` (PID 1508) for
   `com.apple.Battery-Settings.extension`;
2. the extension initialises Metal and calls `MTLLoader` for a precompiled
   library;
3. the loader cannot resolve the device architecture and asserts;
4. the process receives `SIGABRT` and `System Settings` reports "Extension
   process … exited" (PID 1508/1517 on consecutive tries).

The earlier one-shot report had already caught the same event. In
`wex-post-install-20261103-185409.txt` the 18:49 attempt is visible:

```text
18:49:40.059 launchd: Successfully spawned PowerPreferences[973]
18:49:41.049 launchd: exited due to SIGABRT | sent by PowerPreferences[973], ran for 999ms
18:49:42.064 ReportCrash: creating type 309 as /private/var/logs/ramrod/.PowerPreferences-….ips
18:49:42.064 ReportCrash: Error creating file … No such file or directory
```

That is why no `.ips` exists to open: `ReportCrash` could not create its
staging directory, not because the pane failed silently. That report's
predicate did not ask for `MTLLoader` or the `Metal` subsystem, so it recorded
the exit but not the assertion. The later `log stream` capture added the
assertion; the collector's predicates now include both.

The battery data itself is sane (`BatteryInstalled = Yes`,
`MaxCapacity = 7745`, `DesignCapacity = 8638`, `Temperature = 2931` = 29.31 °C,
`CycleCount = 0`), and `pmset -g batt` works while the pane is closed. This is
the same failure class as the ControlCenter archive crash
([§ Metal apps crash](#metal-apps-crash-or-safari-video-freezes-24h232)): the
WhateverXe Graphics 0.3.1 Metal driver expects 24H32 archives on a 24H232
system.

There is **no EFI, SMBIOS, NVRAM or `-wex-*` change that fixes this**, and an
SMC/NVRAM reset does not address it. Do this instead:

1. Install the Metal archive workaround from the Metal section.
2. Clear the Metal caches and reboot:
   ```sh
   rm -rf ~/Library/Caches/com.apple.Metal ~/Library/Caches/com.apple.MetalShaderCache
   ```
3. Open the Battery pane again. If it still aborts, keep the collector running
   and capture the exact seconds:
   ```sh
   log show --last 5m --style compact \
     --predicate 'process == "ReportCrash" OR process == "PowerPreferences" OR eventMessage CONTAINS "MTLLoader"'
   ```
4. Confirm the rest of the power stack is healthy, independent of the pane:
   ```sh
   pmset -g
   pmset -g batt
   pmset -g therm
   ```

Do not remove `SMCBatteryManager.kext` to "fix" the pane: that would trade a
Settings crash for no battery percentage and no power management. Do not change
the SMBIOS either; the pane fails inside Metal, before it reads battery data.

A real fix needs a WhateverXe Graphics build whose Metal driver matches Sequoia
and whose compiler bundle can load. 0.4.0 claims that fix, but it pairs with
WhateverXe 0.7.0, which rejects this panel's VBT (`Status::Conflict`) and leaves
the internal display dark. Until a build accepts both, this pane remains the
one known cosmetic casualty of the working graphics stack.

### Why the machine is slow and hot

The logs point at three separate costs, in order of impact:

1. **Display mode.** Confirm the panel is in **Looks like 1440 × 900** (HiDPI),
   not the 1× 2880×1800 mode. The 1× mode makes every window redraw at full
   panel resolution and was the single biggest source of heat; it is fixed on
   the current install. Verify with `system_profiler SPDisplaysDataType`.
2. **Metal archive / compiler mismatch.** On 24H232 the Graphics 0.3.1 payload
   was built for 24H32. Install the archive workaround in the previous section
   and clear `~/Library/Caches/com.apple.Metal*` once. Repeated
   `MTLCompilerService` sandbox denials of `XeCompilerAdapter.bundle` (see
   [above](#apps-hang-after-a-few-minutes-mtlcompilerservice-sandbox)) make
   apps hang and burn CPU while they retry.
3. **A hung or crash-looping app.** The App Store video hang and the GPU reset
   at 15:34 happened while `DisplaysExt` was changing modes/colour. App Store
   video is a known upstream WhateverXe limitation on Sequoia. Quit the app,
   avoid changing display settings repeatedly, and reboot after a GPU reset. A
   GPU reset is not normal operation; if it repeats without a display change,
   capture the new `gpuRestart` report.

Power management itself is present: `X86PlatformPlugin` is loaded,
`plugin-type = 1`, and `SSDT-PLUG-ALT-12.aml` declares the 12 logical CPUs. The
12 threads are correct. To measure rather than guess:

```sh
pmset -g
pmset -g therm
pmset -g assertions
top -l 1 -o cpu -n 15
sudo powermetrics --samplers smc,cpu_power -n 1 -i 1000
```

If `kernel_task` is high, that is usually thermal compensation, not a kext
leak. If `MTLCompilerService` or `WindowServer` is high, fix the display mode
and the Metal archive issue first. If the CPU idles at a low multiplier but the
machine is still hot, check `pmset -g therm` for `CPU_Scheduler_Limit` and
`CPU_Available_CPUs`; report those values rather than changing SMBIOS.

Because the lag comes in spikes, a single `top` sample rarely catches it. The
collector's 60-second `live/monitor.log` and filtered `live/events.log` are the
right evidence: compare the spike timestamp with `ReportCrash`, `spindump`,
`MTLCompilerService` and `WindowServer` entries. See
[11-diagnostics.md](11-diagnostics.md).

## 8. Sleep and wake

The HP firmware enters sleep and never wakes; this is documented by the
same-model reference and by EliteBook840G8, and it happens with or without
WhateverXe. The workaround (patch `_S3` to soft-off, add `RTCMemoryFixup` and
`rtcfx_exclude=80-AB`) is described in
[06-usb-acpi-power.md](06-usb-acpi-power.md) but deliberately **not applied**:
it changes sleep into shutdown and needs validation on this BIOS.

Do not debug sleep at the same time as graphics. One variable at a time.

## 9. Capturing a boot that dies with a black screen

This section records the Tahoe 26.7.2 capture procedure that produced the
analysis in
[03-graphics.md](03-graphics.md#where-the-2672-bring-up-stops-now-2026-11-01).
On Sequoia the same method is still the right one for a boot that lights the
panel and then loses WindowServer, or for capturing an MMIO-gate failure.

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
hold is needed. **A boot that ends in a self-reboot about two to three minutes
after power-on has not crashed: that is this `shutdown -r now`.** Check
`run.log` and `DONE` before treating it as a firmware reset. The sentinel at `/var/db/openmac-wex-capture.done` is written
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
