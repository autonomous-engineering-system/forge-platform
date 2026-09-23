#!/usr/bin/env python3
"""Measure executable-line coverage for the Managed Installer V1 Python slice.

This uses only the Python standard library so the protected repository gate does
not acquire a new network/package dependency. The executable-line denominator
comes from CPython code-object line tables and the numerator from actual traced
line events while the canonical relevant unittest modules execute.
"""

from __future__ import annotations

import argparse
import dis
import importlib.util
from pathlib import Path
import sys
import trace
import types
import unittest


ROOT = Path(__file__).resolve().parents[1]

TARGETS = (
    "forge_platform/component_operations.py",
    "forge_platform/universal_installer.py",
    "forge_platform/managed_deployments.py",
    "forge_platform/managed_installer.py",
    "forge_platform/managed_pairing.py",
    "forge_platform/provider_fanout.py",
    "forge_platform/provider_runtime.py",
    "forge_platform/engineering_platform_system_adapter.py",
    "forge_platform/forge_server_adapter.py",
)

TESTS = (
    "tests/component_operations/test_component_operations.py",
    "tests/component_operations/test_durable_component_operations.py",
    "tests/component_operations/test_ep_system_provisioner_adapter.py",
    "tests/component_operations/test_forge_server_adapter.py",
    "tests/installer/test_universal_installer.py",
    "tests/installer/test_managed_deployments.py",
    "tests/installer/test_managed_installer.py",
    "tests/installer/test_managed_pairing.py",
    "tests/installer/test_provider_targets.py",
    "tests/installer/test_provider_fanout.py",
    "tests/installer/test_provider_runtime.py",
)


def _executable_lines(path: Path) -> set[int]:
    code = compile(path.read_text(encoding="utf-8"), str(path), "exec")
    lines: set[int] = set()

    def walk(current: types.CodeType) -> None:
        lines.update(line for _offset, line in dis.findlinestarts(current) if line > 0)
        for constant in current.co_consts:
            if isinstance(constant, types.CodeType):
                walk(constant)

    walk(code)
    return lines


def _load_test_module(path: Path, index: int):
    name = f"_managed_installer_coverage_test_{index}_{path.stem}"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load coverage test module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _run_tests() -> unittest.result.TestResult:
    for directory in (
        ROOT,
        ROOT / "tests" / "component_operations",
        ROOT / "tests" / "installer",
    ):
        value = str(directory)
        if value not in sys.path:
            sys.path.insert(0, value)
    suite = unittest.TestSuite()
    loader = unittest.defaultTestLoader
    for index, relative in enumerate(TESTS):
        module = _load_test_module(ROOT / relative, index)
        suite.addTests(loader.loadTestsFromModule(module))
    return unittest.TextTestRunner(verbosity=1).run(suite)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--minimum", type=float, default=80.2)
    args = parser.parse_args(argv)
    if not 0 <= args.minimum <= 100:
        raise ValueError("minimum coverage must be between zero and 100")

    tracer = trace.Trace(count=1, trace=0, ignoredirs=(sys.prefix, sys.base_prefix))
    result = tracer.runfunc(_run_tests)
    if not result.wasSuccessful():
        print("MANAGED_INSTALLER_PYTHON_COVERAGE=TEST_FAILURE", file=sys.stderr)
        return 1

    raw_counts = tracer.results().counts
    counts: dict[Path, set[int]] = {}
    for (filename, line), count in raw_counts.items():
        if count <= 0:
            continue
        try:
            resolved = Path(filename).resolve()
        except (OSError, RuntimeError):
            continue
        counts.setdefault(resolved, set()).add(line)

    failures: list[str] = []
    for relative in TARGETS:
        path = (ROOT / relative).resolve()
        executable = _executable_lines(path)
        hit = counts.get(path, set()) & executable
        percentage = 100.0 if not executable else 100.0 * len(hit) / len(executable)
        print(
            f"MANAGED_INSTALLER_PYTHON_FILE_COVERAGE path={relative} "
            f"covered={len(hit)} executable={len(executable)} percent={percentage:.6f}"
        )
        if percentage <= args.minimum:
            failures.append(f"{relative}={percentage:.6f}%")

    if failures:
        print(
            f"MANAGED_INSTALLER_PYTHON_COVERAGE=FAIL minimum_strictly_greater_than={args.minimum:.6f} "
            + " ".join(failures),
            file=sys.stderr,
        )
        return 1
    print(
        f"MANAGED_INSTALLER_PYTHON_COVERAGE=PASS minimum_strictly_greater_than={args.minimum:.6f}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
