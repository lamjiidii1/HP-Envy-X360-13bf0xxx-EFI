#!/usr/bin/env python3
"""Assemble a bootable OpenCore EFI from the pinned payloads in this repo.

The repository never stores the machine's activation identity.  This script
injects it from a private plist at build time, selects one GPU driver variant
and one Wi-Fi stack, then writes a ready-to-copy EFI folder.

Usage:
    ./scripts/build_efi.py                         # wex080-adlp + airportitlwm-tahoe (macOS 26), release
    ./scripts/build_efi.py --gpu hp-adlp-edp --wifi airportitlwm-sequoia  # macOS 15 pairing
    ./scripts/build_efi.py --gpu wex070            # upstream 0.7.0 (experimental)
    ./scripts/build_efi.py --wifi itlwm            # itlwm + HeliPort fallback
    ./scripts/build_efi.py --debug                 # verbose boot
    ./scripts/build_efi.py --out /run/media/.../EFI
    ./scripts/build_efi.py --skip-sequoia-mmio-patch   # boot another macOS build

The `hp-adlp-edp` GPU variant gets a deterministic byte patch for the Sequoia
15.8.2 (24H232) MMIO signature; pass --skip-sequoia-mmio-patch when building
for a different macOS build.  The `wex080-adlp` default resolves MMIO
dynamically and is never patched.  The pinned payloads in efi/variants stay
untouched.
"""

from __future__ import annotations

import argparse
import plistlib
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BASE = REPO / "efi" / "base"
VARIANTS = REPO / "efi" / "variants"
DEFAULT_IDENTITY = REPO / "private" / "identity.plist"

GPU_VARIANTS = {
    "hp-adlp-edp": {
        "path": VARIANTS / "gpu-hp-adlp-edp" / "WhateverXe.kext",
        "args": [
            "-wex-adlp-edp",
            "-wex-reset-restore",
            "-wex-no-multicontext",
            "-wex-scanout-coherent",
            "-wex-pm",
        ],
        "sequoia_mmio_patch": True,
        "description": "WhateverXe 0.6.0 + adlp-edp patch series 54 (Sequoia build, Graphics 0.3.1)",
    },
    "wex080-adlp": {
        "path": VARIANTS / "gpu-wex080-adlp" / "WhateverXe.kext",
        "args": [
            "-wex-adlp-edp",
            "-wex-reset-restore",
            "-wex-no-multicontext",
            "-wex-scanout-coherent",
            "-wex-pm",
            "-wex-mtl-poshfix",
            "-wex-flip-dedupe",
        ],
        "sequoia_mmio_patch": False,
        "description": "WhateverXe 0.8.0 + adlp-edp + mtl-poshfix + flip-dedupe (default, native dynamic MMIO, Graphics 0.4.1)",
    },
    "wex070": {
        "path": VARIANTS / "gpu-wex070" / "WhateverXe.kext",
        "args": [],
        "description": "WhateverXe 0.7.0 upstream (experimental, Graphics 0.4.0)",
    },
}

WIFI_VARIANTS = {
    "airportitlwm-tahoe": {
        "path": VARIANTS / "wifi-airportitlwm-tahoe" / "AirportItlwm.kext",
        "bundle": "AirportItlwm.kext",
        "exec": "Contents/MacOS/AirportItlwm",
        "description": "AirportItlwm 2.4.1 Tahoe build (tahoe-vtd-1, native Wi-Fi menu, default)",
    },
    "airportitlwm-sequoia": {
        "path": VARIANTS / "wifi-airportitlwm" / "AirportItlwm.kext",
        "bundle": "AirportItlwm.kext",
        "exec": "Contents/MacOS/AirportItlwm",
        "description": "AirportItlwm 2.4.0 Sequoia build (sequoia-vtd-1)",
    },
    "itlwm": {
        "path": VARIANTS / "wifi-itlwm" / "itlwm.kext",
        "bundle": "itlwm.kext",
        "exec": "Contents/MacOS/itlwm",
        "description": "itlwm 2.3.0 + HeliPort (OS-independent fallback)",
    },
}

