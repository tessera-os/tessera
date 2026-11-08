#!/usr/bin/env python3
"""Offline staging bundle tests, including unsafe DTBs and changed payloads."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import json
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parent


def load_python(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BUNDLE = load_python(ROOT / "package-akari-installer.py", "akari_installer_bundle")
DIAGNOSTIC_TEST = load_python(ROOT / "test-package-akari-diagnostic.py", "akari_diagnostic_test")
DIAGNOSTIC = load_python(ROOT / "package-akari-diagnostic.py", "akari_diagnostic")


def squashfs_fixture() -> bytes:
    superblock = bytearray(256)
    superblock[:4] = b"hsqs"
    struct.pack_into("<HH", superblock, 28, 4, 0)
    struct.pack_into("<Q", superblock, 40, len(superblock))
    return bytes(superblock)


class BundleTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="akari-installer-tests-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        kernel = bytearray(1024)
        kernel[0x38:0x3C] = b"ARM\x64"
        files = {
            "kernel": ("Image", bytes(kernel)),
            "dtb": ("akari.dtb", DIAGNOSTIC_TEST.example_dtb()),
            "config": ("akari.config", DIAGNOSTIC_TEST.ARM64_CONFIG.encode()),
            "initramfs": ("initramfs.cpio.zst", BUNDLE.ZSTD_MAGIC + b"initrd"),
            "installer": ("installer.cpio.zst", BUNDLE.ZSTD_MAGIC + b"installer"),
            "system": ("system.img", squashfs_fixture()),
            "recovery": ("recovery.img", squashfs_fixture()),
        }
        args = {}
        for label, (name, contents) in files.items():
            path = root / name
            path.write_bytes(contents)
            args[label] = path
            if label in {"initramfs", "installer", "system", "recovery"}:
                Path(str(path) + ".digest").write_text(hashlib.sha256(contents).hexdigest())
        self.output = root / "bundle.zip"
        self.args = argparse.Namespace(**args, output=self.output)
        # General bundle tests use synthetic SquashFS superblocks. The
        # integration test below checks actual SquashFS recovery extraction.
        patcher = mock.patch.object(BUNDLE, "verify_recovery_payload", return_value=None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_complete_bundle_and_manifest(self):
        self.assertEqual(BUNDLE.package(self.args), self.output)
        with ZipFile(self.output) as archive:
            self.assertIsNone(archive.testzip())
            manifest = json.loads(archive.read("MANIFEST.json"))
            self.assertEqual(manifest["kernel_profile"], "akari")
            self.assertFalse(manifest["flashable"])
            self.assertFalse(manifest["ufs_enabled"])
            self.assertFalse(manifest["boot_tested_on_device"])
            self.assertTrue(manifest["recovery_payload_matches_system"])
            self.assertEqual(manifest["volume_filesystem"], "btrfs")
            self.assertEqual(
                manifest["volume_layout"]["version"],
                hashlib.sha256(self.args.system.read_bytes()).hexdigest()[:16],
            )
            lines = archive.read("SHA256SUMS").decode().splitlines()
            self.assertEqual(len(lines), 9)
            for line in lines:
                sha, name = line.split("  ")
                self.assertEqual(hashlib.sha256(archive.read(name)).hexdigest(), sha)
            self.assertIn("NOT READY", archive.read("README-NOT-FLASHABLE.txt").decode())
        record, filename = Path(str(self.output) + ".sha256").read_text().strip().split("  ")
        self.assertEqual(filename, "bundle.zip")
        self.assertEqual(record, BUNDLE.digest_file(self.output))

    def test_rejects_unsafe_kernel_without_creating_bundle(self):
        self.args.config.write_text(DIAGNOSTIC_TEST.ARM64_CONFIG.replace(
            "# CONFIG_SCSI_UFSHCD is not set", "CONFIG_SCSI_UFSHCD=y"
        ))
        with self.assertRaisesRegex(BUNDLE.BundleError, "unsafe"):
            BUNDLE.package(self.args)
        self.assertFalse(self.output.exists())

    def test_rejects_enabled_ufs_device_tree(self):
        self.args.dtb.write_bytes(DIAGNOSTIC_TEST.example_dtb(ufs=b"okay\0"))
        with self.assertRaisesRegex(BUNDLE.BundleError, "ufshc"):
            BUNDLE.package(self.args)
        self.assertFalse(self.output.exists())

    def test_rejects_changed_system_without_republishing(self):
        self.args.system.write_bytes(squashfs_fixture() + b"extra")
        with self.assertRaisesRegex(BUNDLE.BundleError, "digest"):
            BUNDLE.package(self.args)
        self.assertFalse(self.output.exists())

    def test_rejects_bad_recovery_superblock(self):
        self.args.recovery.write_bytes(b"not a squashfs image")
        with self.assertRaisesRegex(BUNDLE.BundleError, "SquashFS"):
            BUNDLE.package(self.args)
        self.assertFalse(self.output.exists())

    def test_does_not_overwrite_existing_bundle(self):
        self.output.write_text("existing")
        with self.assertRaisesRegex(BUNDLE.BundleError, "overwrite"):
            BUNDLE.package(self.args)
        self.assertEqual(self.output.read_text(), "existing")

    def test_does_not_overwrite_preexisting_checksum(self):
        checksum = Path(str(self.output) + ".sha256")
        checksum.write_text("existing")
        with self.assertRaisesRegex(BUNDLE.BundleError, "overwrite"):
            BUNDLE.package(self.args)
        self.assertFalse(self.output.exists())
        self.assertEqual(checksum.read_text(), "existing")


class RecoveryPayloadTest(unittest.TestCase):
    def test_embedded_system_must_match_published_image(self):
        maker = shutil.which("mksquashfs") or "/opt/homebrew/opt/squashfs/bin/mksquashfs"
        if not Path(maker).is_file():
            self.skipTest("requires mksquashfs")
        with tempfile.TemporaryDirectory(prefix="akari-recovery-validation-") as temp:
            root = Path(temp)
            system = root / "system.img"
            system_tree = root / "system-root"
            system_tree.mkdir()
            (system_tree / "composefs.img").write_bytes(b"sealed system")
            (system_tree / "composefs.sig").write_bytes(b"system signature")
            result = subprocess.run(
                [maker, str(system_tree), str(system), "-noappend", "-quiet"],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            files = root / "tree"
            (files / "System/Installation").mkdir(parents=True)
            (files / "bin").mkdir()
            (files / "System/Installation/system.img").write_bytes(system.read_bytes())
            (files / "System/Installation/system.digest").write_bytes(bytes(32))
            (files / "bin/installer").write_bytes(b"installer executable")
            (files / "composefs.img").write_bytes(b"sealed recovery image")
            (files / "composefs.sig").write_bytes(b"signature")
            recovery = root / "recovery.img"
            result = subprocess.run(
                [maker, str(files), str(recovery), "-noappend", "-quiet"],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = hashlib.sha256(system.read_bytes()).hexdigest()
            BUNDLE.verify_recovery_payload(system, recovery, expected)
            system.write_bytes(system.read_bytes() + b"changed")
            with self.assertRaisesRegex(BUNDLE.BundleError, "different system.img"):
                BUNDLE.verify_recovery_payload(system, recovery, hashlib.sha256(system.read_bytes()).hexdigest())


class AndroidBootCandidateTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="akari-boot-validation-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.kernel = root / "Image"
        contents = bytearray(2048)
        contents[0x38:0x3C] = b"ARM\x64"
        self.kernel.write_bytes(contents)
        self.dtb = root / "akari.dtb"
        self.dtb.write_bytes(DIAGNOSTIC_TEST.example_dtb())
        self.initramfs = root / "initramfs.zst"
        self.initramfs.write_bytes(BUNDLE.ZSTD_MAGIC + b"example data")
        packed_kernel = gzip.compress(bytes(contents), mtime=0) + self.dtb.read_bytes()
        self.boot = root / "boot.img"
        self.boot.write_bytes(DIAGNOSTIC.android_v1_boot(packed_kernel, self.initramfs.read_bytes()))

    def check(self):
        BUNDLE.check_boot_candidate(self.boot, self.kernel, self.dtb, self.initramfs)

    def test_accepts_matched_kernel_dtb_and_initramfs(self):
        self.check()

    def test_rejects_modified_kernel(self):
        self.kernel.write_bytes(self.kernel.read_bytes() + b"changed")
        with self.assertRaisesRegex(BUNDLE.BundleError, "kernel/DTB differs"):
            self.check()

    def test_rejects_modified_initramfs(self):
        self.initramfs.write_bytes(self.initramfs.read_bytes() + b"changed")
        with self.assertRaisesRegex(BUNDLE.BundleError, "initramfs differs"):
            self.check()

    def test_rejects_tampered_android_image_id(self):
        data = bytearray(self.boot.read_bytes())
        data[576] ^= 0x01
        self.boot.write_bytes(data)
        with self.assertRaisesRegex(BUNDLE.BundleError, "ID is invalid"):
            self.check()


if __name__ == "__main__":
    unittest.main()