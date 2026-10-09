"""Give an exact cached wheel its signed source filename for product CLI use.

Only installer staging is written. Product roots, services, credentials and
published venvs remain owned by their existing product boundaries.
"""
from __future__ import annotations

from hashlib import sha256
import os
from pathlib import Path, PurePosixPath
import re
from urllib.parse import urlsplit
from uuid import uuid4

from .component_operations import QualifiedArtifact
from .managed_product_wheel_materialization import (
    _open_private_directory, _open_child, _read_file, _write_file,
)


def stage_product_cli_wheel(path: Path, artifact: QualifiedArtifact) -> Path:
    """Publish only verified bytes, exclusively, under a digest-owned namespace."""
    if path.suffix != ".artifact":
        return path
    if not path.is_absolute() or path.stem != artifact.digest.removeprefix("sha256:"):
        raise ValueError("product CLI staged artifact identity is invalid")
    source = urlsplit(artifact.source)
    name = PurePosixPath(source.path).name
    if (
        source.scheme != "https" or not source.hostname
        or source.username is not None or source.password is not None
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,192}\.whl", name) is None
        or ".." in name or path.parent.resolve(strict=True) != path.parent
    ):
        raise ValueError("product CLI wheel source name is invalid")
    owner = os.geteuid()
    root = _open_private_directory(path.parent, owner, 0o700)
    try:
        if os.stat(path.name, dir_fd=root, follow_symlinks=False).st_size > 512 * 1024 * 1024:
            raise ValueError("product CLI wheel exceeds its size bound")
        contents = _read_file(root, path.name, owner, 0o600)
        if "sha256:" + sha256(contents).hexdigest() != artifact.digest:
            raise ValueError("product CLI staged wheel digest changed")
        namespace = artifact.digest.removeprefix("sha256:") + ".wheel"
        try:
            os.mkdir(namespace, mode=0o700, dir_fd=root)
        except FileExistsError:
            pass
        directory = _open_child(root, namespace, owner, 0o700)
        try:
            try:
                existing = _read_file(directory, name, owner, 0o600)
            except FileNotFoundError:
                temporary = ".wheel-tmp-" + uuid4().hex
                try:
                    _write_file(directory, temporary, contents, 0o600)
                    try:
                        os.link(temporary, name, src_dir_fd=directory,
                                dst_dir_fd=directory, follow_symlinks=False)
                    except FileExistsError:
                        pass
                finally:
                    os.unlink(temporary, dir_fd=directory)
                    os.fsync(directory)
                existing = _read_file(directory, name, owner, 0o600)
            if existing != contents:
                raise ValueError("product CLI named wheel identity changed")
            before = os.fstat(directory)
            after = os.stat(namespace, dir_fd=root, follow_symlinks=False)
            if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
                raise ValueError("product CLI wheel namespace changed")
            return path.parent / namespace / name
        finally:
            os.close(directory)
    finally:
        os.close(root)
