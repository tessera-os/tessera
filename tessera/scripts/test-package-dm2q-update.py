#!/usr/bin/env python3
"""Exercise the native update packager with synthetic inputs; never touch a device."""

from pathlib import Path
import hashlib
import struct
import subprocess
import tempfile
import unittest


class NativeUpdatePackage(unittest.TestCase):
    def test_outputs_five_images_and_a_verified_manifest(self):
        scripts = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(prefix="dm2q-update-test-", dir=scripts) as scratch:
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
                "python3", str(scripts / "package-dm2q-update.py"),
                "--kernel", str(root / "Image"),
                "--initramfs", str(root / "initramfs.zst"),
                "--system-image", str(root / "system.img"),
                "--dtb", str(root / "device.dtb"),
                "--out-dir", str(output),
            ]
            for partition in ("boot", "init-boot", "vendor-boot", "dtbo"):
                command.extend([f"--{partition}-partition-bytes", "16777216"])
            command.extend(["--system-partition-bytes", "16777216"])
            completed = subprocess.run(command, check=True, capture_output=True, text=True)
            self.assertNotIn("Odin", completed.stdout)

            names = ["boot.img", "init_boot.img", "vendor_boot.img", "dtbo.img", "system.img"]
            lines = (output / "SHA256SUMS").read_text().splitlines()
            self.assertEqual(len(lines), len(names))
            for index, name in enumerate(names):
                digest, listed_name = lines[index].split("  ", 1)
                contents = (output / name).read_bytes()
                self.assertEqual(listed_name, name)
                self.assertEqual(digest, hashlib.sha256(contents).hexdigest())

            boot = (output / "boot.img").read_bytes()
            self.assertEqual(boot[:8], b"ANDROID!")
            arguments = boot[44:1580].split(b"\0", 1)[0].decode("ascii").split()
            separator = arguments.index("--")
            kernel_arguments = arguments[:separator]
            self.assertIn("g_multi.removable=1", kernel_arguments)
            self.assertFalse(any(arg.startswith("samsung_sec_log.hold=") for arg in kernel_arguments))
            self.assertFalse(any(arg.startswith("g_multi.file=") for arg in kernel_arguments))
            self.assertIn("tessera.system", arguments[separator + 1:])
            self.assertEqual((output / "vendor_boot.img").read_bytes()[:8], b"VNDRBOOT")
            self.assertEqual((output / "dtbo.img").read_bytes(), bytes(4096))
            self.assertEqual((output / "system.img").read_bytes()[:4], b"hsqs")
            self.assertEqual({path.name for path in output.iterdir()}, set(names + ["SHA256SUMS"]))

            too_small = root / "too-small"
            too_small.mkdir()
            undersized_command = list(command)
            undersized_command[undersized_command.index("--system-partition-bytes") + 1] = "4095"
            undersized_command[undersized_command.index("--out-dir") + 1] = str(too_small)
            rejected = subprocess.run(
                undersized_command,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("over the supplied partition capacity", rejected.stderr)
            self.assertEqual(list(too_small.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
