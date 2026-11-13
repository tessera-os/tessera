#!/usr/bin/env python3
"""Make an OFFLINE, NOT-FLASHABLE Sony Xperia XZ2 (akari) diagnostic boot image.

This is *not* an installer or a release. The stock Tama bootloader may require
changes to the DTBO partition to accept mainline Linux, and this kernel's UFS
driver is intentionally disabled. No partition or connected device is read,
modified, or written by this script.

Sony's SDM845/Tama Android device configuration uses the v1 Android boot
header, 4096-byte pages and Image.gz-dtb. This packager validates the inputs,
preserves the upstream akari DTB, and checks the hard boot-image size limit.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import struct
from pathlib import Path


PAGE_SIZE = 4096
HEADER_SIZE_V1 = 1648
BOOT_MAGIC = b"ANDROID!"
FDT_MAGIC = b"\xd0\x0d\xfe\xed"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
ARM64_IMAGE_MAGIC = b"ARM\x64"
KERNEL_ADDRESS = 0x00008000
RAMDISK_ADDRESS = 0x01000000
TAGS_ADDRESS = 0x00000100

# No UFS: the intended first hardware test is a RAM-only boot diagnostic.
# Parameters after -- are arguments to Tessera's /init, not kernel parameters.
KERNEL_CMDLINE = (
    "console=ttyMSM0,115200n8 console=ttyGS0,115200n8 "
    "ignore_loglevel printk.time=1 panic=0 "
    "-- tessera.system tessera.dev tessera.bootlog tessera.adaptive-mobile"
)

SAFETY_NOTICE = """TESSERA XPERIA XZ2 (akari) — DIAGNOSTIC ARTIFACT ONLY

NOT READY TO INSTALL OR FLASH. DO NOT USE fastboot flash.

This contains a Linux 7.2 mainline-compatible kernel image, the akari device
tree and a Tessera initramfs. The kernel profile explicitly disables the UFS
host because a Sony Tama UFS PURGE/UNMAP operation has historically erased
bootloader partitions. Tessera's real system/data volumes cannot mount.

The Sony bootloader's DTBO overlay handling, verified boot policy and exact
partition layout have NOT been validated against a physical XZ2. Even an
otherwise valid v1 boot.img cannot be called flashable without that test.

The display additionally needs Sony's signed a630_zap.mbn; without the
matching stock firmware Tessera cannot start Adreno graphics. A phone-side
boot test, a validated recovery method and a safely tested storage path are
all still required. No utility in this directory writes to the phone.
"""

UFS_EXPERIMENTAL_NOTICE = """TESSERA XPERIA XZ2 (akari) — EXPERIMENTAL UFS BOOT CANDIDATE

NOT READY TO INSTALL OR FLASH. DO NOT USE fastboot flash.

Internal UFS is ENABLED using the September 2026 proposed Tama device-tree
configuration (GPIO 150 reset and the required regulator supplies). The UFS
PURGE/UNMAP path historically erased bootloader partitions on this family.
Reported successful upstream testing is not proof this handset is safe.

The Sony Tama-specific signed a630_zap.mbn is staged for the GPU, but the
signature and rendering path have NOT been validated on a connected Xperia.
The stock bootloader's DTBO processing, boot partition size, Android AVB
policy, internal partition map and restore path are also unverified.

