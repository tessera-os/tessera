#!/usr/bin/env python3
"""Build a staged, two-phase fastboot installer for Xperia XZ3 (akatsuki).

Part 1: source SquashFS in the inactive system_a partition, installer RAM boot.
Part 2: Tessera system boot image in boot_a, then activate slot a.

This is a host-only packager. It never opens fastboot or writes phone storage.
An Android update ZIP cannot atomically install Tessera: the sealed system is
218 MiB while the boot partition is only 64 MiB and Btrfs needs userdata.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import json
import os
import struct
import tempfile
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_STORED


HERE = Path(__file__).resolve().parent
OUT = Path.home() / ".tessera-build/out"
KERNEL = OUT / "aarch64/kernel/akatsuki/arch/arm64/boot/Image"
DTB = OUT / "aarch64/kernel/akatsuki/arch/arm64/boot/dts/qcom/sdm845-sony-xperia-tama-akatsuki.dtb"
CONFIG = OUT / "aarch64/kernel/akatsuki/.config"
INITRAMFS = OUT / "initramfs/initramfs.cpio.zst"
INSTALLER = OUT / "installer-image/installer.cpio.zst"
SYSTEM = OUT / "system-volume/system.img"
RECOVERY = OUT / "recovery-image/recovery.img"
BOOT_REFERENCE = HERE.parent / ".kira-build/akatsuki-boot-a-reference.img"
OUTPUT = OUT / "Tessera-XZ3-H8416-FASTBOOT-INSTALLER-CANDIDATE-20261107.zip"
PAGE = 4096
MAX_BOOT = 64 * 1024 * 1024  # measured on H8416 boot_{a,b} via fastboot


class InstallImageError(Exception):
    pass


def local_module(filename: str):
    p = HERE / filename
    spec = importlib.util.spec_from_file_location(filename.replace("-", "_"), p)
    if not spec or not spec.loader:
        raise InstallImageError(f"missing Tessera packager {p}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_published(path: Path, staging) -> str:
    staging.checked_file(path, path.name)
    actual = digest(path)
    staging.published_digest(path, actual)
    return actual


def installation_commandline(
    version: str, installer: bool, target_slot: str, stock_cmdline: str = ""
) -> str:
    serial = "console=ttyMSM0,115200n8 console=ttyGS0,115200n8 "
    if installer:
        return (stock_cmdline + " " + serial + "printk.time=1 panic=0 -- "
                f"tessera.version={version} "
                "tessera.target=PARTLABEL:userdata "
                f"tessera.image=PARTLABEL:system_{target_slot} "
                "tessera.reformat-userdata")
    return (stock_cmdline + " " + serial
            + "printk.time=1 panic=0 -- tessera.system tessera.adaptive-mobile")


def build(args: argparse.Namespace) -> Path:
    target_slot = "b" if args.active_slot == "a" else "a"
    diagnose = local_module("package-akari-diagnostic.py")
    staging = local_module("package-akari-installer.py")
    for p in (args.kernel, args.dtb, args.config, args.installer, args.initramfs,
              args.system, args.recovery, args.boot_reference):
        staging.checked_file(p, "XZ3 build input")
    stock_boot = args.boot_reference.read_bytes()
    if stock_boot[:8] != b"ANDROID!" or struct.unpack_from("<I", stock_boot, 40)[0] != 1:
        raise InstallImageError("stock boot reference must be an Android v1 image")
    stock_cmdline = (
        stock_boot[64:576].split(b"\0", 1)[0]
        + stock_boot[608:1632].split(b"\0", 1)[0]
    ).decode("ascii", errors="strict")
    config = args.config.read_text()
    for required in (
        "CONFIG_SCSI_UFSHCD=y", "CONFIG_SCSI_UFS_QCOM=y",
        "CONFIG_PHY_QCOM_QMP_UFS=y", "CONFIG_DRM_MSM=y",
        "CONFIG_DRM_PANEL_LGD_LH599QH3_EDB1=y", "CONFIG_TOUCHSCREEN_ATMEL_MXT=y",
        "CONFIG_BT=y", "CONFIG_BT_LE=y", "CONFIG_BT_HCIUART_QCA=y",
        "# CONFIG_SCSI_UFS_BSG is not set",
    ):
        if required not in config.splitlines():
            raise InstallImageError(f"XZ3 build missing required kernel setting: {required}")
    tree = args.dtb.read_bytes()
    diagnose.check_dtb(tree, experimental_ufs=True, device="akatsuki")
    staging.check_kernel(args.kernel)
    staging.check_zstd(args.installer)
    staging.check_zstd(args.initramfs)
    staging.check_squashfs(args.system)
    staging.check_squashfs(args.recovery)
    system_hash = check_published(args.system, staging)
    check_published(args.installer, staging)
    check_published(args.initramfs, staging)
    check_published(args.recovery, staging)
    staging.verify_recovery_payload(args.system, args.recovery, system_hash)
    version = system_hash[:16]

    # Validate that the *rebuilt* installer really knows about exact userdata
    # opt-in reformat, cannot send trim, and includes a Btrfs formatter.
    executable = staging.cpio_member(args.installer, "init")
    for marker in (
        b"tessera.reformat-userdata", b"tessera.target=PARTLABEL:userdata",
        b"tessera.image=", b"mkfs.btrfs", b"-K",
    ):
        if marker not in executable:
            raise InstallImageError(f"rebuilt installer /init missing {marker!r}")
    staging.cpio_member(args.installer, "bin/mkfs.btrfs")
    for name in (
        "lib/firmware/qcom/a630_sqe.fw", "lib/firmware/qcom/a630_gmu.bin",
        "lib/firmware/qcom/sdm845/Sony/tama/a630_zap.mbn",
        "lib/firmware/qca/crbtfw21.tlv", "lib/firmware/qca/Sony/tama/crnv21.bin",
    ):
        contents = staging.cpio_member(args.initramfs, name)
        if len(contents) < 100:
            raise InstallImageError(f"missing Adreno 630 firmware {name}")

    kernel_bytes = args.kernel.read_bytes()
    zipped_kernel = gzip.compress(kernel_bytes, compresslevel=9, mtime=0) + tree
    installer_boot = diagnose.android_v1_boot(
        zipped_kernel, args.installer.read_bytes(),
        cmdline=installation_commandline(version, installer=True, target_slot=target_slot,
                                         stock_cmdline=stock_cmdline),
        device="akatsuki", ramdisk_address=0x01000000,
        reference_header=stock_boot,
    )
    system_boot = diagnose.android_v1_boot(
        zipped_kernel, args.initramfs.read_bytes(),
        cmdline=installation_commandline(version, installer=False, target_slot=target_slot,
                                         stock_cmdline=stock_cmdline),
        device="akatsuki", ramdisk_address=0x01000000,
        reference_header=stock_boot,
    )
    if len(installer_boot) > MAX_BOOT or len(system_boot) > MAX_BOOT:
        raise InstallImageError("XZ3 boot image exceeds the measured boot partition size")
    with tempfile.TemporaryDirectory(prefix="tessera-xz3-boot-validation-") as directory:
        root = Path(directory)
        for name, contents, ramdisk in (
            ("installer-boot.img", installer_boot, args.installer),
            ("tessera-boot.img", system_boot, args.initramfs),
        ):
            image = root / name
            image.write_bytes(contents)
            staging.check_boot_candidate(
                image, args.kernel, args.dtb, ramdisk,
                expected_ramdisk_address=0x01000000
            )
            if contents[48:64] != stock_boot[48:64]:
                raise InstallImageError("Android boot header does not preserve Sony's stock name field")

    installer_script = (HERE / "akatsuki-install.ps1").read_bytes()
    notice = f"""Tessera Xperia XZ3 H8416 — installation candidate

