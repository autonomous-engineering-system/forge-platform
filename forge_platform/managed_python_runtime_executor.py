"""Durable execution boundary for the exact managed Python runtime.

The signed catalog and composition policy select the runtime before this
module is called.  The executor never consults ``PATH`` and never accepts a
caller-selected installation path.  It derives immutable runtime/venv slot
identities, captures the four digest-pinned inputs, validates an independently
produced archive inspection, and coordinates an injected privileged mutation
adapter.  The adapter remains responsible for archive extraction and the
actual machine-wide filesystem mutation.

Every external mutation is preceded and followed by durable evidence.  An
adapter must therefore make install/venv/activation calls idempotent: after a
crash, readback is attempted before a call is repeated.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict, dataclass, replace
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from typing import Iterator, Mapping, Protocol

from .universal_installer import (
    MANAGED_PYTHON_ROOT_IDENTITY,
    CompositionPlan,
    DownloadIdentity,
    InstallerOperationRecord,
    ManagedPythonRuntimeAction,
    ManagedPythonRuntimeIdentity,
    ManagedPythonRuntimeReadback,
    ProductVenvRequirement,
    UniversalInstallerError,
    plan_managed_python_runtime,
)


MANAGED_PYTHON_EXECUTION_SCHEMA = "forge-platform.managed-python-runtime-execution/v1"
MANAGED_PYTHON_ARCHIVE_LAYOUT = "forge-platform-managed-python-runtime-layout/v1"
MANAGED_PYTHON_INTERPRETER_RELATIVE_PATH = "bin/python3"

_SAFE_OPERATION_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_SAFE_TARGET_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_FINGERPRINT = re.compile(r"^[0-9a-f]{64}$")
_RECEIPT_REFERENCE = re.compile(r"^receipt:[a-z0-9][a-z0-9._-]{0,127}$")
_STATES = (
    "PREPARED",
    "ACQUIRED",
    "VERIFIED",
    "RUNTIME_READY",
    "VENVS_READY",
    "ACTIVE",
    "COMPLETE",
    "ROLLED_BACK",
)
_STATE_INDEX = {state: index for index, state in enumerate(_STATES)}
_ASSET_ROLES = ("runtime", "source", "source_provenance", "build_provenance")
_TERMINAL_STATES = frozenset({"COMPLETE", "ROLLED_BACK"})
_MAXIMUM_RUNTIME_ARCHIVE_BYTES = 4 * 1024 * 1024 * 1024
_MAXIMUM_EVIDENCE_BYTES = 256 * 1024 * 1024
_MAXIMUM_EXECUTION_RECORD_BYTES = 1024 * 1024


def _required(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} is required")
    return value


def _digest(value: object, label: str) -> str:
    value = _required(value, label)
    if _DIGEST.fullmatch(value) is None:
        raise ValueError(f"{label} must be a lowercase sha256 identity")
    return value


def _receipt(value: object, label: str) -> str:
    value = _required(value, label)
    if _RECEIPT_REFERENCE.fullmatch(value) is None:
        raise ValueError(f"{label} must be an opaque receipt reference")
    return value


def _strict_mapping(value: object, fields: frozenset[str], label: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping) or set(value) != fields:
        raise ValueError(f"{label} fields are invalid")
    return value


def _canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("utf-8")


def _runtime_slot_identity(runtime_identity: str) -> str:
    return "sha256-" + _digest(runtime_identity, "runtime identity").removeprefix("sha256:")


def _asset_locators(identity: ManagedPythonRuntimeIdentity) -> Mapping[str, DownloadIdentity]:
    return {
        "runtime": identity.artifact,
        "source": identity.source,
        "source_provenance": identity.source_provenance,
        "build_provenance": identity.build_provenance,
    }


def _sha256_file(path: Path, maximum_bytes: int) -> tuple[str, int]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise UniversalInstallerError("managed Python captured asset is unavailable") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise UniversalInstallerError("managed Python captured asset must be a regular non-symlink file")
    if metadata.st_size > maximum_bytes:
        raise UniversalInstallerError("managed Python captured asset exceeds its size limit")
    digest = sha256()
    total = 0
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                total += len(chunk)
                if total > maximum_bytes:
                    raise UniversalInstallerError("managed Python captured asset exceeds its size limit")
                digest.update(chunk)
    except OSError as error:
        raise UniversalInstallerError("managed Python captured asset could not be read") from error
    return "sha256:" + digest.hexdigest(), total


@dataclass(frozen=True)
class ManagedPythonRuntimeExecutionRequest:
    """One frozen executor request derived from an admitted composition plan."""

    operation_id: str
    runtime_action: ManagedPythonRuntimeAction
    product_venvs: tuple[ProductVenvRequirement, ...]

    def __post_init__(self) -> None:
        if not isinstance(self.operation_id, str) or _SAFE_OPERATION_ID.fullmatch(self.operation_id) is None:
            raise ValueError("managed Python operation_id must be a lowercase safe identifier")
        if not isinstance(self.runtime_action, ManagedPythonRuntimeAction):
            raise ValueError("managed Python runtime action is required")
        if self.runtime_action.action == "BLOCKED":
            raise UniversalInstallerError("blocked managed Python action cannot be executed")
        expected_action = plan_managed_python_runtime(
            self.runtime_action.requirement,
            self.runtime_action.readback,
        )
        if (
            self.runtime_action.action != expected_action.action
            or self.runtime_action.rollback_runtime_identity != expected_action.rollback_runtime_identity
        ):
            raise UniversalInstallerError("managed Python runtime action does not match trusted readback")
        if not self.product_venvs or any(
            not isinstance(requirement, ProductVenvRequirement) for requirement in self.product_venvs
        ):
            raise ValueError("managed Python execution requires product venv identities")
        if len({item.component_identity for item in self.product_venvs}) != len(self.product_venvs):
            raise ValueError("managed Python product venv component identities must be unique")
        if len({item.venv_identity for item in self.product_venvs}) != len(self.product_venvs):
            raise ValueError("managed Python product venv identities must be unique")
        if any(
            item.python_runtime_identity != self.runtime_action.requirement.identity_digest
            for item in self.product_venvs
        ):
            raise ValueError("managed Python product venvs must bind the exact target runtime")

    @property
    def target(self) -> ManagedPythonRuntimeIdentity:
        return self.runtime_action.requirement

    @property
    def rollback_runtime_identity(self) -> str | None:
        return self.runtime_action.rollback_runtime_identity

    @property
    def runtime_slot_identity(self) -> str:
        return _runtime_slot_identity(self.target.identity_digest)

    def immutable_material(self) -> Mapping[str, object]:
        readback = self.runtime_action.readback
        return {
            "schema": MANAGED_PYTHON_EXECUTION_SCHEMA,
            "operation_id": self.operation_id,
            "action": self.runtime_action.action,
            "target": {**self.target.identity_material(), "identity_digest": self.target.identity_digest},
            "initial_readback": {
                "state": readback.state,
                "runtime_identity": readback.runtime_identity,
                "managed_root_identity": readback.managed_root_identity,
                "runtime_slot_identity": readback.runtime_slot_identity,
                "retained_runtime_identities": list(readback.retained_runtime_identities),
                "evidence_reference": readback.evidence_reference,
            },
            "rollback_runtime_identity": self.rollback_runtime_identity,
            "product_venvs": [
                {
                    "component_identity": item.component_identity,
                    "venv_identity": item.venv_identity,
                    "python_runtime_identity": item.python_runtime_identity,
                }
                for item in self.product_venvs
            ],
        }

    def fingerprint(self) -> str:
        return sha256(_canonical_json(self.immutable_material())).hexdigest()


@dataclass(frozen=True)
class ExactAssetFetchReceipt:
    role: str
    requested_url: str
    final_url: str
    digest: str
    byte_count: int
    evidence_reference: str

    def __post_init__(self) -> None:
        if self.role not in _ASSET_ROLES:
            raise ValueError("managed Python asset role is unsupported")
        _required(self.requested_url, "requested asset URL")
        _required(self.final_url, "final asset URL")
        _digest(self.digest, "captured asset digest")
        if isinstance(self.byte_count, bool) or not isinstance(self.byte_count, int) or self.byte_count < 0:
            raise ValueError("captured asset byte_count must be a non-negative integer")
        _receipt(self.evidence_reference, "asset evidence_reference")


@dataclass(frozen=True)
class ManagedPythonArchiveInspection:
    runtime_identity: str
    archive_digest: str
    source_digest: str
    source_provenance_digest: str
    build_provenance_digest: str
    layout: str
    interpreter_relative_path: str
    executable_architectures: tuple[str, ...]
    minimum_macos_major: int
    implementation: str
    version: str
    build_variant: str
    python_tag: str
    abi_tag: str
    platform_tag: str
    policy_revision: str
    evidence_reference: str

    def __post_init__(self) -> None:
        for label in (
            "runtime_identity",
            "archive_digest",
            "source_digest",
            "source_provenance_digest",
            "build_provenance_digest",
        ):
            _digest(getattr(self, label), f"archive inspection {label}")
        if self.layout != MANAGED_PYTHON_ARCHIVE_LAYOUT:
            raise ValueError("managed Python archive layout is unsupported")
        if self.interpreter_relative_path != MANAGED_PYTHON_INTERPRETER_RELATIVE_PATH:
            raise ValueError("managed Python interpreter path is not the fixed archive-relative path")
        if self.executable_architectures != ("arm64",):
            raise ValueError("managed Python executable must be thin arm64")
        if isinstance(self.minimum_macos_major, bool) or not isinstance(self.minimum_macos_major, int):
            raise ValueError("managed Python minimum macOS major must be an integer")
        for label in (
            "implementation",
            "version",
            "build_variant",
            "python_tag",
            "abi_tag",
            "platform_tag",
            "policy_revision",
        ):
            _required(getattr(self, label), f"archive inspection {label}")
        _receipt(self.evidence_reference, "archive inspection evidence_reference")

    def verify(self, identity: ManagedPythonRuntimeIdentity) -> None:
        expected = {
            "runtime_identity": identity.identity_digest,
            "archive_digest": identity.artifact.digest,
            "source_digest": identity.source.digest,
            "source_provenance_digest": identity.source_provenance.digest,
            "build_provenance_digest": identity.build_provenance.digest,
            "implementation": identity.implementation,
            "version": str(identity.version),
            "build_variant": identity.build_variant,
            "python_tag": identity.python_tag,
            "abi_tag": identity.abi_tag,
            "platform_tag": identity.platform_tag,
            "policy_revision": identity.policy_revision,
        }
        for field, value in expected.items():
            if getattr(self, field) != value:
                raise UniversalInstallerError(
                    f"managed Python archive inspection does not bind exact {field}"
                )
        if self.minimum_macos_major != identity.minimum_macos_version.major:
            raise UniversalInstallerError("managed Python archive has a different macOS deployment floor")


@dataclass(frozen=True)
class ManagedPythonRuntimeSlotReceipt:
    operation_id: str
    runtime_identity: str
    managed_root_identity: str
    runtime_slot_identity: str
    archive_digest: str
    interpreter_relative_path: str
    executable_architectures: tuple[str, ...]
    minimum_macos_major: int
    state: str
    evidence_reference: str

    def __post_init__(self) -> None:
        _required(self.operation_id, "runtime-slot operation_id")
        _digest(self.runtime_identity, "runtime-slot runtime_identity")
        if self.managed_root_identity != MANAGED_PYTHON_ROOT_IDENTITY:
            raise ValueError("runtime slot is outside the installer-owned managed root")
        if self.runtime_slot_identity != _runtime_slot_identity(self.runtime_identity):
            raise ValueError("runtime slot identity does not match the exact runtime")
        _digest(self.archive_digest, "runtime-slot archive_digest")
        if self.interpreter_relative_path != MANAGED_PYTHON_INTERPRETER_RELATIVE_PATH:
            raise ValueError("runtime slot interpreter path is invalid")
        if self.executable_architectures != ("arm64",):
            raise ValueError("runtime slot executable must be thin arm64")
        if isinstance(self.minimum_macos_major, bool) or not isinstance(self.minimum_macos_major, int):
            raise ValueError("runtime slot minimum macOS major must be an integer")
        if self.state != "READY":
            raise ValueError("runtime slot must be READY")
        _receipt(self.evidence_reference, "runtime-slot evidence_reference")

    def verify(self, request: ManagedPythonRuntimeExecutionRequest) -> None:
        target = request.target
        if (
            self.operation_id != request.operation_id
            or self.runtime_identity != target.identity_digest
            or self.runtime_slot_identity != request.runtime_slot_identity
            or self.archive_digest != target.artifact.digest
            or self.minimum_macos_major != target.minimum_macos_version.major
        ):
            raise UniversalInstallerError("runtime-slot receipt does not bind the frozen request")


@dataclass(frozen=True)
class ProductVenvExecutionReceipt:
    operation_id: str
    component_identity: str
    venv_identity: str
    python_runtime_identity: str
    runtime_slot_identity: str
    state: str
    evidence_reference: str

    def __post_init__(self) -> None:
        _required(self.operation_id, "product-venv operation_id")
        if not isinstance(self.component_identity, str) or _SAFE_TARGET_ID.fullmatch(self.component_identity) is None:
            raise ValueError("product-venv component identity is invalid")
        if not isinstance(self.venv_identity, str) or _SAFE_TARGET_ID.fullmatch(self.venv_identity) is None:
            raise ValueError("product-venv identity is invalid")
        _digest(self.python_runtime_identity, "product-venv Python runtime identity")
        if self.runtime_slot_identity != _runtime_slot_identity(self.python_runtime_identity):
            raise ValueError("product-venv runtime slot does not match its exact Python runtime")
        if self.state != "READY":
            raise ValueError("product venv must be READY")
        _receipt(self.evidence_reference, "product-venv evidence_reference")

    def verify(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
        requirement: ProductVenvRequirement,
    ) -> None:
        if (
            self.operation_id != request.operation_id
            or self.component_identity != requirement.component_identity
            or self.venv_identity != requirement.venv_identity
            or self.python_runtime_identity != request.target.identity_digest
            or self.runtime_slot_identity != request.runtime_slot_identity
        ):
            raise UniversalInstallerError("product-venv receipt does not bind the frozen request")


@dataclass(frozen=True)
class ManagedPythonActivationReceipt:
    operation_id: str
    active_runtime_identity: str
    active_runtime_slot_identity: str
    retained_runtime_identity: str | None
    state: str
    evidence_reference: str

    def __post_init__(self) -> None:
        _required(self.operation_id, "activation operation_id")
        _digest(self.active_runtime_identity, "active runtime identity")
        if self.active_runtime_slot_identity != _runtime_slot_identity(self.active_runtime_identity):
            raise ValueError("active runtime slot does not match its exact identity")
        if self.retained_runtime_identity is not None:
            _digest(self.retained_runtime_identity, "retained runtime identity")
            if self.retained_runtime_identity == self.active_runtime_identity:
                raise ValueError("retained runtime identity must differ from the active runtime")
        if self.state != "ACTIVE":
            raise ValueError("managed Python activation must be ACTIVE")
        _receipt(self.evidence_reference, "activation evidence_reference")


@dataclass(frozen=True)
class ManagedPythonRollbackReceipt:
    operation_id: str
    restored_runtime_identity: str
    restored_runtime_slot_identity: str
    retained_failed_runtime_identity: str
    state: str
    evidence_reference: str
    final_readback_evidence_reference: str

    def __post_init__(self) -> None:
        _required(self.operation_id, "rollback operation_id")
        _digest(self.restored_runtime_identity, "restored runtime identity")
        if self.restored_runtime_slot_identity != _runtime_slot_identity(self.restored_runtime_identity):
            raise ValueError("restored runtime slot does not match its exact identity")
        _digest(self.retained_failed_runtime_identity, "retained failed runtime identity")
        if self.retained_failed_runtime_identity == self.restored_runtime_identity:
            raise ValueError("retained failed runtime must differ from restored runtime")
        if self.state != "ROLLED_BACK":
            raise ValueError("managed Python rollback receipt must be ROLLED_BACK")
        _receipt(self.evidence_reference, "rollback evidence_reference")
        _receipt(self.final_readback_evidence_reference, "rollback readback evidence_reference")


@dataclass(frozen=True)
class ManagedPythonRuntimeExecutionReceipt:
    operation_id: str
    request_fingerprint: str
    runtime_identity: str
    runtime_slot_identity: str
    rollback_runtime_identity: str | None
    asset_evidence_references: tuple[str, ...]
    archive_inspection_evidence_reference: str
    runtime_slot_evidence_reference: str
    product_venv_evidence_references: tuple[tuple[str, str], ...]
    activation_evidence_reference: str
    final_readback_evidence_reference: str
    evidence_reference: str
    state: str

    def __post_init__(self) -> None:
        _required(self.operation_id, "execution receipt operation_id")
        if _FINGERPRINT.fullmatch(self.request_fingerprint) is None:
            raise ValueError("execution receipt fingerprint is invalid")
        _digest(self.runtime_identity, "execution receipt runtime identity")
        if self.runtime_slot_identity != _runtime_slot_identity(self.runtime_identity):
            raise ValueError("execution receipt runtime slot is invalid")
        if self.rollback_runtime_identity is not None:
            _digest(self.rollback_runtime_identity, "execution receipt rollback identity")
        if len(self.asset_evidence_references) != len(_ASSET_ROLES):
            raise ValueError("execution receipt requires evidence for every runtime asset")
        for value in self.asset_evidence_references:
            _receipt(value, "execution asset evidence reference")
        _receipt(self.archive_inspection_evidence_reference, "archive inspection evidence reference")
        _receipt(self.runtime_slot_evidence_reference, "runtime slot evidence reference")
        if not self.product_venv_evidence_references:
            raise ValueError("execution receipt requires product venv evidence")
        for component, reference in self.product_venv_evidence_references:
            _required(component, "execution receipt venv component")
            _receipt(reference, "execution receipt venv evidence reference")
        if len({component for component, _ in self.product_venv_evidence_references}) != len(
            self.product_venv_evidence_references
        ):
            raise ValueError("execution receipt product venv components must be unique")
        _receipt(self.activation_evidence_reference, "activation evidence reference")
        _receipt(self.final_readback_evidence_reference, "final readback evidence reference")
        _receipt(self.evidence_reference, "managed Python execution evidence reference")
        if self.state != "COMPLETE":
            raise ValueError("managed Python execution receipt must be COMPLETE")

    def installer_journal_evidence(
        self,
        post_tool_plan_fingerprint: str,
        tool_receipt_references: tuple[str, ...] = (),
    ) -> Mapping[str, object]:
        """Project the exact terminal receipt into the parent installer journal."""

        if _FINGERPRINT.fullmatch(post_tool_plan_fingerprint) is None:
            raise ValueError("post-tool plan fingerprint must be a SHA-256 hex value")
        for reference in tool_receipt_references:
            _receipt(reference, "generic managed-tool receipt reference")
        if not tool_receipt_references:
            tool_receipt_references = (self.evidence_reference,)
        return {
            "result": "TOOLS_VERIFIED",
            "tool_receipt_references": list(tool_receipt_references),
            "python_runtime_receipt_reference": self.evidence_reference,
            "python_runtime_identity": self.runtime_identity,
            "retained_python_runtime_identity": self.rollback_runtime_identity,
            "post_tool_plan_fingerprint": post_tool_plan_fingerprint,
        }


class ManagedPythonRuntimeJournalBridge:
    """Admit one exact executor receipt into a frozen installer journal.

    The bridge accepts both the original plan that created the journal and a
    fresh post-tool plan. It permits only tool readbacks/actions to change and
    requires the fresh plan to be ready for product dispatch. The durable
    journal owns atomic persistence; this class only validates and constructs
    the next immutable record.
    """

    @staticmethod
    def advance_record(
        record: InstallerOperationRecord,
        original_plan: CompositionPlan,
        request: ManagedPythonRuntimeExecutionRequest,
        receipt: ManagedPythonRuntimeExecutionReceipt,
        post_tool_plan: CompositionPlan,
        tool_receipts: Mapping[str, str],
    ) -> InstallerOperationRecord:
        if not isinstance(record, InstallerOperationRecord) or record.state != "PLANNED":
            raise UniversalInstallerError("managed Python journal bridge requires a PLANNED record")
        if not isinstance(original_plan, CompositionPlan) or (
            InstallerOperationRecord.create(record.operation_id, original_plan) != record
        ):
            raise UniversalInstallerError("managed Python journal bridge original plan does not match the journal")
        if not isinstance(request, ManagedPythonRuntimeExecutionRequest) or (
            request.operation_id != record.operation_id
            or request.runtime_action != original_plan.python_runtime_action
            or request.product_venvs != original_plan.product_venvs
        ):
            raise UniversalInstallerError("managed Python execution request does not match the frozen plan")
        if not isinstance(receipt, ManagedPythonRuntimeExecutionReceipt) or (
            receipt.operation_id != request.operation_id
            or receipt.request_fingerprint != request.fingerprint()
            or receipt.runtime_identity != record.python_runtime_identity
            or receipt.runtime_identity != request.target.identity_digest
            or receipt.rollback_runtime_identity != record.python_runtime_rollback_identity
            or receipt.rollback_runtime_identity != request.rollback_runtime_identity
            or tuple(
                component for component, _ in receipt.product_venv_evidence_references
            ) != tuple(requirement.component_identity for requirement in request.product_venvs)
        ):
            raise UniversalInstallerError("managed Python terminal receipt does not match the frozen request")
        if not isinstance(post_tool_plan, CompositionPlan):
            raise UniversalInstallerError("managed Python journal bridge requires a fresh post-tool plan")
        if ManagedPythonRuntimeJournalBridge._stable_plan_material(original_plan) != (
            ManagedPythonRuntimeJournalBridge._stable_plan_material(post_tool_plan)
        ):
            raise UniversalInstallerError("post-tool plan changed immutable installer or composition inputs")
        if (
            post_tool_plan.requires_managed_tool_reconciliation
            or not post_tool_plan.permits_product_operation_dispatch
            or any(action.action != "NO_CHANGE" for action in post_tool_plan.managed_tool_actions)
            or post_tool_plan.python_runtime_action.action != "NO_CHANGE"
            or post_tool_plan.python_runtime_action.requirement != request.target
            or post_tool_plan.python_runtime_action.readback.runtime_identity != receipt.runtime_identity
        ):
            raise UniversalInstallerError("post-tool plan does not verify exact managed-tool readback")

        expected_tools = tuple(
            action.identity
            for action in original_plan.managed_tool_actions
            if action.action != "NO_CHANGE"
        )
        if not isinstance(tool_receipts, Mapping) or set(tool_receipts) != set(expected_tools):
            raise UniversalInstallerError("generic managed-tool receipts do not match the frozen actions")
        references: list[str] = []
        for identity in expected_tools:
            reference = tool_receipts[identity]
            _receipt(reference, f"managed-tool {identity} receipt reference")
            references.append(reference)

        evidence = receipt.installer_journal_evidence(
            post_tool_plan.fingerprint(),
            tuple(references),
        )
        return record.transition("MANAGED_TOOLS", evidence)

    @staticmethod
    def _stable_plan_material(plan: CompositionPlan) -> tuple[object, ...]:
        return (
            plan.composition_id,
            plan.manifest_digest,
            plan.installer_context,
            plan.catalog_identity,
            plan.installed_composition,
            plan.composition_route_failures,
            plan.installer_unmet_requirements,
            plan.host_preflight,
            plan.provider_gate,
            tuple(action.requirement for action in plan.managed_tool_actions),
            plan.python_runtime_action.requirement,
            plan.product_venvs,
            plan.component_diffs,
        )


class ExactManagedPythonAssetTransport(Protocol):
    """Credential-free exact-locator transport writing to a chosen staging file."""

    def fetch(
        self,
        role: str,
        locator: DownloadIdentity,
        destination: Path,
    ) -> ExactAssetFetchReceipt:
        ...


class ManagedPythonRuntimeArchiveInspector(Protocol):
    """Inspect exact captured bytes without installing them."""

    def inspect(
        self,
        identity: ManagedPythonRuntimeIdentity,
        assets: Mapping[str, Path],
    ) -> ManagedPythonArchiveInspection:
        ...


class ManagedPythonRuntimeMutationAdapter(Protocol):
    """Privileged, fixed-protocol machine mutation seam; no commands or paths from UI."""

    def read_runtime_slot(
        self,
        operation_id: str,
        runtime_identity: str,
        runtime_slot_identity: str,
    ) -> ManagedPythonRuntimeSlotReceipt | None:
        ...

    def install_runtime_slot(
        self,
        operation_id: str,
        identity: ManagedPythonRuntimeIdentity,
        runtime_slot_identity: str,
        verified_archive: Path,
        inspection: ManagedPythonArchiveInspection,
    ) -> ManagedPythonRuntimeSlotReceipt:
        ...

    def read_product_venv(
        self,
        operation_id: str,
        requirement: ProductVenvRequirement,
        runtime_slot_identity: str,
    ) -> ProductVenvExecutionReceipt | None:
        ...

    def ensure_product_venv(
        self,
        operation_id: str,
        requirement: ProductVenvRequirement,
        runtime_slot_identity: str,
    ) -> ProductVenvExecutionReceipt:
        ...

    def read_active_runtime(self) -> ManagedPythonRuntimeReadback:
        ...

    def activate_runtime(
        self,
        operation_id: str,
        runtime_identity: str,
        runtime_slot_identity: str,
        retained_runtime_identity: str | None,
    ) -> ManagedPythonActivationReceipt:
        ...

    def rollback_runtime(
        self,
        operation_id: str,
        restored_runtime_identity: str,
        restored_runtime_slot_identity: str,
        retained_failed_runtime_identity: str,
    ) -> ManagedPythonRollbackReceipt:
        ...


@dataclass(frozen=True)
class ManagedPythonRuntimeExecutionRecord:
    schema: str
    operation_id: str
    request_fingerprint: str
    action: str
    target_runtime_identity: str
    runtime_slot_identity: str
    rollback_runtime_identity: str | None
    product_venv_identities: tuple[tuple[str, str], ...]
    state: str
    asset_receipts: tuple[ExactAssetFetchReceipt, ...]
    archive_inspection: ManagedPythonArchiveInspection | None
    runtime_slot_receipt: ManagedPythonRuntimeSlotReceipt | None
    product_venv_receipts: tuple[ProductVenvExecutionReceipt, ...]
    activation_receipt: ManagedPythonActivationReceipt | None
    terminal_receipt: ManagedPythonRuntimeExecutionReceipt | None
    rollback_receipt: ManagedPythonRollbackReceipt | None

    @classmethod
    def create(cls, request: ManagedPythonRuntimeExecutionRequest) -> "ManagedPythonRuntimeExecutionRecord":
        return cls(
            MANAGED_PYTHON_EXECUTION_SCHEMA,
            request.operation_id,
            request.fingerprint(),
            request.runtime_action.action,
            request.target.identity_digest,
            request.runtime_slot_identity,
            request.rollback_runtime_identity,
            tuple((item.component_identity, item.venv_identity) for item in request.product_venvs),
            "PREPARED",
            (),
            None,
            None,
            (),
            None,
            None,
            None,
        )

    def __post_init__(self) -> None:
        if self.schema != MANAGED_PYTHON_EXECUTION_SCHEMA:
            raise ValueError("managed Python execution record schema is unsupported")
        if not isinstance(self.operation_id, str) or _SAFE_OPERATION_ID.fullmatch(self.operation_id) is None:
            raise ValueError("managed Python execution record operation_id is invalid")
        if _FINGERPRINT.fullmatch(self.request_fingerprint) is None:
            raise ValueError("managed Python execution record fingerprint is invalid")
        if self.action not in {"INSTALL", "UPGRADE", "NO_CHANGE"}:
            raise ValueError("managed Python execution record action is invalid")
        _digest(self.target_runtime_identity, "execution record target runtime identity")
        if self.runtime_slot_identity != _runtime_slot_identity(self.target_runtime_identity):
            raise ValueError("execution record runtime slot identity is invalid")
        if self.rollback_runtime_identity is not None:
            _digest(self.rollback_runtime_identity, "execution record rollback runtime identity")
        if not self.product_venv_identities or len(set(self.product_venv_identities)) != len(
            self.product_venv_identities
        ):
            raise ValueError("execution record product venv identities are invalid")
        if self.state not in _STATE_INDEX:
            raise ValueError("managed Python execution record state is invalid")
        roles = [item.role for item in self.asset_receipts]
        if roles != list(_ASSET_ROLES[: len(roles)]):
            raise ValueError("managed Python execution asset receipts are incomplete or unordered")
        if self.state == "ACQUIRED" and len(self.asset_receipts) != len(_ASSET_ROLES):
            raise ValueError("ACQUIRED managed Python execution lacks exact asset receipts")
        if _STATE_INDEX[self.state] >= _STATE_INDEX["VERIFIED"] and self.archive_inspection is None:
            raise ValueError("verified managed Python execution lacks archive inspection")
        if _STATE_INDEX[self.state] >= _STATE_INDEX["RUNTIME_READY"] and self.runtime_slot_receipt is None:
            raise ValueError("managed Python execution lacks a runtime-slot receipt")
        if _STATE_INDEX[self.state] >= _STATE_INDEX["VENVS_READY"] and len(
            self.product_venv_receipts
        ) != len(self.product_venv_identities):
            raise ValueError("managed Python execution lacks product-venv receipts")
        if _STATE_INDEX[self.state] >= _STATE_INDEX["ACTIVE"] and self.activation_receipt is None:
            raise ValueError("active managed Python execution lacks activation receipt")
        if self.state == "COMPLETE" and self.terminal_receipt is None:
            raise ValueError("complete managed Python execution lacks a terminal receipt")
        if self.state not in {"COMPLETE", "ROLLED_BACK"} and self.terminal_receipt is not None:
            raise ValueError("non-complete managed Python execution cannot carry a terminal receipt")
        if self.state == "ROLLED_BACK" and self.rollback_receipt is None:
            raise ValueError("rolled-back managed Python execution lacks rollback evidence")
        if self.state != "ROLLED_BACK" and self.rollback_receipt is not None:
            raise ValueError("non-rollback managed Python execution cannot carry rollback evidence")
        if self.archive_inspection is not None and (
            self.archive_inspection.runtime_identity != self.target_runtime_identity
        ):
            raise ValueError("execution record archive inspection has a different runtime identity")
        if self.runtime_slot_receipt is not None and (
            self.runtime_slot_receipt.operation_id != self.operation_id
            or self.runtime_slot_receipt.runtime_identity != self.target_runtime_identity
            or self.runtime_slot_receipt.runtime_slot_identity != self.runtime_slot_identity
        ):
            raise ValueError("execution record runtime-slot receipt is not correlated")
        if self.product_venv_receipts:
            receipt_pairs = tuple(
                (receipt.component_identity, receipt.venv_identity)
                for receipt in self.product_venv_receipts
            )
            if receipt_pairs != self.product_venv_identities or any(
                receipt.operation_id != self.operation_id
                or receipt.python_runtime_identity != self.target_runtime_identity
                or receipt.runtime_slot_identity != self.runtime_slot_identity
                for receipt in self.product_venv_receipts
            ):
                raise ValueError("execution record product-venv receipts are not correlated")
        if self.activation_receipt is not None and (
            self.activation_receipt.operation_id != self.operation_id
            or self.activation_receipt.active_runtime_identity != self.target_runtime_identity
            or self.activation_receipt.active_runtime_slot_identity != self.runtime_slot_identity
            or self.activation_receipt.retained_runtime_identity != self.rollback_runtime_identity
        ):
            raise ValueError("execution record activation receipt is not correlated")
        if self.terminal_receipt is not None and (
            self.terminal_receipt.operation_id != self.operation_id
            or self.terminal_receipt.request_fingerprint != self.request_fingerprint
            or self.terminal_receipt.runtime_identity != self.target_runtime_identity
            or self.terminal_receipt.runtime_slot_identity != self.runtime_slot_identity
            or self.terminal_receipt.rollback_runtime_identity != self.rollback_runtime_identity
            or self.terminal_receipt.asset_evidence_references
            != tuple(receipt.evidence_reference for receipt in self.asset_receipts)
            or self.archive_inspection is None
            or self.terminal_receipt.archive_inspection_evidence_reference
            != self.archive_inspection.evidence_reference
            or self.runtime_slot_receipt is None
            or self.terminal_receipt.runtime_slot_evidence_reference
            != self.runtime_slot_receipt.evidence_reference
            or self.terminal_receipt.product_venv_evidence_references
            != tuple(
                (receipt.component_identity, receipt.evidence_reference)
                for receipt in self.product_venv_receipts
            )
            or self.activation_receipt is None
            or self.terminal_receipt.activation_evidence_reference
            != self.activation_receipt.evidence_reference
        ):
            raise ValueError("execution record terminal receipt is not correlated")
        if self.rollback_receipt is not None and (
            self.rollback_runtime_identity is None
            or self.rollback_receipt.operation_id != self.operation_id
            or self.rollback_receipt.restored_runtime_identity != self.rollback_runtime_identity
            or self.rollback_receipt.retained_failed_runtime_identity != self.target_runtime_identity
        ):
            raise ValueError("execution record rollback receipt is not correlated")

    def verify_request(self, request: ManagedPythonRuntimeExecutionRequest) -> None:
        expected = ManagedPythonRuntimeExecutionRecord.create(request)
        if (
            self.operation_id != expected.operation_id
            or self.request_fingerprint != expected.request_fingerprint
            or self.action != expected.action
            or self.target_runtime_identity != expected.target_runtime_identity
            or self.runtime_slot_identity != expected.runtime_slot_identity
            or self.rollback_runtime_identity != expected.rollback_runtime_identity
            or self.product_venv_identities != expected.product_venv_identities
        ):
            raise UniversalInstallerError("managed Python operation ID already binds different immutable inputs")


class ManagedPythonRuntimeExecutionStore:
    """Mode-0600 crash/reboot record and operation-owned asset staging."""

    def __init__(self, root: Path) -> None:
        if not isinstance(root, Path) or not root.is_absolute():
            raise ValueError("managed Python execution root must be absolute")
        # Normalize dot segments without resolving a final symlink.  The first
        # locked operation must observe and reject a symlinked state root.
        self.root = Path(os.path.abspath(root))

    @contextmanager
    def locked_record(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
    ) -> Iterator[ManagedPythonRuntimeExecutionRecord]:
        self._secure_root()
        with self._lock(self.root / ".host-managed-python.lock", "another managed Python operation is active"):
            existing = self.load(request.operation_id)
            if existing is None:
                active = self._active_record()
                if active is not None:
                    raise UniversalInstallerError(
                        f"managed Python operation {active.operation_id} must resume before another can start"
                    )
                existing = ManagedPythonRuntimeExecutionRecord.create(request)
                self.write(existing)
            else:
                existing.verify_request(request)
            yield existing

    def operation_directory(self, operation_id: str) -> Path:
        if not isinstance(operation_id, str) or _SAFE_OPERATION_ID.fullmatch(operation_id) is None:
            raise ValueError("managed Python operation_id is invalid")
        return self.root / "operations" / operation_id

    def asset_path(self, operation_id: str, role: str) -> Path:
        if role not in _ASSET_ROLES:
            raise ValueError("managed Python asset role is invalid")
        return self.operation_directory(operation_id) / "assets" / f"{role}.payload"

    def load(self, operation_id: str) -> ManagedPythonRuntimeExecutionRecord | None:
        operation_directory = self.operation_directory(operation_id)
        if operation_directory.exists() or operation_directory.is_symlink():
            self._require_secure_directory(operation_directory, "managed Python operation directory")
        path = operation_directory / "record.json"
        if not path.exists():
            return None
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise UniversalInstallerError("managed Python execution record must be a regular file")
        if metadata.st_size > _MAXIMUM_EXECUTION_RECORD_BYTES:
            raise UniversalInstallerError("managed Python execution record exceeds its size limit")
        try:
            payload = json.loads(
                path.read_text(encoding="utf-8"),
                object_pairs_hook=self._unique_object,
                parse_constant=self._reject_nonfinite,
            )
            record = self._parse_record(payload)
            if record.operation_id != operation_id:
                raise ValueError("managed Python execution record operation_id does not match its directory")
            return record
        except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            raise UniversalInstallerError("managed Python execution record is invalid") from error

    def write(self, record: ManagedPythonRuntimeExecutionRecord) -> None:
        operation_directory = self.operation_directory(record.operation_id)
        self._secure_child_directory(operation_directory, "managed Python operation directory")
        path = operation_directory / "record.json"
        descriptor, temporary_name = tempfile.mkstemp(prefix=".record-", dir=operation_directory)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(asdict(record), handle, sort_keys=True, separators=(",", ":"), allow_nan=False)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary_name, 0o600)
            os.replace(temporary_name, path)
            directory = os.open(operation_directory, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)

    def prepare_asset_directory(self, operation_id: str) -> Path:
        assets = self.operation_directory(operation_id) / "assets"
        self._secure_child_directory(assets, "managed Python asset directory")
        return assets

    def prepare_asset_destination(self, operation_id: str, role: str) -> Path:
        self.prepare_asset_directory(operation_id)
        destination = self.asset_path(operation_id, role)
        if destination.exists() or destination.is_symlink():
            metadata = destination.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise UniversalInstallerError(
                    "managed Python asset destination must be a regular non-symlink file"
                )
        return destination

    def _secure_root(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._require_secure_directory(self.root, "managed Python execution root")
        operations = self.root / "operations"
        self._secure_child_directory(operations, "managed Python operations directory")

    @staticmethod
    def _require_secure_directory(path: Path, label: str) -> None:
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise UniversalInstallerError(f"{label} must be a real directory")
        os.chmod(path, 0o700)

    def _secure_child_directory(self, path: Path, label: str) -> None:
        if path.exists() or path.is_symlink():
            self._require_secure_directory(path, label)
            return
        try:
            path.mkdir(mode=0o700)
        except OSError as error:
            raise UniversalInstallerError(f"{label} could not be created") from error
        self._require_secure_directory(path, label)

    @contextmanager
    def _lock(self, path: Path, message: str) -> Iterator[None]:
        descriptor = os.open(
            path,
            os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise UniversalInstallerError("managed Python execution lock is not a regular file")
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise UniversalInstallerError(message) from error
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def _active_record(self) -> ManagedPythonRuntimeExecutionRecord | None:
        active: list[ManagedPythonRuntimeExecutionRecord] = []
        operations = self.root / "operations"
        for candidate in sorted(operations.iterdir()):
            metadata = candidate.lstat()
            if (
                stat.S_ISLNK(metadata.st_mode)
                or not stat.S_ISDIR(metadata.st_mode)
                or _SAFE_OPERATION_ID.fullmatch(candidate.name) is None
            ):
                raise UniversalInstallerError("managed Python execution root contains an unsafe operation")
            record = self.load(candidate.name)
            if record is not None and record.state not in _TERMINAL_STATES:
                active.append(record)
        if len(active) > 1:
            raise UniversalInstallerError("managed Python execution root contains multiple active operations")
        return active[0] if active else None

    @staticmethod
    def _reject_nonfinite(value: str) -> None:
        raise ValueError(f"non-finite JSON value is not permitted: {value}")

    @staticmethod
    def _unique_object(pairs: list[tuple[str, object]]) -> Mapping[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON member is not permitted: {key}")
            result[key] = value
        return result

    @staticmethod
    def _parse_record(value: object) -> ManagedPythonRuntimeExecutionRecord:
        fields = frozenset({
            "schema", "operation_id", "request_fingerprint", "action", "target_runtime_identity",
            "runtime_slot_identity", "rollback_runtime_identity", "product_venv_identities", "state",
            "asset_receipts", "archive_inspection", "runtime_slot_receipt", "product_venv_receipts",
            "activation_receipt", "terminal_receipt",
            "rollback_receipt",
        })
        payload = _strict_mapping(value, fields, "managed Python execution record")

        def tuple_pairs(raw: object, label: str) -> tuple[tuple[str, str], ...]:
            if not isinstance(raw, list):
                raise ValueError(f"{label} must be a list")
            pairs: list[tuple[str, str]] = []
            for item in raw:
                if not isinstance(item, list) or len(item) != 2:
                    raise ValueError(f"{label} entry is invalid")
                pairs.append((_required(item[0], f"{label} identity"), _required(item[1], f"{label} value")))
            return tuple(pairs)

        def dataclass_or_none(raw: object, constructor: object) -> object:
            if raw is None:
                return None
            if not isinstance(raw, Mapping):
                raise ValueError("managed Python nested execution receipt must be an object")
            data = dict(raw)
            if "executable_architectures" in data:
                data["executable_architectures"] = tuple(data["executable_architectures"])
            if "asset_evidence_references" in data:
                data["asset_evidence_references"] = tuple(data["asset_evidence_references"])
            if "product_venv_evidence_references" in data:
                data["product_venv_evidence_references"] = tuple(
                    tuple(item) for item in data["product_venv_evidence_references"]
                )
            return constructor(**data)  # type: ignore[operator]

        asset_receipts_raw = payload["asset_receipts"]
        venv_receipts_raw = payload["product_venv_receipts"]
        if not isinstance(asset_receipts_raw, list) or not isinstance(venv_receipts_raw, list):
            raise ValueError("managed Python execution receipt lists are invalid")
        return ManagedPythonRuntimeExecutionRecord(
            _required(payload["schema"], "execution record schema"),
            _required(payload["operation_id"], "execution record operation_id"),
            _required(payload["request_fingerprint"], "execution record fingerprint"),
            _required(payload["action"], "execution record action"),
            _required(payload["target_runtime_identity"], "execution record target identity"),
            _required(payload["runtime_slot_identity"], "execution record runtime slot"),
            None if payload["rollback_runtime_identity"] is None else _required(
                payload["rollback_runtime_identity"], "execution record rollback identity"
            ),
            tuple_pairs(payload["product_venv_identities"], "product_venv_identities"),
            _required(payload["state"], "execution record state"),
            tuple(ExactAssetFetchReceipt(**dict(item)) for item in asset_receipts_raw),
            dataclass_or_none(payload["archive_inspection"], ManagedPythonArchiveInspection),
            dataclass_or_none(payload["runtime_slot_receipt"], ManagedPythonRuntimeSlotReceipt),
            tuple(ProductVenvExecutionReceipt(**dict(item)) for item in venv_receipts_raw),
            dataclass_or_none(payload["activation_receipt"], ManagedPythonActivationReceipt),
            dataclass_or_none(payload["terminal_receipt"], ManagedPythonRuntimeExecutionReceipt),
            dataclass_or_none(payload["rollback_receipt"], ManagedPythonRollbackReceipt),
        )


class ManagedPythonRuntimeExecutor:
    """Execute and durably resume one exact catalog-approved runtime operation."""

    def __init__(self, store: ManagedPythonRuntimeExecutionStore) -> None:
        if not isinstance(store, ManagedPythonRuntimeExecutionStore):
            raise ValueError("managed Python execution store is required")
        self.store = store

    def execute(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
        transport: ExactManagedPythonAssetTransport,
        inspector: ManagedPythonRuntimeArchiveInspector,
        mutation: ManagedPythonRuntimeMutationAdapter,
    ) -> ManagedPythonRuntimeExecutionReceipt:
        with self.store.locked_record(request) as initial:
            record = initial
            if record.state == "ROLLED_BACK":
                raise UniversalInstallerError(
                    "rolled-back managed Python operation cannot reactivate its failed target"
                )
            record = self._acquire(request, record, transport)
            record = self._inspect(request, record, inspector)
            record = self._install_runtime(request, record, mutation)
            record = self._ensure_venvs(request, record, mutation)
            record = self._activate(request, record, mutation)
            record = self._complete(request, record, mutation)
            if record.terminal_receipt is None:
                raise UniversalInstallerError("managed Python execution did not produce a terminal receipt")
            return record.terminal_receipt

    def rollback(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
        mutation: ManagedPythonRuntimeMutationAdapter,
    ) -> ManagedPythonRollbackReceipt:
        """Restore only the frozen pre-upgrade identity and retain failed target bytes."""

        if request.rollback_runtime_identity is None:
            raise UniversalInstallerError("managed Python operation has no frozen rollback runtime")
        with self.store.locked_record(request) as record:
            if record.state == "ROLLED_BACK":
                if record.rollback_receipt is None:
                    raise UniversalInstallerError("managed Python rollback evidence is unavailable")
                return record.rollback_receipt
            if record.state not in {"ACTIVE", "COMPLETE"}:
                raise UniversalInstallerError("managed Python runtime cannot roll back before activation")
            rollback_identity = request.rollback_runtime_identity
            receipt = mutation.rollback_runtime(
                request.operation_id,
                rollback_identity,
                _runtime_slot_identity(rollback_identity),
                request.target.identity_digest,
            )
            if not isinstance(receipt, ManagedPythonRollbackReceipt):
                raise UniversalInstallerError("managed Python mutation adapter returned invalid rollback evidence")
            if (
                receipt.operation_id != request.operation_id
                or receipt.restored_runtime_identity != rollback_identity
                or receipt.restored_runtime_slot_identity != _runtime_slot_identity(rollback_identity)
                or receipt.retained_failed_runtime_identity != request.target.identity_digest
            ):
                raise UniversalInstallerError("managed Python rollback does not bind frozen identities")
            readback = mutation.read_active_runtime()
            if (
                readback.state != "ACTIVE"
                or readback.runtime_identity != rollback_identity
                or readback.runtime_slot_identity != _runtime_slot_identity(rollback_identity)
                or request.target.identity_digest not in readback.retained_runtime_identities
                or readback.evidence_reference != receipt.final_readback_evidence_reference
            ):
                raise UniversalInstallerError("managed Python rollback final readback is invalid")
            updated = replace(record, state="ROLLED_BACK", rollback_receipt=receipt)
            self.store.write(updated)
            return receipt

    def _acquire(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
        record: ManagedPythonRuntimeExecutionRecord,
        transport: ExactManagedPythonAssetTransport,
    ) -> ManagedPythonRuntimeExecutionRecord:
        if _STATE_INDEX[record.state] > _STATE_INDEX["ACQUIRED"]:
            self._verify_captured_assets(request, record)
            return record
        if record.state == "ACQUIRED":
            self._verify_captured_assets(request, record)
            return record
        self.store.prepare_asset_directory(request.operation_id)
        locators = _asset_locators(request.target)
        receipts = list(record.asset_receipts)
        for receipt in receipts:
            self._verify_captured_receipt(request, receipt)
        for role in _ASSET_ROLES[len(receipts):]:
            locator = locators[role]
            destination = self.store.prepare_asset_destination(request.operation_id, role)
            receipt = transport.fetch(role, locator, destination)
            if not isinstance(receipt, ExactAssetFetchReceipt):
                raise UniversalInstallerError("managed Python transport returned an invalid receipt")
            maximum = _MAXIMUM_RUNTIME_ARCHIVE_BYTES if role == "runtime" else _MAXIMUM_EVIDENCE_BYTES
            actual_digest, actual_size = _sha256_file(destination, maximum)
            if (
                receipt.role != role
                or receipt.requested_url != locator.url
                or receipt.final_url != locator.url
                or receipt.digest != locator.digest
                or receipt.digest != actual_digest
                or receipt.byte_count != actual_size
            ):
                raise UniversalInstallerError("managed Python transport did not capture the exact signed asset")
            receipts.append(receipt)
            record = replace(record, asset_receipts=tuple(receipts))
            self.store.write(record)
        record = replace(record, state="ACQUIRED")
        self.store.write(record)
        return record

    def _verify_captured_assets(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
        record: ManagedPythonRuntimeExecutionRecord,
    ) -> None:
        if len(record.asset_receipts) != len(_ASSET_ROLES):
            raise UniversalInstallerError("managed Python execution lacks complete asset receipts")
        for receipt in record.asset_receipts:
            self._verify_captured_receipt(request, receipt)

    def _verify_captured_receipt(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
        receipt: ExactAssetFetchReceipt,
    ) -> None:
        locator = _asset_locators(request.target)[receipt.role]
        maximum = (
            _MAXIMUM_RUNTIME_ARCHIVE_BYTES if receipt.role == "runtime" else _MAXIMUM_EVIDENCE_BYTES
        )
        actual_digest, actual_size = _sha256_file(
            self.store.asset_path(request.operation_id, receipt.role), maximum
        )
        if (
            receipt.requested_url != locator.url
            or receipt.final_url != locator.url
            or receipt.digest != locator.digest
            or receipt.digest != actual_digest
            or receipt.byte_count != actual_size
        ):
            raise UniversalInstallerError("managed Python captured asset changed after acquisition")

    def _inspect(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
        record: ManagedPythonRuntimeExecutionRecord,
        inspector: ManagedPythonRuntimeArchiveInspector,
    ) -> ManagedPythonRuntimeExecutionRecord:
        if _STATE_INDEX[record.state] >= _STATE_INDEX["VERIFIED"]:
            if record.archive_inspection is None:
                raise UniversalInstallerError("managed Python archive inspection is unavailable")
            record.archive_inspection.verify(request.target)
            return record
        assets = {role: self.store.asset_path(request.operation_id, role) for role in _ASSET_ROLES}
        inspection = inspector.inspect(request.target, assets)
        if not isinstance(inspection, ManagedPythonArchiveInspection):
            raise UniversalInstallerError("managed Python archive inspector returned invalid evidence")
        inspection.verify(request.target)
        record = replace(record, state="VERIFIED", archive_inspection=inspection)
        self.store.write(record)
        return record

    def _install_runtime(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
        record: ManagedPythonRuntimeExecutionRecord,
        mutation: ManagedPythonRuntimeMutationAdapter,
    ) -> ManagedPythonRuntimeExecutionRecord:
        if _STATE_INDEX[record.state] >= _STATE_INDEX["RUNTIME_READY"]:
            if record.runtime_slot_receipt is None:
                raise UniversalInstallerError("managed Python runtime-slot receipt is unavailable")
            record.runtime_slot_receipt.verify(request)
            return record
        receipt = mutation.read_runtime_slot(
            request.operation_id,
            request.target.identity_digest,
            request.runtime_slot_identity,
        )
        if receipt is None:
            if record.archive_inspection is None:
                raise UniversalInstallerError("managed Python archive was not inspected")
            receipt = mutation.install_runtime_slot(
                request.operation_id,
                request.target,
                request.runtime_slot_identity,
                self.store.asset_path(request.operation_id, "runtime"),
                record.archive_inspection,
            )
        if not isinstance(receipt, ManagedPythonRuntimeSlotReceipt):
            raise UniversalInstallerError("managed Python mutation adapter returned invalid runtime evidence")
        receipt.verify(request)
        record = replace(record, state="RUNTIME_READY", runtime_slot_receipt=receipt)
        self.store.write(record)
        return record

    def _ensure_venvs(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
        record: ManagedPythonRuntimeExecutionRecord,
        mutation: ManagedPythonRuntimeMutationAdapter,
    ) -> ManagedPythonRuntimeExecutionRecord:
        if _STATE_INDEX[record.state] >= _STATE_INDEX["VENVS_READY"]:
            self._verify_venv_receipts(request, record.product_venv_receipts)
            return record
        receipts: list[ProductVenvExecutionReceipt] = []
        for requirement in request.product_venvs:
            receipt = mutation.read_product_venv(
                request.operation_id,
                requirement,
                request.runtime_slot_identity,
            )
            if receipt is None:
                receipt = mutation.ensure_product_venv(
                    request.operation_id,
                    requirement,
                    request.runtime_slot_identity,
                )
            if not isinstance(receipt, ProductVenvExecutionReceipt):
                raise UniversalInstallerError("managed Python mutation adapter returned invalid venv evidence")
            receipt.verify(request, requirement)
            receipts.append(receipt)
        self._verify_venv_receipts(request, tuple(receipts))
        record = replace(record, state="VENVS_READY", product_venv_receipts=tuple(receipts))
        self.store.write(record)
        return record

    @staticmethod
    def _verify_venv_receipts(
        request: ManagedPythonRuntimeExecutionRequest,
        receipts: tuple[ProductVenvExecutionReceipt, ...],
    ) -> None:
        if len(receipts) != len(request.product_venvs):
            raise UniversalInstallerError("managed Python execution lacks exact product-venv evidence")
        for receipt, requirement in zip(receipts, request.product_venvs):
            receipt.verify(request, requirement)

    def _activate(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
        record: ManagedPythonRuntimeExecutionRecord,
        mutation: ManagedPythonRuntimeMutationAdapter,
    ) -> ManagedPythonRuntimeExecutionRecord:
        if _STATE_INDEX[record.state] >= _STATE_INDEX["ACTIVE"]:
            if record.activation_receipt is None:
                raise UniversalInstallerError("managed Python activation receipt is unavailable")
            self._verify_activation(request, record.activation_receipt)
            return record
        observed = mutation.read_active_runtime()
        receipt: ManagedPythonActivationReceipt
        if (
            observed.state == "ACTIVE"
            and observed.runtime_identity == request.target.identity_digest
            and observed.runtime_slot_identity == request.runtime_slot_identity
            and (
                request.rollback_runtime_identity is None
                or request.rollback_runtime_identity in observed.retained_runtime_identities
            )
        ):
            receipt = ManagedPythonActivationReceipt(
                request.operation_id,
                request.target.identity_digest,
                request.runtime_slot_identity,
                request.rollback_runtime_identity,
                "ACTIVE",
                observed.evidence_reference,
            )
        else:
            receipt = mutation.activate_runtime(
                request.operation_id,
                request.target.identity_digest,
                request.runtime_slot_identity,
                request.rollback_runtime_identity,
            )
        if not isinstance(receipt, ManagedPythonActivationReceipt):
            raise UniversalInstallerError("managed Python mutation adapter returned invalid activation evidence")
        self._verify_activation(request, receipt)
        record = replace(record, state="ACTIVE", activation_receipt=receipt)
        self.store.write(record)
        return record

    @staticmethod
    def _verify_activation(
        request: ManagedPythonRuntimeExecutionRequest,
        receipt: ManagedPythonActivationReceipt,
    ) -> None:
        if (
            receipt.operation_id != request.operation_id
            or receipt.active_runtime_identity != request.target.identity_digest
            or receipt.active_runtime_slot_identity != request.runtime_slot_identity
            or receipt.retained_runtime_identity != request.rollback_runtime_identity
        ):
            raise UniversalInstallerError("managed Python activation does not bind target and rollback identities")

    def _complete(
        self,
        request: ManagedPythonRuntimeExecutionRequest,
        record: ManagedPythonRuntimeExecutionRecord,
        mutation: ManagedPythonRuntimeMutationAdapter,
    ) -> ManagedPythonRuntimeExecutionRecord:
        if record.state == "COMPLETE":
            if record.terminal_receipt is None:
                raise UniversalInstallerError("managed Python terminal receipt is unavailable")
            return record
        readback = mutation.read_active_runtime()
        if (
            not isinstance(readback, ManagedPythonRuntimeReadback)
            or readback.state != "ACTIVE"
            or readback.runtime_identity != request.target.identity_digest
            or readback.managed_root_identity != MANAGED_PYTHON_ROOT_IDENTITY
            or readback.runtime_slot_identity != request.runtime_slot_identity
            or (
                request.rollback_runtime_identity is not None
                and request.rollback_runtime_identity not in readback.retained_runtime_identities
            )
        ):
            raise UniversalInstallerError("managed Python final readback does not verify exact activation")
        if record.archive_inspection is None or record.runtime_slot_receipt is None or record.activation_receipt is None:
            raise UniversalInstallerError("managed Python execution evidence is incomplete")
        receipt = ManagedPythonRuntimeExecutionReceipt(
            request.operation_id,
            request.fingerprint(),
            request.target.identity_digest,
            request.runtime_slot_identity,
            request.rollback_runtime_identity,
            tuple(item.evidence_reference for item in record.asset_receipts),
            record.archive_inspection.evidence_reference,
            record.runtime_slot_receipt.evidence_reference,
            tuple((item.component_identity, item.evidence_reference) for item in record.product_venv_receipts),
            record.activation_receipt.evidence_reference,
            readback.evidence_reference,
            f"receipt:managed-python-{request.operation_id}",
            "COMPLETE",
        )
        record = replace(record, state="COMPLETE", terminal_receipt=receipt)
        self.store.write(record)
        return record
