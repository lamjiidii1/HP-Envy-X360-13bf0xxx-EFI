# 13 — From clone to a working install

This is the end-to-end checklist for bringing up a **second identical
machine**. It assumes the same hardware: HP ENVY x360 13-bf0xxx, i7-1250U,
Iris Xe `8086:46AA`, 2880×1800 OLED. If any of those differ, stop and read
[01-hardware.md](01-hardware.md) first; several fixes here are tied to this
panel and this VBT.

The shorter per-topic pages remain authoritative for the *why*:
[03-graphics.md](03-graphics.md), [04-wifi-bluetooth.md](04-wifi-bluetooth.md),
[05-audio.md](05-audio.md), [06-usb-acpi-power.md](06-usb-acpi-power.md),
[07-install.md](07-install.md), [08-troubleshooting.md](08-troubleshooting.md).
This page is the ordered path through them.

## 0. What you get

The authoritative table is in the [README](../README.md#status-what-works).
Short version for this exact hardware:

**Works:** boot/install, CPU (2 P + 8 E / 12 threads), internal OLED at
**Looks like 1440 × 900** + Metal 2, Wi-Fi, Bluetooth, all USB-A/USB-C data
ports and USB-C charging, trackpad with gestures, keyboard, audio out over
3.5 mm and USB-C, battery reporting and the Battery pane (after the
`impostor` fix), App Store/Quick Look (after the `TGLVA` fix), XCPM power
profiles.

**Does not work:** internal speakers (CS35L41 smart amps, no driver), camera
(IPU6 `8086:465d` on MIPI, no driver), microSD reader (RTS5288, no driver),
touchscreen (physically broken glass; fails in Windows too), sleep/wake (HP
firmware limit).

**Untested:** internal microphone, HDMI/USB-C video output, Thunderbolt/USB4
alt modes, fan/board sensors.

Do not treat the last group as failures, and do not spend time on the first
group of failures: each is a hardware or firmware limit, not a configuration
mistake.

---

## 1. What you need

| Item | Notes |
|---|---|
| A Mac or Linux machine | To clone and build the EFI; the target laptop does not need an existing OS |
| USB stick, 16 GB+ | macOS installer + OpenCore EFI |
| Second USB stick or the internal ESP | A bootable backup of the EFI you are about to replace |
| macOS Sequoia installer | Use Apple's `createinstallmedia`; this repo does not ship an installer |
| `WhateverXe-Graphics-0.3.1.pkg` | Must match WhateverXe 0.6.0; see [03-graphics.md](03-graphics.md) |
| The 0.4.0 shims | `patch-mtl-impostor.sh` and `patch-va-tglva.sh` download them, or pass `--from FILE` |
| Your own SMBIOS values | Serial, MLB, UUID, ROM. Never reuse someone else's and never commit them |

Do **not** copy the identity from the example file or from another machine.
iCloud, iMessage and the App Store bind to those values.

## 2. Clone and build

```sh
git clone https://github.com/lamjiidii1/OpenMac.git
cd OpenMac

cp private/identity.example.plist private/identity.plist
$EDITOR private/identity.plist        # fill in serial, MLB, UUID, ROM

make build
make verify
```

`make build` assembles `build/EFI` from the pinned payloads and runs
`scripts/verify_efi.py`, which fails on a blank SMBIOS identity. The build
already contains:

- OpenCore 1.0.8 and the 12 ACPI tables;
- WhateverXe 0.6.0 + `-wex-adlp-edp` and the 24H232 MMIO constant;
- AirportItlwm 2.4.0 (Sequoia build);
- `revcpu=1`, `revpatch=sbvmm,cpuname` for the CPU name and OTA updates.

The `1,88 GHz` that macOS shows is the invariant TSC, not the core clock; see
§10.4. There is no OpenCore key for it.

Other variants are optional:

```sh
./scripts/build_efi.py --wifi itlwm --out build/EFI-itlwm --force
./scripts/build_efi.py --gpu wex070 --out build/EFI-wex070 --force   # control only
./scripts/build_efi.py --debug --out build/EFI-debug --force
```

## 3. Prepare the boot medium

### 3.1 Installer USB

On a Mac:

```sh
sudo /Applications/Install\ macOS\ Sequoia.app/Contents/Resources/createinstallmedia \
  --volume /Volumes/MyUSB --nointeraction
```

Then copy the EFI to that stick's EFI System Partition. From macOS:

```sh
diskutil list                       # find the USB's EFI partition, e.g. disk5s1
sudo diskutil mount disk5s1
sudo cp -a /Volumes/EFI/EFI /Volumes/EFI/EFI.backup-$(date +%F)   # if one exists
sudo rm -rf /Volumes/EFI/EFI
sudo cp -a build/EFI /Volumes/EFI/EFI
diskutil unmount /Volumes/EFI
```

From Linux, see [07-install.md §3](07-install.md#3-copy-to-the-esp).

The resulting structure must be exactly:

```
EFI/BOOT/BOOTx64.efi
EFI/OC/OpenCore.efi
EFI/OC/config.plist
EFI/OC/Kexts/...
```

### 3.2 Existing install

If the machine already boots macOS, replace the EFI it actually boots from,
not a partition you assume is the ESP:

```sh
sudo diskutil list                  # identify the EFI with EFI/OC
sudo diskutil mount <that-partition>
ls /Volumes/EFI/EFI/OC/config.plist
```

Back it up before touching it. **On this unit the live OpenCore EFI is a USB
stick (`/Volumes/MACUSB/EFI`); `disk0s1` is the HP/Windows ESP and contains no
`EFI/OC`.** Patching the wrong partition is the most common way to lose a
working boot.

## 4. BIOS

| Setting | Value |
|---|---|
| Secure Boot | Disabled |
| Fast Boot | Disabled |
| VT-d | Enabled (`AirportItlwm` needs AppleVTD; `DisableIoMapper=false`) |
| DVMT Pre-Allocated | HP default (60 MB); `-igfxdvmt` + stolenmem compensate |
| Intel PTT / TPM | Disabled if the boot hangs |
| Storage mode | AHCI / NVMe, no RAID |

Record the BIOS version. This unit is F.35 (2025-11-17); a BIOS update can
change the VBT and break eDP detection.

## 5. Install macOS

1. Boot the OpenCore picker from the installer USB.
2. Select the installer, open Disk Utility, erase the target volume as APFS.
3. Install macOS. The machine reboots several times; keep selecting the
   OpenCore entry, then the macOS volume.
4. Do not enable FileVault or install graphics packages until the desktop
   first appears with the basic framebuffer.

If the machine does not reach the installer, use the `--debug` EFI, read
[08-troubleshooting.md §1](08-troubleshooting.md#1-the-machine-does-not-reach-macos),
and change one variable at a time.

## 6. First boot checks

```sh
kmutil showloaded | grep -i whateverxe        # expect 0.6.0
system_profiler SPHardwareDataType | grep -E 'Processor Name|Total Number of Cores'
system_profiler SPDisplaysDataType | grep -E 'Resolution|UI Looks like|Metal'
ioreg -l | grep -o '"TGLSequoiaMMIOGuard" = <[^>]*>'
ioreg -rc IntelAccelerator | head
```

Expected on this machine:

- `WhateverXe` **0.6.0**, `AppleIntelTGLCompat` **0.6.0** after the package
  below;
- `Processor Name: 12th Gen Intel(R) Core(TM) i7-1250U`;
- `Total Number of Cores: 10` (12 threads online);
- internal panel online at **Looks like 1440 × 900**;
- `TGLSequoiaMMIOGuard` entry 19 = `01`;
- `Metal 2`, not Metal 3.

`hw.physicalcpu = 2` while `hw.ncpu = 12` is expected: CpuTopologyRebuild's
SMT spoof folds the E-cores into the P-cores. Geekbench therefore prints
"2 Cores, 12 Threads". It is not a missing-core bug; see
[08-troubleshooting.md](08-troubleshooting.md#cpu-name-and-thread-count).

## 7. Graphics package and MMIO

Order matters: **boot with the WEX 0.6.0 EFI first, then install the matching
userspace package.**

```sh
shasum -a 256 WhateverXe-Graphics-0.3.1.pkg
sudo installer -pkg WhateverXe-Graphics-0.3.1.pkg -target /
# restart
```

Do not install Graphics 0.3.2 or 0.4.0 with this EFI: they ship Compat 0.6.1
and 0.7.0, and the kext/package versions must match exactly.

A fresh `make build` already carries the 24H232 MMIO signature. If you copied
an older stick, or entry 19 reads `00`, repair it in place:

```sh
sudo bash scripts/macos/patch-wex-sequoia-mmio.sh \
  --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext --dry-run
sudo bash scripts/macos/patch-wex-sequoia-mmio.sh \
  --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext
```

Full background: [03-graphics.md § The 24H232 MMIO signature](03-graphics.md#the-24h232-mmio-signature).

## 8. Post-install fixes

These four fixes address problems that appear **after** acceleration works.
Apply them in this order and restart between graphics-stack changes.

| Symptom | Fix | Why |
|---|---|---|
| System Settings crashes when opening **Battery**; ControlCenter crash-loops | `patch-mtl-impostor.sh` | The 0.3.1 `impostor.dylib` only enables its Metal archive hook on build 24H32; this install is 24H232 |
| App Store hangs on screenshots/Quick Look; HEIC previews spin | `patch-va-tglva.sh` | The VA shim accepts only 24H32, so HEIC/HEVC decode never starts |
| Safari video freezes or apps abort with archive errors | Metal archive workaround, optional | Same build-gate class as the Battery pane |
| Chocolate/overheating under normal use | Display HiDPI + both shims + power profile | 1× mode redraws 5.2 MP, and a thrashing shim burns CPU |

### 8.1 Battery pane and ControlCenter

```sh
sudo bash scripts/macos/patch-mtl-impostor.sh --test
```

`--test` installs the 0.4.0 shim and opens the Battery pane. The old bundle is
backed up next to itself; `--rollback` restores the newest backup. Verify:

```sh
bash scripts/macos/patch-mtl-impostor.sh --status
```

Details and the crash signature:
[08-troubleshooting.md](08-troubleshooting.md#battery-settings-pane-exits-powerpreferences).

### 8.2 App Store, HEIC and Quick Look

```sh
sudo bash scripts/macos/patch-va-tglva.sh --test
bash scripts/macos/patch-va-tglva.sh --status
```

`--test` installs the 0.4.0 `TGLVA` shim and decodes a sample image. If the
machine has no network yet, copy the files from the support stick and use
`--from FILE`.

Details:
[08-troubleshooting.md](08-troubleshooting.md#app-store-hangs-on-screenshots-or-quick-look-tglva-guard).

### 8.3 Metal archive workaround (optional)

Only if ControlCenter/Safari still abort after 8.1 and 8.2:

```sh
sudo bash scripts/macos/install-metal-archive-workaround.sh
bash scripts/macos/check-metal-env.sh
```

This sets the archive environment for GUI apps and installs a LaunchAgent.
`install-metal-archive-workaround.sh --uninstall` removes it. See
[08-troubleshooting.md](08-troubleshooting.md#metal-apps-crash-or-safari-video-freezes-24h232).

### 8.4 Verify the graphics stack

```sh
bash scripts/macos/post-install-check.sh
bash scripts/macos/test-metal-runtime-compile.sh
```

`post-install-check.sh` writes one report to the Desktop. Runtime shader
compilation must succeed even though `XeCompilerAdapter` sandbox denials are
logged; those denials are expected and harmless.

## 9. Display, Wi-Fi, Bluetooth, audio

- **Display:** System Settings → Displays → choose **Looks like 1440 × 900**
  (HiDPI). Never run the panel at 1× 2880×1800: it redraws every pixel and is
  the largest single heat source. Keep the **Display P3** colour profile; this
  OLED covers about 110 % of P3 and sRGB would clip it.
- **Wi-Fi:** the default AirportItlwm build gives the native menu. If no
  interface appears after a macOS point update, build the `itlwm` fallback and
  install HeliPort. See [04-wifi-bluetooth.md](04-wifi-bluetooth.md).
- **Bluetooth:** works from the same AX211; see
  [04-wifi-bluetooth.md](04-wifi-bluetooth.md#bluetooth).
- **Audio:** 3.5 mm and USB-C output work; the internal CS35L41 speakers do not.
  `alcid=11` plus the patched AppleALC is required or recording panics. The
  internal microphone is untested. See [05-audio.md](05-audio.md).

## 10. Power and thermal

### 10.1 Profiles

`scripts/macos/power-profile.sh` wraps the supported `pmset` knobs:

| Profile | Battery | AC |
|---|---|---|
| `balanced` (default) | `lowpowermode 1` (XCPM cap), display sleep 5 s, TCP keepalive off | `lowpowermode 0` (uncapped), display sleep 10 s |
| `battery` | capped | also capped; display sleep 5 s |
| `performance` | uncapped | uncapped |

`balanced` is source-aware: run it once, and macOS uses the battery values
when unplugged and the AC values when plugged in. Measured on battery while
reading a PDF: **7.93 W with the cap, 11.74 W without (+48 %)**, i.e. a
normalised runtime of **8.0 h versus 5.4 h**. See
[14-measurements.md § 4](14-measurements.md#4-battery-life-a-clean-run-and-why-load-dominates).

Apply it once:

```sh
sudo bash scripts/macos/power-profile.sh balanced
bash scripts/macos/power-profile.sh status
```

The cap lowers package power under all-core load from about **19.9 W to
10.3 W** (measured 2026-11-05), at the cost of sustained clock (about 3.6 GHz
→ 1.8 GHz). It does not touch the GPU driver. Full numbers:
[06-usb-acpi-power.md](06-usb-acpi-power.md#measured-effect-2026-11-05).

### 10.2 Make it survive reboots

`pmset` values persist, but the battery menu's **Low Power Mode** toggle writes
the same key. To re-assert the profile at every boot:

```sh
sudo bash scripts/macos/install-power-daemon.sh balanced
sudo bash scripts/macos/install-power-daemon.sh --status
```

This installs `local.openmac.powerprofile` and logs to
`/var/log/openmac-powerprofile.log`. It runs once at boot, not continuously, so
a deliberate toggle after login still wins until the next reboot. Remove it
with `--uninstall`.

The orange/yellow battery icon **is** Low Power Mode. On battery with
`balanced` it is expected and is the cap doing its job. Turning it off sets
`lowpowermode 0` and removes the cap (more performance, more heat, faster
drain); it does not change the EFI or the other timers.

### 10.3 Measure instead of guessing

```sh
sudo bash scripts/macos/power-audit.sh                 # snapshot
sudo bash scripts/macos/power-audit.sh --compare-lpm   # cap on vs off
INTERVAL=10 bash scripts/macos/battery-watch.sh        # real discharge watts
```

`battery-watch.sh` needs no root and writes a CSV under `LOGS/`. Use it with
the charger unplugged and the machine in **normal use**; the projected runtime
is useless while a heavy UI process is running. `SAMPLES=3 INTERVAL=2` runs a
short sanity check instead of waiting for Ctrl-C.

The script converts `ioreg`'s unsigned 64-bit `InstantAmperage` back to signed;
without that, a discharging battery looks like a huge charge rate.

To measure what the cap is worth on light use, run the same session with
`lowpowermode 0` and compare against the recorded 7.93 W baseline:

```sh
bash scripts/macos/battery-cap-compare.sh     # 14 min, restores balanced at exit
```

It needs the charger unplugged and about 15 minutes. Quit OpenCode first; its
helper and renderer keep two cores busy and would dominate the delta.

Do not benchmark under the OpenCode desktop: its helper and renderer keep two
cores busy, and a Geekbench run then measures the agent, not the laptop. See
[14-measurements.md](14-measurements.md#3-geekbench-7-the-runs-and-why-most-were-invalid).

### 10.4 About This Mac shows 1.88 GHz

That is the invariant TSC (`machdep.tsc.frequency = 1881600000`, i.e. CPUID
leaf 0x15: 38.4 MHz × 98 / 2), not the CPU clock. OpenCore 1.0.8 has no key
for it: `PlatformInfo/Generic/ProcessorSpeed` is not in the schema and is
silently ignored. Do not change the TSC to make the label prettier; it is the
kernel's time source.

The real range is XCPM 4700→400 MHz, and the P-cores sustain about 3.6 GHz
under load because of the firmware power limit. Verify with `powermetrics`, not
with About This Mac. Full explanation:
[docs/08](08-troubleshooting.md#cpu-speed-display-shows-188-ghz).

## 11. Final verification

```sh
# identity and CPU
system_profiler SPHardwareDataType | grep -E 'Serial|Processor Name|Cores'
sysctl -n machdep.cpu.brand_string hw.ncpu hw.physicalcpu hw.logicalcpu

# graphics
kmutil showloaded | grep -iE 'whateverxe|AppleIntelTGLCompat'
system_profiler SPDisplaysDataType | grep -E 'Resolution|UI Looks like|Metal'
ioreg -l | grep -o '"TGLSequoiaMMIOGuard" = <[^>]*>'

# power
pmset -g custom | grep -E 'lowpowermode|displaysleep|tcpkeepalive'
launchctl print system/local.openmac.powerprofile >/dev/null && echo daemon-ok
pmset -g therm
```

Healthy signs:

- processor name is the real i7-1250U, 10 cores / 12 threads;
- `WhateverXe` and `Compat` both 0.6.0;
- Metal 2, `Looks like 1440 × 900`, MMIO entry 19 = `01`;
- battery `lowpowermode 1`, AC `lowpowermode 0`;
- `CPU_Speed_Limit = 100`, no thermal warning.

## 12. Troubleshooting map

| Symptom | Most likely cause | Go to |
|---|---|---|
| Black screen, machine alive | display mode / MMIO / blower | [08 §2](08-troubleshooting.md#2-graphics-the-19-mb-fallback) |
| 19 MB VRAM, no Metal | MMIO signature or Compat mismatch | [03](03-graphics.md#the-24h232-mmio-signature) |
| Battery pane exits | `impostor.dylib` gate | [08 § Battery](08-troubleshooting.md#battery-settings-pane-exits-powerpreferences) |
| App Store/HEIC spinner | `TGLVA` gate | [08 § App Store](08-troubleshooting.md#app-store-hangs-on-screenshots-or-quick-look-tglva-guard) |
| No Wi-Fi after update | AirportItlwm ABI | [04](04-wifi-bluetooth.md) |
| No audio / panic on record | AppleALC patch or `alcid` | [05](05-audio.md) |
| Hot and laggy | 1× display mode, shims, UI load | [08 § slow and hot](08-troubleshooting.md#why-the-machine-is-slow-and-hot) |
| Sleep never wakes | HP firmware limit | [06 § Sleep](06-usb-acpi-power.md#sleep--known-broken-on-this-platform) |
| Start over | | [07 § Rollback](07-install.md#8-rollback) |

## 13. Known limits on this platform

- **Sleep does not wake.** It is a firmware limit; the repo disables sleep
  rather than pretending. See [06](06-usb-acpi-power.md#sleep--known-broken-on-this-platform).
- **Metal 2, not Metal 3**, and the GPU is named `Intel(R) TGL Unknown`.
- **Internal speakers are silent** (no CS35L41 driver). Headphone and USB-C
  output work; the internal microphone has not been verified.
- **No fan control**: there is no `SMCSuperIO` kext, so the cap and display
  settings are the only heat levers.
- **P-cores sustain about 3.6 GHz**, not the 4.7 GHz in the XCPM table, because
  the firmware enforces `CPU LIMIT ICCMAX/PL4/OTHER`.
- **GPU DC6 stays at 0 %** without GuC; package C-states are shallow. Treat
  this as a diagnostic, not a tunable.
- **Benchmarks under the OpenCode desktop are invalid**; the agent UI uses
  about two cores.

## 14. Safety rules

- Never commit `private/identity.plist`. It is gitignored for a reason.
- Never run `git clean -fX` in this repository: it would delete the identity,
  `build/`, `LOGS/`, `mine/` and other local recovery material.
- Change one variable at a time, especially in the graphics stack.
- Keep a bootable backup EFI on a separate stick until the new one has booted
  twice.
- The payloads are pinned and hashed; see [10-provenance.md](10-provenance.md).
