# 14 — Measurements and what they taught us

This page keeps the raw numbers that drove the power, thermal and
"is-it-fast-enough" decisions, without requiring the gitignored `LOGS/`
directory. Raw captures remain in `LOGS/power-audit-*`, `LOGS/geekbench/` and
`LOGS/idle-baseline-*` on the machine that produced them.

Environment: macOS Sequoia 15.8.2 (24H232) and macOS 26 Tahoe, i7-1250U
(2P + 8E, 12 threads), 16 GB, 2880×1800 OLED. All macOS package numbers are
the Intel energy-model estimate from `powermetrics` (`CPUs+GT+SA`), not a
wall-meter reading; whole-machine battery numbers come from `InstantAmperage`.
A Fedora run and a tuned Linux idle measurement on the same machine are
recorded in §4 as hardware references.

## 1. XCPM, the cap, and the 1.88 GHz label

`machdep.xcpm.hard_plimit_max_100mhz_ratio = 47` and the `CPUPStates` table
cover **4700 → 400 MHz**. `hw.cpufrequency` still reads `1880000000`, and About
This Mac shows `1,88 GHz`, but that is the **invariant TSC**, not the core
clock:

```text
CPUID leaf 0x15: crystal 38.4 MHz, numerator 98, denominator 2
                 38.4 * 98 / 2 = 1881.6 MHz
machdep.tsc.frequency = 1881600000
```

OpenCore 1.0.8 has no key for this. `PlatformInfo/Generic/ProcessorSpeed` is
not in the Generic or SMBIOS schema and was silently ignored; it has been
removed from the build. Do not "correct" the number by changing the TSC — that
is the kernel's time source. The real clock is visible in `powermetrics`.

`lowpowermode 1` is the real lever. XCPM holds the package to
`IOPlatformPowerProfile`'s `lpm_ratio` (`0x18` = 2.4 GHz ceiling) instead of
the full table.

## 2. Package power, cap on vs off

`sudo bash scripts/macos/power-audit.sh --compare-lpm`, `DURATION=8`, on AC,
desktop open:

| Phase | `lowpowermode 0` | `lowpowermode 1` |
|---|---|---|
| idle | 10.15 W, peak 2.80 GHz | 7.63 W, peak 1.52 GHz |
| one thread | 14.17 W, peak 3.59 GHz | 8.25 W, peak 1.76 GHz |
| all threads | 19.93 W, peak 3.57 GHz | 10.27 W, peak 1.78 GHz |

The cap roughly halves package power under load. "Peak" is the highest 1 s
per-core average in that phase.

Two limits are not pmset settings:

- the P-cores sustain about **3.6 GHz**, not 4.7 GHz, with
  `CPU LIMIT ICCMAX/PL4/OTHER` in every phase — a firmware power limit;
- GPU DC6 is **0.00 %** and the package never goes past **PC3**. Without GuC
  the iGPU never enters DC6, so the DMC-gated deeper package states stay out of
  reach. The **0.00 % package residency** originally written here was
  measurement contamination, not the platform: a quiet window shows PC3
  93–96 % and the cores in C6/C7 (see the clean baseline below).

