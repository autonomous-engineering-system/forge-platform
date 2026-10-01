#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import stat
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from forge_platform.managed_system_keychain_store import (
    ManagedSystemKeychainCredentialStore, ManagedSystemKeychainStoreError,
)


WORKER = Path("/Applications/ForgePlatformInstaller.app/Contents/Resources/forge-platform-product-worker.pyz")
REFERENCE = "keychain://forge.ep/consumer"
OPERATION = "operation-123"
MATERIAL = "a" * 32


def receipt(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


class Info:
    st_mode = stat.S_IFREG | 0o755
    st_uid = 0
    st_nlink = 1


class ManagedSystemKeychainStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.store = ManagedSystemKeychainCredentialStore(worker_path=WORKER)
        self.root = patch("forge_platform.managed_system_keychain_store.os.geteuid", return_value=0)
        self.stat = patch("forge_platform.managed_system_keychain_store.os.lstat", return_value=Info())
        self.root.start()
        self.stat.start()
        self.addCleanup(self.root.stop)
        self.addCleanup(self.stat.stop)

    def test_exact_private_child_and_secret_free_receipts(self) -> None:
        values = [
            {"fingerprint": None},
            {"verified": True},
            {"fingerprint": "f" * 64},
            {"cleared": True},
        ]
        requests = []

        def run(args, **kwargs):
            self.assertEqual(args, [str(WORKER.parent / "forge-platform-installer-helper"),
                                    "--keychain-store-child"])
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
            self.assertEqual(kwargs["timeout"], 10)
            self.assertEqual(kwargs["cwd"], "/var/empty")
            self.assertEqual(kwargs["env"], {"HOME": "/var/empty", "LANG": "C", "LC_ALL": "C"})
            requests.append(json.loads(kwargs["input"]))
            return subprocess.CompletedProcess(args, 0, receipt(values.pop(0)), b"")

        with patch("forge_platform.managed_system_keychain_store.subprocess.run", side_effect=run):
            self.assertIsNone(self.store.fingerprint(REFERENCE, OPERATION))
            self.assertTrue(self.store.put_verified(REFERENCE, OPERATION, MATERIAL))
            self.assertEqual(self.store.fingerprint(REFERENCE, OPERATION), "f" * 64)
            self.assertIsNone(self.store.clear_owned(REFERENCE, OPERATION))
        self.assertEqual([request["action"] for request in requests],
                         ["fingerprint", "put-verified", "fingerprint", "clear-owned"])
        self.assertEqual(requests[1]["material"], MATERIAL)
        self.assertTrue(all("material" not in request for request in requests[::2]))

    def test_target_and_layout_reject_before_process(self) -> None:
        for path in (Path("relative/forge-platform-product-worker.pyz"),
                     WORKER.with_name("other.pyz"),
                     Path("/Applications/ForgePlatformInstaller.app/Other/forge-platform-product-worker.pyz")):
            with self.assertRaisesRegex(ManagedSystemKeychainStoreError, "layout"):
                ManagedSystemKeychainCredentialStore(worker_path=path)
        with patch("forge_platform.managed_system_keychain_store.subprocess.run") as run:
            for reference, operation, material in (
                ("keychain://other/path/extra", OPERATION, None),
                (REFERENCE, "../bad", None),
                (REFERENCE, OPERATION, "short"),
            ):
                with self.assertRaises(ManagedSystemKeychainStoreError):
                    self.store._invoke("put-verified" if material is not None else "fingerprint",
                                       reference, operation, material)
            run.assert_not_called()

    def test_nonroot_symlink_foreign_and_mutable_helper_reject(self) -> None:
        with patch("forge_platform.managed_system_keychain_store.os.geteuid", return_value=501):
            with self.assertRaisesRegex(ManagedSystemKeychainStoreError, "unsafe"):
                self.store.fingerprint(REFERENCE, OPERATION)
        for mode, uid, links in (
            (stat.S_IFLNK | 0o755, 0, 1),
            (stat.S_IFREG | 0o755, 501, 1),
            (stat.S_IFREG | 0o777, 0, 1),
            (stat.S_IFREG | 0o644, 0, 1),
            (stat.S_IFREG | 0o755, 0, 2),
        ):
            info = type("Info", (), {"st_mode": mode, "st_uid": uid, "st_nlink": links})()
            with patch("forge_platform.managed_system_keychain_store.os.lstat", return_value=info):
                with self.assertRaisesRegex(ManagedSystemKeychainStoreError, "unsafe"):
                    self.store.fingerprint(REFERENCE, OPERATION)

    def test_lost_ambiguous_or_secret_echo_receipts_fail_closed(self) -> None:
        for output in (
            receipt({"verified": False, "material": MATERIAL}),
            b'{"verified":true,"verified":false}',
            b'{"verified":true}\n',
            receipt({"verified": 1}),
            b"x" * 257,
        ):
            with patch("forge_platform.managed_system_keychain_store.subprocess.run",
                       return_value=subprocess.CompletedProcess([], 0, output, b"")):
                with self.assertRaises(ManagedSystemKeychainStoreError):
                    self.store.put_verified(REFERENCE, OPERATION, MATERIAL)
        with patch("forge_platform.managed_system_keychain_store.subprocess.run",
                   side_effect=subprocess.TimeoutExpired("helper", 10)):
            with self.assertRaisesRegex(ManagedSystemKeychainStoreError, "unavailable"):
                self.store.put_verified(REFERENCE, OPERATION, MATERIAL)
        with patch("forge_platform.managed_system_keychain_store.subprocess.run",
                   return_value=subprocess.CompletedProcess([], 78, b"", b"secret")):
            with self.assertRaisesRegex(ManagedSystemKeychainStoreError, "unavailable"):
                self.store.fingerprint(REFERENCE, OPERATION)


if __name__ == "__main__":
    unittest.main()
