#!/usr/bin/env python3
from __future__ import annotations

import base64
from contextlib import redirect_stdout, redirect_stderr
import io
import json
import os
import tempfile
from types import SimpleNamespace
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


class QualificationToolBoundaryTests(unittest.TestCase):
    def test_key_tool_regular_owned_executable_and_public_output_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);tool=root/"source-only-tool"
            tool.write_bytes(b"qualification only");tool.chmod(0o700)
            self.assertEqual(qualification._descriptor_key_tool(tool),tool.resolve())
            tool.chmod(0o722)
            with self.assertRaises(ValueError):qualification._descriptor_key_tool(tool)
            tool.chmod(0o700);alias=root/"alias";alias.symlink_to(tool)
            with self.assertRaises(ValueError):qualification._descriptor_key_tool(alias)
            with self.assertRaises(ValueError):qualification._descriptor_key_tool(root)
        prefix="OFFLINE_DESCRIPTOR_KEY=READY key_id=source-test public_key_base64="
        public=base64.b64encode(b"p"*32).decode()
        for text,status,valid in [(prefix+public,0,True),(prefix+public,1,False),(prefix+public+"\nextra",0,False),("wrong",0,False),(prefix+"bad!",0,False),(prefix+base64.b64encode(b"p"*31).decode(),0,False)]:
            with patch.object(qualification.subprocess,"run",return_value=subprocess.CompletedProcess([],status,stdout=text)):
                if valid:self.assertEqual(qualification._tool_public_key(Path("unused-source-tool"),"source-test"),b"p"*32)
                else:
                    with self.assertRaises(ValueError):qualification._tool_public_key(Path("unused-source-tool"),"source-test")
    def test_signature_envelope_and_payload_files_are_bound_to_reviewed_key(self):
        signature=base64.urlsafe_b64encode(b"s"*64).decode().rstrip("=")
        good=dict(algorithm="ed25519",key_id="source-test",signature=signature)
        cases=[good,[],dict(good,extra=True),dict(good,algorithm="wrong"),dict(good,key_id="wrong"),dict(good,signature="bad!")]
        for envelope in cases:
            def run(arguments,**kwargs):
                self.assertEqual(Path(arguments[-2]).read_bytes(),b"exact source-only signing payload")
                Path(arguments[-1]).write_text(json.dumps(envelope))
                return subprocess.CompletedProcess(arguments,0)
            with patch.object(qualification.subprocess,"run",side_effect=run):
                if envelope==good:
                    value,raw=qualification._tool_signature(Path("source-only-tool"),"source-test",b"exact source-only signing payload")
                    self.assertEqual(value,good);self.assertEqual(raw,b"s"*64)
                else:
                    with self.assertRaises(ValueError):qualification._tool_signature(Path("source-only-tool"),"source-test",b"exact source-only signing payload")
        with patch.object(qualification.subprocess,"run",return_value=subprocess.CompletedProcess([],1)):
            with self.assertRaises(ValueError):qualification._tool_signature(Path("source-only-tool"),"source-test",b"message")
    def test_strict_json_and_timestamp_reject_duplicate_and_ambiguous_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            p=Path(temporary)/"document.json"
            for raw in [b'{"schema":1,"schema":2}',b"bad JSON",b"\xff"]:
                p.write_bytes(raw)
                with self.assertRaises(ValueError):qualification._read_json(p,"source-only")
            with self.assertRaises(ValueError):qualification._read_json(p,"source-only",maximum=0)
            p.unlink()
            with self.assertRaises(ValueError):qualification._read_json(p,"source-only")
        for value in ["bad","2026-10-11T00:00:00"]:
            with self.assertRaises(ValueError):qualification._timestamp(value,"source-only")
        self.assertEqual(qualification._timestamp("2026-10-11T00:00:00Z","source-only"),"2026-10-11T00:00:00Z")
    def test_cli_passes_both_helper_fields_and_never_reports_failure_as_pass(self):
        args=["--preparation","p.json","--signed-archive","archive.zip","--release-trust","trust.json","--descriptor-key-tool","source-only-tool","--code-directory-sha256","a"*64,"--notarization-receipt-reference","receipt:source-test","--catalog-url","https://catalog.example.invalid/","--published-at","2026-10-11T00:00:00Z","--expires-at","2026-10-20T00:00:00Z","--run-id","1","--journal-root","journal","--output-directory","output","--signed-helper-package","source.pkg","--helper-package-notarization-receipt-reference","receipt:source-package"]
        operation=SimpleNamespace(operation_id="source-only",descriptor_digest="sha256:"+"a"*64,archives={"arm64":"sha256:"+"b"*64})
        with patch.object(qualification,"qualify",return_value=operation) as call,redirect_stdout(io.StringIO()):
            self.assertEqual(qualification.main(args),0)
        self.assertEqual(call.call_args.kwargs["signed_helper_package"],Path("source.pkg"))
        self.assertEqual(call.call_args.kwargs["helper_package_notarization_receipt_reference"],"receipt:source-package")
        output=io.StringIO()
        with patch.object(qualification,"qualify",side_effect=ValueError("source-only failure")),redirect_stdout(output),redirect_stderr(output):
            self.assertEqual(qualification.main(args),1)
        self.assertNotIn("QUALIFICATION=PASS",output.getvalue())


if __name__ == "__main__":
    unittest.main()
