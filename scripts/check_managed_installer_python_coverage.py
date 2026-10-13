#!/usr/bin/env python3
"""Measure executable-line coverage for the Managed Installer V1 Python slice.

This uses only the Python standard library so the protected repository gate does
not acquire a new network/package dependency. The executable-line denominator
comes from CPython code-object line tables and the numerator from actual traced
line events while the canonical relevant unittest modules execute.
"""

from __future__ import annotations

import argparse
import ast
import dis
import importlib.util
from pathlib import Path
import sys
import trace
import types
import unittest
import contextlib
import io
import os
import subprocess
import hashlib


ROOT = Path(__file__).resolve().parents[1]

TARGETS = (
    "scripts/protected_root_qualification.py",
    "scripts/emit_protected_root_qualification.py",
    "forge_platform/managed_ep_partial_create.py",
    "forge_platform/managed_ep_service_preparation.py",
    "forge_platform/managed_historical_current_executor.py",
    "forge_platform/managed_historical_execution_admission.py",
    "forge_platform/managed_historical_execution_evidence.py",
    "forge_platform/managed_historical_execution_record_reader.py",
    "forge_platform/managed_historical_product_evidence.py",
    "forge_platform/managed_product_progress.py",

    "forge_platform/component_operations.py",
    "forge_platform/universal_installer.py",
    "forge_platform/installer_helper_companion.py",
    "forge_platform/managed_python_runtime_executor.py",
    "forge_platform/managed_deployments.py",
    "forge_platform/managed_preserved_lifecycle_plan.py",
    "forge_platform/managed_preserved_product_adapters.py",
    "forge_platform/managed_preserve_execution.py",
    "forge_platform/managed_ep_restore_execution.py",
    "forge_platform/managed_preserve_recovery.py",
    "forge_platform/managed_purge_recovery.py",
    "forge_platform/managed_preserved_lifecycle_request.py",
    "forge_platform/managed_preserved_lifecycle_dispatch.py",
    "forge_platform/managed_preserved_lifecycle_proposal.py",
    "forge_platform/managed_installer.py",
    "forge_platform/managed_install_flow.py",
    "forge_platform/managed_forge_removal.py",
    "forge_platform/managed_pairing_revocation.py",
    "forge_platform/managed_pairing_detach.py",
    "forge_platform/managed_paired_forge_removal.py",
    "forge_platform/managed_paired_deployment_removal.py",
    "forge_platform/managed_product_operation_admission.py",
    "forge_platform/managed_product_removal_admission.py",
    "forge_platform/managed_product_removal_dispatch.py",
    "forge_platform/managed_product_removal_review.py",
    "forge_platform/managed_product_removal_proposal.py",
    "forge_platform/managed_product_operation_dispatch.py",
    "forge_platform/managed_product_operation_service.py",
    "forge_platform/managed_pairing.py",
    "forge_platform/forge_ep_pairing_executor.py",
    "forge_platform/released_product_routes.py",
    "forge_platform/installer_product_worker.py",
    "forge_platform/product_worker_authority.py",
    "forge_platform/product_preserved_lifecycle.py",
    "forge_platform/qualified_forge_lifecycle.py",
    "forge_platform/qualified_ep_lifecycle.py",
    "forge_platform/provider_fanout.py",
    "forge_platform/engineering_platform_system_adapter.py",
    "forge_platform/engineering_platform_provider_target.py",
    "forge_platform/managed_ep_provider_registration.py",
    "forge_platform/ep_consumer_revocation.py",
    "forge_platform/ep_consumer_registration.py",
    "forge_platform/ep_credential_recovery.py",
    "forge_platform/managed_ep_credential_issuance.py",
    "forge_platform/managed_ep_initial_credential.py",
    "forge_platform/managed_ep_installation_credential.py",
    "forge_platform/ep_installation_pairing_adapter.py",
    "forge_platform/installation_credential_issuer.py",
    "forge_platform/managed_system_keychain_store.py",
    "forge_platform/managed_pairing_repair_credential.py",
    "forge_platform/managed_pairing_repair_execution.py",
    "forge_platform/managed_pairing_repair_commit.py",
    "forge_platform/released_pairing_repair_selection.py",
    "forge_platform/released_pairing_repair_review.py",
    "forge_platform/released_pairing_repair_admission.py",
    "forge_platform/forge_server_adapter.py",
    "forge_platform/forge_update_intent.py",
    "forge_platform/forge_update_resources.py",
    "forge_platform/forge_update_binding_provider.py",
    "forge_platform/managed_product_wheel_inspection.py",
    "forge_platform/managed_product_wheel_materialization.py",
    "forge_platform/managed_product_wheel_readback.py",
    "forge_platform/managed_product_wheel_worker.py",
    "scripts/prepare_composition_catalog_candidate.py",
    "scripts/finalize_signed_composition_catalog.py",
    "scripts/verify_local_catalog_authorization.py",
    "scripts/observe_composition_producer_releases.py",
    "scripts/package_macos_installer_app.py",
    "scripts/prepare_macos_installer_bootstrap_metadata.py",
    "scripts/installer_package_signing_metadata.py",
    "scripts/installer_helper_package_release.py",
    "scripts/verified_installer_helper_package.py",
    "scripts/installer_helper_package_payload.py",
    "scripts/qualify_local_installer_release.py",
    "scripts/record_local_installer_publication.py",
    "scripts/verify_installer_release_evidence.py",
    "scripts/build_installer_product_worker.py",
    "scripts/package_macos_installer_archive.py",
    "scripts/prepare_managed_tool_pages.py",
    "scripts/verify_managed_tool_pages.py",
    "scripts/prepare_provider_runtime_pages.py",
    "scripts/build_provider_runtime_archives.py",
    "scripts/qualify_managed_python_runtime.py",
    "scripts/qualify_product_wheels_managed_python.py",
)

