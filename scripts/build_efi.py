#!/usr/bin/env python3
"""Assemble a bootable OpenCore EFI from the pinned payloads in this repo.

The repository never stores the machine's activation identity.  This script
injects it from a private plist at build time, selects one GPU driver variant
and one Wi-Fi stack, then writes a ready-to-copy EFI folder.

Usage:
    ./scripts/build_efi.py                         # hp-adlp-edp + airportitlwm, release
    ./scripts/build_efi.py --gpu wex061            # upstream 0.6.1 (does not parse this VBT)
    ./scripts/build_efi.py --wifi itlwm            # itlwm + HeliPort fallback
    ./scripts/build_efi.py --debug                 # verbose boot
    ./scripts/build_efi.py --out /run/media/.../EFI
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
        "args": ["-wex-adlp-edp", "-wex-reset-restore", "-wex-no-multicontext"],
        "description": "WhateverXe 0.6.0 + retropineaple adlp-edp patches (default)",
    },
    "wex061": {
        "path": VARIANTS / "gpu-wex061" / "WhateverXe.kext",
        "args": [],
        "description": "WhateverXe 0.6.1 upstream (rejects this unit's VBT: duplicate DDI)",
    },
}

WIFI_VARIANTS = {
    "itlwm": {
        "path": VARIANTS / "wifi-itlwm" / "itlwm.kext",
        "bundle": "itlwm.kext",
        "exec": "Contents/MacOS/itlwm",
        "description": "itlwm 2.3.0 + HeliPort (fallback)",
    },
    "airportitlwm": {
        "path": VARIANTS / "wifi-airportitlwm" / "AirportItlwm.kext",
        "bundle": "AirportItlwm.kext",
        "exec": "Contents/MacOS/AirportItlwm",
        "description": "AirportItlwm 2.4.1 (native Wi-Fi menu, default)",
    },
}

BASE_ARGS = [
    "-allow3d",
    "-disablegfxfirmware",
    "-igfxdvmt",
    "keepsyms=1",
    "msgbuf=4194304",
    "shda-lang=en",
    "alcid=11",
]

IDENTITY_FIELDS = (
    "SystemSerialNumber",
    "MLB",
    "SystemUUID",
    "ROM",
    "SystemProductName",
    "ProcessorType",
    "SystemMemoryStatus",
)


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


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
    parser.add_argument("--gpu", choices=sorted(GPU_VARIANTS), default="hp-adlp-edp")
    parser.add_argument("--wifi", choices=sorted(WIFI_VARIANTS), default="airportitlwm")
    parser.add_argument("--identity", type=Path, default=DEFAULT_IDENTITY)
    parser.add_argument("--out", type=Path, default=REPO / "build" / "EFI")
    parser.add_argument("--debug", action="store_true", help="verbose boot and debug logging")
    parser.add_argument("--force", action="store_true", help="replace an existing output folder")
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

    # 3. Configuration: identity, boot arguments, Wi-Fi entry, debug mode.
    config_path = args.out / "OC" / "config.plist"
    with (BASE / "OC" / "config.template.plist").open("rb") as handle:
        config = plistlib.load(handle)

    identity = load_identity(args.identity)
    generic = config["PlatformInfo"]["Generic"]
    for key in IDENTITY_FIELDS:
        if key in identity:
            generic[key] = identity[key]

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
        "wifi": args.wifi,
        "wifi_description": wifi["description"],
        "debug": args.debug,
        "boot_args": " ".join(boot_args),
        "identity_injected": bool(identity),
    }
    with (args.out / "BUILD-INFO.plist").open("wb") as handle:
        plistlib.dump(manifest, handle, sort_keys=False)

    print(f"built {args.out}")
    print(f"  GPU     : {args.gpu} - {gpu['description']}")
    print(f"  Wi-Fi   : {args.wifi} - {wifi['description']}")
    print(f"  Debug   : {'yes' if args.debug else 'no'}")
    print(f"  Identity: {'injected' if identity else 'BLANK (do not boot yet)'}")
    if args.wifi == "itlwm":
        print("  Note    : copy HeliPort.app to /Applications on the target macOS install.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
