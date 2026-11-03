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
- Safari video freezes the GPU or the window;
- `IntelAccelerator` is present and `system_profiler` reports Metal 2.

Cause: the Metal driver in WhateverXe Graphics 0.3.1 was built for 24H32 and
does not match Apple's precompiled Metal archives on 24H232. The fix is a
per-user LaunchAgent that makes Metal ignore the archives and compile from
source:

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
where it fixed the same crash on the same build. If the crash persists, capture
the `.ips` report and note whether the process is ControlCenter, WindowServer
or Safari; a WindowServer crash is not this bug.

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
| High idle temperature | `CpuTopologyRebuild.kext` loaded; `SSDT-PLUG-ALT-12.aml` present; check `pmset -g therm`; first reduce the display to 1440×900 HiDPI |
| CPU name wrong | `revcpu=1` and `revpatch=cpuname` in boot-args, `revcpuname` in NVRAM, and `RestrictEvents.kext` loaded |
| Fan always on / UI slow | Native 2880×1800 1× mode, `MTLCompilerService` shader denials, or a hung app; see below |
| Battery settings pane exits | `PowerPreferences` extension crash; capture a log while opening it (below) |

Recommended power settings (sleep is broken on this firmware):

```sh
sudo pmset -a hibernatemode 0 standby 0 sleep 0
sudo pmset -a displaysleep 10
sudo rm -f /var/vm/sleepimage
```

### CPU name and thread count

The i7-1250U is **2 P-cores + 8 E-cores = 10 cores and 12 threads**. The hang
report in the collected bundle says `Active cpus: 12`, and `CpuTopologyRebuild`
plus `SSDT-PLUG-ALT-12.aml` present 12 logical CPUs to macOS. Seeing "10 cores"
in a tool is correct; it is the physical core count, not a lost thread. There is
no missing-thread bug to fix in the EFI.

The CPU name is handled by RestrictEvents:

- `revcpu=1` forces the Intel brand-string patch;
- `revpatch=cpuname` requests the CPU-name patch;
- `revcpuname` in NVRAM supplies the string (it cannot contain spaces on the
  boot-args line, which is why the custom name lives in NVRAM).

The default build now carries `revcpu=1 revpatch=cpuname` on the boot-args line
as well, so a stale `NVRAM/Delete` entry cannot silently disable the patch.
After one reboot, check:

```sh
sysctl -n machdep.cpu.brand_string
system_profiler SPHardwareDataType | grep -i 'Processor\|Chip'
kmutil showloaded | grep RestrictEvents
nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:revcpuname
```

`Intel(R) TGL Unknown` in `system_profiler SPDisplaysDataType` is the **GPU**
fallback name, not the CPU; see [the GPU-name section](#the-gpu-name-says-intelr-tgl-unknown).

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

The error is the ExtensionKit process, not the battery data:

```text
Settings Error: Extension process PowerPreferences(1464) exited
```

The collected battery data is sane (`BatteryInstalled = Yes`,
`MaxCapacity = 7745`, `DesignCapacity = 8638`, `Temperature = 2931` = 29.31 °C,
`CycleCount = 0`), so this is not a missing-battery or ACPI-field problem. No
`PowerPreferences` crash report was captured, so reproduce it while logging:

```sh
log stream --style compact --level debug \
  --predicate 'process CONTAINS "PowerPreferences" OR eventMessage CONTAINS "PowerPreferences" OR process == "powerd"'
```

Then open **System Settings > Battery** in another window and stop `log stream`
with Control-C. Also check `~/Library/Logs/DiagnosticReports` for a new
`PowerPreferences*.ips`.

Safe things to try, in order:

1. Quit System Settings, then `sudo killall -9 PowerPreferences` and reopen it.
2. Shut down, unplug the charger, hold the power button for 10 seconds, then
   boot. This is the hackintosh equivalent of an SMC reset and rebuilds the
   virtual SMC state.
3. Reset NVRAM once from the OpenCore picker, boot once, then check whether the
   pane opens. Identity is re-injected by OpenCore, so activation is preserved,
   but do not do this while signed out of iCloud.
4. Confirm `pmset` still works even if the pane does not:
   ```sh
   pmset -g
   pmset -g batt
   pmset -g therm
   ```
   If these are correct, the battery stack is healthy and only the Settings
   extension is failing.

Do not remove `SMCBatteryManager.kext` to "fix" the pane: that would trade a
Settings crash for no battery percentage and no power management.

### Why the machine is slow and hot

The logs point at three separate costs, in order of impact:

1. **Native 1× mode.** 2880×1800 with no HiDPI scaling makes every window
   redraw at full panel resolution. Switch to 1440×900 HiDPI first; this is the
   single biggest change.
2. **Metal archive / compiler mismatch.** On 24H232 the Graphics 0.3.1 payload
   was built for 24H32. Install the archive workaround in the previous section
   and clear `~/Library/Caches/com.apple.Metal*` once. Repeated
   `MTLCompilerService` sandbox denials of `XeCompilerAdapter.bundle` (see
   [above](#apps-hang-after-a-few-minutes-mtlcompilerservice-sandbox)) make
   apps hang and burn CPU while they retry.
3. **A hung or crash-looping app.** The App Store hang at 16:08-16:14 and the
   GPU reset at 15:34 happened while `DisplaysExt` was changing modes/colour.
   Quit the app, avoid changing display settings repeatedly, and reboot after a
   GPU reset. A GPU reset is not normal operation; if it repeats without a
   display change, capture the new `gpuRestart` report.

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
