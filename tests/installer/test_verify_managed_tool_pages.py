"""Direct public GET must match every reviewed byte, without a redirect."""
from __future__ import annotations

import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import verify_managed_tool_pages as verifier
from prepare_managed_tool_pages import PublicationError


class Response(io.BytesIO):
    def __init__(self, body: bytes, url: str, *, status: int = 200,
                 content_length: str | None = None):
        super().__init__(body)
        self.url = url
        self.status = status
        self.headers = {} if content_length is None else {"Content-Length": content_length}

    def geturl(self) -> str:
        return self.url


class Opener:
    def __init__(self, responses: list[Response | Exception]):
        self.responses = responses

    def open(self, request, timeout: int):
        self.request = request
        self.timeout = timeout
        value = self.responses.pop(0)
        if isinstance(value, Exception):
            raise value
        return value


class PublicReadbackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.asset = {"url": "https://autonomous-engineering-system.github.io/forge-platform/managed-tools/v1/source-provenance.json",
                      "size": 3,
                      "sha256": "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}
        self.config = {"assets": [self.asset]}

    def verify_with(self, response: Response | Exception) -> None:
        with patch.object(verifier.urllib.request, "build_opener", return_value=Opener([response])):
            verifier.verify(self.config)

    def test_exact_public_bytes_pass(self) -> None:
        self.verify_with(Response(b"abc", self.asset["url"], content_length="3"))

    def test_status_final_url_length_and_digest_drift_fail(self) -> None:
        cases = [
            (Response(b"abc", self.asset["url"], status=206), "status"),
            (Response(b"abc", "https://elsewhere.invalid/file"), "final URL"),
            (Response(b"abc", self.asset["url"], content_length="4"), "length"),
            (Response(b"abcd", self.asset["url"]), "exceeds"),
            (Response(b"ab", self.asset["url"]), "digest"),
            (Response(b"abd", self.asset["url"]), "digest"),
        ]
        for response, reason in cases:
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(PublicationError, reason):
                    self.verify_with(response)

    def test_network_failure_and_redirect_fail(self) -> None:
        with self.assertRaisesRegex(PublicationError, "unavailable"):
            self.verify_with(urllib.error.URLError("unreachable"))
        with self.assertRaisesRegex(PublicationError, "redirected"):
            verifier.NoRedirect().redirect_request(None, None, 302, "moved", {}, "https://elsewhere.invalid")

    def test_cli_success_and_fail_closed(self) -> None:
        args = ["verify_managed_tool_pages.py", "--config", "reviewed.json"]
        with patch.object(sys, "argv", args), \
             patch.object(verifier, "load_config", return_value=self.config), \
             patch.object(verifier, "verify") as verify:
            self.assertEqual(verifier.main(), 0)
            verify.assert_called_once_with(self.config, None)
        with patch.object(sys, "argv", args), \
             patch.object(verifier, "load_config", side_effect=PublicationError("blocked")):
            with self.assertRaises(SystemExit) as outcome:
                verifier.main()
            self.assertEqual(outcome.exception.code, 1)

    def test_marker_must_match_exact_public_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "publication.json"
            marker.write_bytes(b'{"source_sha":"exact"}\n')
            responses = [Response(b"abc", self.asset["url"]),
                         Response(marker.read_bytes(), verifier.SITE_PREFIX + "publication.json")]
            with patch.object(verifier.urllib.request, "build_opener", return_value=Opener(responses)):
                verifier.verify(self.config, marker)
            responses = [Response(b"abc", self.asset["url"]),
                         Response(b"wrong", verifier.SITE_PREFIX + "publication.json")]
            with patch.object(verifier.urllib.request, "build_opener", return_value=Opener(responses)):
                with self.assertRaisesRegex(PublicationError, "marker differs"):
                    verifier.verify(self.config, marker)
            marker.write_bytes(b"x" * 4097)
            with patch.object(verifier.urllib.request, "build_opener", return_value=Opener([
                Response(b"abc", self.asset["url"])])):
                with self.assertRaisesRegex(PublicationError, "marker is invalid"):
                    verifier.verify(self.config, marker)


if __name__ == "__main__":
    unittest.main()
