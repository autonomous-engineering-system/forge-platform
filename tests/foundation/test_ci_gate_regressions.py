#!/usr/bin/env python3
"""Executable CI-gate regressions; Apple commands are isolated test-owned fakes.

These tests qualify control flow and rejection behaviour, never a real signer,
notarized artifact, provider login, physical Mac or cold-reboot acceptance.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
COVERAGE = ROOT / "scripts/check_managed_installer_swift_coverage.py"
PYTHON_COVERAGE = ROOT / "scripts/check_managed_installer_python_coverage.py"
READINESS = ROOT / "scripts/ci/verify_macos_signing_runner.sh"
spec = importlib.util.spec_from_file_location("swift_coverage_gate", COVERAGE)
assert spec is not None and spec.loader is not None
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
python_spec = importlib.util.spec_from_file_location("python_coverage_gate", PYTHON_COVERAGE)
assert python_spec is not None and python_spec.loader is not None
python_gate = importlib.util.module_from_spec(python_spec)
python_spec.loader.exec_module(python_gate)
FILES = (
    "ForgePlatformInstallerCore/InstallerDomain.swift",
    "ForgePlatformInstallerCore/ManagedDeploymentDomain.swift",
    "ForgePlatformInstallerCore/ManagedCompositionSessionPlan.swift",
    "ForgePlatformInstaller/ForgePlatformInstallerApp.swift",
    "ForgePlatformInstaller/InstallerApplicationStartup.swift",
    "ForgePlatformInstallerCore/ReleasedInstallerStartup.swift",
    "ForgePlatformInstallerCore/SelfUpdateCoordinator.swift",
)


def record(name: str, covered: int = 1000, count: int = 1000, percent: float = 100.0) -> dict:
    return {"filename": "/fixture/macos/ForgePlatformInstaller/Sources/" + name,
            "summary": {"lines": {"count": count, "covered": covered, "percent": percent}}}


def payload() -> dict:
    return {"data": [{"files": [record(name) for name in FILES]}]}


class CoverageContractTests(unittest.TestCase):
    def invoke(self, value: object, *args: str) -> tuple[int, str]:
        with tempfile.TemporaryDirectory(prefix="forge-coverage-test-") as tmp:
            path = Path(tmp) / "coverage.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                code = gate.main([str(path), *args])
            return code, output.getvalue()

    def reject(self, value: object, *args: str) -> None:
        code, output = self.invoke(value, *args)
        self.assertNotEqual(code, 0, output)
        self.assertNotIn("COVERAGE=PASS", output)

    def test_happy_path_has_all_seven_required_files(self) -> None:
        code, output = self.invoke(payload())
        self.assertEqual(code, 0, output)
        self.assertEqual(output.count("SWIFT_FILE_COVERAGE"), len(FILES))

    def test_exact_threshold_fails_but_strictly_greater_passes(self) -> None:
        for covered, expected in ((802, 1), (803, 0)):
            value = {"data": [{"files": [record(name, covered, 1000, covered / 10) for name in FILES]}]}
            self.assertEqual(self.invoke(value)[0], expected)

    def test_rounded_display_does_not_decide_the_threshold(self) -> None:
        value = {"data": [{"files": [record(name, 80201, 100000, 80.20) for name in FILES]}]}
        self.assertEqual(self.invoke(value)[0], 0)

    def test_changed_startup_and_self_update_files_cannot_be_missing(self) -> None:
        for name in FILES[-3:]:
            with self.subTest(name=name):
                self.reject({"data": [{"files": [record(other) for other in FILES if other != name]}]})

    def test_changed_startup_and_self_update_files_cannot_have_zero_coverage(self) -> None:
        for name in FILES[-3:]:
            with self.subTest(name=name):
                records = [record(other, 0, 1000, 0) if other == name else record(other) for other in FILES]
                self.reject({"data": [{"files": records}]})

    def test_invalid_line_counts_fail(self) -> None:
        for key, values in (("count", (0, -1, True, 1.5, "1000", 2**63)),
                            ("covered", (-1, 1001, True, 1.5, "1000"))):
            for value in values:
                with self.subTest(key=key, value=value):
                    body = payload()
                    body["data"][0]["files"][0]["summary"]["lines"][key] = value
                    self.reject(body)

    def test_nonfinite_boolean_and_out_of_range_percent_fail(self) -> None:
        for percent in (float("nan"), float("inf"), float("-inf"), True, -1, 101, "100"):
            with self.subTest(percent=percent):
                body = payload()
                body["data"][0]["files"][0]["summary"]["lines"]["percent"] = percent
                self.reject(body)

    def test_display_percent_cannot_override_zero_executed_lines(self) -> None:
        self.reject({"data": [{"files": [record(name, 0, 1000, 100) for name in FILES]}]})

    def test_duplicate_target_across_llvm_blocks_fails(self) -> None:
        body = payload()
        body["data"].append({"files": [record(FILES[0])]})
        self.reject(body)

    def test_malformed_payload_and_missing_lines_fail(self) -> None:
        for value in ([], None, {}, {"data": []}, {"data": [None]}, {"data": [{}]},
                      {"data": [{"files": [None]}]}, {"data": [{"files": [{"filename": 1}]}]}):
            with self.subTest(value=value):
                self.reject(value)
        for summary in (None, {}, {"lines": None}):
            body = payload()
            body["data"][0]["files"][0]["summary"] = summary
            self.reject(body)

    def test_unsafe_path_fails(self) -> None:
        body = payload()
        body["data"][0]["files"][0]["filename"] = "/../fixture/Sources/" + FILES[0]
        self.reject(body)

    def test_non_target_records_and_windows_path_separators(self) -> None:
        body = payload()
        body["data"][0]["files"].append({"filename": "/fixture/Tests/Example.swift"})
        for item in body["data"][0]["files"]:
            item["filename"] = item["filename"].replace("/", "\\")
        self.assertEqual(self.invoke(body)[0], 0)

    def test_threshold_cannot_be_lowered_or_nonfinite(self) -> None:
        for minimum in ("0", "80.1", "nan", "inf", "101"):
            with self.subTest(minimum=minimum):
                self.reject(payload(), "--minimum", minimum)
        self.reject(payload(), "--minimum", "100")

    def test_cli_rejects_unavailable_and_corrupt_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "missing.json"
            for content in (None, "{", "[]"):
                if content is not None:
                    path.write_text(content, encoding="utf-8")
                result = subprocess.run([sys.executable, str(COVERAGE), str(path)],
                                        text=True, capture_output=True, timeout=10, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("COVERAGE=PASS", result.stdout)

    def test_invalid_git_baseline_never_falls_back_to_fixed_scope(self) -> None:
        for baseline in ("main", "--help", "a" * 39, "A" * 40):
            self.reject(payload(), f"--base-ref={baseline}")
        with mock.patch.object(gate.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["git"])):
            self.reject(payload(), "--base-ref", "a" * 40)
        with mock.patch.object(gate.subprocess, "run", side_effect=subprocess.TimeoutExpired(["git"], 30)):
            self.reject(payload(), "--base-ref", "a" * 40)

    def test_real_git_diff_adds_new_and_renamed_production_files(self) -> None:
        with tempfile.TemporaryDirectory(prefix="forge-coverage-git-") as tmp:
            root = Path(tmp)
            def git(*args: str) -> str:
                return subprocess.run(["git", *args], cwd=root, check=True, text=True,
                                      capture_output=True, timeout=10).stdout.strip()
            git("init", "-q")
            git("config", "user.name", "CI fixture")
            git("config", "user.email", "fixture@example.invalid")
            source = root / gate.SOURCE_PREFIX
            source.mkdir(parents=True)
            (source / "Old.swift").write_text("let value = 1\n", encoding="utf-8")
            git("add", ".")
            git("commit", "-qm", "fixture base")
            base = git("rev-parse", "HEAD")
            (source / "Old.swift").rename(source / "Renamed.swift")
            (source / "New.swift").write_text("let newValue = 2\n", encoding="utf-8")
            (root / "Tests").mkdir()
            (root / "Tests/Ignore.swift").write_text("// not production\n", encoding="utf-8")
            git("add", ".")
            git("commit", "-qm", "fixture change")
            with mock.patch.object(gate, "ROOT", root):
                targets = gate.required_targets(base)
                self.assertIn("/Sources/New.swift", targets)
                self.assertIn("/Sources/Renamed.swift", targets)
                self.assertNotIn("/Sources/Old.swift", targets)
                self.assertFalse(any("Ignore.swift" in target for target in targets))
                self.reject(payload(), "--base-ref", base)
                body = payload()
                body["data"][0]["files"].extend([record("New.swift"), record("Renamed.swift")])
                self.assertEqual(self.invoke(body, "--base-ref", base)[0], 0)

    def test_unsafe_git_source_paths_fail(self) -> None:
        completed = subprocess.CompletedProcess(["git"], 0)
        for path in (gate.SOURCE_PREFIX + "../Escape.swift\0", gate.SOURCE_PREFIX + "Bad\nName.swift\0"):
            with mock.patch.object(gate.subprocess, "run", side_effect=[
                completed, subprocess.CompletedProcess(["git"], 0, path.encode())
            ]):
                self.reject(payload(), "--base-ref", "a" * 40)


class PythonCoverageLineTableTests(unittest.TestCase):
    def test_synthetic_none_line_entries_are_ignored(self) -> None:
        with mock.patch.object(
            python_gate.dis,
            "findlinestarts",
            return_value=[(0, None), (1, 4)],
        ):
            self.assertEqual(python_gate._executable_lines(Path(__file__)), {4})


STUB = r'''#!SHEBANG
import json, os, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
mode = os.environ.get('FAKE_MODE', '')
if name == 'uname': print('x86_64' if mode == 'intel' else 'arm64')
elif name == 'sw_vers': print('25.0' if mode == 'old-os' else '26.0')
elif name == 'xcode-select': print(os.environ['FAKE_DEVELOPER_DIR'])
elif name == 'xcodebuild': print('Xcode TEST\nBuild version TEST_ONLY')
elif name == 'security':
    print('1) ' + '1' * 40 + ' "Developer ID Application: Expected Test (AAAAAAAAAA)"')
    print('2) ' + '2' * 40 + ' "Developer ID Application: Wrong Test (ZZZZZZZZZZ)"')
    if mode == 'duplicate-identity':
        print('3) ' + '3' * 40 + ' "Developer ID Application: Expected Test (AAAAAAAAAA)"')
elif name == 'codesign':
    if '--sign' in args:
        assert sys.stdin.read() == ''
        Path(os.environ['FAKE_SIGN_CALLED']).write_text(args[args.index('--sign') + 1])
        if mode == 'interrupted-sign': sys.exit(130)
    if '--verify' in args and mode == 'bad-signature': sys.exit(1)
    if '-R' in args:
        Path(os.environ['FAKE_ANCHOR_CALLED']).write_text('called')
        if mode == 'bad-anchor': sys.exit(1)
    if '-d' in args or '--display' in args:
        team = 'ZZZZZZZZZZ' if mode == 'signed-wrong-team' else 'AAAAAAAAAA'
        print('TeamIdentifier=' + team, file=sys.stderr)
        if mode == 'duplicate-team': print('TeamIdentifier=' + team, file=sys.stderr)
        bundle = 'wrong.bundle' if mode == 'wrong-bundle' else 'com.forgeplatform.ci.signing-probe'
        print('Identifier=' + bundle, file=sys.stderr)
    sys.exit(0)
elif name == 'xcrun':
    if '--show-sdk-version' in args: print('26.0')
    elif args[:2] == ['notarytool', 'history']:
        Path(os.environ['FAKE_HISTORY_CALLED']).write_text('called')
        if mode == 'notary-failure':
            print('SYNTHETIC_SECRET_MUST_NOT_ESCAPE', file=sys.stderr)
            sys.exit(1)
        if mode == 'bad-notary-json': print('not-json')
        elif mode == 'bad-notary-shape': print('{}')
        else: print(json.dumps({'history': []}))
    sys.exit(0)
else: sys.exit(91)
'''


class SigningReadinessContractTests(unittest.TestCase):
    def run_gate(self, mode: str = "", overrides: dict | None = None) -> tuple:
        with tempfile.TemporaryDirectory(prefix="forge-signing-test-") as tmp:
            root = Path(tmp)
            bindir, tempdir, developer = (root / name for name in ("bin", "temp", "Developer"))
            for path in (bindir, tempdir, developer):
                path.mkdir()
            stub = bindir / "tool"
            stub.write_text(STUB.replace("SHEBANG", sys.executable + " -S"), encoding="utf-8")
            stub.chmod(0o700)
            for name in ("uname", "sw_vers", "xcode-select", "xcodebuild", "security", "codesign", "xcrun"):
                (bindir / name).symlink_to(stub.name)
            (bindir / "python3").symlink_to(sys.executable)
            history, sign, anchor = (root / name for name in ("history", "sign", "anchor"))
            runner_root = root / "signer-runner"
            runner_root.mkdir()
            service = runner_root / "svc.sh"
            service.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            service.chmod(0o700)
            env = {
                "PATH": str(bindir) + ":/usr/bin:/bin", "HOME": str(root), "TMPDIR": str(tempdir),
                "RUNNER_NAME": "fixture-not-a-real-mini", "FORGE_PLATFORM_APPLE_TEAM_ID": "AAAAAAAAAA",
                "FORGE_PLATFORM_CODESIGN_IDENTITY": "Developer ID Application: Expected Test (AAAAAAAAAA)",
                "FORGE_PLATFORM_NOTARYTOOL_PROFILE": "fixture-only",
                "FORGE_PLATFORM_SIGNER_ACCOUNT": os.environ.get("USER", ""),
                "FORGE_PLATFORM_SIGNER_RUNNER_ROOT": str(runner_root),
                "FAKE_MODE": mode,
                "FAKE_DEVELOPER_DIR": str(developer), "FAKE_HISTORY_CALLED": str(history),
                "FAKE_SIGN_CALLED": str(sign), "FAKE_ANCHOR_CALLED": str(anchor),
            }
            env.update(overrides or {})
            result = subprocess.run(["/bin/bash", str(READINESS)], env=env, stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=20, check=False)
            self.assertNotIn("SYNTHETIC_SECRET_MUST_NOT_ESCAPE", result.stdout + result.stderr)
            self.assertEqual(list(tempdir.iterdir()), [], "Private probe was not cleaned up")
            return result, history.exists(), sign.read_text() if sign.exists() else None, anchor.exists()

    def test_complete_simulated_chain_includes_exact_signer_and_apple_anchor(self) -> None:
        result, history, signed, anchor = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(history and anchor)
        self.assertEqual(signed, "1" * 40)
        self.assertIn("NOTARIZATION_ACCEPTANCE=NOT_RUN", result.stdout)
        self.assertIn("Build version TEST_ONLY", result.stdout)

    def test_exact_fingerprint_configuration_is_supported(self) -> None:
        result, _, signed, _ = self.run_gate(overrides={"FORGE_PLATFORM_CODESIGN_IDENTITY": "1" * 40})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(signed, "1" * 40)

    def test_missing_profile_blocks_before_signing(self) -> None:
        result, history, signed, _ = self.run_gate(overrides={"FORGE_PLATFORM_NOTARYTOOL_PROFILE": ""})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(history)
        self.assertIsNone(signed)

    def test_other_certificate_cannot_supply_the_expected_team(self) -> None:
        result, history, signed, _ = self.run_gate(overrides={
            "FORGE_PLATFORM_CODESIGN_IDENTITY": "Developer ID Application: Wrong Test (ZZZZZZZZZZ)"
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(history)
        self.assertIsNone(signed)

    def test_duplicate_identity_is_ambiguous_not_ready(self) -> None:
        result, _, signed, _ = self.run_gate("duplicate-identity")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(signed)

    def test_missing_and_partial_identity_do_not_match(self) -> None:
        for identity in ("", "Expected Test", "9" * 40):
            with self.subTest(identity=identity):
                result, _, signed, _ = self.run_gate(overrides={"FORGE_PLATFORM_CODESIGN_IDENTITY": identity})
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(signed)

    def test_invalid_team_and_runner_name_fail(self) -> None:
        for override in ({"FORGE_PLATFORM_APPLE_TEAM_ID": "invalid"}, {"RUNNER_NAME": ""}):
            result, _, signed, _ = self.run_gate(overrides=override)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(signed)

    def test_wrong_architecture_and_old_os_fail_before_signing(self) -> None:
        for mode in ("intel", "old-os"):
            result, _, signed, _ = self.run_gate(mode)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(signed)

    def test_signature_anchor_and_interruption_fail_closed(self) -> None:
        for mode in ("bad-signature", "bad-anchor", "interrupted-sign"):
            with self.subTest(mode=mode):
                result, history, signed, _ = self.run_gate(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNotNone(signed)
                self.assertFalse(history)
                self.assertNotIn("READINESS=PASS", result.stdout)

    def test_signed_team_bundle_and_ambiguous_metadata_fail(self) -> None:
        for mode in ("signed-wrong-team", "wrong-bundle", "duplicate-team"):
            with self.subTest(mode=mode):
                result, history, _, anchor = self.run_gate(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(anchor)
                self.assertFalse(history)

    def test_notary_errors_invalid_json_and_wrong_shape_fail_without_secret_output(self) -> None:
        for mode in ("notary-failure", "bad-notary-json", "bad-notary-shape"):
            with self.subTest(mode=mode):
                result, history, _, _ = self.run_gate(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(history)
                self.assertNotIn("READINESS=PASS", result.stdout)


class WorkflowWiringTests(unittest.TestCase):
    """Static wiring checks supplement, not replace, live GitHub policy readback."""
    def test_regressions_are_mandatory_in_foundation_and_native_hosted_ci(self) -> None:
        command = "python3 tests/foundation/test_ci_gate_regressions.py"
        self.assertIn(command, (ROOT / "scripts/validate.sh").read_text())
        hosted = (ROOT / ".github/workflows/macos-installer-validation.yml").read_text()
        self.assertIn(command, hosted)
        self.assertIn("workflow_call:", hosted)
        foundation = (ROOT / ".github/workflows/foundation-validation.yml").read_text()
        self.assertIn("pull_request:", foundation)
        self.assertIn("uses: ./.github/workflows/macos-installer-validation.yml", foundation)
        self.assertIn("runs-on: macos-26", hosted)
        self.assertNotIn("self-hosted", hosted)
        self.assertNotIn("paths:", hosted)
        self.assertNotIn("continue-on-error", hosted)
        self.assertIn("persist-credentials: false", hosted)
        self.assertIn(' --base-ref "$COVERAGE_BASE_SHA"', hosted)

    def test_every_privileged_job_has_environment_and_prior_admission(self) -> None:
        text = (ROOT / ".github/workflows/macos-installer-native-integration.yml").read_text()
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("pull_request:", text)
        self.assertIn("github.ref_protected", text)
        self.assertIn("github.workflow_sha == inputs.source_sha", text)
        self.assertIn("github.sha == inputs.source_sha", text)
        self.assertIn("github.ref == 'refs/heads/main'", text)
        self.assertIn("runs-on: ubuntu-latest", text)
        native = text.split("  native-integration:\n", 1)[1].split("  signing-readiness:\n", 1)[0]
        signing = text.split("  signing-readiness:\n", 1)[1]
        self.assertIn("needs: admission", native)
        self.assertIn("needs: native-integration", signing)
        self.assertIn("environment:\n      name: forge-platform-installer-integration", native)
        self.assertIn("environment:\n      name: forge-platform-installer-signing", signing)
        for job in (native, signing):
            self.assertIn("persist-credentials: false", job)
            self.assertIn('test "$SOURCE_SHA" = "$(git rev-parse origin/main)"', job)
        self.assertIn("group: forge-platform-macmini-privileged", text)
        self.assertIn("cancel-in-progress: false", text)
        self.assertIn(' --base-ref "$COVERAGE_BASE_SHA"', native)
        self.assertNotIn("continue-on-error", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