This is a two-phase fastboot installer bundle, NOT a one-click Android OTA.
It contains these files:
  system-source.img   {args.system.stat().st_size} bytes, raw sealed SquashFS
  installer-boot.img  {len(installer_boot)} bytes, installs Btrfs to userdata
  tessera-boot.img    {len(system_boot)} bytes, normal Tessera boot

Tessera version: {version}
Target phone: Xperia XZ3 H8416 (akatsuki), unlocked, active slot {args.active_slot};
inactive slot {target_slot}.

1. Extract the ZIP on Edmond's Windows PC and run:
     powershell -File .\\akatsuki-install.ps1
   This reads device information and verifies all SHA256 hashes only.
2. Once the phone has passed RAM-boot, OLED and UFS checks, the installer
   can stage system-source.img to inactive system_{target_slot}, temporarily RAM-boot
   installer-boot.img, and format userdata as Btrfs. This ERASES userdata.
3. After a confirmed Tessera installation, boot the Tessera image in RAM,
   then flash tessera-boot.img to inactive boot_{target_slot} and switch slot to {target_slot}.

The original bootloader's DTBO handling, LGD OLED bring-up, secure UFS
startup and booting Tessera from Btrfs have NOT yet been tested on this phone.
The install command is not automatically run by creating or opening the ZIP.
Never flash the SquashFS system-source.img to userdata or boot.
Never use this file as an Android fastboot update package.
""".encode()

    derived: dict[str, bytes] = {
        "installer-boot.img": installer_boot,
        "tessera-boot.img": system_boot,
        "akatsuki-install.ps1": installer_script,
        "README.txt": notice,
    }
    inputs = {"system-source.img": args.system}
    items = {
        name: {"bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()}
        for name, body in derived.items()
    }
    items.update({
        name: {"bytes": p.stat().st_size, "sha256": digest(p)}
        for name, p in inputs.items()
    })
    manifest = {
        "format": "tessera.akatsuki.fastboot-installer-candidate.v1",
        "device": "Sony Xperia XZ3 H8416 / akatsuki",
        "architecture": "arm64", "boot_header": 1, "page_size": PAGE,
        "installer": "Tessera PID1 Btrfs installer",
        "source_partition": f"system_{target_slot}", "target_partition": "userdata",
        "target_fs": "btrfs", "overwrite_userdata": "explicit opt-in only",
        "retained_stock_slot": args.active_slot, "boot_target_slot": target_slot,
        "system_version": version, "system_sha256": system_hash,
        "hardware_verified": False, "install_tested_on_device": False,
        "android_fastboot_update_zip": False,
        "boot_partition_capacity_reported": MAX_BOOT,
        "ufs_discard_blocked_in_kernel_source": True,
        "ufs_scsi_destructive_commands_blocked": True,
        "files": items,
    }
    derived["MANIFEST.json"] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    for name, body in derived.items():
        items[name] = {"bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()}
    derived["SHA256SUMS"] = "".join(
        f"{items[name]['sha256']}  {name}\n" for name in sorted(items)
    ).encode()

    output = args.output
    checksum = Path(str(output) + ".sha256")
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() or checksum.exists():
        raise InstallImageError("output already exists; refusing to overwrite")
    with tempfile.NamedTemporaryFile(prefix=".tessera-xz3-install-", suffix=".zip",
                                      dir=output.parent, delete=False) as temp:
        temporary = Path(temp.name)
    try:
        with ZipFile(temporary, "w", allowZip64=True) as archive:
            for name in sorted(set(derived) | set(inputs)):
                info = ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                info.compress_type = ZIP_STORED
                if name in inputs:
                    archive.write(inputs[name], arcname=name, compress_type=ZIP_STORED)
                else:
                    archive.writestr(info, derived[name])
        with ZipFile(temporary) as check:
            if check.testzip() is not None:
                raise InstallImageError("installer ZIP failed CRC verification")
        summary = digest(temporary)
        os.link(temporary, output)
        checksum.write_text(f"{summary}  {output.name}\n")
    finally:
        temporary.unlink(missing_ok=True)
    return output


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    for name, default in (
        ("kernel", KERNEL), ("dtb", DTB), ("config", CONFIG),
        ("installer", INSTALLER), ("initramfs", INITRAMFS),
        ("system", SYSTEM), ("recovery", RECOVERY),
        ("boot-reference", BOOT_REFERENCE), ("output", OUTPUT),
    ):
        p.add_argument("--" + name, type=Path, default=default)
    p.add_argument("--active-slot", choices=("a", "b"), default="b")
    args = p.parse_args()
    try:
        artifact = build(args)
    except (InstallImageError, OSError, ValueError) as error:
        p.exit(1, f"error: {error}\n")
    print(f"Built Xperia XZ3 Btrfs fastboot installer candidate: {artifact}")
    print(f"SHA-256: {digest(artifact)}")
    print("Requires hardware bring-up before actual partition flash.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
