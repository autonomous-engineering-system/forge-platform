"""Exact EP release admitted for new managed system-instance operations.

Older installed or preserved records retain their historical identity during
readback; they do not gain 2.3.106 mutation authority by version inference.
"""

from __future__ import annotations

from .component_operations import QualifiedArtifact


EP_LIFECYCLE_RELEASE = (
    "2.3.106",
    "7b99b578153ae5d72372a09db194306b49ec9f9c",
    "sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694",
)


def qualified_ep_lifecycle_artifact(artifact: QualifiedArtifact | None) -> bool:
    """Require the exact published wheel, source and version from #142 r27."""
    return isinstance(artifact, QualifiedArtifact) and (
        artifact.version, artifact.source_revision, artifact.digest
    ) == EP_LIFECYCLE_RELEASE


def qualified_ep_installation_pairing_artifact(artifact: QualifiedArtifact | None) -> bool:
    """Installation credential commands only, exact published EP 2.3.113.

    RELEASE_COMPLETE receipt digest:
    34f74c085d5de08d5215e938f41e4a3585c9059269fd04e5e4894ac57e204455.
    Historical project credential and lifecycle authority stays unchanged.
    """
    return isinstance(artifact, QualifiedArtifact) and (
        artifact.version, artifact.source_revision, artifact.digest
    ) == (
        "2.3.113", "9318636060706534635954e9131e42e2f63928ef",
        "sha256:878e36323e37b29d97a188c02257283c3dc322c60755d57dc9017259f8ac386e",
    )