TESTS = (
    "tests/installer/test_protected_root_qualification.py",
    "tests/installer/test_managed_ep_partial_create_evidence.py",
    "tests/installer/test_managed_ep_service_preparation.py",
    "tests/installer/test_managed_historical_current_executor.py",
    "tests/installer/test_managed_historical_execution_admission.py",
    "tests/installer/test_managed_historical_execution_evidence.py",
    "tests/installer/test_managed_historical_execution_record_reader.py",
    "tests/installer/test_managed_historical_product_evidence.py",
    "tests/installer/test_managed_historical_recovery_preflight.py",
    "tests/installer/test_managed_product_progress.py",

    "tests/installer/test_managed_tool_pages.py",
    "tests/installer/test_verify_managed_tool_pages.py",
    "tests/installer/test_provider_runtime_pages.py",
    "tests/installer/test_build_provider_runtime_archives.py",
    "tests/installer/test_qualify_managed_python_runtime.py",
    "tests/installer/test_qualify_product_wheels_managed_python.py",
    "tests/component_operations/test_component_operations.py",
    "tests/component_operations/test_durable_component_operations.py",
    "tests/component_operations/test_ep_system_provisioner_adapter.py",
    "tests/component_operations/test_ep_consumer_revocation.py",
    "tests/component_operations/test_ep_consumer_registration.py",
    "tests/installer/test_ep_initial_consumer_registration.py",
    "tests/component_operations/test_ep_credential_recovery.py",
    "tests/installer/test_managed_ep_credential_issuance.py",
    "tests/installer/test_managed_ep_initial_credential.py",
    "tests/installer/test_managed_ep_installation_credential.py",
    "tests/installer/test_ep_installation_pairing_adapter.py",
    "tests/installer/test_installation_credential_issuer.py",
    "tests/installer/test_managed_system_keychain_store.py",
    "tests/installer/test_managed_pairing_repair_credential.py",
    "tests/installer/test_managed_pairing_repair_execution.py",
    "tests/installer/test_managed_pairing_repair_commit.py",
    "tests/installer/test_released_pairing_repair_selection.py",
    "tests/installer/test_released_pairing_repair_review.py",
    "tests/installer/test_released_pairing_repair_admission.py",
    "tests/component_operations/test_forge_server_adapter.py",
    "tests/component_operations/test_forge_update_intent.py",
    "tests/installer/test_forge_update_resources.py",
    "tests/installer/test_forge_update_binding_provider.py",
    "tests/installer/test_managed_product_wheel_inspection.py",
    "tests/installer/test_managed_product_wheel_materialization.py",
    "tests/installer/test_managed_product_wheel_readback.py",
    "tests/installer/test_managed_product_wheel_worker.py",
    "tests/installer/test_universal_installer.py",
    "tests/installer/test_managed_python_runtime_executor.py",
    "tests/installer/test_managed_deployments.py",
    "tests/installer/test_managed_preserved_lifecycle_plan.py",
    "tests/installer/test_managed_preserved_product_adapters.py",
    "tests/installer/test_managed_preserve_execution.py",
    "tests/installer/test_managed_ep_restore_execution.py",
    "tests/installer/test_managed_preserved_lifecycle_request.py",
    "tests/installer/test_managed_preserved_lifecycle_dispatch.py",
    "tests/installer/test_managed_preserved_lifecycle_proposal.py",
    "tests/installer/test_managed_installer.py",
    "tests/installer/test_managed_install_flow.py",
    "tests/installer/test_managed_forge_removal.py",
    "tests/installer/test_managed_pairing_revocation.py",
    "tests/installer/test_managed_pairing_detach.py",
    "tests/installer/test_managed_paired_forge_removal.py",
    "tests/installer/test_managed_paired_deployment_removal.py",
    "tests/installer/test_managed_product_operation_admission.py",
    "tests/installer/test_managed_product_removal_admission.py",
    "tests/installer/test_managed_product_removal_dispatch.py",
    "tests/installer/test_managed_product_removal_review.py",
    "tests/installer/test_managed_product_removal_proposal.py",
    "tests/installer/test_managed_product_removal_review_worker.py",
    "tests/installer/test_managed_product_operation_dispatch.py",
    "tests/installer/test_managed_product_operation_service.py",
    "tests/installer/test_managed_pairing.py",
    "tests/installer/test_forge_ep_pairing_executor.py",
    "tests/installer/test_installation_pairing_service_account_route.py",
    "tests/installer/test_released_product_routes.py",
    "tests/installer/test_installer_product_worker.py",
    "tests/installer/test_product_worker_authority.py",
    "tests/installer/test_product_preserved_lifecycle.py",
    "tests/installer/test_qualified_forge_lifecycle.py",
    "tests/installer/test_provider_targets.py",
    "tests/installer/test_provider_fanout.py",
    "tests/installer/test_ep_provider_target.py",
    "tests/installer/test_managed_ep_provider_registration.py",
    "tests/installer/test_composition_catalog_release.py",
    "tests/installer/test_composition_producer_observer.py",
    "tests/installer/test_package_macos_installer_app.py",
    "tests/installer/test_package_macos_installer_bootstrap.py",
    "tests/installer/test_prepare_macos_installer_bootstrap_metadata.py",
    "tests/installer/test_helper_package_release_orchestration.py",
    "tests/installer/test_installer_package_signing_metadata.py",
    "tests/installer/test_installer_helper_package_release.py",
    "tests/installer/test_installer_helper_companion.py",
    "tests/installer/test_verified_installer_helper_package.py",
    "tests/installer/test_qualify_local_installer_release.py",
    "tests/installer/test_build_installer_product_worker.py",
    "tests/installer/test_package_macos_installer_archive.py",
)


