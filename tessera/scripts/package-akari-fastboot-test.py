#!/usr/bin/env python3
"""Build a guarded Xperia XZ2 (akari) fastboot *boot-test* ZIP.

The existing experimental UFS kernel has not been proven safe to boot. This
utility disables both UFS nodes in its device tree for the initial hardware
test without changing the kernel or Adreno firmware. A boot-test archive is
NOT an Android OTA or `fastboot update` archive, and it cannot install Tessera.

No phone is accessed; no partitions are written.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_STORED

HERE = Path(__file__).resolve().parent
OUT = Path.home() / ".tessera-build/out"
DEFAULT_BOOT = OUT / "aarch64/akari-ufs-gpu-boot-nodiscard-candidate/EXPERIMENTAL-UFS-NOT-FLASHABLE-boot.img"
SOURCE_DTB = OUT / "aarch64/kernel/akari/arch/arm64/boot/dts/qcom/sdm845-sony-xperia-tama-akari.dtb"
SOURCE_KERNEL = OUT / "aarch64/kernel/akari/arch/arm64/boot/Image"
SAFE_KERNEL = OUT / "aarch64/kernel/akari-ramboot-ufs-off/arch/arm64/boot/Image"
SAFE_CONFIG = OUT / "aarch64/kernel/akari-ramboot-ufs-off/.config"
SOURCE_INITRAMFS = OUT / "initramfs/initramfs.cpio.zst"
DEFAULT_OUTPUT = OUT / "Tessera-XZ2-akari-FASTBOOT-RAM-TEST-UFS-OFF-20261107.zip"


class FastbootBundleError(ValueError):
    pass


def load_script(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise FastbootBundleError(f"cannot load local validation script {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def dtc_binary(default_kernel: Path) -> str:
    candidate = default_kernel.parents[3] / "scripts/dtc/dtc"
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    found = shutil.which("dtc")
    if found:
        return found
    raise FastbootBundleError("the Linux host dtc compiler is missing")


def safe_dtb(source: bytes, dtc: str) -> bytes:
    """Disable two named nodes; do not touch the DTBO or any other firmware."""
    with tempfile.TemporaryDirectory(prefix="akari-safe-dtb-") as temporary:
        root = Path(temporary)
        original = root / "original.dtb"
        modified = root / "safe.dts"
        compiled = root / "safe.dtb"
        original.write_bytes(source)
        result = subprocess.run(
            [dtc, "-I", "dtb", "-O", "dts", str(original)],
            capture_output=True, check=False,
        )
        if result.returncode:
            raise FastbootBundleError("cannot decompile original Akari DTB")
        text = result.stdout.decode("utf-8")
        for node in ("ufshc@1d84000", "phy@1d87000"):
            # Constrain the substitution to the direct properties of the
            # selected node, not a peripheral below it or a similar string.
            begin = re.search(r"\b" + re.escape(node) + r"\s*\{", text)
            if begin is None:
                raise FastbootBundleError(f"Akari node not found: {node}")
            depth, end = 1, begin.end()
            while end < len(text) and depth:
                if text[end] == "{":
                    depth += 1
                elif text[end] == "}":
                    depth -= 1
                end += 1
            if depth:
                raise FastbootBundleError(f"unterminated Akari node: {node}")
            block = text[begin.end():end - 1]
            patched, count = re.subn(
                r'(?m)^(\s*status\s*=\s*)"okay"(\s*;)',
                r'\1"disabled"\2', block, count=1,
            )
            if count != 1:
                raise FastbootBundleError(f"cannot safely disable {node}")
            text = text[:begin.end()] + patched + text[end - 1:]

        modified.write_text(text, encoding="utf-8")
        result = subprocess.run(
            [dtc, "-I", "dts", "-O", "dtb", "-o", str(compiled), str(modified)],
            capture_output=True, check=False,
        )
        if result.returncode:
            raise FastbootBundleError(
                "cannot compile UFS-disabled DTB: " + result.stderr.decode(errors="replace")[-500:]
            )
        return compiled.read_bytes()


def info(name: str) -> ZipInfo:
    zi = ZipInfo(name, (1980, 1, 1, 0, 0, 0))
    zi.compress_type = ZIP_STORED
    zi.create_system = 3
    zi.external_attr = (0o100644 if not name.endswith(".sh") else 0o100755) << 16
    return zi


def package(args: argparse.Namespace) -> Path:
    diag = load_script(HERE / "package-akari-diagnostic.py", "akari_diagnostic")
    ins = load_script(HERE / "package-akari-installer.py", "akari_installer")
    device = getattr(args, "device", "akari")
    if device not in ("akari", "akatsuki"):
        raise FastbootBundleError("only Sony Tama akari and akatsuki are supported")
    required = [args.kernel, args.safe_kernel, args.safe_config, args.dtb, args.initramfs]
    if device == "akari":
        required.append(args.unsafe_candidate)
    for source in required:
        if not source.is_file() or source.is_symlink():
            raise FastbootBundleError(f"missing or symbolic-link build input: {source}")
    kernel = args.kernel.read_bytes()
    safe_kernel = args.safe_kernel.read_bytes()
    safe_config = args.safe_config.read_text()
    dtb = args.dtb.read_bytes()
    ramdisk = args.initramfs.read_bytes()
    diag.check_dtb(dtb, experimental_ufs=True, device=device)
    if kernel[0x38:0x3c] != b"ARM\x64" or ramdisk[:4] != b"\x28\xb5\x2f\xfd":
        raise FastbootBundleError("incorrect kernel or ramdisk format")
    if safe_kernel[0x38:0x3c] != b"ARM\x64" or safe_kernel == kernel:
        raise FastbootBundleError("safe kernel is missing or identical to the UFS-enabled kernel")
    for requirement in (
        "# CONFIG_SCSI_UFSHCD is not set", "# CONFIG_PHY_QCOM_QMP_UFS is not set"
    ):
        if requirement not in safe_config.splitlines():
            raise FastbootBundleError(f"safe kernel is missing the verified option {requirement}")
    if device == "akari":
        ins.check_boot_candidate(args.unsafe_candidate, args.kernel, args.dtb, args.initramfs)

    dtc = dtc_binary(args.kernel)
    safe_tree = safe_dtb(dtb, dtc)
    if safe_tree == dtb:
        raise FastbootBundleError("safe and unsafe UFS trees must differ")
    diag.check_dtb(safe_tree, experimental_ufs=False, device=device)

    import gzip
    physical_ramdisk = 0x08000000 if device == "akatsuki" else 0x01000000
    boot = diag.android_v1_boot(
        gzip.compress(safe_kernel, mtime=0) + safe_tree, ramdisk,
        device=device, ramdisk_address=physical_ramdisk
    )
    if len(boot) > 0x4000000:
        raise FastbootBundleError("boot image exceeds Sony's reported 64 MiB limit")
    # Compare exact kernel, DTB and ramdisk by the existing Android v1 parser.
    with tempfile.TemporaryDirectory(prefix="akari-safe-boot-") as temporary:
        safe_file = Path(temporary) / "safe.dtb"
        boot_file = Path(temporary) / "boot.img"
        safe_file.write_bytes(safe_tree)
        boot_file.write_bytes(boot)
        ins.check_boot_candidate(
            boot_file, args.safe_kernel, safe_file, args.initramfs,
            expected_ramdisk_address=physical_ramdisk
        )

    probe_script = (HERE / "probe-akari-device.sh").read_bytes() if device == "akari" else None
    boot_script = (HERE / f"{device}-boot-once.sh").read_bytes()
    if device == "akari":
        title, description, models = (
            "Xperia XZ2", "regular XZ2 LCD", "H8216/H8266/H8276/H8296"
        )
    else:
        title, description, models = (
            "Xperia XZ3", "XZ3 OLED (upstream mainline panel driver is unproven)", "H8416/H9436/H9493"
        )
    notice = f"""TESSERA {title.upper()} ({device}) — FASTBOOT BOOT TEST ONLY

