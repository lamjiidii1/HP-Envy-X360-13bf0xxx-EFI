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
| `BTIdle.kext` | Applies a 100 ms idle-suspend policy to the Bluetooth USB interfaces (see [04-wifi-bluetooth.md](04-wifi-bluetooth.md#bluetooth-idle)) |
| `RestrictEvents.kext` 1.1.7 | CPU name (`revpatch=cpuname`), no board-id patch |

`ProvideCurrentCpuInfo` is enabled in `Kernel/Quirks`; `revcpu=1` and
`revpatch=cpuname` are on the boot-args line, and the custom CPU name comes from
`revcpuname` in NVRAM (boot-args cannot carry a name with spaces reliably).

### Profiles

`scripts/macos/power-profile.sh` wraps the supported knobs:

| Command | Battery | AC |
|---|---|---|
| `status` | current values and XCPM state | current values and XCPM state |
| `balanced` | `lowpowermode 1` (XCPM 2.4 GHz cap), display sleep 5 s, TCP keepalive off | `lowpowermode 0`, display sleep 10 s |
| `battery` | same cap | also capped; display sleep 5 s |
| `performance` | no cap | no cap |

`lowpowermode 1` is the macOS equivalent of `power-profiles-daemon`'s balanced
profile: XCPM holds the package to `IOPlatformPowerProfile`'s `lpm_ratio`
(`0x18` = 2.4 GHz ceiling; the measured all-core sustained result is ~1.8 GHz)
instead of 4.7 GHz. It does not change the topology or the WhateverXe GPU
driver, and `sudo pmset -a lowpowermode 0` reverts it.

On Tahoe 26.7.1 the rebuilt 0.8.0 kext installs the XE-PM HWP route, so EPP
and the HWP cap conversion do reach MSR `0x774`. On Sequoia 15.8.2 the same
route does not install and the profile is inert (see
[§ 3](03-graphics.md#cpu-power--wex-pm-on-tahoe-active-and-sequoia-inert)).

### Persistence, the orange icon, and the boot daemon

`pmset` stores these values in
`/Library/Preferences/SystemConfiguration/com.apple.PowerManagement.plist`, so
one `power-profile.sh balanced` survives a reboot. It is **not** per-boot.

The catch is that `lowpowermode` is also what the battery menu's **Low Power
Mode** switch and System Settings write. The orange/yellow battery icon *is*
Low Power Mode. On battery with `balanced` it is expected; turning it off sets
`lowpowermode 0`, removes the CPU cap and leaves every other timer alone.

Because that toggle can silently undo the profile, the repository also ships a
one-shot LaunchDaemon:

```sh
sudo bash scripts/macos/install-power-daemon.sh balanced
sudo bash scripts/macos/install-power-daemon.sh --status
sudo bash scripts/macos/install-power-daemon.sh --uninstall
```

It installs `/Library/LaunchDaemons/local.openmac.powerprofile.plist` plus a
root-owned copy of `power-profile.sh` under `/usr/local/libexec/openmac/`, and
logs to `/var/log/openmac-powerprofile.log`. It runs at boot only — it does not
watch or fight a deliberate change made after login. `--status` prints the
launchd state and the effective battery/AC `lowpowermode`. Re-run the installer
after updating `power-profile.sh`; the daemon uses the installed copy, not the
one in the repository.

### Measuring real runtime

`pmset -g batt` gives a coarse percentage and a projection that assumes the
current load continues. For actual watts, run:

```sh
INTERVAL=10 bash scripts/macos/battery-watch.sh
```

Unplug the charger and use the machine normally; Ctrl-C prints the discharge
average and projected hours. The CSV is written under `LOGS/`. Charging samples
are recorded but excluded from the average. No root is needed.

For a quick sanity check without leaving it running:

```sh
SAMPLES=3 INTERVAL=2 bash scripts/macos/battery-watch.sh
```

For the idle floor specifically, quit OpenCode and run a fixed window:

```sh
sudo bash scripts/macos/idle-baseline.sh 120
sudo bash scripts/macos/idle-baseline.sh 120 --display-sleep
```

It prints battery draw at both ends, package and per-core residencies, and the
interrupt rates, and writes the raw samples under `LOGS/idle-baseline-*`. Do
not quote `pmset -g batt`'s "time remaining" against these: at ~6 W measured
it implies about 9 W. See
[14 § 2](14-measurements.md#idle-floor-isolation-2026-11-13).

One implementation note: `ioreg` prints a negative `InstantAmperage` as an
unsigned 64-bit number (`-1925 mA` becomes `18446744073709550691`). An early
version of this script treated that as a huge charge rate and reported
`no samples`; `val()` now converts it back to signed with exact integer
arithmetic, and the summary prints the draw as a positive number.

To quantify what the cap buys on **light** battery use, run the same kind of
session with `lowpowermode 0` and compare it with the recorded 7.93 W baseline:

```sh
bash scripts/macos/battery-cap-compare.sh          # 14 min, then restores balanced
bash scripts/macos/battery-cap-compare.sh --analyze LOGS/battery-cap-off-*.csv
```

It refuses to start on AC, keeps the panel awake for the run (the `balanced`
timer sleeps it after 5 s), and restores `lowpowermode 1` on every exit path.
Quit OpenCode first: with the desktop running the delta you measure is the
agent's CPU use, not the cap's.

Do not judge the profile with a benchmark taken under the OpenCode desktop.
Its helper and renderer processes keep roughly two cores busy, so Geekbench
then measures the agent UI rather than the laptop; the same load also makes the
`pmset` runtime projection look far worse than a normal-use session. The
2026-11-05 runs and caveats are recorded in
[14-measurements.md](14-measurements.md#3-geekbench-7-the-runs-and-why-most-were-invalid).

### Measured effect (2026-11-05)

`sudo bash scripts/macos/power-audit.sh --compare-lpm` with `DURATION=8` on AC,
desktop open (not a cold-boot idle):

| Phase | `lowpowermode 0` | `lowpowermode 1` |
|---|---|---|
| idle | 10.15 W, peak 2.80 GHz | 7.63 W, peak 1.52 GHz |
| one thread | 14.17 W, peak 3.59 GHz | 8.25 W, peak 1.76 GHz |
| all threads | 19.93 W, peak 3.57 GHz | 10.27 W, peak 1.78 GHz |

Power is the Intel energy-model estimate (`CPUs+GT+SA`); "peak" is the highest
1 s per-core average seen in that phase, not an instantaneous maximum. The cap
roughly halves package power under load, so `balanced` trades compile speed for
battery; on AC the profile leaves the uncapped values in place.

On **battery**, the same `balanced` profile measured **7.93 W average / 10.51 W
peak** over 14 minutes of PDF reading at 1440×900 with no background apps, and
projected **6.03 h** (77 % → 74 %). That is the realistic light-use figure; see
[14-measurements.md § 4](14-measurements.md#4-battery-life-a-clean-run-and-why-load-dominates).

The cap is worth keeping even for reading: the same session with
`lowpowermode 0` drew **11.74 W average (+48 %)** and cut the normalised
full-charge runtime from 8.0 h to **5.4 h (−33 %)**. The 10.3 → 19.9 W AC
result was not the whole story; UI bursts alone are enough to pay for the cap.

Two platform limits show up in these runs and in the
[quiet baseline](14-measurements.md#clean-idle-baseline-2026-11-13); neither is
a pmset setting:

- The P-cores (reported as CPU 0–3) sustain about 3.6 GHz with one busy
  thread, not the 4.7 GHz in the XCPM table. powermetrics reports
  `CPU LIMIT ICCMAX/PL4/OTHER` in every phase, and a single-thread package
  draw of ~14 W is consistent with a firmware power limit rather than a
  frequency-table error.
- The package never goes deeper than **PC3**. In a quiet window it reports
  PC3 ~93–96 % residency, the P-cores sit in **C7** ~96–98 % and the E-cores
  in **C6** ~99 %; **PC6–PC10 and GPU DC6 stay at 0.00 %**. The iGPU never
  enters DC6 without GuC, so the DMC-gated deeper package states are
  unreachable. Treat PC6+ as a diagnostic, not a tunable target. The
  "0.00 % residency" figure published earlier was contamination from
  measuring with the agent desktop active; see
  [14 § 2](14-measurements.md#clean-idle-baseline-2026-11-13).

The same hardware therefore loses roughly half its sustained CPU power budget
under the macOS `lowpowermode` cap, whereas Fedora's `balance` profile can use
the full PL1/PL2 envelope. The bigger difference is at idle: the same Fedora
machine held **4.2 W with 15 Firefox tabs open**, against **7.9 W on macOS
reading a PDF with no background apps**. The CPU-idle half of that gap is
*not* explained by C-states: macOS does reach PC3 and idles there ~93–95 %
([14 § 2](14-measurements.md#clean-idle-baseline-2026-11-13)). The plausible
remainder is the DMC-gated deep package states and GPU DC6, which macOS never
enters without a GuC/DMC path; that has not been measured on the Fedora side.
See
[14-measurements.md § 4](14-measurements.md#same-machine-on-fedora-a-hardware-reference).

### Idle power: timers, EPP, and device idle (2026-11-12)

Three stack-independent changes were measured on this machine on Tahoe 26.7.1,
with the desktop open (so these are A/B deltas inside a noisy session, not a
cold-boot idle floor):

| Change | Idle package delta | Notes |
|---|---|---|
| Timer coalescing (`scale=1`, max 10 ms; tier-1 20 ms) | **−0.7 to −1.6 W** | real-time threads and hardware interrupts unaffected |
| XE-PM EPP `0` → `96` | **−0.75 W** mean | EPP 128/255 were worse; one-thread turbo 3828 → 3819 MHz |
| Both together | **−0.86 W** mean | the two effects overlap, so they do not add |

EPP 96 costs about **2 %** sustained all-thread clock: 2781 → 2726 MHz and
24.06 → 23.73 W package in a four-thread run. It does not weaken the
`lowpowermode 1` cap: peak stayed at 2373 MHz and 0 of 80 samples reached
2.5 GHz. EPP 96 is now the compiled default of the shipped WhateverXe kext
(`tools/patches/whateverxe-xepm-epp96.patch`), so `-wex-pm` alone is enough;
`debug.xepm.epp` still overrides it.

Timer coalescing is a sysctl, not a pmset key, and is lost on reboot. Install
the boot daemon to re-apply it:

```sh
sudo bash scripts/macos/install-power-tuning.sh
sudo bash scripts/macos/install-power-tuning.sh --status
sudo bash scripts/macos/install-power-tuning.sh --uninstall
```

It writes `/usr/local/sbin/hp-power-tuning`,
`/Library/LaunchDaemons/local.hp-power-tuning.plist` and
`/Library/Logs/hp-power-tuning.log`, and re-asserts EPP 96 for older kexts.
`bash scripts/macos/power-now.sh` prints live battery draw and projected
runtime without root.

Two device-level properties complete the package:

- **NVMe L1SS.** `PciRoot(0x0)/Pci(0x6,0x0)` gets
  `pci-l1ss-enable = <0f001260>` (and the endpoint additionally
  `pci-max-latency = <03100310>`), with `-nvmefaspm` on the boot-args line.
  These are real `IOPCIFamily` device properties. The link stays at
  **x4 / 16 GT/s**, so this changes idle link state, not throughput.
- **Bluetooth idle.** `BTIdle.kext` plus the `kIOPMLowPower` patch to
  `IntelBluetoothFirmware`; see
  [04-wifi-bluetooth.md § Bluetooth idle](04-wifi-bluetooth.md#bluetooth-idle).

The largest remaining gap is platform-level: the package stops at PC3
(**PC6–PC10 stay 0.00 %**) and GPU DC6 stays 0.00 %, because WhateverXe has no
DMC/DC-state control. Four isolation runs put numbers on the floor: ~5.7 W
with the panel and Wi-Fi off, of which the SoC is ~2.2 W. Wi-Fi accounts for
only ~0.25 W and the panel ~0.6 W at 40 % brightness, so ~3.4 W is PCH, DRAM,
NVMe, VRM conversion loss, the EC and the display link. Linux on the same
board idles near 2.5 W because its PMC/i915 stack can reach PC8/PC10 and its
platform drivers drive the sleep states macOS does not; see
[14 § 2](14-measurements.md#idle-floor-isolation-2026-11-13) and
[14 § 4](14-measurements.md#tuned-linux-idle-vs-macos-idle-2026-11-13). The
`lowpowermode` cap and these idle tweaks reduce what the machine burns while
awake; they do not make it reach C8/C10.

### Hybrid P-cores and the `-wex-pm` route

The ~3.6 GHz ceiling and the C-state table XCPM installs have a common cause
in XCPM, which predates Intel's hybrid CPUs:

- XCPM writes the HWP turbo limit in 100 MHz units, but Alder Lake P-cores
  count HWP performance in ~78.7 MHz units. A 4.7 GHz table entry therefore
  becomes ~3.7 GHz on the P-cores.
- Its default EPP (0x80) clips one-core turbo on Alder/Raptor Lake mobile.
- Its idle table enables a C3 entry this CPU never reports and disables
  C8/C10, so cores stop at C6/C7 instead of the deeper states.

WhateverXe ships an XE-PM profile behind `-wex-pm` that addresses this:
converts the HWP request to per-core units on P-cores, writes EPP 96, disables
energy-efficient turbo, enables C8/C10 in the idle table, and puts driverless
IPU/GNA/ISH/DPTF/Thunderbolt-DMA functions into D3hot. The route is
byte-checked and only installs on the kernel build it was written for. On
**Tahoe 26.7.1 (25G241)** the bytes match and it is active; on **Sequoia
15.8.2 (24H232)** it is inert (`debug.xepm.route: 3`). Confirm with:

```sh
sysctl debug.xepm
# hwp: 1, route: 1, cst: 1 -> active
# route: 3                -> off
```

The stock profile maximized every HWP request lower than the core's highest
performance. That repaired the 100 MHz → 78.7 MHz unit mismatch for turbo but
also discarded Low Power Mode: `lowpowermode 1` (ratio 24, 2.4 GHz) still ran
P-cores at ~3.8 GHz. The default kext now converts the requested ratio into
per-core HWP units instead and defaults EPP to 96 (`a84472e2…`, built from the
WhateverXe `main` tip plus `tools/patches/whateverxe-xepm-hwp-caps.patch` and
`tools/patches/whateverxe-xepm-epp96.patch`). Measured on battery, one busy
thread, same boot:

| `lowpowermode` | Upstream XE-PM | Rebuilt XE-PM |
|---|---|---|
| `1` (cap 2.4 GHz) | 3.81–3.84 GHz, 20.6–21.8 W | **2.21–2.23 GHz, 10.8–11.7 W** |
| `0` (no cap) | ~3.87 GHz, 20.1–23.4 W | 3.81 GHz, 14.2–15.4 W |

With the rebuild, a four-thread load under `lowpowermode 1` kept every core at
or below 2.5 GHz; the P-cores sat at ~2.0–2.2 GHz. E-cores use 100 MHz HWP
units and were already correct. With cores busy the package cannot be in a
C-state at all, so package residency is 0 % by definition and says nothing
about this change; the idle number is in
[14 § 2](14-measurements.md#clean-idle-baseline-2026-11-13).

Independent measurements of the same profile on a 2P+8E **i5-1245U** (Dell
Latitude 7430) report Geekbench 6 single-core **1370 → 1832 (+34 %)**, multi
**4142 → 4550**, and idle package **6.2 → ~5.4 W**. On a 4P+8E i7-1360P the
same profile reports Geekbench 7 single-core **1269 → 1697 (+34 %)** and idle
package **4.6 → 3.3 W**. These are the numbers to reproduce here before
changing GPU flags: the profile is the first thing to check when the laptop
is hot or the P-cores look stuck below 4 GHz.

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