This local image is only for offline format analysis and a future supervised
hardware bring-up. No utility here flashes or writes to the handset.
"""


class PackageError(Exception):
    pass


def checked_input(path: Path, label: str) -> bytes:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise PackageError(f"cannot read {label} at {path}: {error}") from error
    if not data:
        raise PackageError(f"empty {label}: {path}")
    return data


def checked_capacity(value: str) -> int:
    try:
        capacity = int(value, 0)
    except ValueError as error:
        raise argparse.ArgumentTypeError("partition size must be a byte count") from error
    if capacity < PAGE_SIZE:
        raise argparse.ArgumentTypeError("partition must be at least 4096 bytes")
    return capacity


def check_kernel_config(config: str, experimental_ufs: bool = False) -> None:
    requirements = (
        "CONFIG_ARM64_4K_PAGES=y",
        "CONFIG_DRM_MSM=y",
        "CONFIG_DRM_PANEL_SONY_TD4353_JDI=y",
        "CONFIG_BLK_DEV_INITRD=y",
        "CONFIG_RD_ZSTD=y",
        "CONFIG_DEVTMPFS=y",
        "CONFIG_MMC_BLOCK=y",
        "CONFIG_MMC_SDHCI_MSM=y",
        "CONFIG_BTRFS_FS=y",
        "# CONFIG_COMPAT is not set",
    )
    lines = set(config.splitlines())
    ufs = (
        (
            "CONFIG_SCSI_UFSHCD=y", "CONFIG_SCSI_UFSHCD_PLATFORM=y",
            "CONFIG_SCSI_UFS_QCOM=y", "CONFIG_PHY_QCOM_QMP_UFS=y",
            "# CONFIG_SCSI_UFS_BSG is not set",
        ) if experimental_ufs else (
            "# CONFIG_SCSI_UFSHCD is not set", "# CONFIG_PHY_QCOM_QMP_UFS is not set"
        )
    )
    missing = [required for required in (*requirements, *ufs) if required not in lines]
    if missing:
        raise PackageError(f"akari kernel configuration is incompatible or unsafe: {missing}")


def check_dtb(dtb: bytes, experimental_ufs: bool = False, device: str = "akari") -> None:
    if device not in ("akari", "akatsuki"):
        raise PackageError("unsupported Tama device tree variant")
    if len(dtb) < 40 or dtb[:4] != FDT_MAGIC:
        raise PackageError("device tree is not a flattened device tree (FDT)")
    declared = struct.unpack_from(">I", dtb, 4)[0]
    if declared != len(dtb):
        raise PackageError("device tree FDT totalsize differs from the file size")
    # Check the actual status properties, not just a byte string that might
    # occur in an unrelated device tree. Linux's unsafe UFS hardware must not
    # probe, while the external microSD host must remain available.
    _, _, off_struct, off_strings, _, _, _, _, strings_size, struct_size = struct.unpack_from(
        ">10I", dtb
    )
    if off_struct + struct_size > len(dtb) or off_strings + strings_size > len(dtb):
        raise PackageError("device tree has out-of-bounds FDT sections")
    strings = dtb[off_strings:off_strings + strings_size]
    struct_end = off_struct + struct_size
    at = off_struct
    nodes: dict[str, dict[str, bytes]] = {}
    path: list[str] = []
    while at + 4 <= struct_end:
        tag = struct.unpack_from(">I", dtb, at)[0]
        at += 4
        if tag == 1:  # FDT_BEGIN_NODE
            end = dtb.find(b"\0", at, struct_end)
            if end < 0:
                raise PackageError("device tree has unterminated node name")
            path.append(dtb[at:end].decode("ascii", errors="replace"))
            nodes["/".join(path)] = {}
            at = (end + 4) & ~3
        elif tag == 2:  # FDT_END_NODE
            if not path:
                raise PackageError("device tree contains unmatched FDT_END_NODE")
            path.pop()
        elif tag == 3:  # FDT_PROP
            if at + 8 > struct_end or not path:
                raise PackageError("device tree contains malformed property header")
            size, nameoff = struct.unpack_from(">II", dtb, at)
            at += 8
            if at + size > struct_end or nameoff >= len(strings):
                raise PackageError("device tree contains out-of-bounds property")
            end = strings.find(b"\0", nameoff)
            if end < 0:
                raise PackageError("device tree has unterminated property name")
            name = strings[nameoff:end].decode("ascii", errors="replace")
            nodes["/".join(path)][name] = dtb[at:at + size]
            at += (size + 3) & ~3
        elif tag == 4:  # FDT_NOP
            continue
        elif tag == 9:  # FDT_END
            break
        else:
            raise PackageError(f"device tree contains unknown FDT token {tag}")

    expected = ("sony," + device + "-row").encode("ascii")
    if expected not in nodes.get("", {}).get("compatible", b"").split(b"\0"):
        raise PackageError(f"device tree root does not identify Sony Xperia {device}")

    if device == "akatsuki":
        panels = [props for props in nodes.values()
                  if b"lgd,lh599qh3-edb1-um1" in props.get("compatible", b"").split(b"\0")]
        if len(panels) != 1:
            raise PackageError("XZ3 device tree must contain its LGD OLED panel")
        reset = panels[0].get("reset-gpios", b"")
        if len(reset) != 12 or struct.unpack(">III", reset)[1:] != (6, 1):
            raise PackageError("XZ3 OLED reset must use GPIO 6 active-low")
        touches = [props for props in nodes.values()
                   if b"atmel,maxtouch" in props.get("compatible", b"").split(b"\0")]
        if len(touches) != 1 or touches[0].get("reg") != struct.pack(">I", 0x4a):
            raise PackageError("XZ3 device tree must contain its maXTouch device at 0x4a")
        touch_reset = touches[0].get("reset-gpios", b"")
        if len(touch_reset) != 12 or struct.unpack(">III", touch_reset)[1:] != (99, 1):
            raise PackageError("XZ3 touchscreen reset must use GPIO 99 active-low")
        if touches[0].get("interrupts") != struct.pack(">II", 125, 8):
            raise PackageError("XZ3 touchscreen must use GPIO 125 level-low interrupt")
        if not touches[0].get("vdd-supply") or not touches[0].get("vdda-supply"):
            raise PackageError("XZ3 touchscreen is missing a power supply")

    targets = {
        "ufshc@1d84000": b"okay\0" if experimental_ufs else b"disabled\0",
        "phy@1d87000": b"okay\0" if experimental_ufs else b"disabled\0",
        "mmc@8804000": b"okay\0",
    }
    for node, required in targets.items():
        found = [props for path, props in nodes.items() if path.endswith("/" + node)]
        if len(found) != 1 or found[0].get("status") != required:
            raise PackageError(
                f"unsafe or incompatible akari device tree: {node} requires status "
                f"{required.rstrip(bytes([0])).decode('ascii')}"
            )
    if experimental_ufs:
        controller = [props for path, props in nodes.items() if path.endswith("/ufshc@1d84000")][0]
        phy = [props for path, props in nodes.items() if path.endswith("/phy@1d87000")][0]
        reset = controller.get("reset-gpios", b"")
        if len(reset) != 12 or struct.unpack(">III", reset)[1:] != (150, 1):
            raise PackageError("experimental UFS requires TLMM GPIO 150 active-low reset")
        if controller.get("vcc-max-microamp") != struct.pack(">I", 600000):
            raise PackageError("experimental UFS requires VCC limit of 600000 microamps")
        for props, name in (
            (controller, "vcc-supply"),
            (phy, "vdda-phy-supply"),
            (phy, "vdda-pll-supply"),
        ):
            if len(props.get(name, b"")) != 4:
                raise PackageError(f"experimental UFS requires {name}")


def align(size: int) -> int:
    return (size + PAGE_SIZE - 1) // PAGE_SIZE * PAGE_SIZE


def android_v0_boot(
    kernel: bytes, ramdisk: bytes, *, cmdline: str,
    ramdisk_address: int = RAMDISK_ADDRESS,
) -> bytes:
    """Build the legacy Android boot image used by the Akatsuki PMOS port."""
    if not 0 < ramdisk_address < 0x100000000:
        raise PackageError("Android boot ramdisk address is outside 32-bit physical memory")
    encoded = cmdline.encode("ascii")
    if len(encoded) >= 512:
        raise PackageError("kernel command line exceeds Android v0 limit")

    sha = hashlib.sha1()
    for payload in (kernel, ramdisk, b""):
        sha.update(payload)
        sha.update(struct.pack("<I", len(payload)))

    header = bytearray(PAGE_SIZE)
    header[:8] = BOOT_MAGIC
    struct.pack_into(
        "<10I", header, 8,
        len(kernel), KERNEL_ADDRESS, len(ramdisk), ramdisk_address,
        0, 0, TAGS_ADDRESS, PAGE_SIZE, 0, 0,
    )
    header[64:576] = encoded.ljust(512, b"\0")
    header[576:608] = sha.digest().ljust(32, b"\0")

    image = bytearray(header)
    for payload in (kernel, ramdisk):
        image.extend(payload)
        image.extend(b"\0" * (align(len(payload)) - len(payload)))
    return bytes(image)


def android_v1_boot(
    kernel: bytes, ramdisk: bytes, *, cmdline: str = KERNEL_CMDLINE,
    device: str = "akari", ramdisk_address: int = RAMDISK_ADDRESS,
    reference_header: bytes | None = None,
) -> bytes:
    # The SHA-1 image ID follows AOSP's mkbootimg.py for header version 1.
    sha = hashlib.sha1()
    for payload in (kernel, ramdisk, b"", b""):
        sha.update(payload)
        sha.update(struct.pack("<I", len(payload)))

    if reference_header is not None:
        if len(reference_header) < PAGE_SIZE or reference_header[:8] != BOOT_MAGIC:
            raise PackageError("stock Android boot header reference is invalid")
        ref = reference_header[:PAGE_SIZE]
        ref_version = struct.unpack_from("<I", ref, 40)[0]
        ref_page_size = struct.unpack_from("<I", ref, 36)[0]
        if ref_version != 1 or ref_page_size != PAGE_SIZE:
            raise PackageError("stock boot reference is not an Android v1/4K image")
        os_version = struct.unpack_from("<I", ref, 44)[0]
        header = bytearray(ref)
    else:
        os_version = 0
        header = bytearray(PAGE_SIZE)
    header[:8] = BOOT_MAGIC
    if not 0 < ramdisk_address < 0x100000000:
        raise PackageError("Android boot ramdisk address is outside 32-bit physical memory")
    # Android bootloaders may relocate the ramdisk when the decompressed Linux
    # Image grows past this conventional address. Xperia XZ3's known working
    # postmarketOS profile uses 0x01000000.
    struct.pack_into(
        "<10I", header, 8,
        len(kernel), KERNEL_ADDRESS, len(ramdisk), ramdisk_address,
        0, 0, TAGS_ADDRESS, PAGE_SIZE, 1, os_version,
    )
    if device not in ("akari", "akatsuki"):
        raise PackageError("unsupported Sony Tama boot image device")
    if reference_header is None:
        header[48:64] = device.encode("ascii").ljust(16, b"\0")
    encoded = cmdline.encode("ascii")
    if len(encoded) >= 1536:
        raise PackageError("kernel command line exceeds Android v1 limit")
    header[64:576] = encoded[:511].ljust(512, b"\0")
    header[576:608] = sha.digest().ljust(32, b"\0")
    header[608:1632] = encoded[511:].ljust(1024, b"\0")
    struct.pack_into("<IQI", header, 1632, 0, 0, HEADER_SIZE_V1)
    assert HEADER_SIZE_V1 <= PAGE_SIZE

    image = bytearray(header)
    for payload in (kernel, ramdisk):
        image.extend(payload)
        image.extend(b"\0" * (align(len(payload)) - len(payload)))
    return bytes(image)


def create_new(path: Path, contents: bytes) -> None:
    # Files are created exclusively, never replaced, to protect test outputs.
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        with os.fdopen(descriptor, "wb") as destination:
            destination.write(contents)
    except OSError as error:
        raise PackageError(f"cannot write {path}: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", type=Path, required=True, help="Linux arm64 raw Image")
    parser.add_argument("--dtb", type=Path, required=True, help="upstream akari DTB")
    parser.add_argument("--initramfs", type=Path, required=True, help="Tessera initramfs.cpio.zst")
    parser.add_argument("--config", type=Path, required=True, help="effective akari Linux .config")
    parser.add_argument("--boot-partition-bytes", type=checked_capacity, required=True,
                        help="boot partition capacity measured on the actual phone")
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument(
        "--experimental-ufs", action="store_true",
        help="accept the untested UFS-enabled kernel and DTB; image remains NON-FLASHABLE",
    )
    args = parser.parse_args()

    kernel = checked_input(args.kernel, "arm64 kernel")
    if len(kernel) < 64 or kernel[0x38:0x3C] != ARM64_IMAGE_MAGIC:
        raise PackageError("not a Linux arm64 Image (ARM64 image magic missing)")
    dtb = checked_input(args.dtb, "Xperia XZ2 DTB")
    check_dtb(dtb, experimental_ufs=args.experimental_ufs)
    ramdisk = checked_input(args.initramfs, "Tessera initramfs")
    if not ramdisk.startswith(ZSTD_MAGIC):
        raise PackageError("initramfs must be compressed with zstd")
    check_kernel_config(checked_input(args.config, "effective kernel configuration").decode(
        "utf-8", errors="replace"
    ), experimental_ufs=args.experimental_ufs)

    # The Tama mainline boot convention requires the DTB appended to the
    # compressed kernel; merely writing a v2 DTB field is not sufficient.
    combined = gzip.compress(kernel, compresslevel=9, mtime=0) + dtb
    image = android_v1_boot(combined, ramdisk)
    if len(image) > args.boot_partition_bytes:
        raise PackageError(
            f"diagnostic boot image ({len(image)} bytes) exceeds supplied boot "
            f"partition capacity ({args.boot_partition_bytes} bytes)"
        )

    output = args.out_dir
    if output.exists() and not output.is_dir():
        raise PackageError(f"output path is not a directory: {output}")
    output.mkdir(parents=True, exist_ok=True)
    names = (
        "EXPERIMENTAL-UFS-NOT-FLASHABLE-boot.img" if args.experimental_ufs
        else "DIAGNOSTIC-NOT-FLASHABLE-boot.img",
        "DO-NOT-FLASH.txt", "SHA256SUMS",
    )
    for name in names:
        if (output / name).exists():
            raise PackageError(f"refusing to overwrite {output / name}")

    notice = (UFS_EXPERIMENTAL_NOTICE if args.experimental_ufs else SAFETY_NOTICE).encode("utf-8")
    sums = "".join(
        f"{hashlib.sha256(data).hexdigest()}  {name}\n"
        for name, data in ((names[0], image), (names[1], notice))
    ).encode("ascii")
    create_new(output / names[0], image)
    create_new(output / names[1], notice)
    create_new(output / names[2], sums)
    print(f"Created {output / names[0]} ({len(image)} bytes)")
    if args.experimental_ufs:
        print("Validated UFS-enabled akari DTB, reset/regulators and built-in UFS kernel config")
        print("NOT FLASHABLE: UFS safety, Sony DTBO, partition geometry and real boot are unverified")
    else:
        print("Validated akari DTB, Linux arm64 Image and UFS-disabled kernel config")
        print("NOT FLASHABLE: UFS, DTBO bootloader handling and hardware boot remain unverified")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PackageError as error:
        raise SystemExit(f"error: {error}") from error
