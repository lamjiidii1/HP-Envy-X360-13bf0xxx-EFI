# 04 — Wi-Fi and Bluetooth

## Hardware

Intel AX211 CNVi (`8086:51F0`), Wi-Fi 6E + Bluetooth 5.3 on the same module.
macOS has no native driver. Both Wi-Fi stacks below are known to work on this
generation; they are mutually exclusive and selected at build time.

## Variant A — `AirportItlwm` (default, native)

- Kext: `AirportItlwm.kext` **2.4.1, Tahoe build** (`tahoe-vtd-1`) for the
  default macOS 26 configuration, or **2.4.0, Sequoia build**
  (`sequoia-vtd-1`) for macOS 15.8.2 (see
  [10-provenance.md](10-provenance.md))
- Mechanism: implements Apple's `AirPort` interface, so the native Wi-Fi menu
  and System Settings pane work.
- Needs AppleVTD: VT-d enabled in firmware and `DisableIoMapper=false`. Both
  are already true in this config.

Why it is the default: it gives the native macOS Wi-Fi UI.

### One build per macOS family

`AirportItlwm` is not OS-independent. It links against
`com.apple.iokit.IO80211Family` and `IOSkywalkFamily`, whose ABI changes
between major macOS releases, so each macOS family needs its own build.

