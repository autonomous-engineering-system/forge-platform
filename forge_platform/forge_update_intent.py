"""Private installer intent for one exact Forge product update operation.

This is coordination evidence, not an updater receipt or authority to mutate
Forge data. Only the frozen product updater may advance product state.
"""

from __future__ import annotations

from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from typing import Mapping


_OPERATION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
_FINGERPRINT = re.compile(r"[0-9a-f]{64}")
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
_PHASES = ("PREPARED", "UPDATER_INVOKED", "PRODUCT_COMPLETE", "COMPLETE")
_FIELDS = frozenset({
    "schema", "operation_id", "request_fingerprint", "instance_id",
    "installed_artifact", "candidate_artifact", "assessment_reference",
    "phase", "product_receipt_reference",
})


class ForgeUpdateIntentError(RuntimeError):
    """The helper cannot prove a durable, exact update intent."""


def _unique_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ForgeUpdateIntentError("Forge update intent contains duplicate JSON keys")
        result[key] = value
    return result


def _canonical(value: Mapping[str, object]) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


@dataclass(frozen=True)
class ForgeUpdateIntent:
    operation_id: str
    request_fingerprint: str
    instance_id: str
    installed_artifact: str
    candidate_artifact: str
    assessment_reference: str
    phase: str = "PREPARED"
    product_receipt_reference: str | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.operation_id, str) or _OPERATION_ID.fullmatch(self.operation_id) is None or self.operation_id in {".", ".."}:
            raise ValueError("Forge update intent operation ID is unsafe")
        if not isinstance(self.request_fingerprint, str) or _FINGERPRINT.fullmatch(self.request_fingerprint) is None:
            raise ValueError("Forge update intent request fingerprint is invalid")
        for value in (
            self.instance_id, self.installed_artifact, self.candidate_artifact,
            self.assessment_reference,
        ):
            if not isinstance(value, str) or not value:
                raise ValueError("Forge update intent identity is incomplete")
        if _DIGEST.fullmatch(self.installed_artifact) is None or _DIGEST.fullmatch(self.candidate_artifact) is None:
            raise ValueError("Forge update intent artifact digest is invalid")
        if not self.assessment_reference.startswith("forge-update-assess:sha256:") or _DIGEST.fullmatch(self.assessment_reference.removeprefix("forge-update-assess:")) is None:
            raise ValueError("Forge update intent assessment reference is invalid")
        if self.phase not in _PHASES:
            raise ValueError("Forge update intent phase is unsupported")
        if self.phase in {"PRODUCT_COMPLETE", "COMPLETE"} and (
            not isinstance(self.product_receipt_reference, str)
            or not self.product_receipt_reference.startswith("forge-update:sha256:")
            or _DIGEST.fullmatch(self.product_receipt_reference.removeprefix("forge-update:")) is None
        ):
            raise ValueError("Forge update terminal intent requires a product receipt")
        if self.phase in {"PREPARED", "UPDATER_INVOKED"} and self.product_receipt_reference is not None:
            raise ValueError("Forge update pending intent cannot claim a product receipt")

    def payload(self) -> dict[str, object]:
        return {
            "schema": "forge-platform.forge-update-intent/v1",
            "operation_id": self.operation_id,
            "request_fingerprint": self.request_fingerprint,
            "instance_id": self.instance_id,
            "installed_artifact": self.installed_artifact,
            "candidate_artifact": self.candidate_artifact,
            "assessment_reference": self.assessment_reference,
            "phase": self.phase,
            "product_receipt_reference": self.product_receipt_reference,
        }

    def same_selection(self, other: "ForgeUpdateIntent") -> bool:
        return all(
            getattr(self, name) == getattr(other, name)
            for name in (
                "operation_id", "request_fingerprint", "instance_id",
                "installed_artifact", "candidate_artifact", "assessment_reference",
            )
        )


