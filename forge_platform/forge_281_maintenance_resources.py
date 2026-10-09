"""Code-sealed resources for the exact postpublication 2.7.39→2.8.1 route.

This separately delivered controller does not change the immutable Forge
2.8.1 wheel or enable its packaged historical lifecycle matrix.
"""
from __future__ import annotations

from hashlib import sha256
from pathlib import Path
import plistlib

from .forge_update_resources import ForgeUpdateResourceError, ForgeUpdateResources, _read_stable

CONTROLLER_SOURCE = "0ea8c1a263a8b71a09d1206387099b748789b04b"
CONTROLLER_SHA256 = "sha256:1b27fa4b985b3f731f4e169b56d9ca880a6aefe0acbc8f734f628ab02df9daf1"
RELEASE_SOURCE = "c8833ffa4754800de451cce94b109ef1ad07123f"
RELEASE_RECEIPT_SHA256 = "sha256:51017bb17faa3d2568e457360d54b873deddbf59eeedb86310b4cb56e1345a76"
CONTROLLER_NAME = "forge-maintenance-controller-2.8.1.py"
RECEIPT_NAME = "forge-release-complete-2.8.1.json"
METADATA = {
    "ForgePlatformForge281MaintenanceControllerSourceRevision": CONTROLLER_SOURCE,
    "ForgePlatformForge281MaintenanceControllerSHA256": CONTROLLER_SHA256,
    "ForgePlatformForge281ReleaseSourceRevision": RELEASE_SOURCE,
    "ForgePlatformForge281ReleaseCompleteSHA256": RELEASE_RECEIPT_SHA256,
}


def read_forge_281_maintenance_resources(worker: Path) -> ForgeUpdateResources:
    if (not isinstance(worker, Path) or not worker.is_absolute()
        or worker.name != "forge-platform-product-worker.pyz"
        or worker.parent.name != "Resources" or worker.parent.parent.name != "Contents"
        or worker.parent.parent.parent.suffix != ".app"):
        raise ForgeUpdateResourceError("Forge maintenance worker layout is invalid")
    _read_stable(worker, 16 * 1024 * 1024)
    try:
        metadata = plistlib.loads(_read_stable(worker.parent.parent / "Info.plist", 1024 * 1024))
    except (ValueError, TypeError) as error:
        raise ForgeUpdateResourceError("Forge maintenance app metadata is invalid") from error
    if (not isinstance(metadata, dict)
        or metadata.get("CFBundleIdentifier") != "com.autonomous-engineering-system.forge-platform-installer"
        or any(metadata.get(key) != value for key, value in METADATA.items())):
        raise ForgeUpdateResourceError("Forge maintenance source bindings changed")
    controller = worker.parent / CONTROLLER_NAME
    receipt = worker.parent / RECEIPT_NAME
    for path, expected, maximum in ((controller, CONTROLLER_SHA256, 512 * 1024),
                                    (receipt, RELEASE_RECEIPT_SHA256, 64 * 1024)):
        if "sha256:" + sha256(_read_stable(path, maximum)).hexdigest() != expected:
            raise ForgeUpdateResourceError("Forge maintenance sealed resource bytes changed")
    return ForgeUpdateResources(controller, receipt)
