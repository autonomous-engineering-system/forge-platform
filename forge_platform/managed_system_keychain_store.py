"""Private sealed-worker transport to the signed helper's System Keychain child.

Only the root product worker constructs this backend. Secret material moves on
one stdin pipe to the fixed sibling helper executable; stdout contains only a
bounded, canonical, non-secret receipt. No path or material is caller authority.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


_SCHEMA = "forge-platform.keychain-store-child/v1"
_REFERENCE = re.compile(r"keychain://[A-Za-z0-9._-]{1,128}/[A-Za-z0-9._-]{1,128}\Z")
_OPERATION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
_MATERIAL = re.compile(r"[A-Za-z0-9_-]{32,256}\Z")
_FINGERPRINT = re.compile(r"[0-9a-f]{64}\Z")


class ManagedSystemKeychainStoreError(RuntimeError):
    """The private secure-store operation is unavailable or ambiguous."""


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")


def _strict_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate secure-store receipt field")
        value[key] = item
    return value


class ManagedSystemKeychainCredentialStore:
    """Implements the issuance coordinator's secure-store protocol."""

    def __init__(self, *, worker_path: Path | None = None) -> None:
        worker = worker_path if worker_path is not None else Path(sys.argv[0])
        if (
            not isinstance(worker, Path) or not worker.is_absolute()
            or worker.name != "forge-platform-product-worker.pyz"
            or worker.parent.name != "Resources"
            or worker.parent.parent.name != "Contents"
        ):
            raise ManagedSystemKeychainStoreError("signed worker layout is unavailable")
        self._helper = worker.parent / "forge-platform-installer-helper"

    def prepare_service_reader(self, reference: str, *, operation_id: str) -> bool:
        receipt = self._invoke("prepare-service-reader", reference, operation_id)
        if set(receipt) != {"reader_ready"} or receipt["reader_ready"] is not True:
            raise ManagedSystemKeychainStoreError("released service reader is unavailable")
        return True

    def prepare_installation_service_reader(self, reference: str, *, operation_id: str) -> bool:
        """Requires the native installation journal route; never legacy fallback."""
        receipt = self._invoke("prepare-installation-service-reader", reference, operation_id)
        if set(receipt) != {"reader_ready"} or receipt["reader_ready"] is not True:
            raise ManagedSystemKeychainStoreError("installation service reader is unavailable")
        return True

    def _require_helper(self) -> None:
        try:
            info = os.lstat(self._helper)
        except OSError:
            raise ManagedSystemKeychainStoreError("signed helper child is unavailable") from None
        if (
            os.geteuid() != 0 or not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0 or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) & 0o111 == 0
            or stat.S_IMODE(info.st_mode) & 0o022
        ):
            raise ManagedSystemKeychainStoreError("signed helper child is unsafe")

    def _invoke(
        self, action: str, reference: str, operation_id: str,
        material: str | None = None,
    ) -> dict[str, object]:
        if (
            action not in {"fingerprint", "put-verified", "clear-owned", "prepare-service-reader", "prepare-installation-service-reader"}
            or not isinstance(reference, str) or _REFERENCE.fullmatch(reference) is None
            or not isinstance(operation_id, str) or _OPERATION.fullmatch(operation_id) is None
            or action == "put-verified" and (
                not isinstance(material, str) or _MATERIAL.fullmatch(material) is None
            )
            or action != "put-verified" and material is not None
        ):
            raise ManagedSystemKeychainStoreError("secure-store target is invalid")
        self._require_helper()
        request: dict[str, object] = {
            "schema": _SCHEMA, "action": action, "reference": reference,
            "operation_id": operation_id,
        }
        if material is not None:
            request["material"] = material
        try:
            result = subprocess.run(
                [str(self._helper), "--keychain-store-child"],
                input=_canonical(request), stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=10, check=False,
                cwd="/var/empty", env={"HOME": "/var/empty", "LANG": "C", "LC_ALL": "C"},
            )
            if result.returncode != 0 or not 0 < len(result.stdout) <= 256:
                raise ValueError("secure-store child failed")
            receipt = json.loads(
                result.stdout.decode("ascii"), object_pairs_hook=_strict_object,
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("nonfinite")),
            )
            if not isinstance(receipt, dict) or _canonical(receipt) != result.stdout:
                raise ValueError("secure-store child receipt changed")
            return receipt
        except Exception:
            raise ManagedSystemKeychainStoreError("secure-store child is unavailable") from None

    def fingerprint(self, reference: str, operation_id: str) -> str | None:
        receipt = self._invoke("fingerprint", reference, operation_id)
        if set(receipt) != {"fingerprint"} or (
            receipt["fingerprint"] is not None
            and (not isinstance(receipt["fingerprint"], str)
                 or _FINGERPRINT.fullmatch(receipt["fingerprint"]) is None)
        ):
            raise ManagedSystemKeychainStoreError("secure-store fingerprint is invalid")
        return receipt["fingerprint"]  # type: ignore[return-value]

    def put_verified(self, reference: str, operation_id: str, material: str) -> bool:
        receipt = self._invoke("put-verified", reference, operation_id, material)
        if set(receipt) != {"verified"} or type(receipt["verified"]) is not bool:
            raise ManagedSystemKeychainStoreError("secure-store write receipt is invalid")
        return receipt["verified"]  # type: ignore[return-value]

    def clear_owned(self, reference: str, operation_id: str) -> None:
        receipt = self._invoke("clear-owned", reference, operation_id)
        if receipt != {"cleared": True}:
            raise ManagedSystemKeychainStoreError("secure-store removal receipt is invalid")
