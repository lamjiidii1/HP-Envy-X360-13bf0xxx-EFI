# Config diff

This document records the recursive comparison that was used to answer one
question: **was the old EFI's configuration the reason the iGPU did not
accelerate?** The short answer is no. The graphics-relevant configuration is
the same as the known-working same-model reference; the differences are
hygiene, provenance and unrelated subsystems.

The comparison is reproducible with a type-aware plist walk (Python
`plistlib`), not by reading the files by eye.

## 1. Method

```python
import plistlib

def walk(a, b, path="", out=None):
    if out is None:
        out = []
    if type(a) is not type(b):
        out.append((path, f"type {type(a).__name__}", f"type {type(b).__name__}"))
        return out
    if isinstance(a, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a:
                out.append((path + "/" + key, "<absent>", b[key]))
            elif key not in b:
                out.append((path + "/" + key, a[key], "<absent>"))
            else:
                walk(a[key], b[key], path + "/" + key, out)
    elif isinstance(a, list):
        if len(a) != len(b):
            out.append((path, f"len {len(a)}", f"len {len(b)}"))
        for index, (x, y) in enumerate(zip(a, b)):
            walk(x, y, f"{path}[{index}]", out)
    elif a != b:
        out.append((path, a, b))
    return out

old = plistlib.load(open("mine/EFI/OC/config.plist", "rb"))
ref = plistlib.load(open("/path/to/whateverxe-hp-envy-x360/EFI/OC/config.plist", "rb"))
new = plistlib.load(open("efi/base/OC/config.template.plist", "rb"))
```

Files compared:

| Label | File | Contains identity? |
|---|---|---|
| **old** | `mine/EFI/OC/config.plist` | yes (local evidence) |
| **ref** | same-model reference `EFI/OC/config.plist` | no (published blank) |
| **new** | `efi/base/OC/config.template.plist` | no (injected at build time) |

The walker reports **158** raw node differences between old and ref and
**156** between old and new. Most are not semantic: inserting two ACPI tables
shifts every later ACPI index, and reordering the kext list shifts every later
kext index. The tables below group the differences by meaning.

## 2. Old vs same-model reference (the important comparison)

### 2.1 Identical (graphics-relevant)

| Section | Result |
|---|---|
| iGPU `DeviceProperties` (`PciRoot(0x0)/Pci(0x2,0x0)`) | identical except old has one extra `rps-control = 01000000` |
| Boot arguments | identical except old has one extra `-vi2c-force-polling` |
| `Kernel/Quirks` | identical |
| `Booter/Quirks` | identical |
| `Booter/MmioWhitelist` | identical (5 entries) |
| `ACPI/Delete` | both empty |
| `ACPI/Patch[0..2]` | identical (GPI0, PNLF, `_OSI`) |
| `csr-active-config` | both `03080000` |
| `SecureBootModel` | both `Disabled` |
| SMBIOS model | both `MacBookPro16,2` |
| `WhateverXe.kext` binary | byte-identical (0.6.0 + `adlp-edp`) |

This is the core finding: no graphics property, quirk or argument differs in a
way that could turn the accelerator on. The old EFI's failure cannot be
explained by its config.

### 2.2 Different — ACPI

| Key | Old | Reference | Meaning |
|---|---|---|---|
| `ACPI/Add` length | 10 | 12 | Missing `SSDT-USB-Reset.aml` and `SSDT-USBW.aml` |
| `ACPI/Add` order | ALS0, EC, GPI0, MCHC, PLUG, PNLF, RTCAWAC, SBUS, USBX, XOSI | ALS0, SBUS, EC, GPI0, MCHC, PLUG, PNLF, RTCAWAC, USB-Reset, USBX, XOSI, USBW | Order only; new follows the reference |
| `ACPI/Patch[3]/TableSignature` | empty (all tables) | `DSDT` | Tightened |
| `ACPI/Patch[3]/Count` | 0 (all occurrences) | 2 | Tightened |
| `ACPI/Patch[3]/Comment` | "Brightness keys…" | "…(BrightnessKeys panel)" | Cosmetic |

The brightness patch `GFX0.DD1F` → `DD02` is correct in both. The old version
applied it to every table and every occurrence; the reference scopes it to the
DSDT, where the notify actually lives.

### 2.3 Different — DeviceProperties

| Key | Old | Reference | Meaning |
|---|---|---|---|
| `PciRoot(0x0)/Pci(0x1f,0x3)` vs `Pci(0x1F,0x3)` | lowercase `f` | uppercase `F` | Same PCI path; string spelling only |
| `PciRoot(0x0)/Pci(0x2,0x0)/rps-control` | `01000000` | absent | Old-only extra property; not in the working reference |

The rest of the iGPU block is byte-identical: `AAPL,backlight-control`,
`AAPL,slot-name`, `built-in`, `framebuffer-patch-enable`,
`framebuffer-stolenmem = 0000c003`, `hda-gfx`, `model`.

### 2.4 Different — kexts

