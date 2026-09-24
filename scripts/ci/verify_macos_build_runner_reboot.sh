#!/bin/bash
# Record and verify that the credentialless runner service survives a real reboot.
set +x
set -euo pipefail
umask 077

fail() { echo "BUILD_RUNNER_REBOOT_PERSISTENCE=FAIL reason=$1" >&2; exit 1; }
[[ "$#" == 1 && ("$1" == "record" || "$1" == "verify") ]] || fail usage-record-or-verify
[[ -n "${FORGE_PLATFORM_EXPECTED_BUILD_USER:-}" ]] || fail expected-build-user-required
[[ "$(id -un)" == "$FORGE_PLATFORM_EXPECTED_BUILD_USER" ]] || fail build-user-mismatch
ROOT="${FORGE_PLATFORM_RUNNER_ROOT:-$HOME/actions-runner-forge-platform-build}"
STATE="${FORGE_PLATFORM_RUNNER_REBOOT_STATE:-$HOME/.forge-platform-build-runner/reboot-baseline.json}"
[[ -x "$ROOT/svc.sh" && -f "$ROOT/.runner" ]] || fail runner-installation-unavailable
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq 'Developer ID Application:'; then
  fail developer-id-visible-in-build-account
fi
boot="$(sysctl -n kern.boottime)"
name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("agentName",""))' "$ROOT/.runner")"
[[ "$name" == "${FORGE_PLATFORM_RUNNER_NAME:-forge-platform-macmini-build}" ]] || fail runner-name-mismatch

if [[ "$1" == "record" ]]; then
  mkdir -p "$(dirname "$STATE")"
  chmod 700 "$(dirname "$STATE")"
  python3 - "$STATE" "$boot" "$name" <<'PY'
import json
from pathlib import Path
import os
import sys
path=Path(sys.argv[1])
payload={"boot":sys.argv[2],"runner_name":sys.argv[3],"uid":os.getuid()}
path.write_text(json.dumps(payload,sort_keys=True,separators=(",",":"))+"\n",encoding="utf-8")
path.chmod(0o600)
PY
  echo "BUILD_RUNNER_REBOOT_BASELINE=RECORDED runner=$name"
  exit 0
fi

[[ -f "$STATE" && ! -L "$STATE" ]] || fail reboot-baseline-missing
before="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["boot"])' "$STATE")"
[[ "$before" != "$boot" ]] || fail host-has-not-rebooted
"$ROOT/svc.sh" status >/dev/null 2>&1 || fail runner-service-not-running-after-reboot
echo "BUILD_RUNNER_REBOOT_PERSISTENCE=PASS runner=$name user=$(id -un)"
