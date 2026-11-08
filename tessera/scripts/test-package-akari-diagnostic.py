#!/usr/bin/env python3
"""Tests for offline Xperia XZ2 image construction and safety checks."""

from __future__ import annotations

import hashlib
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().with_name("package-akari-diagnostic.py")
ARM64_CONFIG = "\n".join((
    "CONFIG_ARM64_4K_PAGES=y", "CONFIG_DRM_MSM=y",
    "CONFIG_DRM_PANEL_SONY_TD4353_JDI=y", "CONFIG_BLK_DEV_INITRD=y",
    "CONFIG_RD_ZSTD=y", "CONFIG_DEVTMPFS=y", "CONFIG_MMC_BLOCK=y",
    "CONFIG_MMC_SDHCI_MSM=y", "CONFIG_BTRFS_FS=y", "# CONFIG_COMPAT is not set",
    "# CONFIG_SCSI_UFSHCD is not set", "# CONFIG_PHY_QCOM_QMP_UFS is not set",
)) + "\n"
ARM64_UFS_CONFIG = ARM64_CONFIG.replace(
    "# CONFIG_SCSI_UFSHCD is not set",
    "\n".join((
        "CONFIG_SCSI_UFSHCD=y", "CONFIG_SCSI_UFSHCD_PLATFORM=y",
        "CONFIG_SCSI_UFS_QCOM=y", "# CONFIG_SCSI_UFS_BSG is not set",
    )),
).replace("# CONFIG_PHY_QCOM_QMP_UFS is not set", "CONFIG_PHY_QCOM_QMP_UFS=y")


def example_dtb(*, model: bytes = b"sony,akari-row\0", ufs: bytes = b"disabled\0",
                phy: bytes = b"disabled\0", sd: bytes = b"okay\0",
                ufs_supplies: bool = False) -> bytes:
    """Valid minimal FDT with the Xperia storage nodes and real status properties."""
    propnames = (
        b"compatible\0status\0reset-gpios\0vcc-supply\0vcc-max-microamp\0"
        b"vdda-phy-supply\0vdda-pll-supply\0"
    )
    structure = bytearray()

    def token(value: int) -> None:
        structure.extend(struct.pack(">I", value))

    def begin(name: str) -> None:
        token(1)
        value = name.encode("ascii") + b"\0"
        structure.extend(value + b"\0" * ((-len(value)) % 4))

    def prop(nameoff: int, data: bytes) -> None:
        token(3)
        structure.extend(struct.pack(">II", len(data), nameoff))
        structure.extend(data + b"\0" * ((-len(data)) % 4))

    begin("")
    prop(0, model)
    begin("soc@0")
    for node, status in (("ufshc@1d84000", ufs), ("phy@1d87000", phy),
                         ("mmc@8804000", sd)):
        begin(node)
        prop(11, status)
        if ufs_supplies and node == "ufshc@1d84000":
            prop(propnames.index(b"reset-gpios"), struct.pack(">III", 12, 150, 1))
            prop(propnames.index(b"vcc-supply"), struct.pack(">I", 13))
            prop(propnames.index(b"vcc-max-microamp"), struct.pack(">I", 600000))
        if ufs_supplies and node == "phy@1d87000":
            prop(propnames.index(b"vdda-phy-supply"), struct.pack(">I", 14))
            prop(propnames.index(b"vdda-pll-supply"), struct.pack(">I", 15))
        token(2)
    token(2)
    token(2)
    token(9)

    off_struct = 40 + 16
    off_strings = off_struct + len(structure)
    header = struct.pack(
        ">10I", 0xD00DFEED, off_strings + len(propnames), off_struct,
        off_strings, 40, 17, 16, 0, len(propnames), len(structure),
    )
    return header + bytes(16) + structure + propnames


