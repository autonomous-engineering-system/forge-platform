#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from hashlib import sha256
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from scripts import qualify_local_installer_release as qualification


class DescriptorSignatureVerificationTests(unittest.TestCase):
    def test_descriptor_digest_covers_exact_newline_terminated_document(self) -> None:
        raw, digest = qualification._descriptor_document({"z": 2, "a": 1})
        self.assertEqual(raw, b'{"a":1,"z":2}\n')
        self.assertEqual(digest, "sha256:" + sha256(raw).hexdigest())
        self.assertNotEqual(digest, "sha256:" + sha256(raw.rstrip(b"\n")).hexdigest())

    def test_ed25519_verification_uses_regular_payload_file(self) -> None:
        payload = b'{"release":"candidate"}'
        observed: dict[str, object] = {}

        def run(arguments: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
            observed["arguments"] = arguments
            observed["kwargs"] = kwargs
            payload_path = Path(arguments[arguments.index("-in") + 1])
            observed["payload"] = payload_path.read_bytes()
            return subprocess.CompletedProcess(arguments, 0)

        with patch.object(qualification.subprocess, "run", side_effect=run):
            qualification._verify_signature(b"p" * 32, payload, b"s" * 64)

        arguments = observed["arguments"]
        self.assertIsInstance(arguments, list)
        self.assertIn("-in", arguments)
        self.assertEqual(observed["payload"], payload)
        self.assertNotIn("input", observed["kwargs"])

    def test_openssl_verification_failure_remains_fail_closed(self) -> None:
        with patch.object(
            qualification.subprocess,
            "run",
            return_value=subprocess.CompletedProcess(["openssl"], 1),
        ):
            with self.assertRaisesRegex(ValueError, "Ed25519 signature verification failed"):
                qualification._verify_signature(b"p" * 32, b"payload", b"s" * 64)


if __name__ == "__main__":
    unittest.main()
