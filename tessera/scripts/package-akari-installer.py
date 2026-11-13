#!/usr/bin/env python3
"""Package the offline Xperia XZ2 Tessera installer and sealed system payload.

This command writes one local ZIP file and its checksum. It never opens block
devices, executes fastboot, repartitions disks, or writes to the Xperia. The
bundle is a *staging artifact*, not a validated boot or installation image.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path
from zipfile import ZIP_STORED, ZipFile, ZipInfo


DIAGNOSTIC_SCRIPT = Path(__file__).with_name("package-akari-diagnostic.py")
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
SQUASHFS_MAGIC = b"hsqs"
SONY_TAMA_ZAP_SHA256 = "9e5c3828fecc98fef87c8a7c841618f28a3d258c35981d1189ac03d85b547479"


class BundleError(Exception):
    pass


def diagnostic_checks():
    spec = importlib.util.spec_from_file_location("akari_diagnostic_checks", DIAGNOSTIC_SCRIPT)
    if spec is None or spec.loader is None:
        raise BundleError("cannot load the Xperia XZ2 device-tree safety checks")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checked_file(path: Path, label: str) -> None:
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        raise BundleError(f"missing, empty, or symbolic-link {label}: {path}")


def published_digest(path: Path, actual: str) -> None:
    stamp = Path(str(path) + ".digest")
    checked_file(stamp, "Tessera build digest")
    recorded = stamp.read_text(encoding="ascii").strip()
    if recorded != actual:
        raise BundleError(f"Tessera's published digest does not match {path}")


def check_squashfs(path: Path) -> None:
    with path.open("rb") as image:
        header = image.read(48)
    if len(header) < 48 or header[:4] != SQUASHFS_MAGIC:
        raise BundleError(f"not a SquashFS system image: {path}")
    major, minor = struct.unpack_from("<HH", header, 28)
    bytes_used = struct.unpack_from("<Q", header, 40)[0]
    if (major, minor) != (4, 0) or bytes_used < 48 or bytes_used > path.stat().st_size:
        raise BundleError(f"invalid SquashFS v4 superblock: {path}")


def check_zstd(path: Path) -> None:
    with path.open("rb") as source:
        if source.read(4) != ZSTD_MAGIC:
            raise BundleError(f"expected a Zstandard-compressed initramfs: {path}")


def zstd_reader() -> str:
    found = shutil.which("zstd")
    if found:
        return found
    mac = Path("/opt/homebrew/opt/zstd/bin/zstd")
    if mac.is_file():
        return str(mac)
    raise BundleError("zstd is required to validate Sony GPU firmware in the initramfs")


def cpio_member(archive: Path, path: str) -> bytes:
    """Read one newc-format initramfs member without extracting it to disk."""
    result = subprocess.run(
        [zstd_reader(), "-dc", str(archive)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        raise BundleError(f"cannot decompress Tessera initramfs: {archive}")
    data = result.stdout
    cursor = 0
    while cursor + 110 <= len(data):
        header = data[cursor:cursor + 110]
        if header[:6] not in (b"070701", b"070702"):
            raise BundleError("invalid Tessera initramfs cpio header")
        try:
            fields = [int(header[6 + i * 8:14 + i * 8], 16) for i in range(13)]
        except ValueError as error:
            raise BundleError("malformed Tessera initramfs cpio size") from error
        size, namesize = fields[6], fields[11]
        begin = cursor + 110
        if not namesize or begin + namesize > len(data):
            raise BundleError("invalid Tessera initramfs member name")
        name = data[begin:begin + namesize - 1].decode("utf-8", errors="replace")
        start = (begin + namesize + 3) & ~3
        end = start + size
        if end > len(data):
            raise BundleError("truncated Tessera initramfs member")
        if name == path or name == "./" + path:
            return data[start:end]
        if name == "TRAILER!!!":
            break
        cursor = (end + 3) & ~3
    raise BundleError(f"missing Tessera initramfs member: {path}")


def check_kernel(path: Path) -> None:
    with path.open("rb") as image:
        image.seek(0x38)
        if image.read(4) != b"ARM\x64":
            raise BundleError(f"not an ARM64 Linux Image: {path}")


def check_boot_candidate(
    boot: Path, kernel: Path, dtb: Path, initramfs: Path,
    *, expected_ramdisk_address: int = 0x1000000,
    expected_header_version: int = 1,
) -> None:
    """Verify Android boot geometry and exact matching Tessera payloads."""
    image = boot.read_bytes()
    if len(image) < 4096 or image[:8] != b"ANDROID!":
        raise BundleError("boot candidate is not an Android boot image")
    kernel_size, kernel_address, ramdisk_size, ramdisk_address = struct.unpack_from("<4I", image, 8)
    page_size, version = struct.unpack_from("<II", image, 36)
    if (kernel_address, ramdisk_address, page_size, version) != (
        0x8000, expected_ramdisk_address, 4096, expected_header_version
    ):
        raise BundleError("boot candidate does not match the expected Xperia Tama geometry")
    if version == 1 and struct.unpack_from("<I", image, 1644)[0] != 1648:
        raise BundleError("boot candidate has an invalid v1 header size")
    aligned = lambda n: (n + 4095) // 4096 * 4096
    ramdisk_offset = 4096 + aligned(kernel_size)
    if len(image) != ramdisk_offset + aligned(ramdisk_size):
        raise BundleError("boot candidate payload lengths do not match its Android header")
    embedded_kernel = image[4096:4096 + kernel_size]
    if not embedded_kernel.startswith(b"\x1f\x8b"):
        raise BundleError("boot candidate kernel is not compressed with gzip")
    decoder = zlib.decompressobj(wbits=31)
    actual_kernel = decoder.decompress(embedded_kernel) + decoder.flush()
    if not decoder.eof or actual_kernel != kernel.read_bytes() or decoder.unused_data != dtb.read_bytes():
        raise BundleError("boot candidate kernel/DTB differs from the published Xperia build")
    embedded_ramdisk = image[ramdisk_offset:ramdisk_offset + ramdisk_size]
    if embedded_ramdisk != initramfs.read_bytes():
        raise BundleError("boot candidate initramfs differs from the published Tessera build")
    sha = hashlib.sha1()
    hashed_payloads = (embedded_kernel, embedded_ramdisk, b"")
    if version == 1:
        hashed_payloads += (b"",)
    for payload in hashed_payloads:
        sha.update(payload)
        sha.update(struct.pack("<I", len(payload)))
    if sha.digest() != image[576:596]:
        raise BundleError("boot candidate Android kernel/ramdisk ID is invalid")


def squashfs_reader() -> str:
    found = shutil.which("unsquashfs")
    if found:
        return found
    mac = Path("/opt/homebrew/opt/squashfs/bin/unsquashfs")
    if mac.is_file():
        return str(mac)
    raise BundleError("unsquashfs is required to validate the recovery payload")


def squashfs_member(source: Path, name: str) -> tuple[str, int]:
    """Hash a member via streaming; never unpack the large system to disk."""
    h = hashlib.sha256()
    total = 0
    command = [squashfs_reader(), "-cat", str(source), name]
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
        assert process.stdout is not None
        for chunk in iter(lambda: process.stdout.read(1024 * 1024), b""):
            total += len(chunk)
            h.update(chunk)
        code = process.wait()
    if code or total == 0:
        raise BundleError(f"missing, empty or unreadable SquashFS member: {source}:{name}")
    return h.hexdigest(), total


def verify_recovery_payload(system: Path, recovery: Path, system_sha: str) -> None:
    embedded, length = squashfs_member(recovery, "System/Installation/system.img")
    if embedded != system_sha or length != system.stat().st_size:
        raise BundleError(
            "the recovery system embeds a different system.img from the separately published "
            "system volume; rebuild `system-volume installer-image recovery-image` together"
        )
    # The recovery's service needs these exact paths. Its digest is the
    # fs-verity digest (32 raw bytes), not the SquashFS file's SHA-256.
    for name in (
        "System/Installation/system.digest", "bin/installer", "composefs.img", "composefs.sig"
    ):
        _, member_size = squashfs_member(recovery, name)
        if name.endswith("system.digest") and member_size != 32:
            raise BundleError("the recovery payload holds an invalid fs-verity digest")
    for name in ("composefs.img", "composefs.sig"):
        squashfs_member(system, name)


def fixed_info(name: str) -> ZipInfo:
    info = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = ZIP_STORED  # the kernel/system/initramfs are already compressed
    info.external_attr = 0o100644 << 16
    info.create_system = 3
    return info


def package(args: argparse.Namespace) -> Path:
    experimental_ufs = getattr(args, "experimental_ufs", False)
    sources = {
        "kernel/Image": args.kernel,
        "kernel/akari.dtb": args.dtb,
        "kernel/akari.config": args.config,
        "boot/initramfs.cpio.zst": args.initramfs,
        "install/installer.cpio.zst": args.installer,
        "install/system.img": args.system,
        "install/recovery-system.img": args.recovery,
    }
    if experimental_ufs:
        firmware_root = Path.home() / ".tessera-build/device/akari/firmware"
        sources.update({
            "boot/experimental-boot.img": getattr(
                args, "boot_candidate",
                Path.home() / ".tessera-build/out/aarch64/akari-ufs-gpu-boot-candidate/EXPERIMENTAL-UFS-NOT-FLASHABLE-boot.img"
            ),
            "firmware/qcom/a630_sqe.fw": getattr(args, "sqe", firmware_root / "linux-firmware/a630_sqe.fw"),
            "firmware/qcom/a630_gmu.bin": getattr(args, "gmu", firmware_root / "linux-firmware/a630_gmu.bin"),
            "firmware/qcom/sdm845/Sony/tama/a630_zap.mbn": getattr(args, "sony_zap", firmware_root / "a630_zap.mbn"),
        })
    for name, source in sources.items():
        checked_file(source, name)
    checks = diagnostic_checks()
    try:
        checks.check_kernel_config(
            args.config.read_text(encoding="utf-8"), experimental_ufs=experimental_ufs
        )
        checks.check_dtb(args.dtb.read_bytes(), experimental_ufs=experimental_ufs)
    except (checks.PackageError, UnicodeError) as error:
        raise BundleError(str(error)) from error
    check_kernel(args.kernel)
    check_zstd(args.initramfs)
    check_zstd(args.installer)
    if experimental_ufs:
        check_boot_candidate(sources["boot/experimental-boot.img"], args.kernel, args.dtb, args.initramfs)
    check_squashfs(args.system)
    check_squashfs(args.recovery)

    metadata = {}
    for name, source in sources.items():
        sha = digest_file(source)
        if name in (
            "boot/initramfs.cpio.zst", "install/installer.cpio.zst",
            "install/system.img", "install/recovery-system.img",
        ):
            published_digest(source, sha)
        metadata[name] = {"size": source.stat().st_size, "sha256": sha}

    if experimental_ufs:
        expected_firmware = {
            "lib/firmware/qcom/a630_sqe.fw": metadata["firmware/qcom/a630_sqe.fw"]["sha256"],
            "lib/firmware/qcom/a630_gmu.bin": metadata["firmware/qcom/a630_gmu.bin"]["sha256"],
            "lib/firmware/qcom/sdm845/Sony/tama/a630_zap.mbn": metadata[
                "firmware/qcom/sdm845/Sony/tama/a630_zap.mbn"
            ]["sha256"],
        }
        if expected_firmware["lib/firmware/qcom/sdm845/Sony/tama/a630_zap.mbn"] != SONY_TAMA_ZAP_SHA256:
            raise BundleError("the Sony Tama firmware differs from the audited vendor blob")
        for path, sha in expected_firmware.items():
            staged = cpio_member(args.initramfs, path)
            if hashlib.sha256(staged).hexdigest() != sha:
                raise BundleError(f"initramfs firmware differs from the expected Sony/GPU payload: {path}")

    verify_recovery_payload(args.system, args.recovery, metadata["install/system.img"]["sha256"])

    version = metadata["install/system.img"]["sha256"][:16]
    manifest = {
        "format": "tessera.akari.installer-staging.v1",
        "target": "Sony Xperia XZ2 (akari, regular-sized model)",
        "kernel_profile": "akari",
        "architecture": "aarch64",
        "volume_filesystem": "btrfs",
        "volume_layout": {
            "boot_directory": "boot/",
            "system_subvolume": "system/" + version,
            "data_subvolume": "data",
            "current_record": "boot/current",
            "version": version,
        },
        "installation_input": "install/system.img (raw SquashFS, not a writable Btrfs volume)",
        "installer_root": "install/installer.cpio.zst",
        "recovery_payload": "install/recovery-system.img (NOT an Android recovery partition image)",
        "flashable": False,
        "boot_tested_on_device": False,
        "recovery_payload_matches_system": True,
        "ufs_enabled": experimental_ufs,
        "ufs_tested_on_device": False,
        "requires_matching_sony_a630_zap": not experimental_ufs,
        "firmware_included": experimental_ufs,
        "gpu_firmware_staged_in_initramfs": experimental_ufs,
        "gpu_tested_on_device": False,
        "boot_candidate_included": experimental_ufs,
        "boot_partition_capacity_tested_on_device": False,
        "gpu_firmware_provenance": (
            "Sony Tama LineageOS proprietary vendor, ELF reconstructed from .mdt/.b00/.b01/.b02"
            if experimental_ufs else "not present"
        ),
        "files": metadata,
    }
    readme = f"""TESSERA — SONY XPERIA XZ2 (AKARI) — OFFLINE INSTALLER STAGING