| Key | Old | Reference | Meaning |
|---|---|---|---|
| `Kernel/Add` order | Lilu, VirtualSMC, AMFIPass, WhateverXe, SMC… | Lilu, AMFIPass, WhateverXe, BT, audio, input… | Reference loads AMFIPass/WhateverXe immediately after Lilu |
| `Arch` | `x86_64` on several entries | `Any` | Cosmetic on this platform |
| Wi-Fi entry | `itlwm.kext` | `AirportItlwm.kext` | Different stack; both work on this generation |
| `BlueToolFixup` `MinKernel` | empty | `21.0.0` | Reference gates it to Monterey+ |
| `SimpleHDA` `MinKernel`/`MaxKernel` | `25.0.0` / `25.99.99` | absent | Old already had the Tahoe gate; reference has no SimpleHDA entry in this position |
| `Kernel/Patch` | 13 disabled entries | 0 | Sample leftovers (AppleRTC, ACPI logging, BCM5701, e1000, Bluetooth kill, serial panic, SurPlus, QEMU) |

The old `WhateverGreen.kext` entry is disabled in both; it is a trap, not an
active driver. The new repository removes the folder entirely.

### 2.5 Different — boot arguments

```
old: -allow3d -disablegfxfirmware -igfxdvmt -wex-adlp-edp -wex-reset-restore \
     -wex-no-multicontext keepsyms=1 msgbuf=4194304 shda-lang=en alcid=11 \
     -vi2c-force-polling

ref: -allow3d -disablegfxfirmware -igfxdvmt -wex-adlp-edp keepsyms=1 \
     msgbuf=4194304 shda-lang=en alcid=11 -wex-reset-restore -wex-no-multicontext
```

Same arguments, different order, plus `-vi2c-force-polling` in the old one.
Order does not matter to Lilu. `-vi2c-force-polling` only affects VoodooI2C,
and the touchpad is dead in hardware on this unit.

### 2.6 Different — boot picker and debug

| Key | Old | Reference | Meaning |
|---|---|---|---|
| `Misc/Boot/PickerMode` | `Builtin` | `External` | Reference uses OpenCanopy |
| `Misc/Boot/PickerAttributes` | 17 | 128 | OpenCanopy attributes |
| `UEFI/Output/Resolution` | `""` | `Max` | Native panel resolution |
| `UEFI/Output/UIScale` | 0 | 2 | Readability on 2880×1800 |
| `Misc/Debug/AppleDebug` | true | false | Old booted with Apple debug logging |
| `Misc/Debug/ApplePanic` | true | false | Same |
| `Misc/Debug/Target` | 67 | 3 | Old wrote a file log every boot |
| `Misc/Debug/DisplayLevel` | 2147483650 | 2147483714 | Different debug mask |
| `Misc/Entries` | 1 | 0 | Old had a sample custom entry |
| `Misc/Tools` | 1 | 0 | Old had a sample tool entry |
| `Misc/Security/DmgLoading` | `Any` | `Signed` | Reference is stricter |

The debug settings explain why the old install produced useful logs; they are
not performance settings. The new build keeps release logging quiet and moves
this to `--debug`.

### 2.7 Different — UEFI drivers and quirks

| Key | Old | Reference | Meaning |
|---|---|---|---|
| `UEFI/Drivers` | 3 (`OpenRuntime`, `OpenHfsPlus`, `ResetNvramEntry`) | 6 (`HfsPlus`, `OpenRuntime`, `ResetNvramEntry`, `OpenCanopy`, `ext4_x64`, `OpenLinuxBoot`) | Reference adds OpenCanopy and Linux boot support |
| `UEFI/Quirks/EnableVectorAcceleration` | true | false | Old-only |
| `UEFI/Quirks/UnblockFsConnect` | true | false | Old-only |
| `UEFI/APFS/MinDate` | 0 | -1 | Reference accepts all APFS versions |
| `UEFI/APFS/MinVersion` | 0 | -1 | Same |
| `UEFI/ReservedMemory` | 2 entries, disabled | 0 | HD3000 errata + T490 hibernation leftovers |
| `UEFI/Audio/AudioDevice` | `Pci(0x1b,0x0)` | `Pci(0x1f,0x3)` | Old pointed audio at the wrong PCI function |

The `AudioDevice` difference is a real bug in the old config, but it only
affects the OpenCore boot chime path, not macOS audio; macOS audio comes from
`DeviceProperties` and AppleALC.

### 2.8 Different — NVRAM

| Key | Old | Reference | Meaning |
|---|---|---|---|
| `ForceDisplayRotationInEFI` | absent | `0` | Reference always writes it |
| `SystemAudioVolume` | absent | `F` | Boot volume level |
| `prev-lang:kbd` | string | data (`en-US:0`) | Type differs; both work |
| `NVRAM/Delete` order | revcpu, revcpuname, revpatch, rtc-blacklist | rtc-blacklist, revcpu, revcpuname, revpatch | Order only |
| `NVRAM/Delete` 7C43… list | 4 entries | 5 (adds `ForceDisplayRotationInEFI`) | Consequence of the Add above |

