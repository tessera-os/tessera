#!/usr/bin/env python3
"""Exercise the real packager with small synthetic inputs; never touch a device."""

from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest


class UsbBootContract(unittest.TestCase):
    def test_both_odin_archives_allow_an_empty_removable_lun(self):
        scripts = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(prefix="dm2q-package-test-", dir=scripts) as scratch:
            root = Path(scratch)
            kernel = bytearray(64)
            kernel[0x38:0x3C] = b"ARM\x64"
            (root / "Image").write_bytes(kernel)
            (root / "initramfs.zst").write_bytes(subprocess.run(
                ["zstd", "-q", "-c"], input=b"synthetic initramfs", check=True,
                capture_output=True,
            ).stdout)
            (root / "system.img").write_bytes(b"hsqs" + bytes(4092))
            (root / "device.dtb").write_bytes(struct.pack(">I", 0xD00DFEED) + bytes(60))
            output = root / "out"
            output.mkdir()
            command = [
                "python3", str(scripts / "package-dm2q-odin.py"),
                "--kernel", str(root / "Image"),
                "--initramfs", str(root / "initramfs.zst"),
                "--installer-initramfs", str(root / "initramfs.zst"),
                "--system-image", str(root / "system.img"),
                "--dtb", str(root / "device.dtb"),
                "--out-dir", str(output),
            ]
            for partition in ("boot", "init-boot", "cache", "vendor-boot", "dtbo"):
                command.extend([f"--{partition}-partition-bytes", "16777216"])
            subprocess.run(command, check=True, capture_output=True)
            for kind in ("system", "install"):
                with self.subTest(kind=kind):
                    with tarfile.open(output / f"Tessera-SM-S916B-{kind}.tar") as archive:
                        boot = archive.extractfile("boot.img").read()
                    self.assertEqual(boot[:8], b"ANDROID!")
                    arguments = boot[44:1580].split(b"\0", 1)[0].decode("ascii").split()
                    kernel_arguments = arguments[:arguments.index("--")]
                    self.assertIn("g_multi.removable=1", kernel_arguments)
                    self.assertFalse(any(arg.startswith("g_multi.file=") for arg in kernel_arguments))
                    if kind == "system":
                        self.assertIn("tessera.dev", arguments[arguments.index("--") + 1:])


if __name__ == "__main__":
    unittest.main()
