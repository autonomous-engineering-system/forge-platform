"""Published managed-Python qualification must bind exact bytes and real probes."""
from __future__ import annotations

import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from scripts import qualify_managed_python_runtime as subject


def archive_with(entries: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as output:
        for name, raw in entries.items():
            member = tarfile.TarInfo(name)
            member.size = len(raw)
            member.mode = 0o755 if name == "bin/python3" else 0o644
            output.addfile(member, io.BytesIO(raw))
    return buffer.getvalue()


class QualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.binary = b"mock interpreter bytes"
        self.build = subject.canonical({
            "schema": "forge-platform.managed-tool-build-provenance/v1",
            "version": "3.14.7",
            "outputs": {"entrypoint": "bin/python3", "entrypoint_digest": subject.digest(self.binary)},
        })
        self.manifest = subject.canonical({
            "schema": "forge-platform.managed-python-runtime-archive-manifest/v1",
            "implementation": "cpython", "operating_system": "macos", "architecture": "arm64",
            "minimum_macos_version": "26.0.0", "build_variant": "standard-gil",
            "python_tag": "cp314", "abi_tag": "cp314", "platform_tag": "macosx_26_0_arm64",
            "artifact_kind": "forge-platform-managed-python-runtime-archive-v1",
            "managed_root_identity": "forge-platform-managed-python-v1",
            "policy_revision": "managed-tools/v1", "artifact_url": "https://example.test/runtime",
            "source_url": "https://example.test/source", "source_digest": "sha256:" + "1" * 64,
            "source_provenance_url": "https://example.test/source-provenance",
            "source_provenance_digest": "sha256:" + "2" * 64,
            "build_provenance_url": "https://example.test/build-provenance",
            "version": "3.14.7",
            "build_provenance_digest": subject.digest(self.build),
            "interpreter_relative_path": "bin/python3",
        })
        self.archive = archive_with({"forge-platform-runtime.json": self.manifest, "bin/python3": self.binary})
        self.sha = "a" * 40

    def qualify(self, archive: bytes | None = None, build: bytes | None = None):
        raw_archive = self.archive if archive is None else archive
        raw_build = self.build if build is None else build
        def probe(executable, args, *, home):
            if "venv" in args:
                (home / "isolated-venv/bin").mkdir(parents=True)
                (home / "isolated-venv/bin/python3").write_bytes(self.binary)
                return ""
            if "import json,sys,pip" in args[-1]:
                return '{"isolated":true,"pip":true}'
            return '{"version":[3,14,7],"machine":"arm64","ssl":"OpenSSL","sqlite":"3","lzma":true,"zlib":true,"ctypes":true}'
        with patch.object(subject.platform, "system", return_value="Darwin"), \
             patch.object(subject.platform, "machine", return_value="arm64"), \
             patch.object(subject, "run_interpreter", side_effect=probe):
            return subject.qualify(raw_archive, raw_build, source_sha=self.sha,
                                   expected_archive_digest=subject.digest(raw_archive),
                                   expected_build_digest=subject.digest(raw_build))

    def test_exact_inputs_produce_secret_free_pass(self) -> None:
        report = self.qualify()
        self.assertEqual(report["outcome"], "PASS")
        self.assertEqual(report["interpreter_digest"], subject.digest(self.binary))
        self.assertTrue(report["runtime_identity_digest"].startswith("sha256:"))
        self.assertEqual(set(report["checks"].values()), {"PASS"})
        self.assertEqual(subject.strict_object(subject.canonical(report)), report)

    def test_wrong_source_host_and_digest_fail(self) -> None:
        with self.assertRaisesRegex(subject.QualificationError, "exact Git SHA"):
            subject.qualify(self.archive, self.build, source_sha="bad",
                            expected_archive_digest=subject.digest(self.archive),
                            expected_build_digest=subject.digest(self.build))
        with patch.object(subject.platform, "system", return_value="Linux"):
            with self.assertRaisesRegex(subject.QualificationError, "native Apple"):
                subject.qualify(self.archive, self.build, source_sha=self.sha,
                                expected_archive_digest=subject.digest(self.archive),
                                expected_build_digest=subject.digest(self.build))
        with patch.object(subject.platform, "system", return_value="Darwin"), \
             patch.object(subject.platform, "machine", return_value="arm64"):
            with self.assertRaisesRegex(subject.QualificationError, "input digest"):
                subject.qualify(self.archive, self.build, source_sha=self.sha,
                                expected_archive_digest="sha256:" + "0" * 64,
                                expected_build_digest=subject.digest(self.build))

    def test_wrong_provenance_or_manifest_fails(self) -> None:
        wrong_build = subject.canonical({"schema": "wrong", "version": "3.14.7"})
        with self.assertRaisesRegex(subject.QualificationError, "build provenance"):
            self.qualify(build=wrong_build)
        wrong_archive = archive_with({"forge-platform-runtime.json": b"{}", "bin/python3": self.binary})
        with self.assertRaisesRegex(subject.QualificationError, "archive manifest"):
            self.qualify(archive=wrong_archive)
        wrong_binary = archive_with({"forge-platform-runtime.json": self.manifest, "bin/python3": b"different"})
        with self.assertRaisesRegex(subject.QualificationError, "interpreter bytes"):
            self.qualify(archive=wrong_binary)
        with self.assertRaisesRegex(subject.QualificationError, "identity is incomplete"):
            subject.runtime_identity_digest({}, subject.digest(self.archive))

    def test_unsafe_archive_rejected(self) -> None:
        for name in ("../escape", "/absolute", "./alias"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                unsafe = archive_with({"forge-platform-runtime.json": self.manifest,
                                       "bin/python3": self.binary, name: b"x"})
                with self.assertRaisesRegex(subject.QualificationError, "unsafe"):
                    subject.safe_extract(unsafe, Path(temporary))
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(subject.QualificationError, "incomplete"):
                subject.safe_extract(archive_with({"bin/python3": self.binary}), Path(temporary))

    def test_json_and_public_url_fail_closed(self) -> None:
        with self.assertRaisesRegex(subject.QualificationError, "duplicate"):
            subject.strict_object(b'{"a":1,"a":2}')
        with self.assertRaisesRegex(subject.QualificationError, "root"):
            subject.strict_object(b"[]")
        with self.assertRaisesRegex(subject.QualificationError, "invalid JSON"):
            subject.strict_object(b"not-json")
        with self.assertRaisesRegex(subject.QualificationError, "non-finite"):
            subject.strict_object(b'{"a":NaN}')
        with self.assertRaisesRegex(subject.QualificationError, "unapproved"):
            subject.fetch_exact("https://example.com/runtime", "sha256:" + "0" * 64)

    def test_load_inputs_requires_unique_complete_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "config.json"
            config.write_bytes(subject.canonical({"schema": "wrong", "assets": []}))
            with self.assertRaisesRegex(subject.QualificationError, "schema"):
                subject.load_inputs(config)
            config.write_bytes(subject.canonical({"schema": "forge-platform.managed-tool-pages/v1", "assets": []}))
            with self.assertRaisesRegex(subject.QualificationError, "incomplete"):
                subject.load_inputs(config)
            config.write_bytes(subject.canonical({"schema": "forge-platform.managed-tool-pages/v1", "assets": [
                {"kind": "build-provenance"}, {"kind": "build-provenance"}]}))
            with self.assertRaisesRegex(subject.QualificationError, "ambiguous"):
                subject.load_inputs(config)

    def test_real_subprocess_failure_is_redacted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(subject.QualificationError, "qualification failed"):
                subject.run_interpreter(Path(temporary) / "absent", ["-I"], home=Path(temporary))
            self.assertEqual(subject.run_interpreter(Path("/bin/echo"), ["hello"], home=Path(temporary)), "hello")

    def test_public_fetch_and_complete_config(self) -> None:
        url = "https://autonomous-engineering-system.github.io/forge-platform/managed-tools/v1/runtime"
        response = MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.geturl.return_value = url
        response.read.return_value = b"exact"
        opener = MagicMock()
        opener.open.return_value = response
        with patch.object(subject, "build_opener", return_value=opener):
            self.assertEqual(subject.fetch_exact(url, subject.digest(b"exact")), b"exact")
            with self.assertRaisesRegex(subject.QualificationError, "bytes differ"):
                subject.fetch_exact(url, subject.digest(b"wrong"))
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "config.json"
            config.write_bytes(subject.canonical({
                "schema": "forge-platform.managed-tool-pages/v1",
                "assets": [
                    {"kind": "managed-python-runtime", "url": url, "sha256": subject.digest(self.archive)},
                    {"kind": "build-provenance", "url": url, "sha256": subject.digest(self.build)},
                ],
            }))
            with patch.object(subject, "fetch_exact", side_effect=[self.archive, self.build]):
                loaded, archive, build = subject.load_inputs(config)
            self.assertEqual((archive, build), (self.archive, self.build))
            self.assertEqual(loaded["assets"][0]["kind"], "managed-python-runtime")

    def test_cli_writes_canonical_report_only_after_qualification(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "report.json"
            config = Path(temporary) / "config.json"
            inputs = ({"assets": [
                {"kind": "managed-python-runtime", "sha256": subject.digest(self.archive)},
                {"kind": "build-provenance", "sha256": subject.digest(self.build)},
            ]}, self.archive, self.build)
            with patch.object(subject, "load_inputs", return_value=inputs), \
                 patch.object(subject, "qualify", return_value={"outcome": "PASS"}), \
                 patch.object(subject.sys, "argv", ["qualify", "--config", str(config),
                                                    "--source-sha", self.sha, "--output", str(output)]):
                subject.main()
            self.assertEqual(output.read_bytes(), subject.canonical({"outcome": "PASS"}))
            output.unlink()
            with patch.object(subject, "load_inputs", side_effect=subject.QualificationError("blocked")), \
                 patch.object(subject.sys, "argv", ["qualify", "--config", str(config),
                                                    "--source-sha", self.sha, "--output", str(output)]):
                with self.assertRaises(SystemExit):
                    subject.main()
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
