#!/usr/bin/env python3
"""Recreate Sony XZ3's three-way DTBO selection with no vendor overlays.

Uses the original phone's *read-only* dtbo_a backup to preserve the exact
hardware revision / board-id selection values. Each replacement overlay is a
no-op root fragment so the mainline Tessera device tree remains intact.

This is strictly an OFFLINE test artifact. No fastboot/ADB/phone write occurs.
The Sony bootloader's handling of this synthetic DTBO is not tested.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED

HERE = Path(__file__).resolve().parent
OUT = Path.home() / ".tessera-build/out"
DTBO_BACKUP = (Path.home() / ".tessera-build/device/akatsuki/"
               "Tessera-XZ3-recovery-verified-backup-20261107/stock-dtbo-a.img")
BASE_DTB = (OUT / "aarch64/kernel/akatsuki/arch/arm64/boot/dts/qcom/"
            "sdm845-sony-xperia-tama-akatsuki.dtb")
OUTPUT = OUT / "Tessera-XZ3-akatsuki-MINIMAL-DTBO-OFFLINE-20261107.zip"
DTBO_MAGIC = 0xD7B7AB1E
FDT_MAGIC = b"\xd0\x0d\xfe\xed"


class DTBOError(ValueError):
    pass


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def root_properties(blob: bytes) -> dict[str, bytes]:
    """Parse only top-level FDT properties from the verified raw FDT bytes."""
    if blob[:4] != FDT_MAGIC or len(blob) < 40:
        raise DTBOError("entry is not a flattened device tree")
    hdr = struct.unpack_from(">10I", blob, 0)
    if hdr[1] > len(blob) or hdr[2] + hdr[9] > len(blob) or hdr[3] + hdr[8] > len(blob):
        raise DTBOError("FDT structure or string table exceeds its declared length")
    strings = blob[hdr[3]:hdr[3] + hdr[8]]
    pos, end, depth = hdr[2], hdr[2] + hdr[9], 0
    props: dict[str, bytes] = {}
    while pos + 4 <= end:
        tag = struct.unpack_from(">I", blob, pos)[0]
        pos += 4
        if tag == 1:  # BEGIN_NODE
            end_name = blob.find(b"\0", pos, end)
            if end_name < 0:
                raise DTBOError("FDT has an unterminated node")
            pos = (end_name + 4) & ~3
            depth += 1
        elif tag == 2:  # END_NODE
            depth -= 1
            if depth == 0:
                return props
        elif tag == 3:  # PROP
            if pos + 8 > end:
                raise DTBOError("truncated FDT property")
            size, nameoff = struct.unpack_from(">2I", blob, pos)
            pos += 8
            if pos + size > end or nameoff >= len(strings):
                raise DTBOError("invalid FDT property offset")
            if depth == 1:
                nameend = strings.find(b"\0", nameoff)
                if nameend < 0:
                    raise DTBOError("invalid property string name")
                props[strings[nameoff:nameend].decode("ascii")] = blob[pos:pos+size]
            pos = (pos + size + 3) & ~3
        elif tag == 4:  # NOP
            continue
        elif tag == 9:  # END
            return props
        else:
            raise DTBOError(f"unknown FDT token {tag}")
    raise DTBOError("FDT has no terminator")


def parse_oem(dtbo: bytes) -> tuple[list[tuple[tuple[int, ...], dict[str, bytes]]], int]:
    if len(dtbo) != 8388608:
        raise DTBOError("Xperia XZ3 stock DTBO must be exactly 8 MiB")
    magic, total, header, entrysize, count, entries_offset, page_size, ver = struct.unpack_from(">8I", dtbo)
    if (magic, header, entrysize, count, entries_offset, page_size, ver) != (
        DTBO_MAGIC, 32, 32, 3, 32, 4096, 0
    ):
        raise DTBOError("unexpected Sony XZ3 DTBO container header")
    if total > len(dtbo) or total < 32 + count * entrysize:
        raise DTBOError("Sony DTBO total_size is invalid")
    entries = []
    for i in range(count):
        fields = struct.unpack_from(">8I", dtbo, entries_offset + i * entrysize)
        size, offset = fields[:2]
        if size < 40 or offset + size > total:
            raise DTBOError("Sony DTBO entry size or offset is invalid")
        props = root_properties(dtbo[offset:offset+size])
        compatible = props.get("compatible", b"").split(b"\0")
        if b"somc,akatsuki-row" not in compatible:
            raise DTBOError("Sony overlay does not target Xperia XZ3")
        board_id = props.get("qcom,board-id")
        msm_id = props.get("qcom,msm-id")
        if not board_id or not msm_id or len(board_id) != 8 or len(msm_id) != 8:
            raise DTBOError("Sony DTBO is missing board or SoC revision IDs")
        if struct.unpack(">2I", board_id) != (8, 0):
            raise DTBOError("unexpected Sony XZ3 board ID")
        entries.append((fields, props))
    expected_revisions = [(0x141, 0x10000), (0x141, 0x20000), (0x141, 0x20001)]
    actual_revisions = [struct.unpack(">2I", props["qcom,msm-id"]) for _, props in entries]
    if actual_revisions != expected_revisions:
        raise DTBOError(f"the XZ3 board-revision table changed: {actual_revisions!r}")
    return entries, page_size


def minimal_entry(msm_id: tuple[int, int], board: tuple[int, int], dtc: str, path: Path) -> bytes:
    # target-path does not require __symbols__ in the base DTB. No vendor
    # nodes, regulators, display bindings or storage parameters are added.
    dts = f"""/dts-v1/;
