#!/usr/bin/env python3
"""RAM-only Sony XZ3 boot test with an embedded recovery DTBO (Android v1).

The Xperia stock DTBO overlays refer to old Qualcomm vendor symbols and
cannot be directly applied to Tessera's mainline device tree. This test adds
the separately validated three-revision NO-OP DTBO to the *recovery_dtbo*
field of Android boot image v1. Some bootloaders ignore this field on normal
fastboot boot, so the image is NOT expected to guarantee a successful boot.

Safety: the kernel has the UFS host compiled OFF. The result is NOT FLASHABLE.
This tool has no device access and cannot execute fastboot or ADB.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import tempfile
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED

HERE = Path(__file__).resolve().parent
OUT = Path.home() / ".tessera-build/out"
SAFE_BOOT = OUT / "Tessera-XZ3-akatsuki-OLED-UFS-OFF-RAM-TEST-20261107.zip"
MINIMAL_DTBO = OUT / "Tessera-XZ3-akatsuki-MINIMAL-DTBO-OFFLINE-20261107.zip"
OUTPUT = OUT / "Tessera-XZ3-akatsuki-RAM-BOOT-EMBEDDED-DTBO-UFS-OFF-20261107.zip"


class BootError(ValueError):
    pass


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def members(path: Path) -> dict[str, bytes]:
    with ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise BootError(f"invalid ZIP CRC: {path}")
        data = {name: archive.read(name) for name in archive.namelist()}
    for row in data["SHA256SUMS"].decode().splitlines():
        digest, name = row.split("  ")
        if sha(data[name]) != digest:
            raise BootError(f"archive member differs from its published SHA: {name}")
    return data


def with_embedded_dtbo(boot: bytes, dtbo: bytes) -> bytes:
    image = bytearray(boot)
    if image[:8] != b"ANDROID!":
        raise BootError("not an Android boot image")
    ksize, kaddr, rsize, raddr, ssize, saddr, tags, page, header_version, osver = struct.unpack_from(
        "<10I", image, 8
    )
    if (page, header_version, ssize) != (4096, 1, 0):
        raise BootError("boot image is not a normal Android v1 Tama image")
    old_dtbo_len, old_dtbo_offset, hdrsize = struct.unpack_from("<IQI", image, 1632)
    if old_dtbo_len or old_dtbo_offset or hdrsize != 1648:
        raise BootError("boot image already contains recovery DTBO or has wrong header")
    if kaddr + ksize >= raddr or raddr != 0x08000000:
        raise BootError("UFS-off diagnostic does not have the corrected RAM load layout")
    align = lambda size: (size + page - 1) // page * page
    expected = page + align(ksize) + align(rsize)
    if len(image) != expected:
        raise BootError("unexpected original Android v1 image payload layout")
    if dtbo[:4] != b"\xd7\xb7\xab\x1e":
        raise BootError("missing Android DTBO table magic")
    total = struct.unpack_from(">I", dtbo, 4)[0]
    if total != len(dtbo) or struct.unpack_from(">I", dtbo, 16)[0] != 3:
        raise BootError("minimal DTBO lacks the original three XZ3 revisions")
    kernel = image[page:page+ksize]
    ramdisk_offset = page + align(ksize)
    ramdisk = image[ramdisk_offset:ramdisk_offset+rsize]
    hashed = hashlib.sha1()
    for item in (kernel, ramdisk, b"", dtbo):
        hashed.update(item)
        hashed.update(struct.pack("<I", len(item)))
    struct.pack_into("<IQI", image, 1632, len(dtbo), expected, 1648)
    image[576:608] = hashed.digest().ljust(32, b"\0")
    image.extend(dtbo)
    image.extend(b"\0" * (align(len(dtbo)) - len(dtbo)))
    if len(image) > 67108864:
        raise BootError("temporary boot image exceeds XZ3's measured 64 MiB boot capacity")
    return bytes(image)


def build(safe_zip: Path, dtbo_zip: Path, output: Path) -> None:
    if output.exists() or Path(str(output) + ".sha256").exists():
        raise BootError("refusing overwrite of an existing diagnostic")
    safe = members(safe_zip)
    table = members(dtbo_zip)
    safe_manifest = json.loads(safe["MANIFEST.json"])
    dtbo_manifest = json.loads(table["MANIFEST.json"])
    if (safe_manifest.get("ufs_driver_disabled_at_compile_time") is not True or
        safe_manifest.get("ufs_enabled_in_device_tree") is not False or
        "akatsuki" not in safe_manifest.get("device", "") or
        dtbo_manifest.get("all_three_overlay_merges_pass") is not True or
        dtbo_manifest.get("flashable") is not False):
        raise BootError("source safe-boot or minimal DTBO has not passed required guards")
    new_image = with_embedded_dtbo(safe["boot-test-ufs-disabled.img"],
                                   table["dtbo-minimal-unflashed.img"])
    safe["boot-test-ufs-disabled.img"] = new_image
    safe["dtbo-embedded-noop.img"] = table["dtbo-minimal-unflashed.img"]
    safe["README-NOT-FLASHABLE.txt"] += b"""

Embedded DTBO test: the existing verified UFS-disabled, OLED-enabled Xperia
XZ3 RAM boot image carries the three-revision no-op DTBO as an Android boot
v1 recovery_dtbo payload. Some Sony bootloaders ignore recovery_dtbo during
fastboot boot. This is an unproven RAM-ONLY test and MUST NOT be flashed.
"""
    manifest = safe_manifest
    manifest["embedded_recovery_dtbo"] = True
    manifest["embedded_dtbo_revision_count"] = 3
    manifest["embedded_dtbo_sha256"] = sha(safe["dtbo-embedded-noop.img"])
    manifest["boot_tested_on_device"] = False
    manifest["flashable"] = False
    manifest["files"] = {
        name: {"bytes": len(body), "sha256": sha(body)}
        for name, body in safe.items() if name not in ("MANIFEST.json", "SHA256SUMS")
    }
    safe["MANIFEST.json"] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    safe["SHA256SUMS"] = "".join(
        f"{sha(safe[name])}  {name}\n" for name in sorted(safe) if name != "SHA256SUMS"
    ).encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".xz3-ramdtbo-", suffix=".zip",
                                      dir=output.parent, delete=False) as f:
        temporary = Path(f.name)
    try:
        with ZipFile(temporary, "w", allowZip64=True) as archive:
            for name in sorted(safe):
                archive.writestr(name, safe[name], compress_type=ZIP_STORED)
        with ZipFile(temporary) as check:
            if check.testzip() is not None:
                raise BootError("repacked RAM test CRC failed")
        os.link(temporary, output)
        Path(str(output) + ".sha256").write_text(f"{sha(temporary.read_bytes())}  {output.name}\n")
    finally:
        temporary.unlink(missing_ok=True)
    print("Created Xperia XZ3 UFS-off RAM-only test with embedded no-op DTBO:", output)
    print("SHA256:", sha(output.read_bytes()))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--safe-boot-zip", type=Path, default=SAFE_BOOT)
    p.add_argument("--dtbo-zip", type=Path, default=MINIMAL_DTBO)
    p.add_argument("--output", type=Path, default=OUTPUT)
    args = p.parse_args()
    try:
        build(args.safe_boot_zip, args.dtbo_zip, args.output)
    except (BootError, OSError, KeyError) as err:
        p.exit(1, f"error: {err}\n")