def _executable_lines(path: Path) -> set[int]:
    source = path.read_text(encoding="utf-8")
    code = compile(source, str(path), "exec")
    lines: set[int] = set()

    def walk(current: types.CodeType) -> None:
        # Some recent CPython bytecode line tables use ``None`` for synthetic
        # instructions. They do not represent executable source lines.
        lines.update(
            line
            for _offset, line in dis.findlinestarts(current)
            if line is not None and line > 0
        )
        for constant in current.co_consts:
            if isinstance(constant, types.CodeType):
                walk(constant)

    walk(code)

    # Python 3.14 can associate RESUME/annotation bytecode with continuation
    # lines in a multiline definition header. Those lines cannot emit trace
    # line events when the function body executes, so counting them makes the
    # same source and tests report lower coverage only on newer interpreters.
    tree = ast.parse(source, filename=str(path))
    definition_continuations: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.body:
            first_body_line = min(statement.lineno for statement in node.body)
            definition_continuations.update(range(node.lineno + 1, first_body_line))
    return lines - definition_continuations


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



# Exact isolated root-only source qualification classes. No installer, service,
# provider credentials, accounts or production paths are created or changed.
ROOT_QUALIFICATION_CLASSES = (
    ("tests/installer/test_managed_ep_partial_create_evidence.py", "ProtectedPartialCreateEvidenceTests"),
    ("tests/installer/test_managed_ep_service_preparation.py", "EPServiceRootAssemblyTests"),
    ("tests/installer/test_managed_historical_current_executor.py", "HistoricalNativeProofRootIOTests"),
    ("tests/installer/test_managed_historical_execution_admission.py", "HistoricalRootFactoryIntegrationTests"),
    ("tests/installer/test_managed_historical_product_evidence.py", "HistoricalProtectedArchiveTests"),
    ("tests/installer/test_managed_product_progress.py", "ProtectedProgressFileTests"),
)

def _source_hashes() -> dict[str, str]:
    return {relative: hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() for relative in TARGETS}