/plugin/;

/ {{
    model = "Tessera Xperia XZ3 no-op overlay";
    compatible = "somc,akatsuki-row", "qcom,sdm845", "qcom,mtp";
    qcom,msm-id = <0x{msm_id[0]:x} 0x{msm_id[1]:x}>;
    qcom,board-id = <0x{board[0]:x} 0x{board[1]:x}>;

    fragment@0 {{
        target-path = "/";
        __overlay__ {{ }};
    }};
}};
"""
    source = path.with_suffix(".dts")
    source.write_text(dts)
    try:
        result = subprocess.run([dtc, "-@", "-I", "dts", "-O", "dtb", "-o", str(path), str(source)],
                                capture_output=True, text=True, check=False)
        if result.returncode:
            raise DTBOError("dtc rejected minimal Sony overlay: " + result.stderr[-500:])
        image = path.read_bytes()
    finally:
        source.unlink(missing_ok=True)
    if root_properties(image)["qcom,msm-id"] != struct.pack(">2I", *msm_id):
        raise DTBOError("recompiled minimal XZ3 overlay lost the hardware revision")
    return image


def build(oem: Path, base: Path, output: Path, dtc: str, fdtoverlay: str) -> Path:
    if output.exists() or Path(str(output) + ".sha256").exists():
        raise DTBOError("refusing to overwrite existing diagnostic bundle")
    if not oem.is_file() or not base.is_file():
        raise DTBOError("the verified Sony DTBO backup and mainline DTB are required")
    oem_bytes = oem.read_bytes()
    entries, page_size = parse_oem(oem_bytes)
    base_bytes = base.read_bytes()
    base_root = root_properties(base_bytes)
    if b"sony,akatsuki-row" not in base_root.get("compatible", b"").split(b"\0"):
        raise DTBOError("mainline input DTB does not identify Sony Xperia XZ3")

    blobs: list[bytes] = []
    with tempfile.TemporaryDirectory(prefix="tessera-xz3-minimal-dtbo-") as temporary:
        root = Path(temporary)
        for i, (_, props) in enumerate(entries):
            msm = struct.unpack(">2I", props["qcom,msm-id"])
            board = struct.unpack(">2I", props["qcom,board-id"])
            entry = minimal_entry(msm, board, dtc, root / f"minimal-{i}.dtbo")
            blobs.append(entry)
            merged = root / f"merged-{i}.dtb"
            result = subprocess.run([fdtoverlay, "-i", str(base), "-o", str(merged),
                                     str(root / f"minimal-{i}.dtbo")], capture_output=True,
                                    text=True, check=False)
            if result.returncode:
                raise DTBOError(f"revision {i} failed to merge with Tessera DTB: {result.stderr}")
            new_props = root_properties(merged.read_bytes())
            if new_props.get("compatible") != base_root.get("compatible"):
                raise DTBOError("minimal overlay unexpectedly changed the device compatible")

    offset = 32 + len(blobs) * 32
    records = []
    for (old, _), blob in zip(entries, blobs):
        records.append(struct.pack(">8I", len(blob), offset, *old[2:]))
        offset += len(blob)
    header = struct.pack(">8I", DTBO_MAGIC, offset, 32, 32, len(blobs), 32, page_size, 0)
    image = header + b"".join(records) + b"".join(blobs)
    if len(image) != offset:
        raise DTBOError("minimal DTBO header lengths do not match the payload")
    reparsed, _ = parse_oem(image.ljust(8388608, b"\0"))
    if len(reparsed) != 3:
        raise DTBOError("minimal DTBO is missing hardware revisions")

    notice = """Sony Xperia XZ3 H8416 (akatsuki) — MINIMAL DTBO OFFLINE TEST