THIS ZIP IS NOT A FLASHABLE TESSERA INSTALLER OR 'fastboot update' PACKAGE.
Do not run `fastboot update` or `fastboot flash` on this ZIP.
This ZIP does not include android-info.txt or Android system.img intentionally.

boot-test-ufs-disabled.img is an Android v1 boot image containing a specially
recompiled Linux 7.2 kernel with the Qualcomm UFS host driver and PHY driver
DISABLED, an {title} DTB with BOTH UFS nodes disabled, and Tessera's
initramfs with Sony-specific Adreno 630 firmware. The original bootloader's
DTBO cannot re-enable a driver absent from this kernel. This image therefore
cannot install or mount Tessera on internal UFS. It is for supervised,
non-persistent initial bootloader/display bring-up only.

Before any test: connect ONE unlocked {title} and verify its model, serial,
boot partition size, active slot, stock firmware and a recovery path. Run
the read-only device probe. If verified, `{device}-boot-once.sh` tries a RAM boot
with `fastboot boot` and DOES NOT flash, format, switch slots, or wipe data.
The Sony bootloader may reject the command or mainline device-tree handling.
The {description} and touch functionality have not been validated on hardware.
For XZ3 the ramdisk loads at 128 MiB: a 96 MiB decompressed kernel cannot
share the original 16 MiB Sony ramdisk offset without memory corruption.

