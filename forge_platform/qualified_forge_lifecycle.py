"""Exact released Forge artifacts admitted by the instance lifecycle routes.

Historical installed 2.7.37/2.7.38 instances remain addressable while the
installer reconciles the separately published 2.7.39 producer. This exact
artifact admission alone does not grant update execution or publication.
Version alone never grants lifecycle authority.
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
    (
        "2.7.39",
        "ebc43dc12da27353f85c991a26da9852aa790f05",
        "sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1",
    ),
})

FORGE_238_UPDATE_SOURCES = frozenset({
    (
        "2.7.35",
        "ff4c0d45f51161376104250cd6efcfb6f045b8ac",
        "sha256:79e7d7ef36da7c73c31981c39f4a1d90b0204965438779014fc129b79a2da2d0",
    ),
    (
        "2.7.36",
        "ed1e623ef3cedd8c4f720510e0052409b2d5ab1f",
        "sha256:c10e9584649538f2f1547bb09fd3982cc3495dcf34ef807d66463661fdd5cd68",
    ),
    (
        "2.7.37",
        "a78523603d6ea081d07875ea6b557e73b5d4fe63",
        "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938",
    ),
})


def qualified_forge_lifecycle_artifact(artifact: QualifiedArtifact | None) -> bool:
    """Admit only a complete exact immutable version/source/wheel binding."""
    return isinstance(artifact, QualifiedArtifact) and (
        artifact.version, artifact.source_revision, artifact.digest
    ) in FORGE_LIFECYCLE_RELEASES


def qualified_forge_238_update_selection(
    installed: QualifiedArtifact, candidate: QualifiedArtifact,
) -> bool:
    """Bind the exact public-wheel source and target matrix from #142 r25."""
    if not isinstance(installed, QualifiedArtifact) or not isinstance(candidate, QualifiedArtifact):
        return False
    selected = (installed.version, installed.source_revision, installed.digest)
    target = (candidate.version, candidate.source_revision, candidate.digest)
    current = (
        "2.7.38", "0a3d6e35b01da93bb5a674ae7795558655c16c7d",
        "sha256:e9a5609969b8e49476f44e99a6cf72b8edf60280a77e010effe55a3bc1b33af8",
    )
    return target == current and (selected in FORGE_238_UPDATE_SOURCES or selected == current)


def qualified_forge_239_update_selection(
    installed: QualifiedArtifact, candidate: QualifiedArtifact,
) -> bool:
    """Read-only exact 2.7.38→2.7.39 producer selection from #142 r29.

    This matrix grants no updater invocation. The reviewed assessment, exact
    published script/receipt, installed state and product-owned execution
    must each be separately admitted at their mutation boundaries.
    """
    if not isinstance(installed, QualifiedArtifact) or not isinstance(candidate, QualifiedArtifact):
        return False
    old = (
        "2.7.38", "0a3d6e35b01da93bb5a674ae7795558655c16c7d",
        "sha256:e9a5609969b8e49476f44e99a6cf72b8edf60280a77e010effe55a3bc1b33af8",
    )
    new = (
        "2.7.39", "ebc43dc12da27353f85c991a26da9852aa790f05",
        "sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1",
    )
    return (
        installed.version, installed.source_revision, installed.digest
    ) == old and (
        candidate.version, candidate.source_revision, candidate.digest
    ) == new