Contains all three original Sony revision/board-selection entries but ONLY
root no-op overlay fragments. This removes the proprietary Qualcomm/Sony
display-tree fragments that refer to old mdss_mdp/mdss_dsi0 symbols missing
from Tessera's mainline Linux device tree. `fdtoverlay` accepted all three
minimal overlays onto the actual Tessera Akatsuki base DTB OFFLINE.

This is NOT a tested phone flash image. Opening this ZIP cannot flash anything.
Before a phone-side trial, the complete ORIGINAL dtbo_a/dtbo_b, boot_a/boot_b
and vbmeta_a/vbmeta_b must remain recoverable. A DTBO change is a real
partition modification and must not be applied blindly.

Upstream/mainline DTBO compatibility is necessary but not sufficient for a
working boot: UFS, OLED, USB gadget, recovery and verified-boot behavior still
require a hardware test before destructive Btrfs installation.
""".encode()
    manifest = {
        "format": "tessera.akatsuki.minimal-dtbo.offline.v1",
        "device": "Sony Xperia XZ3 H8416 / akatsuki",
        "stock_dtbo_sha256": sha(oem_bytes),
        "base_dtb_sha256": sha(base_bytes),
        "entries": len(blobs),
        "selected_revision_index": 2,
        "original_rev_ids": [list(struct.unpack(">2I", props["qcom,msm-id"])) for _, props in entries],
        "all_three_overlay_merges_pass": True,
        "flashable": False,
        "tested_on_device": False,
        "dtbo_image_sha256": sha(image),
    }
    files = {
        "dtbo-minimal-unflashed.img": image,
        "README-NOT-FLASHABLE.txt": notice,
        "MANIFEST.json": (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode(),
    }
    files["SHA256SUMS"] = "".join(f"{sha(files[n])}  {n}\n" for n in sorted(files)).encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".xz3-minimal-dtbo-", suffix=".zip",
                                      delete=False) as handle:
        temp = Path(handle.name)
    try:
        with ZipFile(temp, "w", allowZip64=True) as archive:
            for name in sorted(files):
                archive.writestr(name, files[name], compress_type=ZIP_STORED)
        with ZipFile(temp) as archive:
            if archive.testzip() is not None:
                raise DTBOError("offline DTBO archive failed ZIP verification")
        os.link(temp, output)
        Path(str(output) + ".sha256").write_text(f"{sha(temp.read_bytes())}  {output.name}\n")
    finally:
        temp.unlink(missing_ok=True)
    return output


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--oem", type=Path, default=DTBO_BACKUP)
    p.add_argument("--base", type=Path, default=BASE_DTB)
    p.add_argument("--output", type=Path, default=OUTPUT)
    tool_dir = OUT / "aarch64/kernel/akatsuki/scripts/dtc"
    p.add_argument("--dtc", default=str(tool_dir / "dtc"))
    p.add_argument("--fdtoverlay", default=str(tool_dir / "fdtoverlay"))
    args = p.parse_args()
    try:
        output = build(args.oem, args.base, args.output, args.dtc, args.fdtoverlay)
    except (OSError, DTBOError) as err:
        p.exit(1, f"error: {err}\n")
    print("Produced minimal Xperia XZ3 DTBO OFFLINE test:", output)
    print("SHA256:", sha(output.read_bytes()))
    print("Three Sony revision overlays dry-run merged successfully, NO PHONE FLASH ATTEMPTED.")