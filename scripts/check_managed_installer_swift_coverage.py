#!/usr/bin/env python3
"""Fail-closed executable-line coverage for the managed slice and changed Swift files."""
from __future__ import annotations

import argparse
from decimal import Decimal
import json
import math
from pathlib import Path
import re
import subprocess
import sys


SOURCE_PREFIX = "macos/ForgePlatformInstaller/Sources/"
ROOT = Path(__file__).resolve().parents[1]


def required_targets(base_ref: str | None) -> tuple[str, ...]:
    """Require every tracked production Swift file; a baseline only proves ancestry."""
    if base_ref is not None:
        if re.fullmatch(r"[0-9a-f]{40}", base_ref) is None:
            raise ValueError("coverage base must be an exact 40-character commit SHA")
        subprocess.run(
            ["git", "merge-base", "--is-ancestor", base_ref, "HEAD"],
            cwd=ROOT, check=True, capture_output=True, timeout=30,
        )
    result = subprocess.run(
        ["git", "ls-files", "-z", "--", SOURCE_PREFIX],
        cwd=ROOT, check=True, capture_output=True, timeout=30,
    )
    targets: set[str] = set()
    for path in result.stdout.decode("utf-8").split("\0"):
        if not path:
            continue
        if not path.startswith(SOURCE_PREFIX) or not path.endswith(".swift"):
            raise ValueError("unexpected production source path")
        if any(part in {"", ".", ".."} for part in path.split("/")) or any(
            ord(character) < 32 for character in path
        ):
            raise ValueError("unsafe production source path")
        targets.add("/Sources/" + path.removeprefix(SOURCE_PREFIX))
    if not targets:
        raise ValueError("no tracked production Swift files")
    return tuple(sorted(targets))


def validate(payload: object, targets: tuple[str, ...], minimum: float) -> int:
    if not math.isfinite(minimum) or not 80.2 <= minimum <= 100:
        raise ValueError("minimum coverage must be finite and between 80.2 and 100")
    if not isinstance(payload, dict):
        raise ValueError("Swift coverage must be a JSON object")
    data = payload.get("data")
    if not isinstance(data, list) or not data:
        raise ValueError("Swift coverage JSON has no data entries")
    records: dict[str, dict[str, object]] = {}
    for block in data:
        if not isinstance(block, dict) or not isinstance(block.get("files"), list):
            raise ValueError("Swift coverage has an invalid data block")
        for item in block["files"]:
            if not isinstance(item, dict) or not isinstance(item.get("filename"), str):
                raise ValueError("Swift coverage has an invalid file record")
            filename = item["filename"].replace("\\", "/")
            if ".." in filename.split("/"):
                raise ValueError("Swift coverage has an unsafe file path")
            for suffix in targets:
                if filename.endswith(suffix):
                    if suffix in records:
                        raise ValueError(f"Swift coverage contains duplicate target file: {suffix}")
                    records[suffix] = item
    missing = sorted(set(targets) - records.keys())
    if missing:
        raise ValueError("Swift coverage is missing production files: " + ", ".join(missing))
    failures: list[str] = []
    for suffix in targets:
        summary = records[suffix].get("summary")
        if not isinstance(summary, dict) or not isinstance(summary.get("lines"), dict):
            raise ValueError(f"Swift line coverage is missing: {suffix}")
        lines = summary["lines"]
        count, covered, percent = (lines.get(key) for key in ("count", "covered", "percent"))
        if (
            type(count) is not int or not 0 < count <= 2**63 - 1
            or type(covered) is not int or not 0 <= covered <= count
            or type(percent) not in (int, float) or not math.isfinite(percent)
            or not 0 <= percent <= 100
        ):
            raise ValueError(f"Swift line coverage values are invalid: {suffix}")
        measured = 100 * covered / count
        # LLVM may round display percentages; they never grant coverage authority.
        if not math.isclose(float(percent), measured, rel_tol=0, abs_tol=0.011):
            raise ValueError(f"Swift coverage percentage disagrees with line counts: {suffix}")
        print(
            "MANAGED_INSTALLER_SWIFT_FILE_COVERAGE "
            f"path={suffix.removeprefix('/')} covered={covered} executable={count} "
            f"percent={measured:.6f}"
        )
        if Decimal(covered) * 100 <= Decimal(str(minimum)) * Decimal(count):
            failures.append(f"{suffix}={measured:.6f}%")
    if failures:
        print(
            f"MANAGED_INSTALLER_SWIFT_COVERAGE=FAIL minimum_strictly_greater_than={minimum:.6f} "
            + " ".join(failures), file=sys.stderr,
        )
        return 1
    print(f"MANAGED_INSTALLER_SWIFT_COVERAGE=PASS minimum_strictly_greater_than={minimum:.6f}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("coverage_json", type=Path)
    parser.add_argument("--minimum", type=float, default=80.2)
    parser.add_argument("--base-ref", help="Exact ancestor commit; adds every changed production Swift file")
    args = parser.parse_args(argv)
    try:
        targets = required_targets(args.base_ref)
        payload = json.loads(args.coverage_json.read_text(encoding="utf-8"))
        return validate(payload, targets, args.minimum)
    except (OSError, ValueError, ArithmeticError, subprocess.SubprocessError) as error:
        print(f"MANAGED_INSTALLER_SWIFT_COVERAGE=FAIL reason={type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