The UFS-enabled Tessera build was intentionally NOT included. Sony's original
UFS warning says even probing UFS without card quirks may permanently erase
the bootloader. A September 2026 UFS device-tree proposal does not replace
device-specific verification. Do not boot the experimental UFS-on image.

The full Tessera system/recovery images live in the separately checked offline
installer bundle. Tessera's SquashFS system.img is NOT an Android fastboot
system partition image. Never use `fastboot flash system` on it.
"""
    content: dict[str, bytes] = {
        "boot-test-ufs-disabled.img": boot,
        f"dtb/{device}-ufs-disabled.dtb": safe_tree,
        f"kernel/{device}-ufs-disabled.config": safe_config.encode(),
        f"{device}-boot-once.sh": boot_script,
        "README-NOT-FLASHABLE.txt": notice.encode("utf-8"),
    }
    if probe_script is not None:
        content["probe-device.sh"] = probe_script
    if device == "akatsuki":
        content["akatsuki-preflight.ps1"] = (HERE / "akatsuki-preflight.ps1").read_bytes()
    metadata = {
        "device": f"Sony {title} {device} ({models})",
        "purpose": "read-only fastboot preflight and temporary RAM boot test",
        "flashable": False,
        "android_fastboot_update": False,
        "ufs_enabled_in_device_tree": False,
        "ufs_driver_present_but_not_probed": False,
        "ufs_driver_disabled_at_compile_time": True,
        "gpu_firmware_source": "Sony Tama firmware staged in Tessera zstd initramfs",
        "boot_tested_on_device": False,
        "boot_partition_size_measured": False,
        "unsafe_ufs_candidate_excluded": True,
        "files": {name: {"bytes": len(data), "sha256": sha(data)} for name, data in content.items()},
    }
    content["MANIFEST.json"] = (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode()
    content["SHA256SUMS"] = "".join(
        f"{sha(content[name])}  {name}\n" for name in sorted(content) if name != "SHA256SUMS"
    ).encode()

    output = args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    sidecar = Path(str(output) + ".sha256")
    if output.exists() or sidecar.exists():
        raise FastbootBundleError("refusing overwrite of existing archive or checksum")
    with tempfile.NamedTemporaryFile(
        prefix=".akari-fastboot-", suffix=".zip", dir=output.parent, delete=False
    ) as temp:
        temporary_path = Path(temp.name)
    try:
        with ZipFile(temporary_path, "w", allowZip64=True) as zipout:
            for name in sorted(content):
                zipout.writestr(info(name), content[name])
        with ZipFile(temporary_path) as check:
            if check.testzip() is not None:
                raise FastbootBundleError("ZIP CRC verification failed")
        archive_sha = hashlib.sha256(temporary_path.read_bytes()).hexdigest()
        os.link(temporary_path, output)
        sidecar.write_text(f"{archive_sha}  {output.name}\n", encoding="ascii")
    finally:
        temporary_path.unlink(missing_ok=True)
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", type=Path, default=SOURCE_KERNEL)
    parser.add_argument("--device", choices=("akari", "akatsuki"), default="akari")
    parser.add_argument("--safe-kernel", type=Path, default=SAFE_KERNEL)
    parser.add_argument("--safe-config", type=Path, default=SAFE_CONFIG)
    parser.add_argument("--dtb", type=Path, default=SOURCE_DTB)
    parser.add_argument("--initramfs", type=Path, default=SOURCE_INITRAMFS)
    parser.add_argument("--unsafe-candidate", type=Path, default=DEFAULT_BOOT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    try:
        produced = package(args)
    except (FastbootBundleError, OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
    print(f"Fastboot temporary boot-test ZIP: {produced}")
    print(f"SHA256: {hashlib.sha256(produced.read_bytes()).hexdigest()}")
    print("NOT FLASHABLE. UFS deliberately disabled for first-device bring-up.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())