class ForgeUpdateIntentStore:
    """Exact private file under an already provisioned helper-owned directory."""

    def __init__(self, root: Path) -> None:
        if not isinstance(root, Path) or not root.is_absolute():
            raise ValueError("Forge update intent root must be absolute")
        self.root = root

    def _directory(self) -> int:
        flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(self.root, flags)
        except OSError as error:
            raise ForgeUpdateIntentError("Forge update intent root is unavailable") from error
        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
            os.close(descriptor)
            raise ForgeUpdateIntentError("Forge update intent root owner or mode is unsafe")
        return descriptor

    @staticmethod
    def _decode(raw: bytes) -> ForgeUpdateIntent:
        try:
            value = json.loads(raw, object_pairs_hook=_unique_pairs)
        except (UnicodeError, json.JSONDecodeError, ValueError) as error:
            raise ForgeUpdateIntentError("Forge update intent is unreadable") from error
        if not isinstance(value, dict) or set(value) != _FIELDS or value.get("schema") != "forge-platform.forge-update-intent/v1":
            raise ForgeUpdateIntentError("Forge update intent shape is invalid")
        try:
            intent = ForgeUpdateIntent(**{key: value[key] for key in _FIELDS if key != "schema"})
        except (TypeError, ValueError) as error:
            raise ForgeUpdateIntentError("Forge update intent values are invalid") from error
        if raw != _canonical(intent.payload()):
            raise ForgeUpdateIntentError("Forge update intent bytes are noncanonical")
        return intent

    def read(self, operation_id: str) -> ForgeUpdateIntent | None:
        if not isinstance(operation_id, str) or _OPERATION_ID.fullmatch(operation_id) is None or operation_id in {".", ".."}:
            raise ValueError("Forge update intent operation ID is unsafe")
        directory = self._directory()
        try:
            try:
                descriptor = os.open(
                    operation_id + ".json", os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory,
                )
            except FileNotFoundError:
                return None
            except OSError as error:
                raise ForgeUpdateIntentError("Forge update intent file is unavailable") from error
            try:
                metadata = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                    or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1
                    or metadata.st_size > 16_384
                ):
                    raise ForgeUpdateIntentError("Forge update intent file is unsafe")
                raw = os.read(descriptor, 16_385)
                intent = self._decode(raw)
                if intent.operation_id != operation_id:
                    raise ForgeUpdateIntentError("Forge update intent filename does not match its operation")
                return intent
            finally:
                os.close(descriptor)
        finally:
            os.close(directory)

    def _write(self, intent: ForgeUpdateIntent, *, create: bool) -> None:
        directory = self._directory()
        name = intent.operation_id + ".json"
        raw = _canonical(intent.payload())
        temporary = None
        try:
            if create:
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
                try:
                    descriptor = os.open(name, flags, 0o600, dir_fd=directory)
                except FileExistsError as error:
                    raise ForgeUpdateIntentError("Forge update intent already exists") from error
            else:
                descriptor, temporary = tempfile.mkstemp(prefix=".forge-update-", dir=self.root)
                os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            if temporary is not None:
                os.replace(temporary, self.root / name)
            os.fsync(directory)
        finally:
            if temporary is not None:
                Path(temporary).unlink(missing_ok=True)
            os.close(directory)

    def prepare(self, intent: ForgeUpdateIntent) -> ForgeUpdateIntent:
        if intent.phase != "PREPARED":
            raise ValueError("Forge update intent preparation must be pending")
        directory = self._directory()
        try:
            fcntl.flock(directory, fcntl.LOCK_EX)
            existing = self.read(intent.operation_id)
            if existing is not None:
                if not existing.same_selection(intent):
                    raise ForgeUpdateIntentError("Forge update operation identity changed")
                return existing
            for entry in self.root.iterdir():
                if not entry.name.endswith(".json"):
                    continue
                other = self.read(entry.name[:-5])
                if other is not None and other.instance_id == intent.instance_id and other.phase != "COMPLETE":
                    raise ForgeUpdateIntentError("Forge instance has another pending update operation")
            self._write(intent, create=True)
            observed = self.read(intent.operation_id)
            if observed != intent:
                raise ForgeUpdateIntentError("Forge update intent readback changed")
            return observed
        finally:
            os.close(directory)

    def advance(self, current: ForgeUpdateIntent, phase: str, product_receipt_reference: str | None = None) -> ForgeUpdateIntent:
        if phase not in _PHASES or _PHASES.index(phase) != _PHASES.index(current.phase) + 1:
            raise ForgeUpdateIntentError("Forge update intent phase transition is invalid")
        directory = self._directory()
        try:
            fcntl.flock(directory, fcntl.LOCK_EX)
            observed = self.read(current.operation_id)
            if observed != current:
                raise ForgeUpdateIntentError("Forge update intent changed before phase advance")
            receipt = product_receipt_reference or current.product_receipt_reference
            if product_receipt_reference is not None and current.product_receipt_reference is not None and product_receipt_reference != current.product_receipt_reference:
                raise ForgeUpdateIntentError("Forge product receipt changed during phase advance")
            updated = ForgeUpdateIntent(
                current.operation_id, current.request_fingerprint, current.instance_id,
                current.installed_artifact, current.candidate_artifact,
                current.assessment_reference, phase, receipt,
            )
            self._write(updated, create=False)
            if self.read(current.operation_id) != updated:
                raise ForgeUpdateIntentError("Forge update intent phase readback changed")
            return updated
        finally:
            os.close(directory)
