#!/bin/bash
# Credential-bearing signing is intentionally forbidden on a repository-scoped
# self-hosted Actions runner while pcvantol/forge-platform is public under a
# personal account. Labels and workflow YAML are routing metadata, not an ACL.
set -euo pipefail
set +x
echo 'MAC_SIGNING_READINESS=FAIL reason=github-actions-signer-disabled-public-repository' >&2
echo 'Use scripts/ci/verify_macos_offline_signing_host.sh from the dedicated local signer account.' >&2
exit 1
