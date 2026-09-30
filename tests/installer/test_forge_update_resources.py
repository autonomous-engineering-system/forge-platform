"""Fixed signed-app sibling resource admission for the isolated product worker."""

from __future__ import annotations

from hashlib import sha256
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from forge_platform import forge_update_resources as module


class ForgeUpdateResourcesTests(unittest.TestCase):
    def test_exact_239_siblings_and_fail_closed_drift(self) -> None:
        self.assertEqual(module._FORGE_239_CONTROLLER_SOURCE,
                         "ebc43dc12da27353f85c991a26da9852aa790f05")
        self.assertEqual(module._FORGE_239_CONTROLLER_DIGEST,
                         "sha256:84bac133849c539a2bfae662234be93c3cd6583e841cae34eb27f3b21728fb87")
        self.assertEqual(module._FORGE_239_RECEIPT_DIGEST,
                         "sha256:078a9f09f048cbd1fd36c4d5f83a5739dfeb3c3a546ba94bb1148596135ba15f")
        with tempfile.TemporaryDirectory() as temporary:
            resources = Path(temporary).resolve() / "Installer.app/Contents/Resources"
            resources.mkdir(parents=True)
            worker = resources / "forge-platform-product-worker.pyz"
            controller = resources / module._FORGE_239_CONTROLLER_NAME
            receipt = resources / module._FORGE_239_RECEIPT_NAME
            worker.write_bytes(b"worker fixture")
            controller.write_bytes(b"published script fixture")
            receipt.write_bytes(b"published receipt fixture")
            controller_digest = "sha256:" + sha256(controller.read_bytes()).hexdigest()
            receipt_digest = "sha256:" + sha256(receipt.read_bytes()).hexdigest()
            metadata = {
                "CFBundleIdentifier": module._BUNDLE_IDENTIFIER,
                "ForgePlatformForge239UpdateControllerSourceRevision": module._FORGE_239_CONTROLLER_SOURCE,
                "ForgePlatformForge239UpdateControllerSHA256": controller_digest,
                "ForgePlatformForge239ReleaseSourceRevision": module._FORGE_239_CONTROLLER_SOURCE,
                "ForgePlatformForge239ReleaseCompleteSHA256": receipt_digest,
            }
            info = resources.parent / "Info.plist"
            def write_info() -> None:
                info.write_bytes(plistlib.dumps(metadata, sort_keys=True))
            write_info()
            with (
                patch.object(module, "_FORGE_239_CONTROLLER_DIGEST", controller_digest),
                patch.object(module, "_FORGE_239_RECEIPT_DIGEST", receipt_digest),
            ):
                self.assertEqual(module.read_forge_239_update_resources(worker),
                                 module.Forge239UpdateResources(controller, receipt))
                metadata["ForgePlatformForge239ReleaseSourceRevision"] = "wrong"
                write_info()
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_239_update_resources(worker)
                metadata["ForgePlatformForge239ReleaseSourceRevision"] = module._FORGE_239_CONTROLLER_SOURCE
                write_info()
                controller.write_bytes(b"changed")
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_239_update_resources(worker)
                controller.write_bytes(b"published script fixture")
                receipt.write_bytes(b"changed")
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_239_update_resources(worker)

    def test_production_binding_uses_corrected_protected_controller(self) -> None:
        self.assertEqual(module._CONTROLLER_SOURCE, "e4b99a249845a547fd6b8e7e11d22467b2d0886d")
        self.assertEqual(
            module._CONTROLLER_DIGEST,
            "sha256:6a6bb4ade3db9d1e45ba64a0d928e91013109de3243e8e2dbccfaa04a7a455b4",
        )

    def test_exact_siblings_and_fail_closed_resource_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            resources = root / "Installer.app/Contents/Resources"
            resources.mkdir(parents=True)
            worker = resources / "forge-platform-product-worker.pyz"
            controller = resources / "forge-update-controller.py"
            receipt = resources / "forge-release-complete-2.7.38.json"
            worker.write_bytes(b"worker fixture")
            controller_bytes = b"controller fixture"
            receipt_bytes = b"release receipt fixture"
            controller.write_bytes(controller_bytes)
            receipt.write_bytes(receipt_bytes)
            controller_digest = "sha256:" + sha256(controller_bytes).hexdigest()
            receipt_digest = "sha256:" + sha256(receipt_bytes).hexdigest()
            info = resources.parent / "Info.plist"
            metadata = {
                "CFBundleIdentifier": module._BUNDLE_IDENTIFIER,
                "ForgePlatformForgeUpdateControllerSourceRevision": module._CONTROLLER_SOURCE,
                "ForgePlatformForgeUpdateControllerSHA256": controller_digest,
                "ForgePlatformForgeReleaseSourceRevision": module._RELEASE_SOURCE,
                "ForgePlatformForgeReleaseCompleteSHA256": receipt_digest,
            }
            def write_info() -> None:
                info.write_bytes(plistlib.dumps(metadata, sort_keys=True))
            write_info()
            with (
                patch.object(module, "_CONTROLLER_DIGEST", controller_digest),
                patch.object(module, "_RELEASE_DIGEST", receipt_digest),
            ):
                self.assertEqual(
                    module.read_forge_update_resources(worker),
                    module.ForgeUpdateResources(controller, receipt),
                )
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_update_resources(Path("relative.pyz"))
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_update_resources(resources / "foreign.pyz")
                metadata["ForgePlatformForgeReleaseSourceRevision"] = "wrong"
                write_info()
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_update_resources(worker)
                metadata["ForgePlatformForgeReleaseSourceRevision"] = module._RELEASE_SOURCE
                write_info()
                receipt.write_bytes(receipt_bytes + b"tampered")
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_update_resources(worker)
                receipt.write_bytes(receipt_bytes)
                controller.write_bytes(controller_bytes + b"tampered")
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_update_resources(worker)
                controller.write_bytes(controller_bytes)
                receipt.chmod(0o666)
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_update_resources(worker)
                receipt.chmod(0o600)
                other = root / "other.json"
                other.write_bytes(receipt_bytes)
                receipt.unlink()
                receipt.symlink_to(other)
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_update_resources(worker)
                receipt.unlink()
                receipt.hardlink_to(other)
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_update_resources(worker)
                receipt.unlink()
                receipt.write_bytes(receipt_bytes)
                worker.unlink()
                with self.assertRaises(module.ForgeUpdateResourceError):
                    module.read_forge_update_resources(worker)


if __name__ == "__main__":
    unittest.main()