# NOTE: there is no OpenCore 1.0.8 key for SMBIOS type 4 processor speed.
# `PlatformInfo/Generic/ProcessorSpeed` is not in the Generic or SMBIOS
# schema; OpenCore silently ignores it.  The 1.88 GHz shown by macOS is the
# invariant TSC (CPUID leaf 0x15: 38.4 MHz * 98 / 2 = 1881.6 MHz), not the
# core clock, and changing it would break timekeeping.  The real range is
# XCPM 4700..400 MHz; see docs/08-troubleshooting.md.

BASE_ARGS = [
    "-allow3d",
    "-disablegfxfirmware",
    "-igfxdvmt",
    "keepsyms=1",
    "msgbuf=4194304",
    "shda-lang=en",
    "alcid=13",
    "alcverbs=1",
    "-tgldmic",
    "-cirrusreset",
    "-lilubetaall",
    # RestrictEvents: force the Intel brand-string patch and request the
    # cpuname patch.  Keep sbvmm as well: a boot-argument revpatch overrides
    # the NVRAM value, so listing only cpuname would silently drop the VMM
    # spoof that is needed for OTA updates.  The custom name itself lives in
    # NVRAM because boot-args cannot carry spaces reliably.
    "revcpu=1",
    "revpatch=sbvmm,cpuname",
    # NVMeFix only turns on ASPM L1 with this.  The L1.1/L1.2 substates and
    # LTR come from NVME_L1SS_PROPERTIES below: without them IOPCIFamily writes
    # zero to the endpoint's L1PM Sub-states Control 1 register.  A link
    # without L1.2 keeps the CPU package from going below PC3.
    "-nvmefaspm",
]

# NVMe on PciRoot(0x0)/Pci(0x6,0x0)/Pci(0x0,0x0) (SK hynix BC901 here) and its
# root port.  macOS's IOPCIFamily reads both keys from DeviceProperties; the
# values are proven to produce "L1 + all four L1 substates + LTR" in config
# space (0f001260 = enable PCI-PM/ASPM L1.1+L1.2, 03100310 = LTR).  They are
# inert on a port with no L1PM capability.  Source: keenerdavid18's ThinkPad
# E16 Gen 3 config, same IOPCIFamily behavior on 25G241.
NVME_L1SS_PROPERTIES = {
    "PciRoot(0x0)/Pci(0x6,0x0)": {
        "pci-l1ss-enable": bytes.fromhex("0f001260"),
    },
    "PciRoot(0x0)/Pci(0x6,0x0)/Pci(0x0,0x0)": {
        "pci-l1ss-enable": bytes.fromhex("0f001260"),
        "pci-max-latency": bytes.fromhex("03100310"),
    },
}

IDENTITY_FIELDS = (
    "SystemSerialNumber",
    "MLB",
    "SystemUUID",
    "ROM",
    "SystemProductName",
    "ProcessorType",
    "SystemMemoryStatus",
)

# WhateverXe 0.6.0/0.6.1 compares _IOProtectCacheMode+0xCA with this call.
# macOS 15.8.2 (24H232) moved the target by +0x30, which leaves the ninth
# Sequoia guard comparison false and the accelerator stopped.  The value is
# patched into the build output, not into the pinned payload in efi/variants,
# so the repository still hashes the published binary.  See
# scripts/macos/patch-wex-sequoia-mmio.sh and docs/03-graphics.md.
SEQUOIA_MMIO_OLD = bytes.fromhex("e871cb0200")
SEQUOIA_MMIO_NEW = bytes.fromhex("e8a1cb0200")
SEQUOIA_MMIO_MOVL = b"\xc7\x45"


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def _live_sites(data: bytes, pattern: bytes) -> list[int]:
    return [
        i
        for i in range(3, len(data))
        if data[i - 3 : i - 1] == SEQUOIA_MMIO_MOVL and data[i : i + len(pattern)] == pattern
    ]


