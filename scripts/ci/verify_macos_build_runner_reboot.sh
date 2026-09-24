#!/bin/bash
# Record and verify that the credentialless runner service survives a real reboot.
set +x
set -euo pipefail
umask 077

fail() { echo "BUILD_RUNNER_REBOOT_PERSISTENCE=FAIL reason=$1" >&2; exit 1; }
[[ "$#" == 1 && ("$1" == "record" || "$1" == "verify") ]] || fail usage-record-or-verify
[[ "$(id -u)" == "0" ]] || fail root-required
[[ -n "${FORGE_PLATFORM_EXPECTED_BUILD_USER:-}" ]] || fail expected-build-user-required
BUILD_USER="$FORGE_PLATFORM_EXPECTED_BUILD_USER"
BUILD_UID="$(id -u "$BUILD_USER" 2>/dev/null)" || fail build-user-missing
BUILD_HOME="$(dscacheutil -q user -a name "$BUILD_USER" | awk -F': ' '/^dir: / {print $2; exit}')"
[[ "$BUILD_HOME" == "/Users/$BUILD_USER" ]] || fail build-user-home-mismatch
ROOT="${FORGE_PLATFORM_RUNNER_ROOT:-$BUILD_HOME/actions-runner-forge-platform-build}"
STATE="${FORGE_PLATFORM_RUNNER_REBOOT_STATE:-/var/db/forge-platform-build-runner/reboot-baseline.json}"
SERVICE_LABEL="org.autonomous-engineering-system.forge-platform.build-runner"
[[ -x "$ROOT/runsvc.sh" && -f "$ROOT/.runner" ]] || fail runner-installation-unavailable
if sudo -H -u "$BUILD_USER" security find-identity -v -p codesigning 2>/dev/null | grep -Fq 'Developer ID Application:'; then
  fail developer-id-visible-in-build-account
fi
if dseditgroup -o checkmember -m "$BUILD_USER" admin 2>/dev/null | grep -Fq 'yes'; then
  fail build-user-must-not-be-admin
fi
auto_login="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
[[ -z "$auto_login" && ! -e /etc/kcpassword ]] || fail automatic-login-must-be-disabled
launchctl print "system/$SERVICE_LABEL" 2>/dev/null | grep -Eq 'state = (running|waiting)' || fail runner-launchdaemon-not-active
pgrep -u "$BUILD_UID" -f "$ROOT/bin/Runner.Listener" >/dev/null 2>&1 || fail runner-listener-not-owned-by-build-user
boot="$(sysctl -n kern.boottime)"
name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8-sig")).get("agentName",""))' "$ROOT/.runner")"
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
  echo "BUILD_RUNNER_REBOOT_BASELINE=RECORDED runner=$name user=$BUILD_USER service=$SERVICE_LABEL"
  exit 0
fi

[[ -f "$STATE" && ! -L "$STATE" ]] || fail reboot-baseline-missing
before="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["boot"])' "$STATE")"
[[ "$before" != "$boot" ]] || fail host-has-not-rebooted
launchctl print "system/$SERVICE_LABEL" 2>/dev/null | grep -Eq 'state = (running|waiting)' || fail runner-service-not-running-after-reboot
pgrep -u "$BUILD_UID" -f "$ROOT/bin/Runner.Listener" >/dev/null 2>&1 || fail runner-listener-not-running-after-reboot
echo "BUILD_RUNNER_REBOOT_PERSISTENCE=PASS runner=$name user=$BUILD_USER service=$SERVICE_LABEL automatic_login=disabled"