NOT READY TO BOOT, INSTALL OR FLASH. This bundle is a build output for
inspection and a future, physically validated bring-up. It contains no
fastboot scripts and writes nothing to a connected device.

Tessera's system image and Tessera's writable volume are different:
  install/system.img              signed/sealed system payload (SquashFS)
  install/installer.cpio.zst      PID 1 installer that creates Btrfs
  install/recovery-system.img     Tessera recovery system image (SquashFS)
  boot/initramfs.cpio.zst        PID 1 for the installed Tessera system
  kernel/Image + kernel/akari.dtb Linux 7.2 image and Sony device tree
  {"boot/experimental-boot.img    Android v1 diagnostic-only boot candidate" if experimental_ufs else ""}

When booted on supported hardware, the installer formats an EMPTY target
block device as Btrfs (refusing to overwrite an existing filesystem), creates
boot/, a data subvolume, and system/{version} as a read-only snapshot,
then writes boot/current last. It expects the SquashFS system payload on
a SEPARATE readable block device. The recovery-system image packages that
payload and the installer service for the Tessera recovery environment.

The installer's configurable kernel command-line arguments are:
  tessera.version={version}
  tessera.target=PARTLABEL:<verified-target-partition-name>
  tessera.image=PARTLABEL:<verified-squashfs-source-partition-name>

