#!/bin/bash
set +x
set -euo pipefail
echo 'MAC_SIGNING_READINESS=FAIL reason=actions-signer-prohibited use=scripts/ci/verify_macos_offline_signing_host.sh' >&2
exit 1
