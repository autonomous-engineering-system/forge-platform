#!/usr/bin/env python3
"""Test the actual required-check shell gate, including skipped/cancelled needs.

Structural assertions supplement the read-back main ruleset. They do not
prove protection against a malicious rewrite of repository workflows or
qualify any self-hosted runner configuration.
"""
from __future__ import annotations

import itertools
from pathlib import Path
import re
import subprocess
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
FOUNDATION = ROOT / ".github/workflows/foundation-validation.yml"
NATIVE = ROOT / ".github/workflows/macos-installer-validation.yml"


def job_source(text: str, job: str) -> str:
    match = re.search(r"^  " + re.escape(job) + r":\n(.*?)(?=^  [a-z][a-z0-9-]*:\n|\Z)",
                      text, flags=re.MULTILINE | re.DOTALL)
    if match is None:
        raise ValueError(f"Missing required workflow job {job}")
    return match.group(1)


def actual_gate_script() -> str:
    body = job_source(FOUNDATION.read_text(encoding="utf-8"), "foundation")
    blocks = re.findall(r"^        run: \|\n((?:^          .*\n)+)", body, flags=re.MULTILINE)
    if len(blocks) != 1:
        raise ValueError("Expected one unambiguous required-check script")
    return textwrap.dedent(blocks[0])


class RequiredCIAggregationTests(unittest.TestCase):
    def test_existing_required_check_always_depends_on_both_suites(self) -> None:
        foundation = FOUNDATION.read_text(encoding="utf-8")
        final = job_source(foundation, "foundation")
        self.assertIn("    name: Foundation validation\n", final)
        self.assertIn("    if: ${{ always() }}\n", final)
        self.assertIn("    needs: [repository-validation, native-validation]\n", final)
        self.assertIn("REPOSITORY_RESULT: ${{ needs.repository-validation.result }}", final)
        self.assertIn("NATIVE_RESULT: ${{ needs.native-validation.result }}", final)
        self.assertIn("timeout-minutes: 5", final)
        self.assertNotIn("checkout", final)
        self.assertNotIn("continue-on-error", foundation)
        self.assertNotIn("paths:", foundation)
        self.assertIn("  pull_request:\n", foundation)
        self.assertIn("  push:\n    branches: [main]\n", foundation)

    def test_same_commit_native_suite_and_all_regressions_are_mandatory(self) -> None:
        foundation = FOUNDATION.read_text(encoding="utf-8")
        native = NATIVE.read_text(encoding="utf-8")
        python_job = job_source(foundation, "repository-validation")
        native_job = job_source(foundation, "native-validation")
        self.assertIn("run: sh scripts/validate.sh", python_job)
        self.assertIn("persist-credentials: false", python_job)
        self.assertIn("uses: ./.github/workflows/macos-installer-validation.yml", native_job)
        self.assertIn("coverage_base_sha: ${{ github.event.pull_request.base.sha || github.event.before }}", native_job)
        self.assertNotIn("    if:", python_job + native_job)
        self.assertIn("  workflow_call:\n", native)
        self.assertIn("      coverage_base_sha:\n", native)
        self.assertIn("        required: true\n        type: string\n", native)
        self.assertIn("COVERAGE_BASE_SHA: ${{ inputs.coverage_base_sha }}", native)
        self.assertNotIn("  pull_request:", native, "Avoid a second independent native run")
        self.assertIn("runs-on: macos-26", native)
        self.assertIn("swift test --enable-code-coverage", native)
        self.assertIn('--minimum 80.2 --base-ref "$COVERAGE_BASE_SHA"', native)
        self.assertNotIn("continue-on-error", native)
        for text in (foundation, native):
            for forbidden in ("self-hosted", "secrets:", "environment:", "pull_request_target:"):
                self.assertNotIn(forbidden, text)
            self.assertIn("  contents: read\n", text)
        command = "python3 tests/foundation/test_required_ci_aggregation.py"
        self.assertIn(command, native)
        self.assertIn(command, (ROOT / "scripts/validate.sh").read_text(encoding="utf-8"))

    def test_actual_shell_accepts_only_success_success_across_the_result_matrix(self) -> None:
        script = actual_gate_script()
        states = ("success", "failure", "cancelled", "skipped", "neutral", "timed_out", "", "unknown")
        for repository, native in itertools.product(states, repeat=2):
            with self.subTest(repository=repository, native=native):
                result = subprocess.run(
                    ["/bin/bash", "-c", script], check=False, text=True, capture_output=True,
                    timeout=5, env={"REPOSITORY_RESULT": repository, "NATIVE_RESULT": native},
                )
                expected = repository == native == "success"
                self.assertEqual(result.returncode == 0, expected, result.stdout + result.stderr)
                self.assertEqual("FOUNDATION_GATE=PASS" in result.stdout, expected)

    def test_missing_dependency_result_never_grants_authority(self) -> None:
        for env in ({}, {"REPOSITORY_RESULT": "success"}, {"NATIVE_RESULT": "success"}):
            with self.subTest(env=env):
                result = subprocess.run(["/bin/bash", "-c", actual_gate_script()], env=env,
                                        check=False, text=True, capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("FOUNDATION_GATE=PASS", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
