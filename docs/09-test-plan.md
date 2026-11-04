# 09 — Hardware test plan

Run the phases in order. Each phase depends on the previous one; a failure in
phase 1 makes phase 3 meaningless. Record the result of every step, including
the failures — the point of the repository is that the state of the machine is
known, not that everything passes.

Use the `--debug` build for any phase where a step fails, then repeat the
step once and capture the evidence described in
[08-troubleshooting.md](08-troubleshooting.md).

## Phase 0 — Offline pre-flight (no reboot)

| ID | Step | Pass criterion |
|---|---|---|
| T00.1 | `make build` | exits 0; `checked build/EFI` ends with `result : OK` |
| T00.2 | `python3 scripts/verify_efi.py --allow-blank-identity build/EFI` on a checkout without the private identity | `result : OK` (CI mode) |
| T00.3 | `make inventory` and `git diff --exit-code audit/payloads.tsv` | no diff: pinned payloads are unchanged |
| T00.4 | `shasum -a 256 efi/variants/gpu-hp-adlp-edp/WhateverXe.kext/Contents/MacOS/WhateverXe` | `197da23b…770288c` — the stored payload stays published |
| T00.5 | Inspect `build/EFI/BUILD-INFO.plist` | `gpu = hp-adlp-edp`, `wifi = airportitlwm`, `debug = false`, `identity_injected = true`; `gpu_patches.sequoia_mmio` = `applied` |
| T00.6 | `shasum -a 256 build/EFI/OC/Kexts/WhateverXe.kext/Contents/MacOS/WhateverXe` | `6bf93338…3bea60ba` (published binary plus the 24H232 constant) |
| T00.7 | Open `build/EFI/OC/config.plist` | `boot-args` contains the five `-wex-*` fork arguments and `revpatch=sbvmm,cpuname`; `PlatformInfo/Generic/ProcessorType` is `3841`; SMBIOS fields are filled |
| T00.8 | Back up the current ESP and keep a bootable USB | both exist and boot (test the USB before relying on it) |

Do not skip T00.8. The rest of the plan assumes a working escape hatch.

## Phase 1 — Boot and identity

| ID | Step | Pass criterion |
|---|---|---|
| T01.1 | Boot the new EFI from USB first | OpenCore picker appears |
| T01.2 | Select the macOS volume | reaches the desktop without a panic |
| T01.3 | `sw_vers` | `15.8.2` / `24H232` (`Darwin 24.6.0`) |
| T01.4 | `ioreg -l \| grep IOPlatformSerialNumber` | matches `private/identity.plist` |
| T01.5 | `system_profiler SPHardwareDataType` | `MacBookPro16,2`, correct serial, 16 GB |
| T01.6 | Sign in state of iCloud/iMessage/App Store | unchanged; no re-activation prompt |
| T01.7 | `nvram boot-args` and `nvram csr-active-config` | expected arguments; `03080000` |
| T01.8 | Reboot once more | identity survives (values are written by OpenCore, not only by macOS) |

If T01.6 fails, stop. Fix the identity before testing anything else; a
graphics experiment must not be tangled with an activation problem.

## Phase 2 — Baseline (before changing the GPU driver)

This phase records the state the machine is in today, so the A/B comparison
later is honest.

| ID | Step | Pass criterion |
|---|---|---|
| T02.1 | `kextstat \| grep -Ei 'whateverxe\|tglcompat'` | WhateverXe and Compat load |
| T02.2 | `ioreg -rc IONDRVFramebuffer -d1` | exactly one (fallback) if acceleration is not working |
| T02.3 | `ioreg -rc AppleIntelFramebuffer` | count 1 if accelerated, 0 if falling back |
| T02.4 | `ioreg -rc IntelAccelerator` | count 1 if accelerated, 0 if falling back |
| T02.5 | `system_profiler SPDisplaysDataType` | record VRAM and "Kernel Extension Info" verbatim |
| T02.6 | Save the whole evidence bundle | files exist under `~/Desktop/wex-report` |
| T02.7 | `./scripts/macos/openmac-diag.sh install`, then `status` after two minutes | five agents loaded; `live/monitor.log` has a sample; see [11-diagnostics.md](11-diagnostics.md) |

## Phase 3 — Graphics: the primary experiment

Prerequisite: `WhateverXe Graphics 0.3.1` (Compat 0.6.0) is installed and the
`hp-adlp-edp` EFI is on the ESP. The default `make build` already carries the
24H232 Sequoia MMIO constant; T00.5/T00.6 prove it before boot. A stick copied
from an older build must be repaired with
`scripts/macos/patch-wex-sequoia-mmio.sh` or rebuilt.