### 2.9 Different — PlatformInfo

| Key | Old | Reference | Meaning |
|---|---|---|---|
| `MLB`, `ROM`, `SystemSerialNumber`, `SystemUUID` | real values | blank (published) | The reference cannot be booted as-is |
| `ProcessorType` | 1793 | 3841 | Old reports the CPU name it already uses |
| `SystemMemoryStatus` | `Soldered` | `Auto` | This machine is soldered |
| `AdviseFeatures` | true | false | Old-only |

The identity values are the reason the old config is gitignored and the reason
this repository injects them at build time.

## 3. Old vs the new template (intentional changes)

The new template is not a copy of the reference either. It starts from the
OpenCore 1.0.8 schema and keeps only what is justified.

| Change | Old | New | Reason |
|---|---|---|---|
| ACPI set | 10 tables | 12 (adds USB-Reset, USBW) | Reference-proven; USB behaviour after wake |
| ACPI brightness patch | all tables, all occurrences | DSDT, count 2 | Scope matches where the notify is |
| `Kernel/Patch` | 13 disabled samples | none | Dead weight and a future foot-gun |
| `UEFI/ReservedMemory` | 2 disabled samples | none | Same |
| `Misc/Entries` / `Misc/Tools` | 1 each | none | OpenCore sample leftovers |
| `WhateverGreen.kext` | present, disabled | removed | Must never be enabled next to WhateverXe |
| `rps-control` | present | removed | Not in the working reference; can alter RPS |
| `-vi2c-force-polling` | present | removed | Touchpad dead in hardware; not in reference |
| Kext order | VirtualSMC before AMFIPass/WEX | Lilu → AMFIPass → WhateverXe → … | Reference order; Lilu plugins load after Lilu |
| `Arch` | `x86_64` | `Any` | No reason to restrict |
| Wi-Fi | `itlwm` hard-coded | build-time choice, default AirportItlwm | Native UI by default; both stacks pinned; never both |
| GPU driver | 0.6.0 + adlp-edp | 0.6.1 default; 0.6.0 variant | 0.6.1 has generic ADL-P/U eDP support |
| Boot args | hard-coded | template placeholder + variant args | Prevents 0.6.1 build carrying 0.6.0 flags |
| `Misc/Boot` | Builtin, UIScale 0 | OpenCanopy, Max, UIScale 2 | Reference-proven on this panel |
| `Misc/Debug` | debug on every boot | release quiet; `--debug` sets 67 | Logs only when investigating |
| `Misc/Security/DmgLoading` | `Any` | `Signed` | Stricter, matches reference |
| `UEFI/Drivers` | OpenHfsPlus, no OpenCanopy | HfsPlus + OpenCanopy + ext4 + OpenLinuxBoot | Feature parity with reference |
| `UEFI/Quirks` | two extras enabled | reference values | No evidence they help; fewer variables |
| `UEFI/APFS` | `MinDate`/`MinVersion` 0 | -1 | Accept all APFS versions, as reference |
| `UEFI/Audio/AudioDevice` | `Pci(0x1b,0x0)` | `Pci(0x1f,0x3)` | Correct HDA function |
| `NVRAM` | 4 deletes | 5 deletes + rotation/volume | Matches reference |
| SMBIOS | real values in file | injected from `private/identity.plist` | Keep activation identity out of Git |

The full old-vs-new node list is what the walker in §1 prints; this table is
the semantic summary. Every row is also a commit in the Git history.

## 4. What the diff rules out

- **A wrong iGPU property.** The only difference is `rps-control`.
- **A wrong stolen-memory/DVMT setting.** `framebuffer-stolenmem` and
  `-igfxdvmt` are identical.
- **A wrong SMBIOS for graphics.** Both use `MacBookPro16,2`.
- **A missing kext or wrong load order for WhateverXe.** The kext binary and
  its dependencies are the same; the order change is hygiene.
- **A missing boot argument.** All graphics arguments are present in both.

It does **not** rule out:

- the driver binary (0.6.0 `adlp-edp` vs 0.6.1),
- the macOS build (26.7.1 vs 26.7.2),
- the firmware/VBT (BIOS revision, panel batch),
- the installed Graphics package / Compat ABI.

Those are exactly the variables the new repository keeps separate: two GPU
variants, a debug build, and a pinned Graphics package. See
[../docs/03-graphics.md](../docs/03-graphics.md) and
[log-analysis.md](log-analysis.md).

## 5. Reproducing

```sh
# old vs reference
python3 - <<'PY'
# paste the walk() function from §1
old = plistlib.load(open("mine/EFI/OC/config.plist", "rb"))
ref = plistlib.load(open("/path/to/reference/EFI/OC/config.plist", "rb"))
for row in walk(old, ref):
    print(*row, sep=" | ")
PY
```

The reference clone used here was
`retropineaple/whateverxe-hp-envy-x360` at `9809987`. The old config is local
only (`mine/`), because it contains the identity.
