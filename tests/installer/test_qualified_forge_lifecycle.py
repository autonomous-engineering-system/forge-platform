"""Exact Forge lifecycle producer admission across the qualified rebaseline."""

from dataclasses import replace
import unittest

from forge_platform.component_operations import QualifiedArtifact
from forge_platform.product_preserved_lifecycle import frozen_preserved_release
from forge_platform.qualified_forge_lifecycle import (
    qualified_forge_238_update_selection, qualified_forge_lifecycle_artifact,
)


class QualifiedForgeLifecycleTests(unittest.TestCase):
    def test_exact_public_wheel_update_matrix_to_238(self) -> None:
        target = QualifiedArtifact(
            "2.7.38", "0a3d6e35b01da93bb5a674ae7795558655c16c7d",
            "released-wheel",
            "sha256:e9a5609969b8e49476f44e99a6cf72b8edf60280a77e010effe55a3bc1b33af8",
            "release-complete",
        )
        sources = (
            ("2.7.35", "ff4c0d45f51161376104250cd6efcfb6f045b8ac",
             "sha256:79e7d7ef36da7c73c31981c39f4a1d90b0204965438779014fc129b79a2da2d0"),
            ("2.7.36", "ed1e623ef3cedd8c4f720510e0052409b2d5ab1f",
             "sha256:c10e9584649538f2f1547bb09fd3982cc3495dcf34ef807d66463661fdd5cd68"),
            ("2.7.37", "a78523603d6ea081d07875ea6b557e73b5d4fe63",
             "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938"),
        )
        for version, source, digest in sources:
            old = QualifiedArtifact(version, source, "released-wheel", digest, "release-complete")
            with self.subTest(version=version):
                self.assertTrue(qualified_forge_238_update_selection(old, target))
                self.assertFalse(qualified_forge_238_update_selection(
                    replace(old, digest=target.digest), target,
                ))
                self.assertFalse(qualified_forge_238_update_selection(
                    old, replace(target, source_revision=old.source_revision),
                ))
        self.assertTrue(qualified_forge_238_update_selection(target, target))
        self.assertFalse(qualified_forge_238_update_selection(None, target))

    def test_exact_237_and_238_are_admitted_without_cross_binding(self) -> None:
        old = QualifiedArtifact(
            "2.7.37", "a78523603d6ea081d07875ea6b557e73b5d4fe63",
            "released-wheel",
            "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938",
            "release-complete",
        )
        current = QualifiedArtifact(
            "2.7.38", "0a3d6e35b01da93bb5a674ae7795558655c16c7d",
            "released-wheel",
            "sha256:e9a5609969b8e49476f44e99a6cf72b8edf60280a77e010effe55a3bc1b33af8",
            "release-complete",
        )
        for artifact in (old, current):
            self.assertTrue(qualified_forge_lifecycle_artifact(artifact))
            self.assertTrue(frozen_preserved_release("forge-runtime", artifact))
        self.assertFalse(qualified_forge_lifecycle_artifact(None))
        for mismatched in (
            replace(current, version=old.version),
            replace(current, source_revision=old.source_revision),
            replace(current, digest=old.digest),
            replace(old, version="2.7.36"),
        ):
            self.assertFalse(qualified_forge_lifecycle_artifact(mismatched))
            self.assertFalse(frozen_preserved_release("forge-runtime", mismatched))


if __name__ == "__main__":
    unittest.main()
