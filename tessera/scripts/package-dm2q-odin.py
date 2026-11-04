#!/usr/bin/env python3
"""Package Tessera's installer and system boot images for a Samsung SM-S916B.

This only creates local files; it never opens or writes to a device. The
Android v4 boot and vendor_boot headers are generated from scratch. The
mainline kernel cannot use Samsung's downstream device tree, and ABL's overlay
code rejects a mainline base tree, so the dm2q DTB is appended to the gzip
kernel and DTBO is disabled (a zero header): ABL then boots the appended tree.
vendor_boot carries the same DTB. Both ramdisks are LZ4 legacy, as on stock.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import gzip
import struct
import subprocess
import tarfile
from pathlib import Path


PAGE_SIZE = 4096
BOOT_MAGIC = b"ANDROID!"
BOOT_HEADER_V4_SIZE = 1584
BOOT_SIGNATURE_SIZE_OFFSET = 1580
BOOT_CMDLINE_OFFSET = 44
BOOT_CMDLINE_SIZE = 1536


# The kernel's parameters on both images. The panel, its clocks and its
# supplies stay as the bootloader left them, because simpledrm scans out of the
# splash region and no driver owns them. The Adreno is a render-only DRM device.
# Every kernel message reaches the console (ignore_loglevel), which includes
# a CDC ACM serial gadget on the USB-C port (ttyGS0), so a host reads the boot
# log while the panel shows nothing. tty0 stays last, as /dev/console.
# From setup_arch() on, the log also goes into Samsung's sec_log_buf ring
# (earlycon=seclog, kept past console_init by keep_bootcon). Only a warm
# reset keeps that ring, and the panic reboot, power-off and restart are cold,
# so a panic hangs (panic=0) and so do power-off and restart
# (samsung_sec_log.hold=1): holding Volume Down and Power warm-resets the
# phone, and a recovery then shows the log as /proc/last_kmsg.
KERNEL_CMDLINE = (
    # g_multi binds before userspace creates the exchange image. An empty
    # non-removable LUN rejects binding and takes ACM and ECM down with it.
    # This must precede `--`: it is a built-in kernel driver parameter.
    "g_multi.removable=1 "
    "earlycon=seclog,0x880200000 keep_bootcon samsung_sec_log.hold=1 "
    "console=ttyMSM0,115200n8 console=ttyGS0,115200 console=tty0 ignore_loglevel printk.time=1 printk.devkmsg=on panic=0 "
    "clk_ignore_unused pd_ignore_unused regulator_ignore_unused "
    "msm.separate_gpu_kms=1"
)


class PackageError(Exception):
    pass


def read_bytes(path: Path, description: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as error:
        raise PackageError(f"cannot read {description} {path}: {error}") from error


def require_image_size(size: int, capacity: int, description: str) -> None:
    if size > capacity:
        raise PackageError(
            f"{description} would be {size} bytes, over the supplied partition capacity "
            f"of {capacity} bytes"
        )


def v4_boot_header(cmdline: str) -> bytearray:
    """Create an AOSP Android boot image v4 header with an explicit init argv."""
    header = bytearray(PAGE_SIZE)
    header[: len(BOOT_MAGIC)] = BOOT_MAGIC
    struct.pack_into("<I", header, 20, BOOT_HEADER_V4_SIZE)
    struct.pack_into("<I", header, 40, 4)
    set_cmdline(header, cmdline)
    return header


def set_cmdline(header: bytearray, cmdline: str) -> None:
    try:
        encoded = cmdline.encode("ascii")
    except UnicodeEncodeError as error:
        raise PackageError("Android boot command lines must contain only ASCII") from error
    if b"\0" in encoded:
        raise PackageError("Android boot command lines cannot contain NUL bytes")
    if len(encoded) >= BOOT_CMDLINE_SIZE:
        raise PackageError(
            f"boot command line is {len(encoded)} bytes; the v4 header allows "
            f"at most {BOOT_CMDLINE_SIZE - 1}"
        )
    header[BOOT_CMDLINE_OFFSET : BOOT_CMDLINE_OFFSET + BOOT_CMDLINE_SIZE] = (
        encoded + b"\0" * (BOOT_CMDLINE_SIZE - len(encoded))
    )


def align(size: int, boundary: int) -> int:
    return (size + boundary - 1) & -boundary


def make_boot_image(header: bytearray, kernel: bytes, ramdisk: bytes) -> bytes:
    struct.pack_into("<II", header, 8, len(kernel), len(ramdisk))
    # This generated v4 image has no trailing boot_signature payload.
    struct.pack_into("<I", header, BOOT_SIGNATURE_SIZE_OFFSET, 0)

    image = bytearray(header)
    image.extend(b"\0" * (PAGE_SIZE - len(image)))
    for payload in (kernel, ramdisk):
        image.extend(payload)
        image.extend(b"\0" * (align(len(payload), PAGE_SIZE) - len(payload)))
    return bytes(image)


VENDOR_BOOT_MAGIC = b"VNDRBOOT"
VENDOR_BOOT_HEADER_V4_SIZE = 2128
VENDOR_RAMDISK_TABLE_ENTRY_SIZE = 108
VENDOR_RAMDISK_TYPE_PLATFORM = 1
# Qualcomm's conventional load addresses (base 0). SM8550's ABL places the
# images itself; these only have to be plausible.
VENDOR_KERNEL_ADDR = 0x00008000
VENDOR_RAMDISK_ADDR = 0x01000000
VENDOR_TAGS_ADDR = 0x00000100
VENDOR_DTB_ADDR = 0x01F00000


def empty_cpio() -> bytes:
    """A newc archive holding only its trailer, so the vendor ramdisk adds nothing."""
    name = b"TRAILER!!!\0"
    # ino mode uid gid | nlink | mtime filesize devmajor devminor rdevmajor rdevminor | namesize check
    fields = ["070701"] + ["00000000"] * 4 + ["00000001"] + ["00000000"] * 6 + [f"{len(name):08X}", "00000000"]
    header = "".join(fields).encode("ascii") + name
    header += b"\0" * (align(len(header), 4) - len(header))
    return header + b"\0" * (align(len(header), 512) - len(header))


def lz4_legacy(data: bytes) -> bytes:
    """Compress with LZ4's legacy frame, the format stock dm2q ramdisks use.

    Samsung's ABL handles the ramdisks before Linux does; a ramdisk in any
    other format reaches the kernel as an initrd with an invalid magic.
    """
    return subprocess.run(["lz4", "-l", "-12", "-c"], input=data, capture_output=True, check=True).stdout


def zstd_decompress(data: bytes) -> bytes:
    return subprocess.run(["zstd", "-d", "-c"], input=data, capture_output=True, check=True).stdout


def appended_dtb_kernel(image: bytes, dtb: bytes) -> bytes:
    """The kernel as gzip with the device tree right after it.

    With an invalid dtbo, ABL does not run its overlay code, which rejects a
    mainline base tree, and takes the device tree concatenated after the gzip
    member of the kernel instead.
    """
    return gzip.compress(image, compresslevel=9, mtime=0) + dtb


def disabled_dtbo() -> bytes:
    """A dtbo whose header is zero, so ABL treats it as absent."""
    return bytes(PAGE_SIZE)


def make_vendor_boot_image(dtb: bytes) -> bytes:
    """Build an AOSP vendor_boot v4 image whose only content is Tessera's device tree.

    Samsung's stock vendor_boot carries a downstream device tree that a
    mainline kernel cannot use, so dm2q needs its own.
    """
    ramdisk = lz4_legacy(empty_cpio())
    entry = struct.pack("<III", len(ramdisk), 0, VENDOR_RAMDISK_TYPE_PLATFORM) + b"\0" * 32 + b"\0" * 64
    assert len(entry) == VENDOR_RAMDISK_TABLE_ENTRY_SIZE
    header = bytearray(PAGE_SIZE)
    header[:8] = VENDOR_BOOT_MAGIC
    struct.pack_into("<IIIII", header, 8, 4, PAGE_SIZE, VENDOR_KERNEL_ADDR, VENDOR_RAMDISK_ADDR, len(ramdisk))
    struct.pack_into("<I", header, 2076, VENDOR_TAGS_ADDR)
    header[2080:2096] = b"tessera-dm2q".ljust(16, b"\0")
    struct.pack_into("<IIQ", header, 2096, VENDOR_BOOT_HEADER_V4_SIZE, len(dtb), VENDOR_DTB_ADDR)
    struct.pack_into("<IIII", header, 2112, len(entry), 1, VENDOR_RAMDISK_TABLE_ENTRY_SIZE, 0)
    image = bytearray(header)
    for payload in (ramdisk, dtb, entry):
        image.extend(payload)
        image.extend(b"\0" * (align(len(payload), PAGE_SIZE) - len(payload)))
    return bytes(image)


FDT_MAGIC = 0xD00DFEED


def write_new(path: Path, contents: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError as error:
        raise PackageError(f"refusing to overwrite existing output {path}") from error
    except OSError as error:
        raise PackageError(f"cannot create {path}: {error}") from error
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(contents)
    except OSError as error:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        raise PackageError(f"cannot write {path}: {error}") from error


SPARSE_MAGIC = 0xED26FF3A
SPARSE_BLOCK_SIZE = 4096
SPARSE_CHUNK_RAW = 0xCAC1
SPARSE_CHUNK_DONT_CARE = 0xCAC3
SPARSE_MAX_RAW_BLOCKS = 4096


def android_sparse(image: bytes) -> bytes:
    """Encode a raw image in Android sparse format v1.0.

    The SM-S916B bootloader rejects a raw image that spans more than one 30 MiB
    Odin slice (response 0xFFFFFFFF, value 3), so CACHE must be sent sparse.
    All-zero blocks become DONT_CARE chunks; the bootloader expands the rest to
    the same bytes on the partition.
    """
    remainder = len(image) % SPARSE_BLOCK_SIZE
    if remainder:
        image += b"\0" * (SPARSE_BLOCK_SIZE - remainder)
    block_count = len(image) // SPARSE_BLOCK_SIZE
    zero_block = b"\0" * SPARSE_BLOCK_SIZE

    def is_zero(index: int) -> bool:
        start = index * SPARSE_BLOCK_SIZE
        return image[start : start + SPARSE_BLOCK_SIZE] == zero_block

    chunks: list[bytes] = []
    index = 0
    while index < block_count:
        zero = is_zero(index)
        end = index + 1
        while end < block_count and is_zero(end) == zero and (zero or end - index < SPARSE_MAX_RAW_BLOCKS):
            end += 1
        count = end - index
        if zero:
            chunks.append(struct.pack("<HHII", SPARSE_CHUNK_DONT_CARE, 0, count, 12))
        else:
            payload = image[index * SPARSE_BLOCK_SIZE : end * SPARSE_BLOCK_SIZE]
            chunks.append(struct.pack("<HHII", SPARSE_CHUNK_RAW, 0, count, 12 + len(payload)) + payload)
        index = end
    header = struct.pack("<IHHHHIIII", SPARSE_MAGIC, 1, 0, 28, 12, SPARSE_BLOCK_SIZE, block_count, len(chunks), 0)
    return header + b"".join(chunks)


def odin_tar(entries: list[tuple[Path | bytes, str]]) -> bytes:
    import io

    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for source, name in entries:
            contents = source if isinstance(source, bytes) else read_bytes(source, "image for Odin archive")
            info = tarfile.TarInfo(name)
            info.size = len(contents)
            info.mode = 0o644
            info.uid = 0
            info.gid = 0
            info.mtime = 0
            archive.addfile(info, io.BytesIO(contents))
    return stream.getvalue()


def byte_count(value: str) -> int:
    try:
        parsed = int(value, 0)
    except ValueError as error:
        raise argparse.ArgumentTypeError("use a byte count, optionally in hexadecimal") from error
    if parsed <= 0:
        raise argparse.ArgumentTypeError("partition capacities must be positive")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", required=True, type=Path, help="Tessera arm64 Image")
    parser.add_argument("--initramfs", required=True, type=Path, help="Tessera initramfs.cpio.zst")
    parser.add_argument("--installer-initramfs", required=True, type=Path, help="installer.cpio.zst")
    parser.add_argument("--system-image", required=True, type=Path, help="system-volume/system.img to flash to CACHE")
    parser.add_argument("--boot-partition-bytes", required=True, type=byte_count, help="boot capacity reported by the device PIT")
    parser.add_argument("--init-boot-partition-bytes", required=True, type=byte_count, help="init_boot capacity reported by the device PIT")
    parser.add_argument("--cache-partition-bytes", required=True, type=byte_count, help="CACHE capacity reported by the device PIT")
    parser.add_argument("--dtb", required=True, type=Path, help="sm8550-samsung-dm2q.dtb from the dm2q kernel build")
    parser.add_argument("--vendor-boot-partition-bytes", required=True, type=byte_count, help="vendor_boot capacity reported by the device PIT")
    parser.add_argument("--dtbo-partition-bytes", required=True, type=byte_count, help="dtbo capacity reported by the device PIT")
    parser.add_argument("--out-dir", required=True, type=Path)
    args = parser.parse_args()

    kernel = read_bytes(args.kernel, "Tessera kernel")
    initramfs = read_bytes(args.initramfs, "Tessera initramfs")
    if len(kernel) < 64 or kernel[0x38:0x3C] != b"ARM\x64":
        raise PackageError(f"{args.kernel} is not an arm64 Linux Image")
    if not initramfs.startswith(b"\x28\xb5\x2f\xfd"):
        raise PackageError(f"{args.initramfs} is not a Zstandard-compressed initramfs")

    installer_initramfs = read_bytes(args.installer_initramfs, "Tessera installer initramfs")
    system_image = read_bytes(args.system_image, "Tessera system volume")
    if not installer_initramfs.startswith(bytes([0x28, 0xb5, 0x2f, 0xfd])):
        raise PackageError(
            f"{args.installer_initramfs} is not a Zstandard-compressed installer initramfs"
        )
    if not system_image.startswith(b"hsqs"):
        raise PackageError(f"{args.system_image} is not a little-endian SquashFS image")
    require_image_size(len(system_image), args.cache_partition_bytes, "Tessera system image for CACHE")

    version = hashlib.sha256(system_image).hexdigest()[:16]
    installer_cmdline = (
        f"{KERNEL_CMDLINE} -- "
        f"tessera.version={version} tessera.target=PARTLABEL:SUPER "
        "tessera.image=PARTLABEL:CACHE tessera.logpart=PARTLABEL:CACHE"
    )
    system_cmdline = (
        f"{KERNEL_CMDLINE} -- tessera.system tessera.dev tessera.bootlog "
        "tessera.adaptive-mobile "
        "tessera.logpart=PARTLABEL:CACHE"
    )
    dtb = read_bytes(args.dtb, "dm2q device tree")
    if not dtb.startswith(struct.pack(">I", FDT_MAGIC)):
        raise PackageError(f"{args.dtb} is not a flattened device tree")
    boot_kernel = appended_dtb_kernel(kernel, dtb)
    system_boot = make_boot_image(v4_boot_header(system_cmdline), boot_kernel, b"")
    installer_boot = make_boot_image(v4_boot_header(installer_cmdline), boot_kernel, b"")
    system_init_boot = make_boot_image(v4_boot_header(""), b"", lz4_legacy(zstd_decompress(initramfs)))
    installer_init_boot = make_boot_image(
        v4_boot_header(""), b"", lz4_legacy(zstd_decompress(installer_initramfs))
    )
    require_image_size(len(system_boot), args.boot_partition_bytes, "Tessera system boot image")
    require_image_size(len(installer_boot), args.boot_partition_bytes, "Tessera installer boot image")
    require_image_size(len(system_init_boot), args.init_boot_partition_bytes, "Tessera system init_boot image")
    require_image_size(len(installer_init_boot), args.init_boot_partition_bytes, "Tessera installer init_boot image")

    vendor_boot = make_vendor_boot_image(dtb)
    dtbo = disabled_dtbo()
    require_image_size(len(vendor_boot), args.vendor_boot_partition_bytes, "Tessera vendor_boot image")
    require_image_size(len(dtbo), args.dtbo_partition_bytes, "Tessera dtbo image")

    out_dir = args.out_dir
    system_boot_path = out_dir / "boot-system.img"
    system_init_boot_path = out_dir / "init_boot-system.img"
    installer_boot_path = out_dir / "boot-installer.img"
    installer_init_boot_path = out_dir / "init_boot-installer.img"
    vendor_boot_path = out_dir / "vendor_boot.img"
    dtbo_path = out_dir / "dtbo.img"
    system_tar_path = out_dir / "Tessera-SM-S916B-system.tar"
    system_tar_md5_path = out_dir / "Tessera-SM-S916B-system.tar.md5"
    installer_tar_path = out_dir / "Tessera-SM-S916B-install.tar"
    installer_tar_md5_path = out_dir / "Tessera-SM-S916B-install.tar.md5"
    output_paths = (
        system_boot_path,
        system_init_boot_path,
        installer_boot_path,
        installer_init_boot_path,
        vendor_boot_path,
        dtbo_path,
        system_tar_path,
        system_tar_md5_path,
        installer_tar_path,
        installer_tar_md5_path,
    )
    for path in output_paths:
        if path.exists():
            raise PackageError(f"refusing to overwrite existing output {path}")

    write_new(system_boot_path, system_boot)
    write_new(system_init_boot_path, system_init_boot)
    write_new(installer_boot_path, installer_boot)
    write_new(installer_init_boot_path, installer_init_boot)
    write_new(vendor_boot_path, vendor_boot)
    write_new(dtbo_path, dtbo)

    system_tar = odin_tar([
        (system_boot_path, "boot.img"),
        (system_init_boot_path, "init_boot.img"),
        (vendor_boot_path, "vendor_boot.img"),
        (dtbo_path, "dtbo.img"),
    ])
    write_new(system_tar_path, system_tar)
    system_trailer = f"{hashlib.md5(system_tar).hexdigest()}  {system_tar_path.name}\n".encode("ascii")
    write_new(system_tar_md5_path, system_tar + system_trailer)

    installer_tar = odin_tar([
        (installer_boot_path, "boot.img"),
        (installer_init_boot_path, "init_boot.img"),
        (vendor_boot_path, "vendor_boot.img"),
        (dtbo_path, "dtbo.img"),
        (android_sparse(system_image), "cache.img"),
    ])
    write_new(installer_tar_path, installer_tar)
    installer_trailer = f"{hashlib.md5(installer_tar).hexdigest()}  {installer_tar_path.name}\n".encode("ascii")
    write_new(installer_tar_md5_path, installer_tar + installer_trailer)

    print(f"System version: {version}")
    print(f"Created {system_boot_path} ({len(system_boot)} bytes)")
    print(f"Created {system_init_boot_path} ({len(system_init_boot)} bytes)")
    print(f"Created installer images {installer_boot_path} and {installer_init_boot_path}")
    print(f"Created {vendor_boot_path} ({len(vendor_boot)} bytes) and {dtbo_path} ({len(dtbo)} bytes)")
    print(f"Created Odin install archive {installer_tar_md5_path} (BOOT, INIT_BOOT, VENDOR_BOOT, DTBO, sparse CACHE)")
    print(f"Created Odin system archive {system_tar_md5_path} (BOOT, INIT_BOOT, VENDOR_BOOT, DTBO)")
    print("No device was opened or flashed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PackageError as error:
        raise SystemExit(f"error: {error}") from error
