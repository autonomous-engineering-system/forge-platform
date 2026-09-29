#!/usr/bin/env python3
"""Independently read exact no-redirect public managed-tool bytes."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import urllib.error
import urllib.request

from prepare_managed_tool_pages import load_config, PublicationError, SITE_PREFIX


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        raise PublicationError("public asset redirected")


def verify(config: dict[str, object], marker: Path | None = None) -> None:
    opener = urllib.request.build_opener(NoRedirect())
    for asset in config["assets"]:
        assert isinstance(asset, dict)
        url = asset["url"]
        assert isinstance(url, str)
        request = urllib.request.Request(url, headers={"User-Agent": "forge-platform-managed-tool-verifier/1"})
        try:
            with opener.open(request, timeout=60) as response:
                if response.status != 200 or response.geturl() != url:
                    raise PublicationError("public status or final URL differs")
                length = response.headers.get("Content-Length")
                if length is not None and length != str(asset["size"]):
                    raise PublicationError("public content length differs")
                digest = hashlib.sha256()
                count = 0
                while chunk := response.read(1024 * 1024):
                    count += len(chunk)
                    if count > asset["size"]:
                        raise PublicationError("public asset exceeds reviewed size")
                    digest.update(chunk)
                if count != asset["size"] or "sha256:" + digest.hexdigest() != asset["sha256"]:
                    raise PublicationError("public byte count or digest differs")
        except (urllib.error.URLError, TimeoutError) as error:
            raise PublicationError("public asset unavailable") from error
    if marker is not None:
        if marker.is_symlink() or not marker.is_file() or marker.stat().st_size > 4096:
            raise PublicationError("local publication marker is invalid")
        expected = marker.read_bytes()
        url = SITE_PREFIX + "publication.json"
        try:
            with opener.open(urllib.request.Request(url), timeout=30) as response:
                if (response.status != 200 or response.geturl() != url
                    or response.read(4097) != expected):
                    raise PublicationError("public publication marker differs")
        except (urllib.error.URLError, TimeoutError) as error:
            raise PublicationError("public publication marker unavailable") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--marker", type=Path)
    args = parser.parse_args()
    try:
        verify(load_config(args.config), args.marker)
    except (PublicationError, OSError) as error:
        parser.exit(1, f"MANAGED_TOOL_PAGES_READBACK=BLOCKED reason={error}\n")
    print("MANAGED_TOOL_PAGES_READBACK=PASS assets=5 direct_get=true")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
