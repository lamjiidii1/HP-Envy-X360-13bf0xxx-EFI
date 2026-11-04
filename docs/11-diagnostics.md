# 11 — Diagnostics collector

`scripts/macos/openmac-diag.sh` records what the machine was doing *before* a
problem is noticed. It is the follow-up to the one-shot
`post-install-check.sh`: that script answers "what is the state now", this one
answers "what happened at 21:34:59 when the pane closed".

Everything is per-user. No root is required, no EFI or boot-arg change is made,
and the collector can be removed without touching the system.

## What it collects

| Agent | When | Output |
|---|---|---|
| `local.openmac.diag.snapshot` | at login and every 15 min | one directory of text snapshots (`snapshots/`) |
| `local.openmac.diag.monitor` | every 60 s | one metric line (`live/monitor.log`) |
| `local.openmac.diag.stream` | continuously | filtered Metal/GPU/crash/power log lines (`live/events.log`) |
| `local.openmac.diag.archive` | at login and hourly | error/fault extract, or a full `.logarchive` when run as root (`archives/`) |
| `local.openmac.diag.crashwatch` | when a report appears | a crash-triggered snapshot |

A snapshot contains:

- macOS build, boot time, load average, `pmset -g log` tail;
- CPU brand string, core/thread counts, the System Information processor name
  and `cpu-type`, memory, `top`, all processes by CPU;
- loaded kexts, `/Library/Extensions`, `/Library/GPUBundles`;
- `system_profiler SPDisplaysDataType`, `IntelAccelerator`, `IOAccelerator`,
  the GFX0 device tree, WhateverXe/guard keys, GPU statistics;
- display modes, WindowServer preferences, backlight/framebuffer objects;
- `pmset` state, battery registers, XCPM/thermal sysctls;
- processes, listening ports, network, audio, USB, Bluetooth;
- NVRAM and boot-args with identity fields redacted;
- unified-log extracts for errors, GPU/Metal, Settings/App Store/crashes,
  sandbox denials, and kernel GPU/hang/reset events;
- the installed Metal-archive workaround plist, its `launchctl` state, the
  GUI-domain environment and the three `launchctl getenv` values;
- copies of crash, hang, spin and panic reports from the last three days;
- `powermetrics` when it can run without a password prompt.

## Install

```sh
# From the repository checkout:
bash scripts/macos/openmac-diag.sh install

# Or from the USB stick after copying it there:
bash /Volumes/MACUSB/OpenC/macos/openmac-diag.sh install
```

The install step copies the script to
`~/Library/Application Support/OpenMacDiag/openmac-diag.sh`, writes five
LaunchAgents, validates them with `plutil -lint`, and bootstraps them into the
current GUI session. Check it:

```sh
bash ~/Library/Application\ Support/OpenMacDiag/openmac-diag.sh status
bash ~/Library/Application\ Support/OpenMacDiag/openmac-diag.sh selftest
```

The first snapshot starts immediately. Allow two or three minutes before
expecting `live/monitor.log` and `live/events.log` to have content.

## Daily use

```sh
# Current agent and storage state
openmac-diag.sh status

# Take a snapshot now ("why" becomes part of the directory name)
openmac-diag.sh snapshot before-battery-test

# Bundle the newest snapshot plus the live logs for sharing
openmac-diag.sh report
```

`report` writes `reports/openmac-diag-<timestamp>.tar.gz`, copies the newest
bundle to `latest.tar.gz`, and then tries `/Volumes/MACUSB` and finally
`~/Desktop`. Pass a path to override:

```sh
openmac-diag.sh report /Volumes/MACUSB/diag.tar.gz
```

The bundle is deliberately small: text snapshots plus the two live logs. It does
not include `logarchive` directories.

## Where the data lives

```text
~/Library/Logs/OpenMacDiag/
├── snapshots/   20261103-213500-periodic/…      40 newest kept
├── archives/    20261103-220000-hourly-errors.log   6 newest kept
├── live/        monitor.log, events.log          rotated at 16/32 MB
└── reports/     openmac-diag-….tar.gz, latest.tar.gz
```

