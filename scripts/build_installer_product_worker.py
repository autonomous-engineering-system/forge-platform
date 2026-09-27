#!/usr/bin/env python3
"""Build the deterministic, dependency-closed installer product-worker zipapp."""

from __future__ import annotations

import argparse
from hashlib import sha256
import io
import os
from pathlib import Path
import stat
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_ROOT = ROOT / "forge_platform"
FIXED_DATE_TIME = (1980, 1, 1, 0, 0, 0)
MAXIMUM_SOURCE_BYTES = 2 * 1_024 * 1_024
MAXIMUM_TOTAL_SOURCE_BYTES = 16 * 1_024 * 1_024
ENTRYPOINT = (
    b"from forge_platform.installer_product_worker import main\n"
    b"main()\n"
)


def _read_source(path: Path) -> bytes:
    if path.is_symlink():
        raise ValueError("product worker source must not be a symlink")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAXIMUM_SOURCE_BYTES:
            raise ValueError("product worker source is invalid")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            contents = stream.read(MAXIMUM_SOURCE_BYTES + 1)
        after = os.fstat(descriptor)
        if (
            len(contents) > MAXIMUM_SOURCE_BYTES
            or before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise ValueError("product worker source changed while reading")
        return contents
    finally:
        os.close(descriptor)


def collect_sources(package_root: Path = PACKAGE_ROOT) -> tuple[tuple[str, bytes], ...]:
    root = package_root.resolve(strict=True)
    if not root.is_dir() or package_root.is_symlink():
        raise ValueError("product worker package root is invalid")
    entries: list[tuple[str, bytes]] = [("__main__.py", ENTRYPOINT)]
    total = len(ENTRYPOINT)
    for source in sorted(root.glob("*.py"), key=lambda value: value.name):
        contents = _read_source(source)
        total += len(contents)
        if total > MAXIMUM_TOTAL_SOURCE_BYTES:
            raise ValueError("product worker sources exceed their maximum size")
        entries.append((f"forge_platform/{source.name}", contents))
    if not any(name == "forge_platform/installer_product_worker.py" for name, _ in entries):
        raise ValueError("product worker entrypoint module is missing")
    names = [name for name, _ in entries]
    if names != sorted(names) or len(names) != len(set(names)):
        raise ValueError("product worker source inventory is not canonical")
    return tuple(entries)


def build_bytes(package_root: Path = PACKAGE_ROOT) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, contents in collect_sources(package_root):
            entry = zipfile.ZipInfo(name, date_time=FIXED_DATE_TIME)
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(entry, contents)
    return output.getvalue()


def output_path(value: str) -> Path:
    supplied = Path(value).expanduser()
    if supplied.is_symlink():
        raise ValueError("product worker output must not be a symlink")
    target = supplied.resolve(strict=False)
    if target.suffix != ".pyz":
        raise ValueError("product worker output must end in .pyz")
    if target.exists():
        raise ValueError("product worker output must not already exist")
    return target


def build(output: Path, package_root: Path = PACKAGE_ROOT) -> str:
    output = output_path(str(output))
    contents = build_bytes(package_root)
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with output.open("xb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        output.chmod(0o644)
    except BaseException:
        output.unlink(missing_ok=True)
        raise
    return "sha256:" + sha256(contents).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        target = output_path(args.output)
        digest = build(target)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"INSTALLER_PRODUCT_WORKER=FAIL reason={error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(f"INSTALLER_PRODUCT_WORKER=PASS output={target} digest={digest}")


if __name__ == "__main__":
    main()
