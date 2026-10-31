# 04 — Wi-Fi and Bluetooth

## Hardware

Intel AX211 CNVi (`8086:51F0`), Wi-Fi 6E + Bluetooth 5.3 on the same module.
macOS has no native driver. Both Wi-Fi stacks below are known to work on this
generation; they are mutually exclusive and selected at build time.

## Variant A — `AirportItlwm` (default, native)

- Kext: `AirportItlwm.kext` 2.4.1 (downstream Tahoe/VTD build; see
  [10-provenance.md](10-provenance.md))
- Mechanism: implements Apple's `AirPort` interface, so the native Wi-Fi menu
  and System Settings pane work.
- Needs AppleVTD: VT-d enabled in firmware and `DisableIoMapper=false`. Both
  are already true in this config.

Why it is the default:

- It gives the native macOS Wi-Fi UI, which is what you asked for.
- The exact-model reference EFI ships the identical binary (same SHA-256) and
  boots it on Tahoe 26.7.1.

Caveats:

- It is tied to the macOS networking stack, so a point update can require a new
  build. 2.4.1 is not an official OpenIntelWireless release; it is a Tahoe/VTD
  build and is not yet validated on 26.7.2.
- If no interface appears, switch to `itlwm` instead of debugging two variables
  at once.

Build:

```sh
./scripts/build_efi.py --wifi airportitlwm   # default
```

## Variant B — `itlwm` + HeliPort (fallback)

- Kext: `itlwm.kext` 2.3.0
- App: [HeliPort](https://github.com/OpenIntelWireless/HeliPort) (already
  installed on this machine)
- Mechanism: `itlwm` is an Ethernet-style driver. macOS sees a wired
  interface; HeliPort is the user-space UI that scans and joins networks.

Why it is the fallback:

- It is independent of the macOS build, so a point update (26.7.1 → 26.7.2)
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

Only one of the two kext folders is copied into the EFI, and the config has a
single Wi-Fi entry. Do not merge the two variants by hand: two drivers
claiming the same PCI device is a reliable way to lose Wi-Fi entirely.

## Bluetooth

Always enabled, independent of the Wi-Fi choice:

| Kext | Version | Role |
|---|---|---|
| `IntelBluetoothFirmware.kext` | 2.5.1 | Uploads firmware to the Intel controller |
| `IntelBTPatcher.kext` | 2.5.1 | Fixes HCI behaviour on newer Intel chips |
| `BlueToolFixup.kext` | 2.7.3 | Fixes `bluetoothd` on macOS 12+ |

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
