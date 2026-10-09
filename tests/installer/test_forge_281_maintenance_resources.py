"""Resource-boundary fixtures; these do not qualify a signed installation."""
from hashlib import sha256
from pathlib import Path
import os
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from forge_platform import forge_281_maintenance_resources as module


class Forge281MaintenanceResourceTests(unittest.TestCase):
    def test_exact_separate_source_and_immutable_receipt_pins(self):
        self.assertEqual(module.CONTROLLER_SOURCE, "0ea8c1a263a8b71a09d1206387099b748789b04b")
        self.assertEqual(module.CONTROLLER_SHA256,
            "sha256:1b27fa4b985b3f731f4e169b56d9ca880a6aefe0acbc8f734f628ab02df9daf1")
        self.assertEqual(module.RELEASE_SOURCE, "c8833ffa4754800de451cce94b109ef1ad07123f")
        self.assertEqual(module.RELEASE_RECEIPT_SHA256,
            "sha256:51017bb17faa3d2568e457360d54b873deddbf59eeedb86310b4cb56e1345a76")

    def test_physical_sibling_admission_and_byte_metadata_path_drift(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            resources = Path(temporary) / "Installer.app/Contents/Resources"
            resources.mkdir(parents=True)
            worker = resources / "forge-platform-product-worker.pyz"
            controller = resources / module.CONTROLLER_NAME
            receipt = resources / module.RECEIPT_NAME
            worker.write_bytes(b"worker fixture")
            controller_bytes, receipt_bytes = b"controller fixture", b"receipt fixture"
            controller.write_bytes(controller_bytes); receipt.write_bytes(receipt_bytes)
            expected_controller = "sha256:" + sha256(controller_bytes).hexdigest()
            expected_receipt = "sha256:" + sha256(receipt_bytes).hexdigest()
            metadata = dict(module.METADATA, CFBundleIdentifier="com.autonomous-engineering-system.forge-platform-installer")
            info = resources.parent / "Info.plist"
            info.write_bytes(plistlib.dumps(metadata))
            with patch.object(module, "CONTROLLER_SHA256", expected_controller), \
                 patch.object(module, "RELEASE_RECEIPT_SHA256", expected_receipt):
                admitted = module.read_forge_281_maintenance_resources(worker)
                self.assertEqual(admitted.controller, controller)
                self.assertEqual(admitted.release_receipt, receipt)
                for path, original in ((controller, controller_bytes), (receipt, receipt_bytes)):
                    path.write_bytes(b"changed")
                    with self.assertRaises(module.ForgeUpdateResourceError): module.read_forge_281_maintenance_resources(worker)
                    path.write_bytes(original)
                metadata["ForgePlatformForge281MaintenanceControllerSourceRevision"] = "0" * 40
                info.write_bytes(plistlib.dumps(metadata))
                with self.assertRaises(module.ForgeUpdateResourceError): module.read_forge_281_maintenance_resources(worker)
                info.write_bytes(b"invalid plist")
                with self.assertRaises(module.ForgeUpdateResourceError): module.read_forge_281_maintenance_resources(worker)
                metadata = dict(module.METADATA, CFBundleIdentifier="com.autonomous-engineering-system.forge-platform-installer")
                info.write_bytes(plistlib.dumps(metadata))
                controller.chmod(0o666)
                with self.assertRaises(module.ForgeUpdateResourceError): module.read_forge_281_maintenance_resources(worker)
                controller.chmod(0o644)
                duplicate = controller.with_name("duplicate")
                os.link(controller, duplicate)
                with self.assertRaises(module.ForgeUpdateResourceError): module.read_forge_281_maintenance_resources(worker)
                duplicate.unlink()
                controller.unlink(); controller.symlink_to(receipt)
                with self.assertRaises(module.ForgeUpdateResourceError): module.read_forge_281_maintenance_resources(worker)
            with self.assertRaises(module.ForgeUpdateResourceError): module.read_forge_281_maintenance_resources(Path("relative.pyz"))
