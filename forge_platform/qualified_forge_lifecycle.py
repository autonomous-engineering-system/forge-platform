"""Exact released Forge artifacts admitted by the instance lifecycle routes.

Historical installed 2.7.37 instances remain addressable while new managed
deployments select the separately qualified 2.7.38 producer. Version alone
never grants lifecycle authority.
"""

from __future__ import annotations

from .component_operations import QualifiedArtifact


FORGE_LIFECYCLE_RELEASES = frozenset({
    (
        "2.7.37",
        "a78523603d6ea081d07875ea6b557e73b5d4fe63",
        "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938",
    ),
    (
        "2.7.38",
        "0a3d6e35b01da93bb5a674ae7795558655c16c7d",
        "sha256:e9a5609969b8e49476f44e99a6cf72b8edf60280a77e010effe55a3bc1b33af8",
    ),
})


def qualified_forge_lifecycle_artifact(artifact: QualifiedArtifact | None) -> bool:
    """Admit only a complete exact immutable version/source/wheel binding."""
    return isinstance(artifact, QualifiedArtifact) and (
        artifact.version, artifact.source_revision, artifact.digest
    ) in FORGE_LIFECYCLE_RELEASES