| ID | Step | Pass criterion |
|---|---|---|
| T03.1 | `kmutil showloaded \| grep -Ei 'whateverxe\|tgl'` | `WhateverXe (0.6.0)` and `AppleIntelTGLCompat (0.6.0)` |
| T03.2 | `ioreg -l \| grep -o '"TGLSequoiaMMIOGuard" = <[^>]*>'` | entry 19 = `01` |
| T03.3 | `ioreg -l \| grep -o '"TGLSequoiaMMIOInspection" = <[^>]*>'` | present; record the bytes |
| T03.4 | `ioreg -l \| grep N97NativeStartAllowed` | `Yes` |
| T03.5 | `ioreg -rc AppleIntelFramebuffer` | count ≥ 1 |
| T03.6 | `ioreg -rc IntelAccelerator` | count ≥ 1 |
| T03.7 | `system_profiler SPDisplaysDataType` | VRAM in the GB range (not 19 MB); Metal listed |
| T03.8 | Set **Looks like 1440 × 900** (HiDPI) and check the internal panel | no flicker, no half-screen, brightness keys work; UI scale matches GNOME at 200 % |
| T03.8a | `system_profiler SPHardwareDataType \| grep -E 'Processor Name\|Total Number of Cores'`; `ioreg -lw0 -p IODeviceTree \| grep -o '"cpu-type" = <[^>]*>'`; `sysctl -n hw.ncpu machdep.cpu.brand_string` | `Processor Name` is the i7-1250U (not `Unknown`), `cpu-type = <010f>` (0x0F01), `Total Number of Cores: 10`, `hw.ncpu: 12`, brand string correct |
| T03.8b | Open System Settings > Battery | pane opens; if it exits, capture the PowerPreferences log described in [08](08-troubleshooting.md#battery-settings-pane-exits-powerpreferences) |
| T03.9 | Attach an external display over USB-C/HDMI (if available) | second display appears; record the connection path |
| T03.10 | Open a Metal app (Maps, Photos, a game) | renders without software fallback |
| T03.11 | Leave ControlCenter and Safari video running for a few minutes | no ControlCenter crash loop, no `RB::load_library_archive` assert |
| T03.12 | If T03.11 fails, install `scripts/macos/metal-archive-workaround.plist` and repeat | ControlCenter stays up; Metal app renders |

If T03.2 shows entry 19 = `00`, save `TGLSequoiaMMIOGuard` and
`TGLSequoiaMMIOInspection` and confirm the ESP has the patched binary
(`6bf93338…`, or `gpu_patches.sequoia_mmio` in `BUILD-INFO.plist`). If it does
and entry 19 is still `00`, the kernel moved the call again: read the real
bytes with `scripts/macos/patch-wex-sequoia-mmio.sh --kernel <KDK>` and record
entry 16. Do not change `-igfxdvmt`, `framebuffer-stolenmem` or the SMBIOS:
memory admission already passed.
See [03-graphics.md](03-graphics.md#the-24h232-mmio-signature).

## Phase 4 — Graphics fallbacks (only if phase 3 fails)

Each step changes exactly one thing and records the same evidence bundle.

| ID | Step | Pass criterion / decision |
|---|---|---|
| T04.1 | Reconfirm the default build is unchanged (same kext hash, same boot args) | isolates the driver as the only variable |
| T04.2 | Boot `wex070` with `--debug` (`-v debug=0x100`), after installing Graphics 0.4.0 | capture the OpenCore log and `WhateverXeFirmwarePorts`; expect a VBT conflict and a dark internal panel |
| T04.3 | Capture `WhateverXeVBTRaw` + port records + `TGLSequoiaMMIOGuard` | complete report for upstream |
| T04.4 | If the patched 0.6.0 still shows entry 19 = `00`, record the real bytes at `_IOProtectCacheMode + 0xCA` with `patch-wex-sequoia-mmio.sh --kernel` | evidence for the next point-update constant |
| T04.5 | Report upstream with BIOS F.35, macOS 24H232, the VBT and the guard | issue contains the evidence listed in [08](08-troubleshooting.md#11-reporting-a-graphics-bug-upstream) |
| T04.6 | Revert to the default EFI and reinstall Graphics 0.3.1 | machine boots and is usable |

If neither variant accelerates, do not try NootedGreen as a quick fix. It is a
different driver with a different support matrix, and mixing investigations
makes both reports unusable.

## Phase 5 — Networking

| ID | Step | Pass criterion |
|---|---|---|
| T05.1 | `kmutil showloaded \| grep -i itlwm` | exactly one Wi-Fi driver (`com.zxystd.AirportItlwm` by default) |
| T05.2 | Open the Wi-Fi menu / System Settings → Network | native Airport interface appears; scan returns networks |
| T05.3 | Join a WPA2/WPA3 network | DHCP address; `ping 1.1.1.1` succeeds |
| T05.4 | `system_profiler SPBluetoothDataType` | controller present, firmware version shown |
| T05.5 | Pair a Bluetooth mouse or headphones | connects and works |
| T05.6 | Reboot and reconnect | both survive a reboot |
| T05.7 | Only if AirportItlwm fails: build `--wifi itlwm --out build/EFI-itlwm` and repeat with HeliPort | interface appears; record whether it is better on this install |

Do not run T05.7 during the graphics A/B; it adds a second variable.

## Phase 6 — Audio

| ID | Step | Pass criterion |
|---|---|---|
| T06.1 | `system_profiler SPAudioDataType` | output devices include Headphones; input includes Internal Microphone |
| T06.2 | Play audio through the 3.5 mm jack | clean output, both channels |
| T06.3 | Record 10 s with QuickTime/Voice Memos | no panic in `EupDSP::ConfigParamInt`; file is audible |
| T06.4 | Change volume and mute | works |
| T06.5 | Optional: built-in speakers | expected silent (CS35L41); record, do not chase |
| T06.6 | `log show --last 5m \| grep -i applealc` | no repeating errors |

Recording is the critical step: the unpatched layout 11 panics the kernel, and
a successful recording proves the DSP patch is in the built kext.

## Phase 7 — USB, input, camera

| ID | Step | Pass criterion |
|---|---|---|
| T07.1 | `system_profiler SPUSBDataType` | both controllers and the expected ports |
| T07.2 | Plug a USB-A stick and a USB-C device | both mount |
| T07.3 | Sleep/wake is not required for this test; hot-plug instead | devices appear/disappear cleanly |
| T07.4 | Keyboard (internal) | all keys, brightness keys included |
| T07.5 | Trackpad | expected dead on this unit; touchscreen may also be dead |
| T07.6 | Camera | known issue; record `SPCameraDataType` and whether any app sees it |
| T07.7 | SD card reader | expected unsupported (RTS5288); record |

## Phase 8 — Power, battery, thermals

| ID | Step | Pass criterion |
|---|---|---|
| T08.1 | `pmset -g batt` | percentage and charging state correct |
| T08.2 | Unplug and run 10 min of light use | percentage decreases plausibly; no sudden shutdown |
| T08.3 | `pmset -g therm` and `powermetrics --samplers smc -n1` (sudo) | CPU temperature sane at idle; fan behaviour recorded |
| T08.4 | `sysctl -n machdep.cpu.brand_string` | `12th Gen Intel(R) Core(TM) i7-1250U` |
| T08.5 | `ioreg -l \| grep -i AppleSmartBattery` | battery data present |
| T08.6 | Close the lid with sleep disabled | no wake hang; machine stays off/awake as configured |
| T08.7 | Open **System Settings > Battery** after installing the Metal archive workaround and clearing the Metal caches | pane opens; if it aborts, the collector captured `MTLLoader sliceIDForDevice` and a `ReportCrash` line for that second |
| T08.8 | Record `openmac-diag.sh status` and keep one `report` bundle | the investigation has a timestamped baseline before any further change |

## Phase 9 — Sleep (known broken, informational)

Only run this after the machine is otherwise stable and the EFI is backed up.

| ID | Step | Observation |
|---|---|---|
| T09.1 | `sudo pmset sleepnow` | does the machine enter sleep? |
| T09.2 | Press a key / lid | does it wake? (expected: no) |
| T09.3 | Forced power-off and boot | does macOS and the BIOS survive? |
| T09.4 | If it hangs, record the exact LED/fan behaviour | evidence for the `_S3`→soft-off workaround decision |

Do not apply the `_S3` patch during this test plan. It is a separate change
with its own validation.

## Phase 10 — Video decode (optional)

| ID | Step | Pass criterion |
|---|---|---|
| T10.1 | Play a 4K HEVC file in QuickTime | plays; record whether hardware decode is active (`sudo powermetrics --samplers gpu_power`) |
| T10.2 | Use the camera in a video call | no `AppleIntelTGLGraphicsVADriver` crash |
| T10.3 | If it crashes, apply the VA-bundle workaround | playback works on CPU; hardware decode is lost |

## Phase 11 — Regression pass

Repeat after any payload update:

| ID | Check |
|---|---|
| T11.1 | `make variants` — all four builds pass `verify_efi.py` |
| T11.2 | `make inventory` — hashes unchanged unless the payload changed intentionally |
| T11.3 | Boot the default build: desktop, Wi-Fi, audio, battery, keyboard |
| T11.4 | Graphics state matches the last recorded state (no silent regression) |
| T11.5 | Identity unchanged; iCloud still signed in |
| T11.6 | `openmac-diag.sh status` and `selftest` | agents still loaded, no required tool missing |

## Recording results

Keep a simple log next to the evidence bundle:

```
date:
BIOS:            F.35 (2025-11-17)
macOS:           15.8.2 (24H232, Darwin 24.6.0)
EFI variant:     hp-adlp-edp / airportitlwm / debug=no
WhateverXe:      0.6.0  197da23b…
Compat:          0.6.0
Graphics pkg:    0.3.1
T03.2 Guard[19]: 01
T03.4 StartAllowed: Yes
T03.5 AIFB:      1
T03.7 VRAM/Metal:  GB / Yes
Notes:
```

The most useful comparison is between two rows that differ in exactly one
column. That is why the plan forbids changing Wi-Fi, SMBIOS, boot arguments
and the GPU driver in the same reboot.
