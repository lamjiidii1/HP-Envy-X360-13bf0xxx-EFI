# 14 — Measurements and what they taught us

This page keeps the raw numbers that drove the power, thermal and
"is-it-fast-enough" decisions, without requiring the gitignored `LOGS/`
directory. Raw captures remain in `LOGS/power-audit-*` and
`LOGS/geekbench/` on the machine that produced them.

Environment: macOS Sequoia 15.8.2 (24H232), i7-1250U (2P + 8E, 12 threads),
16 GB, 2880×1800 OLED. All CPU numbers are the Intel energy-model estimate from
`powermetrics` (`CPUs+GT+SA`), not a wall-meter reading.

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
- package C-state residency is **0.00 %** and GPU DC6 is **0.00 %**. Without
  GuC the iGPU never enters DC6, so the package cannot reach its deepest
  states. This is a diagnostic, not a knob.

Full detail: [06-usb-acpi-power.md](06-usb-acpi-power.md#measured-effect-2026-11-05).

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

The bootable OpenCore EFI on this machine is on the USB stick
(`/Volumes/MACUSB/EFI/OC/config.plist`). `disk0s1` is the HP/Windows ESP and
contains no `EFI/OC`. This matters for every "patch the ESP" instruction: patch
the config the machine actually boots, and back it up first.

The dead `ProcessorSpeed` key was removed from that file with PlistBuddy;
afterwards the live config is byte-identical to `build/EFI`:

```sh
CFG=/Volumes/MACUSB/EFI/OC/config.plist
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

# real discharge over normal use (no root)
INTERVAL=10 bash scripts/macos/battery-watch.sh

# post-boot state in one file
bash scripts/macos/post-install-check.sh
```

Keep the raw output. A conclusion without the phase, the power source and the
background load is not reproducible.