class AkariPackageTest(unittest.TestCase):
    def setUp(self) -> None:
        self.workspace = tempfile.TemporaryDirectory(prefix="akari-package-")
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        kernel = bytearray(1024)
        kernel[0x38:0x3C] = b"ARM\x64"
        (self.root / "Image").write_bytes(kernel)
        (self.root / "akari.dtb").write_bytes(example_dtb())
        (self.root / "initramfs.zst").write_bytes(b"\x28\xb5\x2f\xfd" + bytes(200))
        (self.root / "config").write_text(ARM64_CONFIG)
        self.output = self.root / "output"

    def run_packager(self, *extra: str) -> subprocess.CompletedProcess[str]:
        args = [
            sys.executable, str(SCRIPT),
            "--kernel", str(self.root / "Image"),
            "--dtb", str(self.root / "akari.dtb"),
            "--initramfs", str(self.root / "initramfs.zst"),
            "--config", str(self.root / "config"),
            "--boot-partition-bytes", "0x4000000",
            "--out-dir", str(self.output),
        ]
        return subprocess.run(args + list(extra), capture_output=True, text=True, check=False)

    def test_header_and_sums(self) -> None:
        result = self.run_packager()
        self.assertEqual(result.returncode, 0, result.stderr)
        boot = (self.output / "DIAGNOSTIC-NOT-FLASHABLE-boot.img").read_bytes()
        self.assertEqual(boot[:8], b"ANDROID!")
        kernel_size, kern_addr, ramdisk_size, ram_addr = struct.unpack_from("<4I", boot, 8)
        self.assertEqual(kern_addr, 0x8000)
        self.assertEqual(ram_addr, 0x1000000)
        self.assertEqual(struct.unpack_from("<II", boot, 24), (0, 0))
        self.assertEqual(struct.unpack_from("<I", boot, 36)[0], 4096)
        self.assertEqual(struct.unpack_from("<I", boot, 40)[0], 1)
        self.assertEqual(struct.unpack_from("<I", boot, 1644)[0], 1648)
        self.assertEqual(ramdisk_size, 204)
        self.assertEqual(boot[4096:4098], b"\x1f\x8b")
        self.assertIn(b"sony,akari-row\0", boot[4096:4096 + kernel_size])
        self.assertIn(b"tessera.adaptive-mobile", boot[64:576])
        ramdisk_offset = 4096 + ((kernel_size + 4095) // 4096) * 4096
        self.assertEqual(boot[ramdisk_offset:ramdisk_offset + 4], b"\x28\xb5\x2f\xfd")
        self.assertIn("DO NOT USE fastboot flash", (self.output / "DO-NOT-FLASH.txt").read_text())
        for line in (self.output / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ")
            self.assertEqual(hashlib.sha256((self.output / name).read_bytes()).hexdigest(), digest)
        self.assertEqual(self.run_packager().returncode, 1)  # no silent overwrite

    def test_unsafe_ufs_config_rejected_without_output(self) -> None:
        (self.root / "config").write_text(ARM64_CONFIG.replace(
            "# CONFIG_SCSI_UFSHCD is not set", "CONFIG_SCSI_UFSHCD=y"
        ))
        result = self.run_packager()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe", result.stderr)
        self.assertFalse(self.output.exists())

    def test_wrong_device_tree_rejected(self) -> None:
        (self.root / "akari.dtb").write_bytes(example_dtb(model=b"sony,akaro-row\0"))
        result = self.run_packager()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("akari", result.stderr)
        self.assertFalse(self.output.exists())

    def test_enabled_ufs_host_rejected(self) -> None:
        (self.root / "akari.dtb").write_bytes(example_dtb(ufs=b"okay\0"))
        result = self.run_packager()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ufshc@1d84000", result.stderr)
        self.assertFalse(self.output.exists())

    def test_enabled_ufs_phy_rejected(self) -> None:
        (self.root / "akari.dtb").write_bytes(example_dtb(phy=b"okay\0"))
        result = self.run_packager()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("phy@1d87000", result.stderr)
        self.assertFalse(self.output.exists())

    def test_disabled_microsd_rejected(self) -> None:
        (self.root / "akari.dtb").write_bytes(example_dtb(sd=b"disabled\0"))
        result = self.run_packager()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mmc@8804000", result.stderr)
        self.assertFalse(self.output.exists())

    def test_oversized_image_rejected(self) -> None:
        result = self.run_packager("--boot-partition-bytes", "4096")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exceeds supplied", result.stderr)
        self.assertFalse(self.output.exists())

    def test_experimental_ufs_requires_explicit_mode_and_regulators(self) -> None:
        (self.root / "config").write_text(ARM64_UFS_CONFIG)
        (self.root / "akari.dtb").write_bytes(example_dtb(
            ufs=b"okay\0", phy=b"okay\0", ufs_supplies=True
        ))
        without_opt_in = self.run_packager()
        self.assertNotEqual(without_opt_in.returncode, 0)
        self.assertIn("unsafe", without_opt_in.stderr)
        experimental = self.run_packager("--experimental-ufs")
        self.assertEqual(experimental.returncode, 0, experimental.stderr)
        candidate = self.output / "EXPERIMENTAL-UFS-NOT-FLASHABLE-boot.img"
        self.assertEqual(candidate.read_bytes()[:8], b"ANDROID!")
        self.assertIn("NOT been validated", (self.output / "DO-NOT-FLASH.txt").read_text())

    def test_experimental_ufs_rejects_missing_reset_gpio(self) -> None:
        (self.root / "config").write_text(ARM64_UFS_CONFIG)
        (self.root / "akari.dtb").write_bytes(example_dtb(
            ufs=b"okay\0", phy=b"okay\0", ufs_supplies=False
        ))
        result = self.run_packager("--experimental-ufs")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GPIO 150", result.stderr)


if __name__ == "__main__":
    unittest.main()