def patch_sequoia_mmio(binary: Path) -> dict:
    """Rewrite WhateverXe's stale Sequoia MMIO constant in a built kext.

    The live comparison loads a four-byte immediate (``c7 45 <disp> imm32``);
    the fifth byte comes from the adjacent ``c6 45 <disp> 00``.  A second,
    five-byte copy sits in the literal pool.  Replacing the four-byte pattern
    covers both: the pool copy keeps its trailing zero.
    """
    data = binary.read_bytes()
    old_live = SEQUOIA_MMIO_OLD[:4]
    new_live = SEQUOIA_MMIO_NEW[:4]

    old_n = data.count(old_live)
    new_n = data.count(new_live)
    live_old = _live_sites(data, old_live)
    live_new = _live_sites(data, new_live)

    if len(live_new) == 1 and old_n == 0:
        return {"status": "already-patched", "offset": f"0x{live_new[0]:x}"}
    if old_n == 0 and new_n == 0:
        fail(
            f"{binary} has neither the old nor the new Sequoia MMIO constant; "
            "this is not the expected WhateverXe build"
        )
    if old_n and new_n:
        fail(f"{binary} contains both the old and the new Sequoia MMIO constant")
    if len(live_old) != 1:
        fail(f"{binary} has {len(live_old)} live Sequoia MMIO movl sites, expected one")
    if old_n > 2:
        fail(f"{binary} has {old_n} copies of the old Sequoia MMIO constant, expected at most two")

    binary.write_bytes(data.replace(old_live, new_live))
    return {
        "status": "applied",
        "old": SEQUOIA_MMIO_OLD.hex(),
        "new": SEQUOIA_MMIO_NEW.hex(),
        "offset": f"0x{live_old[0]:x}",
    }


# IntelBluetoothFirmware describes its "on" power state with
# inputPowerRequirement = kIOPMPowerOn.  Apple's USB idle-suspend rules
# (IOUSBHostFamily.h, "Idle suspend") say a power child that requires
# kIOPMPowerOn vetoes suspend, so BTIdle cannot park the AX211 and the CPU
# package stays at PC3 while Bluetooth is on.  Change that one field to
# kIOPMLowPower (0x00010000).  IOPMPowerState is twelve uint64 fields; the
# table is two states (version 1, both).  IntelBluetoothFirmware 2.5.1 has
# exactly one match.  The pinned payload stays as published.
BT_LOWPOWER_INPUT_REQUIREMENT = 3 * 8
BT_LOWPOWER_VALUE = 0x00010000


def _bt_state_table(fields: list[int]) -> bytes:
    return b"".join(field.to_bytes(8, "little") for field in fields)


BT_LOWPOWER_OLD = _bt_state_table([1] + [0] * 11) + _bt_state_table([1, 2, 2, 2] + [0] * 8)
BT_LOWPOWER_NEW = _bt_state_table([1] + [0] * 11) + _bt_state_table(
    [1, 2, 2, BT_LOWPOWER_VALUE] + [0] * 8
)


def _find_all(data: bytes, pattern: bytes) -> list[int]:
    sites = []
    start = 0
    while True:
        offset = data.find(pattern, start)
        if offset < 0:
            return sites
        sites.append(offset)
        start = offset + 1


def patch_intel_bt_lowpower(binary: Path) -> dict:
    """Let the Intel Bluetooth power child idle-suspend (one table field)."""
    data = bytearray(binary.read_bytes())
    old_sites = _find_all(data, BT_LOWPOWER_OLD)
    new_sites = _find_all(data, BT_LOWPOWER_NEW)
    field_offset = 96 + BT_LOWPOWER_INPUT_REQUIREMENT

    if len(new_sites) == 1 and not old_sites:
        return {"status": "already-patched", "offset": f"0x{new_sites[0] + field_offset:x}"}
    if not old_sites and not new_sites:
        fail(f"{binary} has no IntelBluetoothFirmware power-state table; not the expected build")
    if old_sites and new_sites:
        fail(f"{binary} has both the old and the new Bluetooth power-state table")
    if len(old_sites) != 1:
        fail(f"{binary} has {len(old_sites)} Bluetooth power-state tables, expected one")

    offset = old_sites[0] + field_offset
    data[offset : offset + 8] = BT_LOWPOWER_VALUE.to_bytes(8, "little")
    binary.write_bytes(bytes(data))
    return {
        "status": "applied",
        "old": "2",
        "new": hex(BT_LOWPOWER_VALUE),
        "offset": f"0x{offset:x}",
    }


