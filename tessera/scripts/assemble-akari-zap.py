#!/usr/bin/env python3
"""Reconstruct an unmodified Qualcomm ELF zap image from Sony Tama split firmware.

Stock Android vendor firmware ships a630_zap.mdt and a630_zap.b00/b01/b02.
Mainline's Sony Tama device tree requests a630_zap.mbn instead. Each .bNN
is an ELF program-header payload; reconstruct it at the original p_offset,
without modifying its contents or its Qualcomm signature/hash metadata.

This is a *file format conversion*, not signature verification. Only an
actual Xperia GPU startup test can establish compatibility with the handset.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
from pathlib import Path


# Audited download: TheMuppets/proprietary_vendor_sony_tama-common,
# lineage-23.0, proprietary/vendor/firmware/a630_zap.{mdt,b00,b01,b02}.
LINEAGE_HASHES = {
    "mdt": "238f53706d6178319b206785c8c3ce56b78b094c5325246e72533c75086ce8d9",
    "b00": "b2975f6a4c28a98197c1d694f6e275e71b23ec7e31e32ff5d1f83fdb80a94282",
    "b01": "f5829ab0950cf6369d78120a4086b8bf49b320f7ba3742fa14f5a3e9e2ebb13e",
    "b02": "519b5538809f54ee566246b0520746a8ea82ca9384ea6bddb0b0e0d3c2de520c",
}


class FirmwareError(Exception):
    pass


def assemble(source: Path, verify_lineage: bool = True) -> bytes:
    contents: dict[str, bytes] = {}
    for ext in LINEAGE_HASHES:
        path = source / f"a630_zap.{ext}"
        if not path.is_file() or path.is_symlink():
            raise FirmwareError(f"missing ordinary firmware file: {path}")
        data = path.read_bytes()
        if verify_lineage and hashlib.sha256(data).hexdigest() != LINEAGE_HASHES[ext]:
            raise FirmwareError(f"Sony Tama vendor source digest mismatch: {path}")
        contents[ext] = data

    mdt = contents["mdt"]
    if len(mdt) < 52 or mdt[:6] != b"\x7fELF\x01\x01":
        raise FirmwareError("expected little-endian ELF32 Sony zap.mdt")
    machine = struct.unpack_from("<H", mdt, 18)[0]
    if machine != 164:  # EM_HEXAGON
        raise FirmwareError(f"expected Qualcomm Hexagon ELF, machine={machine}")
    phoff = struct.unpack_from("<I", mdt, 28)[0]
    entsize, count = struct.unpack_from("<HH", mdt, 42)
    if entsize != 32 or count != 3 or phoff + count * entsize > len(mdt):
        raise FirmwareError("unexpected Sony zap ELF program header table")

    segments: list[tuple[int, bytes]] = []
    for index in range(count):
        ph = struct.unpack_from("<8I", mdt, phoff + index * entsize)
        offset, filesize = ph[1], ph[4]
        data = contents[f"b{index:02d}"]
        if not filesize or filesize != len(data):
            raise FirmwareError(f"program header {index} size differs from b{index:02d}")
        if offset > 16 * 1024 * 1024 or offset + filesize > 16 * 1024 * 1024:
            raise FirmwareError("refusing unreasonable firmware ELF offsets")
        for existing_offset, existing in segments:
            if offset < existing_offset + len(existing) and existing_offset < offset + filesize:
                raise FirmwareError("overlapping firmware ELF segments")
        segments.append((offset, data))

    # Sony's MDT concatenates the header segment and the hash-table segment.
    # Check both against the individually distributed vendor files.
    if mdt != contents["b00"] + contents["b01"]:
        raise FirmwareError("Sony MDT metadata does not match b00+b01")
    length = max(offset + len(data) for offset, data in segments)
    result = bytearray(length)
    for offset, data in segments:
        result[offset:offset + len(data)] = data
    if result[:52] != mdt[:52]:
        raise FirmwareError("reconstructed Qualcomm ELF header differs from stock")
    return bytes(result)


def main() -> int:
    root = Path.home() / ".tessera-build/device/akari/firmware"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=root / "sony-stock")
    parser.add_argument("--output", type=Path, default=root / "a630_zap.mbn")
    parser.add_argument(
        "--unverified-source", action="store_true",
        help="accept a different split vendor dump after checking its ELF layout"
    )
    args = parser.parse_args()
    try:
        output = assemble(args.source, verify_lineage=not args.unverified_source)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("xb") as file:
            file.write(output)
    except (FirmwareError, OSError) as error:
        parser.exit(1, f"error: {error}\n")
    print(f"Reconstructed Sony Tama GPU firmware: {args.output}")
    print(f"ELF size: {len(output)} bytes; SHA-256: {hashlib.sha256(output).hexdigest()}")
    print("Sony vendor payload preserved; GPU signature acceptance needs handset testing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())