#!/usr/bin/env python3
"""Correct the Xperia XZ3 first-stage RAM boot layout without changing payloads.

The original Sony 16 MiB ramdisk address overlaps the built mainline kernel
(over 96 MiB decompressed). Move only the Android v1 ramdisk address to
128 MiB, with verified non-overlap of both compressed and raw kernel.

This is an OFFLINE operation. It cannot and does not write phone storage.
"""

from __future__ import annotations

import hashlib
import json
import os
import struct
import tempfile
import zlib
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_STORED

OUT = Path.home() / ".tessera-build/out"
SOURCE = OUT / "Tessera-XZ3-akatsuki-FASTBOOT-RAM-TEST-UFS-OFF-20261107.zip"
DESTINATION = OUT / "Tessera-XZ3-akatsuki-FASTBOOT-RAM-TEST-RAMDISK128M-UFS-OFF-20261107.zip"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def repackage(source: Path, output: Path) -> None:
    if output.exists() or Path(str(output) + ".sha256").exists():
        raise ValueError("refusing to overwrite an existing test package")
    with ZipFile(source) as archive:
        if archive.testzip() is not None:
            raise ValueError("original UFS-disabled ZIP CRC failed")
        files = {name: archive.read(name) for name in archive.namelist()}
    expected = {
        line.split("  ", 1)[1]: line.split("  ", 1)[0]
        for line in files["SHA256SUMS"].decode().splitlines()
    }
    for name, expected_sha in expected.items():
        if sha(files[name]) != expected_sha:
            raise ValueError(f"original UFS-disabled ZIP content differs: {name}")
    metadata = json.loads(files["MANIFEST.json"])
    if "akatsuki" not in metadata["device"] or metadata["ufs_driver_disabled_at_compile_time"] is not True:
        raise ValueError("only verified, UFS-disabled XZ3 test builds may be repacked")

    b = bytearray(files["boot-test-ufs-disabled.img"])
    if b[:8] != b"ANDROID!" or struct.unpack_from("<I", b, 40)[0] != 1:
        raise ValueError("not an Android boot-image header v1")
    compressed_size, kernel_addr, ramdisk_size, old_addr = struct.unpack_from("<4I", b, 8)
    if old_addr != 0x01000000 or kernel_addr != 0x8000:
        raise ValueError("unexpected original Sony Tama load addresses")
    compressed = bytes(b[4096:4096+compressed_size])
    decoder = zlib.decompressobj(wbits=31)
    raw_kernel = decoder.decompress(compressed) + decoder.flush()
    if not decoder.eof or raw_kernel[0x38:0x3c] != b"ARM\x64":
        raise ValueError("gzip payload is not the expected arm64 Linux kernel")
    if decoder.unused_data[:4] != b"\xd0\x0d\xfe\xed":
        raise ValueError("appended XZ3 device tree is missing")

    new_addr = 0x08000000
    compressed_end = kernel_addr + compressed_size
    raw_end = kernel_addr + len(raw_kernel)
    if max(compressed_end, raw_end) >= new_addr:
        raise ValueError("kernel still overlaps the relocated ramdisk")
    if new_addr + ramdisk_size > 0x40000000:
        raise ValueError("ramdisk address is unreasonably high for a 4 GiB XZ3")
    struct.pack_into("<I", b, 20, new_addr)
    files["boot-test-ufs-disabled.img"] = bytes(b)

    metadata["ramdisk_load_address"] = hex(new_addr)
    metadata["kernel_compressed_end"] = hex(compressed_end)
    metadata["kernel_uncompressed_end"] = hex(raw_end)
    metadata["boot_tested_on_device"] = False
    metadata["reason_for_repack"] = (
        "Sony's legacy 16 MiB ramdisk address overlaps the >96 MiB "
        "uncompressed Linux kernel; 128 MiB avoids both overlaps"
    )
    metadata["files"]["boot-test-ufs-disabled.img"] = {
        "bytes": len(b), "sha256": sha(b)
    }
    files["README-NOT-FLASHABLE.txt"] += (
        "\nXZ3 RAMDISK LOAD-ADDRESS CORRECTION\n"
        f"Kernel compressed end: {hex(compressed_end)}, uncompressed end: {hex(raw_end)}.\n"
        "The RAMDISK is now loaded at 0x08000000 (128 MiB) rather than 16 MiB.\n"
        "This remains a UFS-disabled RAM-only boot test, NEVER a flash install.\n"
    ).encode()
    for name in ("README-NOT-FLASHABLE.txt",):
        metadata["files"][name] = {"bytes": len(files[name]), "sha256": sha(files[name])}
    files["MANIFEST.json"] = (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode()
    files["SHA256SUMS"] = "".join(
        f"{sha(files[name])}  {name}\n" for name in sorted(files) if name != "SHA256SUMS"
    ).encode()

    with tempfile.NamedTemporaryFile(prefix=".xz3-ramdisk128m-", suffix=".zip",
                                      dir=output.parent, delete=False) as handle:
        tmp = Path(handle.name)
    try:
        with ZipFile(tmp, "w", allowZip64=True) as archive:
            for name in sorted(files):
                entry = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.compress_type = ZIP_STORED
                archive.writestr(entry, files[name])
        with ZipFile(tmp) as archive:
            if archive.testzip() is not None:
                raise ValueError("corrected ZIP integrity failed")
        os.link(tmp, output)
        Path(str(output) + ".sha256").write_text(f"{sha(tmp.read_bytes())}  {output.name}\n")
    finally:
        tmp.unlink(missing_ok=True)
    print(f"New Sony XZ3 UFS-disabled RAM boot package: {output}")
    print(f"Kernel compressed end {hex(compressed_end)}; raw end {hex(raw_end)}; RAMDISK at {hex(new_addr)}")
    print(f"SHA256 {sha(output.read_bytes())}")


if __name__ == "__main__":
    repackage(SOURCE, DESTINATION)