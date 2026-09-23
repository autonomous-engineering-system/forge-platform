#!/usr/bin/env python3
"""Validate per-file Swift executable-line coverage from SwiftPM/LLVM JSON."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


TARGET_SUFFIXES = (
    "/Sources/ForgePlatformInstallerCore/InstallerDomain.swift",
    "/Sources/ForgePlatformInstallerCore/ManagedDeploymentDomain.swift",
    "/Sources/ForgePlatformInstallerCore/ManagedCompositionSessionPlan.swift",
    "/Sources/ForgePlatformInstaller/ForgePlatformInstallerApp.swift",
)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("coverage_json", type=Path)
    parser.add_argument("--minimum", type=float, default=80.2)
    args = parser.parse_args(argv)
    if not 0 <= args.minimum <= 100:
        raise ValueError("minimum coverage must be between zero and 100")

    try:
        payload = json.loads(args.coverage_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError("Swift coverage JSON is unavailable or invalid") from error

    data = payload.get("data")
    if not isinstance(data, list) or not data:
        raise RuntimeError("Swift coverage JSON has no data entries")

    records: dict[str, dict[str, object]] = {}
    for block in data:
        if not isinstance(block, dict):
            continue
        files = block.get("files")
        if not isinstance(files, list):
            continue
        for item in files:
            if not isinstance(item, dict) or not isinstance(item.get("filename"), str):
                continue
            filename = item["filename"].replace("\\", "/")
            for suffix in TARGET_SUFFIXES:
                if filename.endswith(suffix):
                    if suffix in records:
                        raise RuntimeError(f"Swift coverage contains duplicate target file: {suffix}")
                    records[suffix] = item

    missing = [suffix for suffix in TARGET_SUFFIXES if suffix not in records]
    if missing:
        raise RuntimeError("Swift coverage is missing production files: " + ", ".join(missing))

    failures: list[str] = []
    for suffix in TARGET_SUFFIXES:
        summary = records[suffix].get("summary")
        if not isinstance(summary, dict):
            raise RuntimeError(f"Swift coverage summary is missing: {suffix}")
        lines = summary.get("lines")
        if not isinstance(lines, dict):
            raise RuntimeError(f"Swift line coverage is missing: {suffix}")
        count = lines.get("count")
        covered = lines.get("covered")
        percent = lines.get("percent")
        if (
            isinstance(count, bool) or not isinstance(count, int) or count <= 0
            or isinstance(covered, bool) or not isinstance(covered, int) or covered < 0
            or not isinstance(percent, (int, float))
        ):
            raise RuntimeError(f"Swift line coverage values are invalid: {suffix}")
        measured = float(percent)
        print(
            "MANAGED_INSTALLER_SWIFT_FILE_COVERAGE "
            f"path={suffix.removeprefix('/')} covered={covered} executable={count} "
            f"percent={measured:.6f}"
        )
        if measured <= args.minimum:
            failures.append(f"{suffix}={measured:.6f}%")

    if failures:
        print(
            f"MANAGED_INSTALLER_SWIFT_COVERAGE=FAIL minimum_strictly_greater_than={args.minimum:.6f} "
            + " ".join(failures),
            file=sys.stderr,
        )
        return 1
    print(
        f"MANAGED_INSTALLER_SWIFT_COVERAGE=PASS minimum_strictly_greater_than={args.minimum:.6f}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
