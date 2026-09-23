#!/bin/bash
set +x
set -euo pipefail
echo 'RUNNER_BOOTSTRAP=FAIL reason=credential-bearing-actions-runner-prohibited use=scripts/ci/bootstrap_macos_build_runner.sh' >&2
exit 1