Total steady-state size is normally a few tens of megabytes. Snapshots are
pruned by count, not age, so a manual burst of `snapshot` calls does not evict
the history faster than the 15-minute schedule.

## Reading the output

Start with the timestamp of the symptom, then:

```sh
# What the machine was doing each minute
grep '2026-11-03T21:3' ~/Library/Logs/OpenMacDiag/live/monitor.log

# What the kernel/GPU/Metal said in the seconds around it
grep -n '21:34:5' ~/Library/Logs/OpenMacDiag/live/events.log | head -40

# The full snapshot nearest the event
ls -1dt ~/Library/Logs/OpenMacDiag/snapshots/* | head -3
```

In a battery-pane failure, the interesting line is the Metal assertion:

```text
PowerPreferences: (Metal) +[MTLLoader sliceIDForDevice:…], line 685:
ReportCrash: … failed assertion `Target device architecture is nil`
```

That is the same failure as the ControlCenter archive crash, not a battery
problem. See
[08-troubleshooting.md § Battery settings pane](08-troubleshooting.md#battery-settings-pane-exits-powerpreferences).

## Privacy

Serial number, hardware/platform UUID, provisioning UDID, MLB, ROM and MAC
addresses are rewritten to `<redacted>` in every `.txt`/`.log` file a snapshot
produces and in the non-root hourly archive. Two caveats:

- `.ips`, `.hang`, `.spin` and `.panic` reports copied from
  `DiagnosticReports` are **not** rewritten; review them before publishing.
- A root `.logarchive` is a binary log store and is **not** redacted. Do not
  post it publicly without checking it.

The live `events.log` is a narrow filter (Metal, GPU, PowerPreferences,
App Store, ReportCrash, kernel GPU/hang/reset), so it should not contain
identity lines, but it is still a log.

## Requirements and limits

- macOS `/bin/bash` 3.2 is enough; no Homebrew tools are used.
- `powermetrics` is skipped unless the user is root or passwordless `sudo`
  works. Run `sudo ./openmac-diag.sh snapshot` for a one-off with GPU power.
- `log collect` needs root. Without it the hourly agent stores an error/fault
  extract instead of a `.logarchive`. To get a full archive:
  ```sh
  sudo bash ~/Library/Application\ Support/OpenMacDiag/openmac-diag.sh archive manual
  ```
- A LaunchAgent only runs while the user is logged into the GUI session. It
  does not survive a logout, and it does not capture panics that occur before
  macOS starts (`install-boot-capture.sh` covers the black-screen boot case).
- The crash watcher fires on new files in `~/Library/Logs/DiagnosticReports`.
  System-wide reports in `/Library/Logs/DiagnosticReports` are captured by the
  15-minute snapshot, not instantly.

## Uninstall

```sh
bash ~/Library/Application\ Support/OpenMacDiag/openmac-diag.sh uninstall
rm -rf ~/Library/Logs/OpenMacDiag \
       ~/Library/Application\ Support/OpenMacDiag
```

`uninstall` removes the five agents and their plists but keeps the collected
data, so an in-progress investigation is not lost.

## Troubleshooting the collector

| Symptom | Check |
|---|---|
| `status` says every agent is "not loaded" | run the install from a GUI Terminal, not SSH; check `launchctl print gui/$(id -u)/local.openmac.diag.snapshot` |
| Agents load but no files appear | `cat ~/Library/Logs/OpenMacDiag/launchd-local.openmac.diag.*.log`; check the data path is writable |
| `plutil -lint` warns at install | permissions on `~/Library/LaunchAgents`; the agent file is plain XML and can be inspected directly |
| `report` copies to the wrong place | pass an explicit path; the `/Volumes/MACUSB` probe only writes when the volume is mounted and writable |
| Snapshot takes a long time | `pmset -g log` and `sysctl -a` dominate; this is expected on first run and does not block the agents |