- Upstream [OpenIntelWireless/itlwm](https://github.com/OpenIntelWireless/itlwm)
  has no Sequoia or Tahoe asset: the newest release, `v2.3.0` (2024-06-09),
  stops at Sonoma 14.4.
- The [laobamac/itlwm](https://github.com/laobamac/itlwm) fork's release
  `v2.4.0-alpha` publishes separate `AirportItlwm-Tahoe` and
  `AirportItlwm-Sequoia` assets. The Tahoe asset reports 2.4.1 and embeds
  `tahoe-vtd-1`; the Sequoia asset reports 2.4.0 and embeds
  `sequoia-vtd-1`.
- The default build selects the Tahoe asset. The Sequoia asset is not removed;
  it stays in the tree as `wifi-airportitlwm` and is selected explicitly.

Both are alpha builds, which is why the `itlwm` fallback below stays pinned.

Caveats:

- A macOS point update may again require a new build. If no interface appears
  after an update, that is the first thing to check.
- If no interface appears at all, switch to `itlwm` instead of debugging two
  variables at once.

Build:

```sh
./scripts/build_efi.py --wifi airportitlwm-tahoe     # default, macOS 26
./scripts/build_efi.py --wifi airportitlwm-sequoia \
  --out build/EFI-sequoia                            # macOS 15.8.2
```

## Variant B — `itlwm` + HeliPort (fallback)

- Kext: `itlwm.kext` 2.3.0
- App: [HeliPort](https://github.com/OpenIntelWireless/HeliPort) (already
  installed on this machine)
- Mechanism: `itlwm` is an Ethernet-style driver. macOS sees a wired
  interface; HeliPort is the user-space UI that scans and joins networks.

Why it is the fallback:

- It is independent of the macOS build, so a point update (15.8.1 → 15.8.2)
  does not invalidate the driver.
- It is the stack that was working on this exact install before the rebuild.

Costs:

- No native Wi-Fi menu, no `AirportItlwm`-style status item.
- HeliPort must be running to join networks; it can be added to Login Items.
- No AirDrop/Continuity/AirPlay-to-Mac anyway (Intel limitation).

Build:

```sh
./scripts/build_efi.py --wifi itlwm --out build/EFI-itlwm
```

The build script places `itlwm.kext` in `OC/Kexts` and points the single
Wi-Fi entry at `Contents/MacOS/itlwm`. It also prints a reminder to copy
`HeliPort.app` to `/Applications`.

Only one Wi-Fi kext folder is copied into the EFI, and the config has a
single Wi-Fi entry. Do not merge the variants by hand: two drivers
claiming the same PCI device is a reliable way to lose Wi-Fi entirely.

## Bluetooth

Always enabled, independent of the Wi-Fi choice:

| Kext | Version | Role |
|---|---|---|
| `IntelBluetoothFirmware.kext` | 2.5.1 | Uploads firmware to the Intel controller (power-state byte patched at build time, see [Bluetooth idle](#bluetooth-idle)) |
| `IntelBTPatcher.kext` | 2.5.1 | Fixes HCI behaviour on newer Intel chips |
| `BlueToolFixup.kext` | 2.7.3 | Fixes `bluetoothd` on macOS 12+ |
| `BTIdle.kext` | local build | Lowers the USB controller's idle-suspend policy to 100 ms |

The config also clears two NVRAM variables on every boot, as required by
BlueToolFixup for Intel Bluetooth:

```
bluetoothExternalDongleFailed   = 00
bluetoothInternalControllerInfo = 0000000000000000000000000000
```

These are in `NVRAM/Add` and `NVRAM/Delete`.

The EliteBook840G8 project adds `SSDT-BTEN` to power-cycle the Bluetooth core
when the module comes from Windows/Linux with stale firmware. This machine's
Bluetooth already works, so that table is **not** included; adding it would be
a solution to a problem that does not exist here.

The Dell Latitude 7420 EFI uses `-ibtcompatbeta`. That is a compatibility
switch for a different Bluetooth generation; it is not needed on AX211 and is
not in this config.

## Bluetooth idle

The AX211 exposes two USB interfaces, and without an idle policy
`IOUSBHostFamily` keeps the controller in USB power state 2 even when nothing
is connected. Two pieces fix that:

1. **`BTIdle.kext`** (`local.btidle` 0.1.1) waits for the Bluetooth interfaces
   to appear, opens them, and calls `setIdlePolicy(100)` on each interface and
   pipe. It retries every 5 s, because `bluetoothd` owns the interfaces only
   while Bluetooth is on.
2. **`IntelBluetoothFirmware` power-state patch.** The stock 2.5.1 binary
   advertises a capability mask without `kIOPMLowPower`, so the device would
   still refuse the low-power state. `scripts/build_efi.py` rewrites one
   immediate (`2` → `0x10000`) in the copied binary at build time; the base
   payload in `efi/base` is untouched.

Verify with Bluetooth **on**:

```sh
ioreg -r -c BTIdle -d1 -l -w0 | grep -E 'btidle-status|btidle-applied'
sysctl debug.btidle.ms
ioreg -r -c IOUSBHostDevice -l -w0 | grep -A2 '"idProduct" = 51'
```

Expected: `btidle-status = "ms=100 rw=1 if0=100 p81=100 p82=100 if1=0"`,
`btidle-applied = 3`, and the controller's `IOPowerManagement` reports
`"CurrentPowerState"=1` with `CapabilityFlags` containing `65536`
(`kIOPMLowPower`). The `if1=0` is normal: the second interface has no pipes on
this firmware.

When Bluetooth is **off**, `btidle-applied = 0` and the status shows zeros —
the interfaces are closed, so there is nothing to configure. That is not a
failure; it applies by itself when the controller comes up.

To disable at runtime without rebuilding, `sudo sysctl -w debug.btidle.ms=0`
(`0` = off; the value is writable). To remove it permanently, delete the
`BTIdle.kext` entry from `Kernel/Add` and the bundle from `OC/Kexts`, and drop
the `patch_intel_bt_lowpower()` call from `scripts/build_efi.py`. The
controller then returns to power state 2.

Provenance: `BTIdle` is built from
[hackintosh-power-tools](https://github.com/keenerdavid18/hackintosh-power-tools)
`macos/btidle` @ `ddd15e63` (the same kext used by the ThinkPad E16 Gen 3
reference); see [10-provenance.md § 3](10-provenance.md#3-common-kexts-efibaseockexts).

## Troubleshooting

| Symptom | Check |
|---|---|
| No Wi-Fi interface at all | Exactly one Wi-Fi kext enabled? `kmutil showloaded \| grep -i itlwm` |
| `itlwm` loaded but no networks | Is HeliPort running? Does `ifconfig` show an `en` interface? |
| Native menu missing with AirportItlwm | Wrong macOS build; use the Tahoe-matching kext |
| Bluetooth icon greyed out | `kmutil showloaded \| grep -i bluetooth`; check the two NVRAM variables; power-cycle |
| Wi-Fi dies after sleep | Known Intel limitation; reboot is the reliable recovery |

Do not enable `itlwm` and `AirportItlwm` together, and do not add
`IOSkywalkFamily` or `com.apple.iokit.IO80211Family` blockers — those belong to
Broadcom/OCLP setups, not this one.
