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

For the other variants:

```sh
./scripts/build_efi.py --gpu wex080-adlp --out build/EFI-wex080-adlp --force  # 0.8.0 native dynamic MMIO
./scripts/build_efi.py --gpu wex070 --out build/EFI-wex070 --force          # upstream 0.7.0 control
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

## 4. Boot the new EFI, then check the matching graphics package

Order matters: **boot the target macOS with the WEX 0.6.0 EFI first, then make
sure Graphics 0.3.1 is installed.** The EFI provides the WEX binary; the package
provides Compat 0.6.0 and the patched Apple kexts. The default `make build`
already carries the 24H232 Sequoia MMIO constant, so a fresh `build/EFI` needs
no manual byte patch. A stick copied from an older build does; see step 4.

1. Copy `build/EFI` to the ESP/USB and boot macOS from it (§3 and §5).
   Confirm the injected driver:
   ```sh
   kmutil showloaded | grep -i whateverxe    # expect 0.6.0
   kmutil showloaded | grep -i tglcompat     # expect 0.6.0
   ```
2. If `AppleIntelTGLCompat` is not **0.6.0**, install **WhateverXe Graphics
   0.3.1** (the package matching the `adlp-edp` fork). Do **not** install
   0.3.2 or 0.4.0: 0.3.2 ships Compat 0.6.1 and 0.4.0 ships Compat 0.7.0, and
   the kext/package versions must match exactly.

```sh
shasum -a 256 WhateverXe-Graphics-0.3.1.pkg
sudo installer -pkg WhateverXe-Graphics-0.3.1.pkg -target /
```

3. The package rebuilds the Auxiliary Kernel Collection. **Restart** after it
   succeeds.
4. On the next boot, check the Sequoia MMIO verdict and acceleration (§5).
   A fresh default build is already patched. If you copied a stick made before
   2026-11-03 (or the guard says `00`), repair it in place:
   ```sh
   sudo scripts/macos/patch-wex-sequoia-mmio.sh \
     --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext --dry-run
   sudo scripts/macos/patch-wex-sequoia-mmio.sh \
     --kext /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext
   ```

Do not install Graphics 0.3.2/0.4.0 with this EFI, and do not boot the
`wex070` variant expecting a picture. The supported pair on this machine is
WhateverXe 0.6.0 (`adlp-edp`) + Graphics 0.3.1.

### Testing upstream 0.7.0 (optional control)

1. Copy `EFI-wex070` to the ESP and boot it.
2. Install `WhateverXe-Graphics-0.4.0.pkg` (on the support stick) and restart.
3. Expect the internal panel to stay dark: upstream discards this VBT. The
   useful output is IORegistry evidence, not a working display.
4. To revert, restore the default EFI and reinstall Graphics 0.3.1.

## 5. First boot

1. Select the OpenCore entry, then the macOS volume.
2. If the picker is OpenCanopy (`PickerMode External`), the macOS entry may be
   under the auxiliary/spacebar view depending on `HideAuxiliary`.
3. Check the result:
   ```sh
   system_profiler SPDisplaysDataType
   ioreg -l | grep -o '"TGLSequoiaMMIOGuard" = <[^>]*>'
   ioreg -rc AppleIntelFramebuffer | head
   ioreg -rc IntelAccelerator | head
   ```
   On Sequoia, entry 19 of `TGLSequoiaMMIOGuard` must be `01` before expecting
   Metal; `TGLMMIOStrongUCRouted` is the Tahoe-era property name and may be
   absent. The default build patches the ninth comparison for 24H232; see
   [docs/03-graphics.md](03-graphics.md#the-24h232-mmio-signature).
4. If ControlCenter crash-loops or Safari video freezes **after** Metal is
   reported, install the archive workaround from
   [docs/08-troubleshooting.md](08-troubleshooting.md#metal-apps-crash-or-safari-video-freezes-24h232).
5. If the screen is black but the machine is alive, boot the `--debug` build
   with `-v` and capture the last screen; see
   [docs/08-troubleshooting.md](08-troubleshooting.md).

## 6. Switching Wi-Fi stack

The default build uses AirportItlwm 2.4.0 (Sequoia). If it does not attach on
15.8.2, build the `itlwm` fallback and copy only the OC folder:

```sh
./scripts/build_efi.py --wifi itlwm --out build/EFI-itlwm --force
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
2. Reinstall WhateverXe Graphics 0.3.1. If you cannot boot macOS, the package
   can be reinstalled from Recovery with `installer -pkg … -target /Volumes/…`.
   (The default EFI is rebuilt from the published payload, so there is no
   patched kext to restore; `patch-wex-sequoia-mmio.sh --restore` only undoes a
   repair made with that script.)
3. The old EFI in `mine/EFI` is the exact previous state; it is not in Git.

## 9. Notes for a clean reinstall

- The SMBIOS identity in `private/identity.plist` is the machine's **current,
  activated** identity. Reuse it; do not generate a new serial or iCloud/
  iMessage will require re-authentication.
- A clean install needs only the EFI and a macOS installer; the Graphics
  package is installed after first boot.
- The USB installer must include `HfsPlus.efi` (or `OpenHfsPlus.efi`) to see
  the installer volume; this EFI uses `HfsPlus.efi`.