def _require_source_snapshot(expected: dict[str, str]) -> None:
    if _source_hashes() != expected:
        raise ValueError("source changed during qualification")


def _root_qualification_counts() -> dict[str, object]:
    if os.geteuid() != 0 or sys.platform != "darwin":
        raise RuntimeError("root-private Darwin qualification required")
    source_before = _source_hashes()
    for directory in (ROOT, ROOT / "tests" / "installer"):
        sys.path.insert(0, str(directory))
    def run():
        suite = unittest.TestSuite(); loader = unittest.TestLoader()
        for index, (path, name) in enumerate(ROOT_QUALIFICATION_CLASSES):
            module = _load_test_module(ROOT / path, 10000 + index)
            suite.addTests(loader.loadTestsFromTestCase(getattr(module, name)))
        return unittest.TextTestRunner(stream=sys.stderr, verbosity=1).run(suite)
    tracer = trace.Trace(count=1, trace=0, ignoredirs=(sys.prefix, sys.base_prefix))
    with contextlib.redirect_stdout(io.StringIO()): result = tracer.runfunc(run)
    if not result.wasSuccessful() or result.skipped:
        raise RuntimeError("root-private qualification failed or skipped")
    hit: dict[str, set[int]] = {}
    for (filename, line), count in tracer.results().counts.items():
        path = Path(filename).resolve()
        if count > 0 and path.is_relative_to(ROOT) and path.relative_to(ROOT).as_posix() in TARGETS:
            hit.setdefault(path.relative_to(ROOT).as_posix(), set()).add(line)
    _require_source_snapshot(source_before)
    hit = {path: lines & _executable_lines(ROOT / path) for path, lines in hit.items()}
    _require_source_snapshot(source_before)
    return {"schema": "forge-platform.source-root-coverage/v1", "files": {
        path: {"source_sha256": source_before[path], "lines": sorted(lines)}
        for path, lines in hit.items()}}

def _merge_root_qualification(counts: dict[Path, set[int]], source_before: dict[str, str]) -> None:
    import json
    _require_source_snapshot(source_before)
    from scripts.protected_root_qualification import protected_build, read_counts, decode
    if protected_build(os.environ):
        payload = read_counts(ROOT, os.environ)
    else:
        completed = subprocess.run(["sudo", "-n", sys.executable, str(Path(__file__).resolve()), "--root-private-qualification-counts"],
            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=None, check=True, timeout=300)
        payload = decode(completed.stdout)
    _require_source_snapshot(source_before)
    _merge_root_counts(counts, source_before, payload)


def _merge_root_counts(counts: dict[Path, set[int]], source_before: dict[str, str], payload: dict) -> None:
    _require_source_snapshot(source_before)
    if set(payload) != {"schema", "files"} or payload["schema"] != "forge-platform.source-root-coverage/v1" or not isinstance(payload["files"], dict):
        raise ValueError("invalid root counts")
    if not payload["files"]: raise ValueError("empty root qualification")
    for relative, record in payload["files"].items():
        if relative not in TARGETS or set(record) != {"source_sha256", "lines"}: raise ValueError("foreign source counts")
        path = (ROOT / relative).resolve()
        if record["source_sha256"] != source_before[relative]: raise ValueError("source changed during qualification")
        lines = record["lines"]
        if not isinstance(lines, list) or len(lines) > 100000 or any(type(line) is not int or line <= 0 for line in lines): raise ValueError("invalid line counts")
        if lines != sorted(set(lines)) or not set(lines).issubset(_executable_lines(path)): raise ValueError("nonexecutable or duplicate line counts")
        counts.setdefault(path, set()).update(lines)
    _require_source_snapshot(source_before)

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--minimum", type=float, default=80.2)
    parser.add_argument("--root-private-qualification-counts", action="store_true")
    args = parser.parse_args(argv)
    if args.root_private_qualification_counts:
        import json
        print(json.dumps(_root_qualification_counts(), sort_keys=True, separators=(",", ":")))
        return 0
    if not 0 <= args.minimum <= 100:
        raise ValueError("minimum coverage must be between zero and 100")

    source_before = _source_hashes()
    tracer = trace.Trace(count=1, trace=0, ignoredirs=(sys.prefix, sys.base_prefix))
    result = tracer.runfunc(_run_tests)
    _require_source_snapshot(source_before)
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

    _merge_root_qualification(counts, source_before)

    failures: list[str] = []
    for relative in TARGETS:
        path = (ROOT / relative).resolve()
        _require_source_snapshot(source_before)
        executable = _executable_lines(path)
        _require_source_snapshot(source_before)
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
