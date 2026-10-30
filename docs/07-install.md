# 07 — Install, upgrade, rollback

## 0. Before touching anything

1. Keep the current EFI. It is the only known state that boots this machine.
   ```sh
   cp -a /path/to/ESP/EFI /path/to/backup/EFI-$(date +%F)
   ```
2. Keep a bootable USB with the same EFI. If the new EFI fails, the firmware
   may still prefer the internal disk; the USB is the escape hatch.
3. Have the macOS install's recovery or another Mac available for
   `kmutil`/`csrutil` work if the system does not reach the desktop.

## 1. BIOS settings

| Setting | Value |
|---|---|
| Secure Boot | Disabled |
| Fast Boot | Disabled |
| VT-d | can stay enabled (no `DisableIoMapper` needed with this config) |
| DVMT Pre-Allocated | leave at the HP default (60 MB); `-igfxdvmt` + `framebuffer-stolenmem` compensate |
| Intel PTT / TPM | Disabled if the boot hangs |
| SATA / storage mode | AHCI/NVMe (no RAID) |

The BIOS on this unit is F.35 (2025-11-17). Record the version before and after
any BIOS update: VBT changes can break eDP detection (see
[docs/03-graphics.md](03-graphics.md)).

## 2. Build the EFI

On Linux or macOS, in the repository:

```sh
cp private/identity.example.plist private/identity.plist
$EDITOR private/identity.plist        # serial, MLB, UUID, ROM
make build
make verify
```

`make build` writes `build/EFI` and refuses to continue if a payload is missing
or the SMBIOS is blank.

For the fallback or debug variants:

```sh
./scripts/build_efi.py --gpu hp-adlp-edp --out build/EFI-hp --force
./scripts/build_efi.py --debug --out build/EFI-debug --force
```

## 3. Copy to the ESP

### From Linux

```sh
lsblk -f                                  # find the EFI System Partition (vfat, ~200-500 MB)
sudo mkdir -p /mnt/esp
sudo mount /dev/nvme0n1p1 /mnt/esp        # adjust the partition
sudo cp -a /mnt/esp/EFI /mnt/esp/EFI.backup-$(date +%F)
sudo rm -rf /mnt/esp/EFI
sudo cp -a build/EFI /mnt/esp/EFI
sync
sudo umount /mnt/esp
```

### From macOS

```sh
diskutil list
sudo diskutil mount disk0s1
sudo cp -a /Volumes/EFI/EFI /Volumes/EFI/EFI.backup-$(date +%F)
sudo rm -rf /Volumes/EFI/EFI
sudo cp -a build/EFI /Volumes/EFI/EFI
diskutil unmount /Volumes/EFI
```

Keep the folder structure exactly `EFI/BOOT/BOOTx64.efi` and
`EFI/OC/OpenCore.efi`.

## 4. Install the matching graphics package (macOS side)

The EFI only contains `WhateverXe.kext`. The patched Apple drivers and
`AppleIntelTGLCompat` are installed **inside macOS**:

| EFI variant | Required package |
|---|---|
| `wex061` (default) | `WhateverXe-Graphics-0.3.2.pkg` |
| `hp-adlp-edp` | `WhateverXe-Graphics-0.3.1.pkg` (or 0.3.2 if it still loads; see below) |

Download from the
[WhateverXe Graphics releases](https://github.com/b00t0x/WhateverXe-Graphics/releases)
and verify:

```sh
shasum -a 256 WhateverXe-Graphics-0.3.2.pkg
# 7ac6c7149248c483efbd93555294d587a93d81392421f3af8a4f5b1b5fcc0101
sudo installer -pkg WhateverXe-Graphics-0.3.2.pkg -target /
```

The package rebuilds the Auxiliary Kernel Collection. Reboot afterwards.

**Order matters when upgrading from the old install:** install the new
Graphics package first (so Compat 0.6.1 is in place), then boot the new EFI
with WhateverXe 0.6.1. Booting 0.6.1 against Compat 0.6.0 is a version
mismatch; booting 0.6.0 against Compat 0.6.1 may be tolerated but is not the
supported pair.

## 5. First boot

1. Select the OpenCore entry, then the macOS volume.
2. If the picker is OpenCanopy (`PickerMode External`), the macOS entry may be
   under the auxiliary/spacebar view depending on `HideAuxiliary`.
3. Check the result:
   ```sh
   system_profiler SPDisplaysDataType
   ioreg -rc AppleIntelFramebuffer | head
   ioreg -rc IntelAccelerator | head
   ```
4. If the screen is black but the machine is alive, boot the `--debug` build
   with `-v` and capture the last screen; see
   [docs/08-troubleshooting.md](08-troubleshooting.md).

## 6. Switching Wi-Fi stack

Build with the other variant and copy only the OC folder:

```sh
./scripts/build_efi.py --wifi airportitlwm --out build/EFI-airport --force
```

The build script copies exactly one Wi-Fi kext and points the single config
entry at it. Keep HeliPort installed even when using AirportItlwm, so you can
switch back without network access problems.

## 7. Resetting NVRAM

`ResetNvramEntry.efi` is enabled. Use it from the OpenCore picker after
changing SMBIOS or boot arguments. After a reset, re-check:

```sh
nvram boot-args
nvram csr-active-config
```

`csr-active-config = 03080000` is required by the graphics stack and is written
by the config on every boot, so a reset is safe.

## 8. Rollback

1. Boot the backup EFI from the USB stick (or restore `EFI.backup-*` from
   Linux/macOS).
2. Reinstall WhateverXe Graphics 0.3.1 if you had upgraded to 0.3.2. If you
   cannot boot macOS, the package can be reinstalled from Recovery with
   `installer -pkg … -target /Volumes/…`.
3. The old EFI in `mine/EFI` is the exact previous state; it is not in Git.

## 9. Notes for a clean reinstall

- The SMBIOS identity in `private/identity.plist` is the machine's **current,
  activated** identity. Reuse it; do not generate a new serial or iCloud/
  iMessage will require re-authentication.
- A clean install needs only the EFI and a macOS installer; the Graphics
  package is installed after first boot.
- The USB installer must include `HfsPlus.efi` (or `OpenHfsPlus.efi`) to see
  the installer volume; this EFI uses `HfsPlus.efi`.