def load_identity(path: Path) -> dict:
    if not path.exists():
        print(
            f"warning: {path} not found; building with blank SMBIOS values.\n"
            "         Copy private/identity.example.plist to private/identity.plist\n"
            "         and fill in your own values before booting.",
            file=sys.stderr,
        )
        return {}
    with path.open("rb") as handle:
        identity = plistlib.load(handle)
    missing = [key for key in IDENTITY_FIELDS if key not in identity]
    if missing:
        fail(f"{path} is missing: {', '.join(missing)}")
    return identity


def copy_tree(src: Path, dst: Path) -> None:
    shutil.copytree(src, dst, symlinks=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gpu", choices=sorted(GPU_VARIANTS), default="wex080-adlp")
    parser.add_argument("--wifi", choices=sorted(WIFI_VARIANTS), default="airportitlwm-tahoe")
    parser.add_argument("--identity", type=Path, default=DEFAULT_IDENTITY)
    parser.add_argument("--out", type=Path, default=REPO / "build" / "EFI")
    parser.add_argument("--debug", action="store_true", help="verbose boot and debug logging")
    parser.add_argument("--force", action="store_true", help="replace an existing output folder")
    parser.add_argument(
        "--skip-sequoia-mmio-patch",
        action="store_true",
        help="do not patch WhateverXe's 24H232 Sequoia MMIO constant (for other macOS builds)",
    )
    args = parser.parse_args()

    gpu = GPU_VARIANTS[args.gpu]
    wifi = WIFI_VARIANTS[args.wifi]
    for required in (gpu["path"], wifi["path"]):
        if not required.is_dir():
            fail(f"missing payload: {required}")

    if args.out.exists():
        if not args.force:
            fail(f"{args.out} already exists (use --force to replace it)")
        shutil.rmtree(args.out)

    # 1. Base OpenCore tree (OpenCore 1.0.8, ACPI, drivers, resources).
    copy_tree(BASE, args.out)
    (args.out / "OC" / "config.template.plist").unlink()

    # 2. Selected kext variants.
    copy_tree(gpu["path"], args.out / "OC" / "Kexts" / "WhateverXe.kext")
    copy_tree(wifi["path"], args.out / "OC" / "Kexts" / wifi["bundle"])

    gpu_patches = {}
    if gpu.get("sequoia_mmio_patch") and not args.skip_sequoia_mmio_patch:
        wex_binary = args.out / "OC" / "Kexts" / "WhateverXe.kext" / "Contents" / "MacOS" / "WhateverXe"
        gpu_patches["sequoia_mmio"] = patch_sequoia_mmio(wex_binary)

    bt_binary = (
        args.out
        / "OC"
        / "Kexts"
        / "IntelBluetoothFirmware.kext"
        / "Contents"
        / "MacOS"
        / "IntelBluetoothFirmware"
    )
    kext_patches = {"intel_bt_lowpower": patch_intel_bt_lowpower(bt_binary)}

    # 3. Configuration: identity, boot arguments, Wi-Fi entry, debug mode.
    config_path = args.out / "OC" / "config.plist"
    with (BASE / "OC" / "config.template.plist").open("rb") as handle:
        config = plistlib.load(handle)

    # NVMe L1.1/L1.2 (ASPM) and LTR.  These live in code rather than the
    # template so the hardware path and the reason stay next to the boot arg.
    device_properties = config["DeviceProperties"]["Add"]
    for path, properties in NVME_L1SS_PROPERTIES.items():
        device_properties.setdefault(path, {}).update(properties)

    identity = load_identity(args.identity)
    generic = config["PlatformInfo"]["Generic"]
    for key in IDENTITY_FIELDS:
        if key in identity:
            generic[key] = identity[key]

    # 0x0701 is AppleProcessorTypeCorei7Type1, a dual-core Sandy Bridge era
    # type.  On Sequoia an Alder Lake CPU with this type renders as
    # "Processor Name: Unknown" in System Information, and RestrictEvents has
    # no marketing string to replace.  0x0F01 (Xeon W) is the value both the
    # reference configuration and RestrictEvents document for 8+ cores.
    if generic.get("ProcessorType") == 1793:
        print(
            "warning: ProcessorType 1793 (0x0701, Core i7 Type 1) is not valid\n"
            "         for this Alder Lake CPU and shows 'Processor Name: Unknown'.\n"
            "         Set it to 3841 (0x0F01, Xeon W).",
            file=sys.stderr,
        )

    boot_args = list(BASE_ARGS) + gpu["args"]
    if args.debug:
        boot_args = ["-v", "debug=0x100"] + boot_args
    config["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"] = " ".join(boot_args)

    wifi_entry = next(k for k in config["Kernel"]["Add"] if k["BundlePath"] == "WIFI_BUNDLE.kext")
    wifi_entry["BundlePath"] = wifi["bundle"]
    wifi_entry["ExecutablePath"] = wifi["exec"]
    wifi_entry["Comment"] = f"Wi-Fi: {wifi['description']}"

    if args.debug:
        config["Misc"]["Debug"].update(
            {"AppleDebug": True, "ApplePanic": True, "DisplayLevel": 2147483650, "Target": 67}
        )
        config["Misc"]["Boot"]["Timeout"] = 10

    with config_path.open("wb") as handle:
        plistlib.dump(config, handle, sort_keys=False)

    # 4. Record what was built next to the EFI.
    manifest = {
        "gpu": args.gpu,
        "gpu_description": gpu["description"],
        "gpu_patches": gpu_patches,
        "kext_patches": kext_patches,
        "wifi": args.wifi,
        "wifi_description": wifi["description"],
        "debug": args.debug,
        "boot_args": " ".join(boot_args),
        "nvme_l1ss_paths": sorted(NVME_L1SS_PROPERTIES),
        "identity_injected": bool(identity),
    }
    with (args.out / "BUILD-INFO.plist").open("wb") as handle:
        plistlib.dump(manifest, handle, sort_keys=False)

    print(f"built {args.out}")
    print(f"  GPU     : {args.gpu} - {gpu['description']}")
    if gpu_patches.get("sequoia_mmio"):
        patch = gpu_patches["sequoia_mmio"]
        if patch["status"] == "applied":
            print(f"  GPU fix : Sequoia 24H232 MMIO {patch['old']} -> {patch['new']} at {patch['offset']}")
        else:
            print(f"  GPU fix : Sequoia 24H232 MMIO already patched at {patch['offset']}")
    elif gpu.get("sequoia_mmio_patch"):
        print("  GPU fix : Sequoia MMIO patch SKIPPED (--skip-sequoia-mmio-patch)")
    bt_patch = kext_patches["intel_bt_lowpower"]
    print(
        f"  BT fix  : IntelBluetoothFirmware inputPowerRequirement {bt_patch['status']}"
        + (f" ({bt_patch.get('old', '?')} -> {bt_patch.get('new', '?')} at {bt_patch['offset']})"
           if bt_patch["status"] == "applied" else f" at {bt_patch['offset']}")
    )
    print(f"  Wi-Fi   : {args.wifi} - {wifi['description']}")
    print("  CPU     : 12th Gen Intel Core i7-1250U (XCPM 4700..400 MHz; UI reports TSC 1.88 GHz)")
    print(f"  Debug   : {'yes' if args.debug else 'no'}")
    print(f"  Identity: {'injected' if identity else 'BLANK (do not boot yet)'}")
    if args.wifi == "itlwm":
        print("  Note    : copy HeliPort.app to /Applications on the target macOS install.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