These are NOT instructions to repartition or boot the Xperia now. Both
PARTLABEL values are placeholders; no real partition labels, locations or
capacities have been validated. The system payload must be exposed as a raw
SquashFS block device, not simply copied into an arbitrary FAT folder.

Critical blockers for actual phone installation:
* The Sony bootloader/DTBO, boot partitions and safe recovery are unverified.
* {"Sony Tama GPU firmware is staged but GPU initialization is not tested." if experimental_ufs else "No matching Sony-signed a630_zap.mbn was provided; Adreno cannot start."}
* {"Internal UFS is ENABLED EXPERIMENTALLY. Historical UFS PURGE/UNMAP can erase bootloader partitions." if experimental_ufs else "Internal UFS is DISABLED in the kernel and device tree for safety."}
* No microSD Btrfs mount, display, touch, USB console or reboot was tested.
* The installation mode has NOT been executed against an Xperia device.

{"The experimental-boot.img has an Android v1 header but is NOT safe to flash or a tested boot release." if experimental_ufs else "None of the included SquashFS files is an Android boot/recovery/system partition image."}
Do not use `fastboot flash`, dd onto physical storage, or overwrite partitions
with any file in this bundle. Check MANIFEST.json and SHA256SUMS for details.
"""
    extras = {
        "MANIFEST.json": (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8"),
        "README-NOT-FLASHABLE.txt": readme.encode("utf-8"),
    }
    sums = []
    for name, item in metadata.items():
        sums.append(f"{item['sha256']}  {name}\n")
    for name, value in extras.items():
        sums.append(f"{hashlib.sha256(value).hexdigest()}  {name}\n")
    extras["SHA256SUMS"] = "".join(sums).encode("ascii")

    output = args.output
    checksum_path = Path(str(output) + ".sha256")
    if output.exists() or output.is_symlink() or checksum_path.exists() or checksum_path.is_symlink():
        raise BundleError(f"refusing to overwrite {output} or its checksum")
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, staging = tempfile.mkstemp(prefix=".akari-installer-", suffix=".zip", dir=output.parent)
    os.close(descriptor)
    try:
        with ZipFile(staging, "w", allowZip64=True) as archive:
            for name, source in sources.items():
                with source.open("rb") as stream, archive.open(fixed_info(name), "w", force_zip64=True) as member:
                    shutil.copyfileobj(stream, member, length=1024 * 1024)
            for name, value in extras.items():
                archive.writestr(fixed_info(name), value)
        with ZipFile(staging, "r") as archive:
            corrupted = archive.testzip()
            if corrupted:
                raise BundleError(f"ZIP verification failed at {corrupted}")
        # Atomic no-overwrite publication. os.link fails instead of replacing
        # a previously published file, including if a second packager raced.
        os.link(staging, output)
        checksum = digest_file(output)
        with checksum_path.open("x", encoding="ascii") as file:
            file.write(f"{checksum}  {output.name}\n")
    except OSError as error:
        raise BundleError(f"cannot publish installer bundle: {error}") from error
    finally:
        Path(staging).unlink(missing_ok=True)
    print(f"Created {output} ({output.stat().st_size} bytes)")
    print(f"Version: {version}; all ZIP members verified; SHA256: {checksum}")
    print("NOT FLASHABLE: phone boot, firmware, microSD volume and recovery are unverified")
    return output


def main() -> int:
    root = Path.home() / ".tessera-build"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", type=Path, default=root / "out/aarch64/kernel/akari/arch/arm64/boot/Image")
    parser.add_argument("--dtb", type=Path, default=root / "out/aarch64/kernel/akari/arch/arm64/boot/dts/qcom/sdm845-sony-xperia-tama-akari.dtb")
    parser.add_argument("--config", type=Path, default=root / "out/aarch64/kernel/akari/.config")
    parser.add_argument("--initramfs", type=Path, default=root / "out/initramfs/initramfs.cpio.zst")
    parser.add_argument("--installer", type=Path, default=root / "out/installer-image/installer.cpio.zst")
    parser.add_argument("--system", type=Path, default=root / "out/system-volume/system.img")
    parser.add_argument("--recovery", type=Path, default=root / "out/recovery-image/recovery.img")
    parser.add_argument("--experimental-ufs", action="store_true",
                        help="package the UFS-enabled build with audited Sony GPU firmware; still NOT flashable")
    parser.add_argument("--sony-zap", type=Path, default=root / "device/akari/firmware/a630_zap.mbn")
    parser.add_argument("--sqe", type=Path, default=root / "device/akari/firmware/linux-firmware/a630_sqe.fw")
    parser.add_argument("--gmu", type=Path, default=root / "device/akari/firmware/linux-firmware/a630_gmu.bin")
    parser.add_argument("--boot-candidate", type=Path, default=root / "out/aarch64/akari-ufs-gpu-boot-candidate/EXPERIMENTAL-UFS-NOT-FLASHABLE-boot.img")
    parser.add_argument("--output", type=Path, required=True, help="new ZIP file to create, never overwritten")
    args = parser.parse_args()
    try:
        package(args)
    except (BundleError, OSError) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
