#!/usr/bin/env python3
"""Print the version, bundle identifier and SHA-256 of every kext payload.

Run from the repository root and redirect to audit/payloads.tsv after changing
a kext.  The executable hash is what actually ships; Info.plist versions are
displayed for humans and can be stale in third-party builds.
"""

from __future__ import annotations

import hashlib
import plistlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def main() -> None:
    rows = []
    for info in sorted(REPO.glob("efi/**/*.kext/Contents/Info.plist")):
        kext = info.parent.parent
        with info.open("rb") as handle:
            data = plistlib.load(handle)
        executable = data.get("CFBundleExecutable")
        binary = kext / "Contents" / "MacOS" / executable if executable else None
        rows.append(
            (
                str(kext.relative_to(REPO)),
                data.get("CFBundleIdentifier", ""),
                data.get("CFBundleShortVersionString", ""),
                digest(binary) if binary and binary.is_file() else "-",
            )
        )
    print("path\tbundle_id\tversion\tsha256")
    for row in rows:
        print("\t".join(row))


if __name__ == "__main__":
    main()
