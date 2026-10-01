from __future__ import annotations

from hashlib import sha256
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts import qualify_product_wheels_managed_python as subject


class ProductWheelManagedPythonQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = subject.load_config(subject.ROOT / "product-runtime-qualification-inputs.json")

    def test_committed_exact_inputs(self) -> None:
        self.assertEqual([x["identity"] for x in self.config["products"]], sorted(subject.PRODUCTS))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "inputs.json"
            for mutation in (
                lambda d: d.update(schema="wrong"),
                lambda d: d.update(runtime_identity_digest="wrong"),
                lambda d: d.update(products=[]),
                lambda d: d["products"][0].update(identity="forge-runtime"),
                lambda d: d["products"][0]["wheel"].update(url="https://example.invalid/a.whl"),
                lambda d: d["products"][0]["wheel"].update(digest="wrong"),
                lambda d: d["products"][0].update(source_revision="wrong"),
                lambda d: d["products"][0].update(version="wrong"),
                lambda d: d["products"][0].update(extra="wrong"),
            ):
                value = json.loads(json.dumps(self.config))
                mutation(value)
                path.write_text(json.dumps(value))
                with self.assertRaises(subject.QualificationError):
                    subject.load_config(path)

    def test_fetch_rejects_wrong_host_and_bytes(self) -> None:
        with self.assertRaises(subject.QualificationError):
            subject.fetch_wheel("https://example.invalid/a.whl", "sha256:" + "0" * 64)
        response = unittest.mock.MagicMock()
        response.status = 200
        response.geturl.return_value = "https://files.pythonhosted.org/packages/a.whl"
        response.read.return_value = b"wheel"
        response.__enter__.return_value = response
        with patch.object(subject, "build_opener") as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(subject.QualificationError, "bytes differ"):
                subject.fetch_wheel(response.geturl(), "sha256:" + "0" * 64)
            self.assertEqual(subject.fetch_wheel(response.geturl(), subject.digest(b"wheel")), b"wheel")
            response.status = 302
            with self.assertRaisesRegex(subject.QualificationError, "URL changed"):
                subject.fetch_wheel(response.geturl(), subject.digest(b"wheel"))
        with self.assertRaises(subject.QualificationError):
            subject.NoRedirect().redirect_request(None, None, 302, "", None, "https://other.invalid")

    def test_run_rejects_process_failure_and_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            self.assertEqual(subject.run(["/usr/bin/printf", "ok"], home=home), "ok")
            with self.assertRaises(subject.QualificationError):
                subject.run(["/usr/bin/false"], home=home)
            with patch.object(subject.subprocess, "run") as process:
                process.return_value.stdout = "ok"
                process.return_value.stderr = "unexpected"
                with self.assertRaisesRegex(subject.QualificationError, "diagnostics"):
                    subject.run(["/usr/bin/true"], home=home)

    def test_qualify_exact_isolated_products(self) -> None:
        config = json.loads(json.dumps(self.config))
        wheels = {}
        for item in config["products"]:
            raw = item["identity"].encode()
            item["wheel"]["digest"] = subject.digest(raw)
            wheels[item["identity"]] = raw
        with patch.object(subject.platform, "system", return_value="Darwin"), \
             patch.object(subject.platform, "machine", return_value="arm64"), \
             patch.object(subject, "runtime_identity_digest_from_archive", return_value=config["runtime_identity_digest"]), \
             patch.object(subject, "safe_extract") as extract, \
             patch.object(subject, "run") as run:
            run.side_effect = lambda argv, **kwargs: (
                next(item["version"] for item in config["products"] if subject.PRODUCTS[item["identity"]][0] in argv[-1])
                if argv[-2:] and argv[-2] == "-c" else "help"
            )
            report = subject.qualify(config, b"archive", wheels, source_sha="a" * 40)
            self.assertEqual(report["outcome"], "PASS")
            self.assertEqual(len(report["products"]), 2)
            self.assertEqual(run.call_count, 8)
            extract.assert_called_once()
            with self.assertRaisesRegex(subject.QualificationError, "wheel bytes differ"):
                subject.qualify(config, b"archive", {**wheels, "forge-runtime": b"wrong"}, source_sha="a" * 40)
            run.side_effect = lambda argv, **kwargs: "wrong" if argv[-2:] and argv[-2] == "-c" else "help"
            with self.assertRaisesRegex(subject.QualificationError, "version differs"):
                subject.qualify(config, b"archive", wheels, source_sha="a" * 40)
            run.side_effect = lambda argv, **kwargs: "" if argv[-1] == "--help" else config["products"][0]["version"]
            with self.assertRaisesRegex(subject.QualificationError, "help is empty"):
                subject.qualify(config, b"archive", wheels, source_sha="a" * 40)
        with self.assertRaisesRegex(subject.QualificationError, "exact source"):
            subject.qualify(config, b"archive", wheels, source_sha="wrong")
        with patch.object(subject.platform, "system", return_value="Linux"):
            with self.assertRaisesRegex(subject.QualificationError, "Apple Silicon"):
                subject.qualify(config, b"archive", wheels, source_sha="a" * 40)
        with patch.object(subject.platform, "system", return_value="Darwin"), \
             patch.object(subject.platform, "machine", return_value="arm64"), \
             patch.object(subject, "runtime_identity_digest_from_archive", return_value="wrong"):
            with self.assertRaisesRegex(subject.QualificationError, "identity differs"):
                subject.qualify(config, b"archive", wheels, source_sha="a" * 40)

    def test_runtime_identity_member_fail_closed(self) -> None:
        with self.assertRaises(subject.QualificationError):
            subject.runtime_identity_digest_from_archive(b"invalid", "sha256:" + "0" * 64)


if __name__ == "__main__":
    unittest.main()
