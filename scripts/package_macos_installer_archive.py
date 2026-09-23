#!/usr/bin/env python3
"""Create a deterministic, stored ZIP from one already-built macOS ``.app``.

This producer has a deliberately narrow archive profile shared with the native
installer's read-only layout gate.  It only reads one existing application
bundle and creates one new archive; it does not sign, notarize, extract,
launch, publish, or modify the source bundle.  A protected later stage remains
responsible for signing, notarization, and public release publication.

Filesystem extended attributes are deliberately not archive inputs. macOS may
attach local provenance attributes to ordinary build output; this producer does
not read or serialize them. It emits neither ZIP extra fields nor AppleDouble/
``__MACOSX`` sidecars, so the resulting archive contains no xattr payload.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import stat
import sys
from typing import BinaryIO, Iterable
import zipfile


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from forge_platform.macos_platform_contract import require_thin_arm64_macho_header  # noqa: E402


# These limits intentionally fit inside the native layout inspector defaults.
# Stored entries make the archive-size bound meaningful before any future
# extractor considers uncompressed bytes.
MAXIMUM_ARCHIVE_BYTES = 512 * 1024 * 1024
MAXIMUM_TOTAL_UNCOMPRESSED_BYTES = 2 * 1024 * 1024 * 1024
MAXIMUM_ENTRY_COUNT = 8_192
MAXIMUM_PATH_BYTES = 1_024
MAXIMUM_PATH_DEPTH = 64
STREAM_CHUNK_BYTES = 1024 * 1024
_FIXED_ZIP_DATE_TIME = (1980, 1, 1, 0, 0, 0)
_SAFE_COMPONENT_CHARACTERS = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 +.-_"
)
_FORBIDDEN_SIDECAR_COMPONENTS = frozenset({"__MACOSX", ".DS_Store"})


@dataclass(frozen=True)
class BundleEntry:
    """One source entry admitted into the strict archive profile."""

    source: Path
    archive_path: str
    kind: str
    permissions: int
    size: int
    device: int
    inode: int
    modification_ns: int
    change_ns: int

    @property
    def zip_name(self) -> str:
        return self.archive_path + "/" if self.kind == "directory" else self.archive_path


@dataclass(frozen=True)
class ArchivePackageResult:
    """Non-secret result evidence for the exact archive that was produced."""

    entry_count: int
    archive_byte_count: int
    total_uncompressed_byte_count: int


@dataclass(frozen=True)
class _OutputFileIdentity:
    """The filesystem identity of the one output created by this operation."""

    device: int
    inode: int


@dataclass(frozen=True)
class _OpenedOutput:
    """A new output stream together with its identity-bound cleanup authority."""

    stream: BinaryIO
    identity: _OutputFileIdentity


class _BoundedArchiveWriter:
    """Seekable ZIP sink that rejects writes beyond the public size bound."""

    def __init__(self, stream: BinaryIO, maximum_bytes: int) -> None:
        self._stream = stream
        self._maximum_bytes = maximum_bytes

    def write(self, contents: bytes) -> int:
        position = self._stream.tell()
        if position < 0 or position + len(contents) > self._maximum_bytes:
            raise ValueError("installer archive exceeds its maximum size")
        return self._stream.write(contents)

    def tell(self) -> int:
        return self._stream.tell()

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        current = self._stream.tell()
        if whence == os.SEEK_SET:
            target = offset
        elif whence == os.SEEK_CUR:
            target = current + offset
        elif whence == os.SEEK_END:
            self._stream.seek(0, os.SEEK_END)
            target = self._stream.tell() + offset
            self._stream.seek(current, os.SEEK_SET)
        else:
            raise ValueError("installer archive writer received an invalid seek mode")
        if target < 0 or target > self._maximum_bytes:
            raise ValueError("installer archive exceeds its maximum size")
        return self._stream.seek(offset, whence)

    def flush(self) -> None:
        self._stream.flush()

    def writable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True


def _normalised_non_symlink_leaf(value: str, *, label: str) -> Path:
    """Normalize ancestors such as ``/tmp`` without accepting a leaf symlink."""

    supplied = Path(value).expanduser()
    if supplied.is_symlink():
        raise ValueError(f"{label} must not be selected through a symlink")
    try:
        parent = supplied.parent.resolve(strict=True)
    except FileNotFoundError as error:
        raise ValueError(f"{label} parent does not exist") from error
    candidate = parent / supplied.name
    if candidate.is_symlink():
        raise ValueError(f"{label} must not be selected through a symlink")
    return candidate


def _source_bundle(value: str) -> Path:
    source = _normalised_non_symlink_leaf(value, label="installer app bundle")
    if source.suffix != ".app":
        raise ValueError("installer app bundle must end in .app")
    try:
        details = os.lstat(source)
    except FileNotFoundError as error:
        raise ValueError("installer app bundle does not exist") from error
    if stat.S_ISLNK(details.st_mode) or not stat.S_ISDIR(details.st_mode):
        raise ValueError("installer app bundle must be a directory, never a symlink")
    _validate_archive_component(source.name, is_root=True)
    return source


def _output_archive(value: str, *, source: Path) -> Path:
    candidate = _normalised_non_symlink_leaf(value, label="installer archive output")
    if candidate.suffix != ".zip":
        raise ValueError("installer archive output must end in .zip")
    if candidate.exists() or candidate.is_symlink():
        raise ValueError("installer archive output must not already exist")
    try:
        common = Path(os.path.commonpath((str(source), str(candidate))))
    except ValueError as error:
        raise ValueError("installer archive output is not comparable with the app bundle") from error
    if common == source:
        raise ValueError("installer archive output must not be inside the app bundle")
    return candidate


def _validate_archive_component(value: str, *, is_root: bool = False) -> None:
    if not value or value in {".", ".."}:
        raise ValueError("installer app bundle contains an unsafe relative path")
    if any(character not in _SAFE_COMPONENT_CHARACTERS for character in value):
        raise ValueError("installer app bundle contains an unsafe relative path")
    if value in _FORBIDDEN_SIDECAR_COMPONENTS or value.startswith("._"):
        raise ValueError("installer app bundle contains an unsupported metadata sidecar")
    if is_root:
        if not value.endswith(".app") or len(value) <= 4:
            raise ValueError("installer app bundle root is invalid")
        if value[:-4] in _FORBIDDEN_SIDECAR_COMPONENTS or value[:-4].startswith("._"):
            raise ValueError("installer app bundle root is an unsupported metadata sidecar")
    elif value.endswith(".app"):
        raise ValueError("installer app bundle must not contain a nested .app bundle")


def _permissions(details: os.stat_result, *, label: str) -> int:
    permissions = stat.S_IMODE(details.st_mode)
    if permissions & 0o022:
        raise ValueError(f"{label} must not be group- or world-writable")
    if permissions & 0o7000:
        raise ValueError(f"{label} must not carry setuid, setgid, or sticky permissions")
    return permissions


def _entry_from_stat(source: Path, archive_path: str, details: os.stat_result) -> BundleEntry:
    if stat.S_ISLNK(details.st_mode):
        raise ValueError("installer app bundle must not contain symlinks")
    if stat.S_ISDIR(details.st_mode):
        kind = "directory"
        size = 0
    elif stat.S_ISREG(details.st_mode):
        kind = "file"
        size = details.st_size
    else:
        raise ValueError("installer app bundle must contain only directories and regular files")
    permissions = _permissions(details, label="installer app bundle entry")
    if size < 0:
        raise ValueError("installer app bundle file size is invalid")
    return BundleEntry(
        source=source,
        archive_path=archive_path,
        kind=kind,
        permissions=permissions,
        size=size,
        device=details.st_dev,
        inode=details.st_ino,
        modification_ns=details.st_mtime_ns,
        change_ns=details.st_ctime_ns,
    )


def _scan_bundle(source: Path) -> tuple[BundleEntry, ...]:
    """Capture an immutable-looking, sorted input tree without following links."""

    entries: list[BundleEntry] = []
    seen_casefolded_paths: set[str] = set()

    def append_entry(path: Path, archive_path: str, details: os.stat_result) -> BundleEntry:
        encoded_path = archive_path.encode("utf-8")
        components = archive_path.split("/")
        if (
            len(encoded_path) > MAXIMUM_PATH_BYTES
            or len(components) > MAXIMUM_PATH_DEPTH
            or not components
        ):
            raise ValueError("installer app bundle contains a path outside the strict archive profile")
        if not all(component and component not in {".", ".."} for component in components):
            raise ValueError("installer app bundle contains an unsafe relative path")
        folded = archive_path.lower()
        if folded in seen_casefolded_paths:
            raise ValueError("installer app bundle contains case-ambiguous paths")
        seen_casefolded_paths.add(folded)
        entry = _entry_from_stat(path, archive_path, details)
        entries.append(entry)
        return entry

    def visit(path: Path, archive_path: str, *, root: bool = False) -> None:
        name = path.name
        _validate_archive_component(name, is_root=root)
        try:
            details = os.lstat(path)
        except OSError as error:
            raise ValueError("installer app bundle cannot be inspected safely") from error
        entry = append_entry(path, archive_path, details)
        if entry.kind != "directory":
            return
        try:
            with os.scandir(path) as stream:
                children = sorted(stream, key=lambda child: child.name)
        except OSError as error:
            raise ValueError("installer app bundle cannot be inspected safely") from error
        for child in children:
            _validate_archive_component(child.name)
            visit(path / child.name, f"{archive_path}/{child.name}")

    visit(source, source.name, root=True)
    ordered = tuple(sorted(entries, key=lambda entry: entry.archive_path))
    _validate_profile_bounds(ordered)
    _validate_minimum_app_layout(ordered)
    return ordered


def _validate_profile_bounds(entries: tuple[BundleEntry, ...]) -> None:
    if not entries or len(entries) > MAXIMUM_ENTRY_COUNT:
        raise ValueError("installer app bundle exceeds the strict archive entry limit")
    total_uncompressed = sum(entry.size for entry in entries)
    if total_uncompressed > MAXIMUM_TOTAL_UNCOMPRESSED_BYTES:
        raise ValueError("installer app bundle exceeds the strict uncompressed size limit")
    # Stored ZIP records have no per-entry extra data or comments. This exact
    # upper bound keeps output admission deterministic before writing begins.
    estimated_archive_size = 22
    for entry in entries:
        name_bytes = len(entry.zip_name.encode("utf-8"))
        estimated_archive_size += 30 + name_bytes + entry.size
        estimated_archive_size += 46 + name_bytes
    if estimated_archive_size > MAXIMUM_ARCHIVE_BYTES:
        raise ValueError("installer app bundle exceeds the strict archive size limit")


def _validate_minimum_app_layout(entries: Iterable[BundleEntry]) -> None:
    entries = tuple(entries)
    root = entries[0].archive_path.split("/", 1)[0]
    by_path = {entry.archive_path: entry for entry in entries}
    required_directories = (root, f"{root}/Contents", f"{root}/Contents/MacOS")
    if any(by_path.get(path) is None or by_path[path].kind != "directory" for path in required_directories):
        raise ValueError("installer app bundle has no supported macOS app layout")
    info_plist = by_path.get(f"{root}/Contents/Info.plist")
    if info_plist is None or info_plist.kind != "file":
        raise ValueError("installer app bundle has no regular Contents/Info.plist")
    executable = by_path.get(f"{root}/Contents/MacOS/ForgePlatformInstaller")
    if executable is None or executable.kind != "file" or not executable.permissions & stat.S_IXUSR:
        raise ValueError("installer app bundle has no regular executable ForgePlatformInstaller")
    cli_executable = by_path.get(f"{root}/Contents/MacOS/forge-platform-installer")
    if cli_executable is None or cli_executable.kind != "file" or not cli_executable.permissions & stat.S_IXUSR:
        raise ValueError("installer app bundle has no regular executable forge-platform-installer")


def _zip_info(entry: BundleEntry) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(entry.zip_name, date_time=_FIXED_ZIP_DATE_TIME)
    info.create_system = 3  # Unix mode semantics are mandatory for the consumer.
    info.create_version = 20
    info.extract_version = 20
    info.flag_bits = 0
    info.compress_type = zipfile.ZIP_STORED
    info.extra = b""
    info.comment = b""
    info.internal_attr = 0
    info.file_size = entry.size
    file_type = stat.S_IFDIR if entry.kind == "directory" else stat.S_IFREG
    info.external_attr = (file_type | entry.permissions) << 16
    if entry.kind == "directory":
        info.external_attr |= 0x10
    return info


def _same_snapshot(details: os.stat_result, entry: BundleEntry) -> bool:
    return (
        details.st_dev == entry.device
        and details.st_ino == entry.inode
        and details.st_mtime_ns == entry.modification_ns
        and details.st_ctime_ns == entry.change_ns
        and stat.S_IMODE(details.st_mode) == entry.permissions
        and (
            (entry.kind == "directory" and stat.S_ISDIR(details.st_mode))
            or (entry.kind == "file" and stat.S_ISREG(details.st_mode) and details.st_size == entry.size)
        )
    )


def _write_regular_file(archive: zipfile.ZipFile, entry: BundleEntry) -> None:
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        raise ValueError("installer app bundle file cannot be opened safely on this platform")
    descriptor = -1
    try:
        descriptor = os.open(entry.source, os.O_RDONLY | nofollow | getattr(os, "O_CLOEXEC", 0))
        before = os.fstat(descriptor)
        if not _same_snapshot(before, entry):
            raise ValueError("installer app bundle changed while it was being archived")
        remaining = entry.size
        with os.fdopen(descriptor, "rb", closefd=False) as source, archive.open(
            _zip_info(entry), "w", force_zip64=False
        ) as destination:
            if entry.archive_path.endswith("/Contents/MacOS/ForgePlatformInstaller") or entry.archive_path.endswith("/Contents/MacOS/forge-platform-installer"):
                require_thin_arm64_macho_header(
                    source.read(32),
                    "installer archive executable",
                )
                source.seek(0)
            while remaining:
                block = source.read(min(STREAM_CHUNK_BYTES, remaining))
                if not block:
                    raise ValueError("installer app bundle file changed while it was being archived")
                destination.write(block)
                remaining -= len(block)
            if source.read(1):
                raise ValueError("installer app bundle file changed while it was being archived")
        after = os.fstat(descriptor)
        if not _same_snapshot(after, entry):
            raise ValueError("installer app bundle changed while it was being archived")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _verify_directories_unchanged(entries: Iterable[BundleEntry]) -> None:
    for entry in entries:
        if entry.kind != "directory":
            continue
        try:
            details = os.lstat(entry.source)
        except OSError as error:
            raise ValueError("installer app bundle changed while it was being archived") from error
        if not _same_snapshot(details, entry):
            raise ValueError("installer app bundle changed while it was being archived")


def _close_descriptor(descriptor: int) -> None:
    """Best-effort close for a descriptor whose ownership was not transferred."""

    try:
        os.close(descriptor)
    except OSError:
        pass


def _unlink_owned_output(path: Path, identity: _OutputFileIdentity) -> None:
    """Remove only the exact regular file this operation created.

    Cleanup never follows a replacement, a symlink, or another file at the
    output path.  A mismatch is deliberately surfaced so a release operation
    can record cleanup as pending instead of concealing a foreign artifact.
    """

    try:
        details = os.lstat(path)
    except OSError as error:
        raise ValueError("installer archive output cannot be inspected for safe cleanup") from error
    if (
        stat.S_ISLNK(details.st_mode)
        or not stat.S_ISREG(details.st_mode)
        or details.st_dev != identity.device
        or details.st_ino != identity.inode
    ):
        raise ValueError("installer archive output changed before safe cleanup")
    try:
        path.unlink()
    except OSError as error:
        raise ValueError("installer archive output cannot be removed safely") from error


def _open_new_output(path: Path) -> _OpenedOutput:
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        raise ValueError("installer archive output cannot be opened safely on this platform")
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | nofollow | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except FileExistsError as error:
        raise ValueError("installer archive output must not already exist") from error
    except OSError as error:
        raise ValueError("installer archive output cannot be created safely") from error
    try:
        details = os.fstat(descriptor)
        identity = _OutputFileIdentity(device=details.st_dev, inode=details.st_ino)
        if not stat.S_ISREG(details.st_mode):
            raise ValueError("installer archive output was not created as a regular file")
    except BaseException:
        _close_descriptor(descriptor)
        raise
    try:
        stream = os.fdopen(descriptor, "w+b")
    except BaseException:
        # O_EXCL created this path, and fstat captured its identity before any
        # stream construction.  Do not leave a partial operation artifact, but
        # never delete a path that another actor has since replaced.
        _close_descriptor(descriptor)
        try:
            _unlink_owned_output(path, identity)
        except BaseException as cleanup_error:
            raise ValueError(
                f"installer archive output could not be safely cleaned up: {cleanup_error}"
            ) from cleanup_error
        raise
    return _OpenedOutput(stream=stream, identity=identity)


def package_archive(*, app_bundle: Path, output: Path) -> ArchivePackageResult:
    """Write one new strict stored ZIP without modifying ``app_bundle``."""

    source = _source_bundle(str(app_bundle))
    destination = _output_archive(str(output), source=source)
    entries = _scan_bundle(source)
    total_uncompressed = sum(entry.size for entry in entries)
    opened_output: _OpenedOutput | None = None
    try:
        opened_output = _open_new_output(destination)
        with opened_output.stream as raw_output:
            os.fchmod(raw_output.fileno(), 0o600)
            bounded_output = _BoundedArchiveWriter(raw_output, MAXIMUM_ARCHIVE_BYTES)
            with zipfile.ZipFile(
                bounded_output,
                mode="w",
                compression=zipfile.ZIP_STORED,
                allowZip64=False,
                strict_timestamps=True,
            ) as archive:
                archive.comment = b""
                for entry in entries:
                    if entry.kind == "directory":
                        archive.writestr(_zip_info(entry), b"", compress_type=zipfile.ZIP_STORED)
                    else:
                        _write_regular_file(archive, entry)
            _verify_directories_unchanged(entries)
            raw_output.flush()
            os.fsync(raw_output.fileno())
            archive_size = os.fstat(raw_output.fileno()).st_size
            if archive_size <= 0 or archive_size > MAXIMUM_ARCHIVE_BYTES:
                raise ValueError("installer archive exceeds its maximum size")
            os.fchmod(raw_output.fileno(), 0o600)
        return ArchivePackageResult(
            entry_count=len(entries),
            archive_byte_count=archive_size,
            total_uncompressed_byte_count=total_uncompressed,
        )
    except BaseException:
        # The output is admitted as a new, identity-bound operation-owned file
        # before this point. Never touch a replacement or the caller's app
        # bundle on failure.
        if opened_output is not None:
            try:
                _unlink_owned_output(destination, opened_output.identity)
            except BaseException as cleanup_error:
                raise ValueError(
                    f"installer archive output could not be safely cleaned up: {cleanup_error}"
                ) from cleanup_error
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-bundle", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        result = package_archive(
            app_bundle=Path(args.app_bundle),
            output=Path(args.output),
        )
        print(
            "INSTALLER_APP_ARCHIVE=PASS"
            " profile=stored-zip-v1"
            f" entries={result.entry_count}"
            f" archive_bytes={result.archive_byte_count}"
            f" uncompressed_bytes={result.total_uncompressed_byte_count}"
        )
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        print(f"INSTALLER_APP_ARCHIVE=FAIL reason={error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