Full detail: [06-usb-acpi-power.md](06-usb-acpi-power.md#measured-effect-2026-11-05).

### XE-PM HWP cap fix (2026-11-11)

The default WhateverXe 0.8.0 was rebuilt with
`tools/patches/whateverxe-xepm-hwp-caps.patch`, which makes XE-PM convert
XCPM's HWP request instead of maximizing it. Same boot, one busy thread, on
battery:

| Case | Busiest core | Package |
|---|---|---|
| old kext, `lowpowermode 1`, `hwp=1` | 3.81–3.84 GHz | 20.6–21.8 W |
| rebuilt kext, `lowpowermode 1`, `hwp=1` | **2.21–2.23 GHz** | **10.8–11.7 W** |
| rebuilt kext, `lowpowermode 0`, `hwp=1` | 3.81 GHz | 14.2–15.4 W |

A four-thread run under `lowpowermode 1` kept all ten cores at or below
2.5 GHz (P-cores ~2.0–2.2 GHz), so the cap is enforced on both core types.
All ten cores were busy, so the package cannot be in a C-state at all; that
figure says nothing about this change. The idle figure is below. Battery draw
with OpenCode, WindowServer and post-boot background work active fell from
17.2 W to 14.4 W, but that is not an idle baseline.

### Idle power: timer coalescing and EPP 96 (2026-11-12)

Measured on the same install with the desktop open (Tahoe 26.7.1, AC). These
are A/B deltas inside a noisy session, not a cold-boot idle floor; the package
figure was roughly 9–10 W throughout.

| Change | Idle package delta | Detail |
|---|---|---|
| Timer coalescing | **−0.7 to −1.6 W** | `kern.timer_coalesce_{kt,fp,ts,tier0}_scale=1`, `ns_max=10 ms`; tier-1 `20 ms` |
| XE-PM EPP `0` → `96` | **−0.75 W** mean | EPP 128 and 255 were both worse |
| Both | **−0.86 W** mean | effects overlap; they do not add |

EPP 96 is close to free in performance terms:

| Load | EPP 0 | EPP 96 |
|---|---|---|
| One-thread turbo | 3828 MHz | **3819 MHz** |
| Four-thread sustained | 2781 MHz, 24.06 W | 2726 MHz (−2 %), 23.73 W |
| `lowpowermode 1` peak (80 samples) | 2373 MHz | 2373 MHz, 0 samples ≥ 2500 MHz |

So EPP 96 lowers idle draw without weakening the Low Power Mode cap and with
no meaningful turbo loss. It is now the compiled XE-PM default; the sysctl
still overrides it. Timer coalescing needs the boot daemon
(`scripts/macos/install-power-tuning.sh`) because it is a sysctl.

The NVMe L1SS properties + `-nvmefaspm` and `BTIdle` + the
IntelBluetoothFirmware power-state patch shipped in the same EFI build and
were verified live, but neither has a clean isolated A/B yet. They are
documented as mechanisms in
[06-usb-acpi-power.md](06-usb-acpi-power.md#idle-power-timers-epp-and-device-idle-2026-11-12)
and [04-wifi-bluetooth.md](04-wifi-bluetooth.md#bluetooth-idle); do not assign
them a wattage until one is measured.

### Clean idle baseline (2026-11-13)

The idle numbers above were taken with the agent desktop (OpenCode, its TUI
renderer and WindowServer) active, and that tooling alone keeps cores out of
their deep C-states and roughly doubles package power. The corrected baseline
is a hand-run window on battery, Tahoe 26.7.1, `balanced`, brightness
unchanged, with OpenCode and the desktop quit:

```sh
sudo scripts/macos/idle-baseline.sh 120                    # display on
sudo scripts/macos/idle-baseline.sh 120 --display-sleep    # panel off
```

The script sleeps through the window, reads the battery at both ends, and only
then starts powermetrics/top/assertions, so the samplers do not land inside the
interval they describe.

| Metric | display on | display asleep |
|---|---|---|
| package power (energy model) | **2.46 W** | **2.14 W** |
| package C-state | **92.7 %** (C2 15.8, C3 76.9) | **96.3 %** (C2 1.6, C3 94.7) |
| PC6–PC10 | 0.00 % | 0.00 % |
| P-cores C7 | 96.34 / 95.93 % | 97.60 / 97.77 % |
| E-cores C6 | 98.7–99.9 % | 99.4–99.9 % |
| whole-machine draw | **7.07 W** | **5.84 W** |
| top interrupt rates | TMR 53.7/s, IPI 22–32/s | IPI 22–34/s, TMR 29/s |

Both reads show the same `0xE2 = 0x74008008` (limit 8 = C10, CFG lock set) and
`deep_idle_count = 0`; the GPU stays at RC6 ~100 % with `GPU Busy 0.00 %`.

One artifact to ignore: powermetrics sometimes prints an E-core slightly above
100 % (100.02–100.42 %). It derives total and per-C-state residency over
marginally different intervals; the overshoot is under half a percent and is
not real residency.

**Why PC6+ never appears.** A probe build of WhateverXe, archived as
`tools/patches/whateverxe-xepm-msr-probe.patch`, exposed the package power
MSRs through `debug.xepm.msr`. On this part:

- `0xE2 = 0x74008008`: limit **8** (C10, "no limit"), CFG lock set, C1
  demotion and package demotion enabled. The limit was never the blocker, and
  the guarded write (`debug.xepm.pcst`) is refused by the lock.
- `0x60` (PC2 residency) is unsupported; `0x3F8` (PC3) advances with the wall
  clock while `0x3F9`–`0x632` (PC6–PC10) stay at exactly zero.
- `0x770` bit 0 is set (HWP on) and `0x774` carries EPP 96 with the expected
  min/max/desired fields; `0x771` reports the core's HWP capabilities.

So the hardware limit is high, the OS asks for the right states, and the
package still stops at PC3. Deeper states need the DMC/PMC coordination that
WhateverXe does not implement, which makes it a driver project rather than a
configuration toggle. The probe only added three read-only/debug sysctls and
is not part of the shipped kext.

**Correction.** The "package and cores never idle, stuck in PC0" conclusion in
earlier revisions of this page was an artifact of the measuring session. With
the desktop quit, the package sits in PC3 ~93–96 %, the P-cores in C7 ~96–98 %
and the E-cores in C6 ~99 %. There is no P-core blocker to fix. Package PC6+
and GPU DC6 remain at zero because they need a DMC/PMC path WhateverXe does
not implement, so that headroom is a driver project with low expected gain,
not a configuration toggle.

Confirmed again on the **shipped** kext (`a84472e2…`, no probe sysctls) after
a reboot, display asleep: **2.24 W** package, **95.3 %** package residency
(C2 1.6 / C3 93.7), P-cores C7 97.8 / 97.5 %, **6.29 W** whole-machine. The
probe build carried only three read-only/debug sysctls, so this is the expected
result.

The 7.07 W vs 5.84 W split is the useful part: with the panel off the SoC is
only ~2.2 W, so the rest is platform. The isolation runs below attribute it.

One contamination example from the same session: the first run after that
reboot read 4.45 W and 47.9 % residency because `triald` (12.8 % CPU) and
Spotlight (`mds`/`mdworker`) were still indexing, with IPIs at ~750/s.
Post-boot background work has to finish before any of these numbers mean
anything.

#### Idle floor isolation (2026-11-13)

Four more 120 s windows, same machine, on battery, Bluetooth **off**, no USB
devices attached, panel and Wi-Fi controlled:

```sh
sudo networksetup -setairportpower en0 off
sudo scripts/macos/idle-baseline.sh 120 --display-sleep   # A
sudo networksetup -setairportpower en0 on
sudo scripts/macos/idle-baseline.sh 120 --display-sleep   # B
sudo scripts/macos/idle-baseline.sh 120                   # C, panel minimum
sudo scripts/macos/idle-baseline.sh 120                   # D, panel ~40 %
```

| run | panel | Wi-Fi | total draw | SoC package | everything else |
|---|---|---|---|---|---|
| A | asleep | off | **5.66 W** | 2.22 W | 3.44 W |
| B | asleep | on | **5.91 W** | 2.43 W | 3.48 W |
| C | on | on | **6.49 W** | 2.63 W | 3.86 W |
| D | on, ~40 % | on | **6.30 W** | 2.52 W | 3.78 W |

What the split says:

- **Wi-Fi ≈ 0.25 W** (A → B). The AirPortItlwm power penalty is real but
  small; it is not the multi-watt item it had been assumed to be.
- **Panel ≈ 0.6 W** at this brightness (B → D). C and D are 0.19 W apart,
  inside the noise, so the intended minimum-brightness step did not register;
  a minimum-vs-maximum panel A/B is still open.
- **3.4 W of the 5.7 W panel-off floor is neither CPU/GPU, Wi-Fi nor panel.**
  With Bluetooth off and nothing on USB, the residue is PCH, DRAM, NVMe, VRM
  conversion loss, the EC and the display link.

Caveat: the OpenCode CLI process was still resident during A and B (~2 % CPU),
because these runs were started from the agent session. The fully-quiet runs
earlier in the evening gave the same floor (5.84 W), so the conclusion stands.

In both panel-asleep runs `IODisplayWrangler` reported state 1 and the
backlight `DevicePowerState 0`, so the panel and its backlight were genuinely
off; the ~0.6 W step is the lit panel at ~40 %, not a half-asleep link.

Sanity check on the battery rail: over the ~11 min of the four runs the pack
fell **71 % → 69 %**. At this pack's health (`AppleRawMaxCapacity` 7745 mAh
against `DesignCapacity` 8638 mAh, ≈90 %, about 59 Wh at 7.6 V) that is
1.18 Wh / 0.19 h ≈ **6.2 W** average, matching the ~6.0 W measured. `pmset`'s
"time remaining" implies ~9 W at the same moment and is pessimistic; quote the
rail, not the projection.

## 3. Geekbench 7: the runs, and why most were invalid

All runs are Geekbench 7.1.0 for macOS AVX2, on battery, same install.

| # | Date | `lowpowermode` | Background | Single | Multi | Result |
|---|---|---|---|---|---|---|
| 1 | 2026-11-04 15:58 | unknown (quiet) | none | **1453** | **5399** | [801689](https://browser.geekbench.com/v7/cpu/801689) |
| 2 | 2026-11-05 19:08 | 0 | OpenCode streaming | 812 | 3827 | [810510](https://browser.geekbench.com/v7/cpu/810510) |
| 3 | 2026-11-05 19:34 | 0 | OpenCode "idle" | 885 | 4586 | [810664](https://browser.geekbench.com/v7/cpu/810664) |

Run 3 was intended to be quiet, but throughout the run:

| Process | CPU |
|---|---|
| OpenCode Helper | ~47 % |
| OpenCode Helper (Renderer) | ~41 % |
| WindowServer | ~28 % |

Load average was **6.2**. The two low runs are therefore a measurement of
contention with the agent desktop, not of the laptop, and they are not
comparable with run 1 or with the Linux numbers (about 2100 / 7700 reported
from Fedora).

**Decision:** do not use Geekbench under the OpenCode desktop to judge the
power profile, and do not treat the macOS-vs-Fedora score gap as a tuning
target by itself. If a clean comparison is needed, quit the desktop and run it
from a normal session.

## 4. Battery life: a clean run, and why load dominates

### Clean measurement (2026-11-07)

On battery, `balanced` (`lowpowermode 1`), panel at **Looks like 1440 × 900**,
reading a PDF from internal storage with no background apps:

| Metric | Value |
|---|---|
| Window | 14:24:44 → 14:39:00 (14 min 16 s) |
| Samples | 81 at 10 s |
| Average draw | **7.93 W** |
| Peak draw | 10.51 W (first minute, panel refresh) |
| Charge used | 77 % → 74 % |
| Projected runtime | **6.03 h** |

The numbers cross-check: 7.93 W × 0.238 h ≈ 1.89 Wh, and 3 % of the ~63 Wh
pack is about 1.9 Wh. `pmset` independently projected 5:42 at 77 %. **This is
the figure to quote for normal document reading**, not the 1:51 seen under the
agent UI.

Caveat: the SMC updates `InstantAmperage` about once every 50 s, so the 81
rows contain only ~17 independent changes. The average is still valid, but the
row count overstates the statistical power.

### What the cap is worth on light use

The run above used `balanced` (`lowpowermode 1`). To price the cap, repeat it
with the cap removed and compare against the 7.93 W baseline:

```sh
bash scripts/macos/battery-cap-compare.sh
```

The script refuses to start on AC, holds the panel awake, runs 14 minutes with
`lowpowermode 0`, and restores `lowpowermode 1` on every exit path. Quit
OpenCode first: its helper and renderer keep roughly two cores busy.

**Result, 2026-11-07 14:46–14:54** (8 minutes, PDF reading, no background
apps, `lowpowermode 0`):

| Metric | Cap on (`balanced`) | Cap off | Delta |
|---|---|---|---|
| Average draw | 7.93 W | **11.74 W** | **+3.81 W (+48 %)** |
| Peak draw | 10.51 W | 15.05 W | +4.54 W |
| Minimum draw | 6.97 W | 9.37 W | +2.40 W |
| Full-charge runtime (normalised) | 8.0 h | **5.4 h** | **−33 %** |
| Observed range | 7.0–10.5 W | 9.4–15.1 W | much wider |

`InstantAmperage` was sampled every 10 s; 47 rows but only **9 distinct
currents**, because the SMC updates about once a minute. The two projections
were taken at different charge levels (75 % and 70 %), so the table normalises
both to a full pack before comparing; the watts need no normalisation.

The result was larger than expected for "light use". Reading and scrolling a
PDF still produces UI bursts that the uncapped CPU services at full turbo, and
the cap removes exactly those. **Keep `balanced` for reading, not just for
compiles.**

Caveats: one session per state, different charge levels, 8 versus 14 minutes,
and screen brightness was not recorded. Treat the magnitude as ±10–15 %, not
as a precise law. The direction is large enough to be real, and the cap-off
range being wider at both ends makes the mechanism clear.

Record a repeat here if you want a tighter number. `--analyze FILE` re-scores
any CSV without measuring again:

```sh
bash scripts/macos/battery-cap-compare.sh --analyze LOGS/battery-cap-off-*.csv
```

### Load dominates the projection

During Geekbench run 3 the battery fell **83 % → 75 % in 8 min 10 s** (about
46 %/h; `pmset` projected 1:51). Moments later, with the UI idle, the same pack
projected **3:54** at 60 %. That spread is why the repository ships
`battery-watch.sh` instead of trusting a single `pmset` estimate:

```sh
INTERVAL=10 bash scripts/macos/battery-watch.sh
```

Unplug, use the machine normally, and read the average watts and projected
hours from the CSV. The earlier "100 % → 40 % in under 4 h" observation was
made under the same kind of UI load, so it is an upper bound on drain, not a
property of the hardware.

### Same machine on Fedora: a hardware reference

A short Fedora run on 2026-11-08 read the battery rail directly
(`/sys/class/power_supply/BAT*/power_now`) while Firefox kept **15 tabs open**.
The power-save profile was active for the idle phase; the performance profile
was selected for Geekbench 7. Raw log: `LOGS/fedora-power-20261108.txt`.

| Phase | Window | Average | Peak |
|---|---|---|---|
| Browser warm-up / settling | 15:58:00–15:59:56 | 6.65 W | 8.37 W |
| **Power save, idle, Firefox 15 tabs open** | 16:02:00–16:05:52 | **4.23 W** | 4.82 W |
| **Geekbench 7, performance profile** | 16:06:52–16:12:03 | 17.8 W | **24.12 W** |
| Cooldown after the benchmark | 16:12:08–16:15:33 | 11.95 W | 21.51 W |

This is a whole-machine battery-rail measurement, the same kind of number as
`battery-watch.sh`, so it can be set beside the macOS 7.93 W light-use figure.
The gap is the important result:

- **Fedora: 4.2 W idle with 15 browser tabs.**
- **macOS: 7.9 W reading a PDF with no background apps.**

That is roughly **+3.7 W (+88 %)** at the lightest comparable load, before any
browser tab is added. The CPU-idle half of that gap is **not** explained by
C-state residency: both systems reach their shallow package states, and macOS
idles in PC3 93–96 % (§2). The plausible remainder is the DMC-gated deep
package states and GPU DC6, which macOS never enters without a GuC/DMC path;
no Fedora-side residency data was captured to prove it.

The practical consequences are the ones reported on the machine: a warmer
chassis and, as measured below, about 2.5× the idle draw of Linux on the same
board.

Caveats: one run per state, screen brightness and battery health were not
recorded, and the Fedora `power_now` value includes the panel, Wi-Fi and SSD
just like the macOS battery-rail figure. The Fedora Geekbench score was not
saved in this log. This is a reference floor, not a controlled A/B: repeat the
same 15-tab Firefox idle workload on macOS, at the same brightness, before
treating the 3.7 W difference as a target.

Before that repeat, record the CPU-power state that produced the macOS number:

```sh
sysctl debug.xepm          # hwp / route / cst should be 1 on Tahoe 26.7.1
pmset -g | grep lowpowermode
kmutil showloaded | grep -E 'WhateverXe|AppleIntelTGLCompat'
```

`route: 3` means WhateverXe's XE-PM profile did not install (the Sequoia
24H232 case); `lowpowermode 0` means the performance profile is active. Both
change the result by more than the ±10–15 % measurement noise. The kext and
`AppleIntelTGLCompat` versions must also match: 0.6.0 with 0.6.0 (Graphics
0.3.1) on Sequoia, or 0.8.0 with 0.8.0 (Graphics 0.4.1) on Tahoe. See
[06-usb-acpi-power.md § Hybrid P-cores](06-usb-acpi-power.md#hybrid-p-cores-and-the--wex-pm-route).

### Tuned Linux idle vs macOS idle (2026-11-13)

The Fedora run above was a browser workload. A separate tuned Linux session on
the same laptop idled at **~2.5 Wh/h ≈ 2.5 W** with the panel **on** at ~40 %
brightness, 2880×1800 at 200 % scale and Wi-Fi connected, as reported by the
PowerState app. Treat the unit with care: if the app was showing accumulated
energy over a window rather than a rate, the figure is not comparable; the
authoritative read is `/sys/class/power_supply/BAT*/power_now` (µW).

Against the four-run isolation in §2 that is a **2.5× gap**: 2.5 W on Linux
vs 6.30 W on macOS at the same panel setting. The split rules out the obvious
suspects:

- Wi-Fi is 0.25 W and was **on** in both cases;
- the panel is ~0.6 W at that brightness, and both numbers include it;
- Bluetooth was off, no USB device was attached, and the desktop was quiet.

So the gap is not the compositor and not the desktop environment. It is the
platform: macOS stops at **PC3**, and the states above it need the DMC/PMC
coordination that Linux's i915/PMC stack provides and WhateverXe does not
implement. macOS also never drives the PCH/EC/s0ix states that Linux's
platform drivers do. About **3.4 W** is spent outside the CPU/GPU package and
cannot be attributed to one device.

What it would take, in order of effort:

| Lever | Expected | Cost |
|---|---|---|
| PC6+ / DMC path | 1.3–1.6 W | driver work in WhateverXe; not a toggle |
| PCH/EC/s0ix power states | ~1–2 W | reverse-engineering the HP ACPI/EC; high risk |
| NVMe controller APST | 0.2–0.5 W | kext-level forcing; the link state is already fixed |
| Background daemons | <0.3 W | marginal |

The practical consequence is runtime, not heat: about **9 h** of idle runtime
on this pack (59 Wh ÷ 6.3 W) against roughly 23 h at the Linux floor. That
matters for a machine left idle on battery for a whole day, and hardly at all
next to load power (10–24 W). It is the price of running macOS on a board
whose power management it does not know.

This also corrects an earlier assumption on this page: Wi-Fi is not a
multi-watt item, and the gap is not because macOS fails to reach PC2/PC3 — it
reaches them. What it never reaches is PC6+ and the platform states behind it.

## 5. Hybrid topology looks wrong but is intentional

```text
hw.physicalcpu        = 2
hw.logicalcpu         = 12
machdep.cpu.core_count = 12
SMBIOS Total Cores    = 10
```

`hw.physicalcpu = 2` is CpuTopologyRebuild's SMT spoof: the E-cores are folded
into the P-cores as extra SMT siblings so macOS schedules the hybrid CPU
better. All 12 threads are online, and 10 is the true P+E core count. Geekbench
prints "2 Cores, 12 Threads" for the same reason. Do not "fix" it with
`ctrsmt=off` or `-ctrfixcnt` without a measured reason; the kext author warns
that performance can drop.

See [08-troubleshooting.md](08-troubleshooting.md#cpu-name-and-thread-count).

## 6. Where the live EFI actually lives

The bootable OpenCore EFI for Tahoe is on the internal ESP labelled
**`EFITAHOE`** (`/dev/disk0s10`, ~150 MB FAT16,
`/Volumes/EFITAHOE/EFI/OC/config.plist`). The second internal ESP,
**`SECONDEFI`** (`/dev/disk0s8`), holds a copy of the same tree for rollback.
`disk0s1` is the HP/Windows ESP and contains no `EFI/OC`. This matters for
every "patch the ESP" instruction: patch the config the machine actually
boots, and back it up first (partition numbers move after repartitioning, so
confirm with `diskutil list` and `mount` rather than trusting the number).

The live config is byte-identical to the deployed build
(`build/EFI-wex080-adlp`). The dead `ProcessorSpeed` key was removed from it
with PlistBuddy:

```sh
CFG=/Volumes/EFITAHOE/EFI/OC/config.plist
cp -p "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"
/usr/libexec/PlistBuddy -c 'Delete :PlatformInfo:Generic:ProcessorSpeed' "$CFG"
plutil -lint "$CFG"
```

## 7. Reproducing these measurements

```sh
# package power, cap on vs off (needs root)
sudo bash scripts/macos/power-audit.sh --compare-lpm

# one snapshot: pmset, XCPM sysctls, WhateverXe -wex-pm state, thermals
sudo bash scripts/macos/power-audit.sh

# quiet idle baseline (quit OpenCode first; 120 s window, optional panel off)
sudo bash scripts/macos/idle-baseline.sh 120
sudo bash scripts/macos/idle-baseline.sh 120 --display-sleep

# real discharge over normal use (no root)
INTERVAL=10 bash scripts/macos/battery-watch.sh

# one-line live draw and projected runtime (no root)
bash scripts/macos/power-now.sh --once

# re-apply timer coalescing + EPP at every boot
sudo bash scripts/macos/install-power-tuning.sh
sysctl kern.timer_coalesce_tier0_ns_max kern.timer_coalesce_tier1_ns_max

# same-machine Fedora reference (battery rail, no root)
while true; do
  echo "$(date +%T)  $(awk '{printf "%.2f W\n", $1/1000000}' /sys/class/power_supply/BAT*/power_now)"
  sleep 5
done

# post-boot state in one file
bash scripts/macos/post-install-check.sh
```

Keep the raw output. A conclusion without the phase, the power source and the
background load is not reproducible.
