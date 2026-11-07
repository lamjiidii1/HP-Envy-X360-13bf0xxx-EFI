# 01 — Hardware inventory

Everything here was read from the live machine, not copied from the reference
repositories. Linux exposes the DMI and PCI data without root; the macOS side
comes from the logs in the local `LOGS/` folder (not committed, because they
contain the SMBIOS identity).

## Identity

| Field | Value |
|---|---|
| System vendor | HP |
| Product | HP ENVY x360 2-in-1 Laptop 13-bf0xxx |
| Board | 8A28, version 21.49 |
| BIOS | F.35, 2025-11-17 |
| SKU family | 13-bf0xxx (same platform as the reference 13-bf0059TU) |

The reference repository uses a **13-bf0059TU**. Both machines are the same
board (`8A28`) with the same i7-1250U and the same 2880×1800 OLED, which is why
its EFI is a valid starting point — but BIOS revisions and panel batches can
still change the firmware VBT, and that matters for eDP detection (see
[docs/03-graphics.md](03-graphics.md)).

## CPU

```
Model name:  12th Gen Intel(R) Core(TM) i7-1250U
CPU(s):      12
Cores:       10 (2 P-cores + 8 E-cores)
Threads:     2 per P-core, 1 per E-core
```

macOS sees 12 logical CPUs. `SSDT-PLUG-ALT-12.aml` declares that topology for
XCPM and `CpuTopologyRebuild.kext` rebuilds the cache hierarchy so the P-cores
are not treated as E-cores.

## Graphics

```
00:02.0 VGA compatible controller [0300]:
  Intel Corporation Alder Lake-UP4 GT2 [Iris Xe Graphics] [8086:46aa] (rev 0c)
```

- Device ID `0x46AA`, revision `0x0C`.
- Subsystem `103c:8a28` (HP board).
- The same device is supported by WhateverXe's Alder Lake-P/U path.
- The panel is a 2880×1800 OLED driven over eDP; the previous EFI reports it as
  `Display 2880 x 1800`, and the working reference describes it as a Samsung
  SDC 4166 eDP 1.4 panel with AUX brightness.

## Memory and storage

```
Mem:   15 GiB usable (16 GB LPDDR5, soldered)
nvme0n1  SK hynix BC901 HFS512GEJ9X108N  476.9G
```

The SMBIOS reports `SystemMemoryStatus = Soldered`, which is why the config
keeps that value instead of `Auto`.

## Networking and Bluetooth

```
00:14.3 Network controller [0280]:
  Intel Corporation Alder Lake-P PCH CNVi WiFi [8086:51f0] (rev 01)
```

AX211 CNVi. Bluetooth is the same module over USB. Two Wi-Fi stacks are
provided because both are known to work on this generation; see
[docs/04-wifi-bluetooth.md](04-wifi-bluetooth.md).

## Audio

```
00:1f.3 Multimedia audio controller [0401]:
  Intel Corporation Alder Lake Smart Sound Technology Audio Controller [8086:51cc] (rev 01)
```

- Codec: Realtek ALC245.
- Speaker amplifiers: Cirrus Logic CS35L41 (no macOS driver — speakers stay
  silent; the headphone jack and USB-C output work, and the internal microphone
  is untested).
- The config uses AppleALC layout 11 (`alcid=11`) plus `SimpleHDA.kext`.
- AppleALC is locally patched to remove layout 11's DSP chain, which panics in
  `coreaudiod` on this machine. See [docs/05-audio.md](05-audio.md).

## Other devices

| Device | ID | State |
|---|---|---|
| Card reader | Realtek RTS5288 `10ec:5228` | no macOS driver; not tested physically |
| Camera | Intel Alder Lake IPU6 `8086:465d` (MIPI, not USB) | no macOS driver; not attempted |
| Touchscreen | I2C HID | physically broken glass on this unit; does not work in Windows either |
| Touchpad | I2C HID | **works**: precision trackpad with gestures via `VoodooI2C` + `VoodooI2CHID` |

## How this inventory was collected

```sh
for f in sys_vendor product_name product_version board_name board_version bios_version bios_date; do
  printf '%s: %s\n' "$f" "$(cat /sys/class/dmi/id/$f)"
done
lscpu
lspci -nn | grep -Ei 'vga|audio|network|card'
lsblk -dno NAME,MODEL,SIZE
```

On macOS the same data comes from `system_profiler SPHardwareDataType
SPDisplaysDataType`, `ioreg -l`, and `kmutil showloaded`.
