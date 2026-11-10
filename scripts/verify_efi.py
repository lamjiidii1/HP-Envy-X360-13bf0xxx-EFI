#!/usr/bin/env python3
"""Check a built EFI folder for the mistakes that actually stop this laptop.

This is not a replacement for OpenCore's ocvalidate (which needs macOS), but
it catches the failure modes that matter here: missing ACPI/kext payloads,
Lilu not first, graphics drivers loaded twice, legacy kexts left enabled and
a config that would boot with a blank SMBIOS.

Usage: ./scripts/verify_efi.py build/EFI
"""

from __future__ import annotations

import argparse
import json
import plistlib
import sys
from pathlib import Path

EXPECTED_ACPI = 13
SCHEMA = Path(__file__).resolve().parent.parent / "audit" / "config-schema.json"
FORBIDDEN_KEXTS = {"WhateverGreen.kext", "NootedGreen.kext", "NootedRed.kext", "AppleIntelTGLCompat.kext"}
# Live `movl` immediate inside WhateverXe's Sequoia guard (four bytes).
SEQUOIA_MMIO_OLD = bytes.fromhex("e871cb02")
SEQUOIA_MMIO_NEW = bytes.fromhex("e8a1cb02")

TYPE_NAMES = {
    bool: "bool",
    int: "int",
    float: "float",
    str: "string",
    bytes: "data",
}


def schema_problems(value, expected, path="", out=None):
    """Compare a plist value against the structure captured from OpenCore 1.0.8."""
    if out is None:
        out = []
    if expected == "list":
        if not isinstance(value, list):
            out.append(f"{path}: expected list, got {type(value).__name__}")
        return out
    if isinstance(expected, list):
        if not isinstance(value, list):
            out.append(f"{path}: expected list, got {type(value).__name__}")
            return out
        for index, item in enumerate(value):
            schema_problems(item, expected[0], f"{path}[{index}]", out)
        return out
    if isinstance(expected, dict):
        if not isinstance(value, dict):
            out.append(f"{path}: expected dict, got {type(value).__name__}")
            return out
        for key, child in expected.items():
            if key not in value:
                out.append(f"{path}/{key}: missing key")
            else:
                schema_problems(value[key], child, f"{path}/{key}", out)
        return out
    actual = TYPE_NAMES.get(type(value), type(value).__name__)
    if actual != expected:
        out.append(f"{path}: expected {expected}, got {actual}")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root", nargs="?", default="build/EFI", help="EFI folder to check")
    parser.add_argument(
        "--allow-blank-identity",
        action="store_true",
        help="do not fail when SMBIOS fields are blank (for CI/template checks)",
    )
    args = parser.parse_args()

    root = Path(args.root)
    oc = root / "OC"
    problems: list[str] = []
    warnings: list[str] = []

    if not (root / "BOOT" / "BOOTx64.efi").is_file():
        problems.append("BOOT/BOOTx64.efi is missing")
    if not (oc / "OpenCore.efi").is_file():
        problems.append("OC/OpenCore.efi is missing")

    with (oc / "config.plist").open("rb") as handle:
        config = plistlib.load(handle)

    # The config must keep the OpenCore 1.0.8 key structure it was derived from.
    if SCHEMA.is_file():
        with SCHEMA.open() as handle:
            schema = json.load(handle)
        problems.extend(schema_problems(config, schema, "config"))

    # ACPI payloads referenced by the config must exist.
    enabled_acpi = [a for a in config["ACPI"]["Add"] if a.get("Enabled")]
    for entry in enabled_acpi:
        if not (oc / "ACPI" / entry["Path"]).is_file():
            problems.append(f"ACPI payload missing: {entry['Path']}")
    if len(enabled_acpi) != EXPECTED_ACPI:
        problems.append(f"expected {EXPECTED_ACPI} enabled ACPI tables, found {len(enabled_acpi)}")

    # Kexts: payload exists, Lilu first, no conflicting graphics kexts.
    enabled_kexts = [k for k in config["Kernel"]["Add"] if k.get("Enabled")]
    if not enabled_kexts:
        problems.append("no kexts enabled")
    elif enabled_kexts[0]["BundlePath"] != "Lilu.kext":
        problems.append("Lilu.kext must be the first enabled kext")

    for kext in enabled_kexts:
        bundle = kext["BundlePath"]
        if bundle.endswith(".kext") and not (oc / "Kexts" / bundle).exists():
            problems.append(f"kext payload missing: {bundle}")
        if bundle in FORBIDDEN_KEXTS:
            problems.append(f"conflicting/incompatible kext enabled: {bundle}")
        if kext.get("ExecutablePath") and not (oc / "Kexts" / bundle / kext["ExecutablePath"]).is_file():
            problems.append(f"kext executable missing: {bundle}/{kext['ExecutablePath']}")

    if any(k["BundlePath"] == "WhateverGreen.kext" for k in enabled_kexts):
        problems.append("WhateverGreen and WhateverXe must not be enabled together")

    # A build for Sequoia 15.8.2 records its MMIO byte patch in BUILD-INFO.
    # Check the output, not the pinned payload: the payload stays published.
    info_path = root / "BUILD-INFO.plist"
    if info_path.is_file():
        with info_path.open("rb") as handle:
            build_info = plistlib.load(handle)
        if (build_info.get("gpu_patches") or {}).get("sequoia_mmio"):
            wex = oc / "Kexts" / "WhateverXe.kext" / "Contents" / "MacOS" / "WhateverXe"
            if not wex.is_file():
                problems.append("WhateverXe.kext executable is missing")
            else:
                blob = wex.read_bytes()
                if blob.count(SEQUOIA_MMIO_OLD) or blob.count(SEQUOIA_MMIO_NEW) < 1:
                    problems.append("WhateverXe Sequoia MMIO patch is missing or inconsistent")

    wifi = [k["BundlePath"] for k in enabled_kexts if "itlwm" in k["BundlePath"].lower()]
    if len(wifi) != 1:
        problems.append(f"expected exactly one Wi-Fi kext, found {wifi or 'none'}")

    # SMBIOS must be filled before booting.
    generic = config["PlatformInfo"]["Generic"]
    for key in ("SystemSerialNumber", "MLB", "SystemUUID"):
        if not generic.get(key):
            (warnings if args.allow_blank_identity else problems).append(f"SMBIOS field is blank: {key}")
    if not generic.get("ROM"):
        (warnings if args.allow_blank_identity else problems).append("SMBIOS field is blank: ROM")

    # Anything left enabled in Kernel/Patch deserves a loud warning.
    if any(p.get("Enabled") for p in config["Kernel"]["Patch"]):
        warnings.append("Kernel/Patch contains enabled entries")

    # Boot arguments must match the installed driver variant.
    args = config["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"].get("boot-args", "")
    wex_args = {"-wex-adlp-edp", "-wex-reset-restore", "-wex-no-multicontext"}
    present = {a for a in args.split() if a in wex_args}
    if present and len(present) != len(wex_args):
        problems.append(f"partial adlp-edp boot arguments: {sorted(present)}")
    if args.count("-keepsyms") or args.count("keepsyms=1") > 1:
        warnings.append("duplicate keepsyms argument")

    print(f"checked {root}")
    for item in warnings:
        print(f"  warning: {item}")
    for item in problems:
        print(f"  ERROR  : {item}")
    print(f"  result : {'FAIL' if problems else 'OK'}")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
