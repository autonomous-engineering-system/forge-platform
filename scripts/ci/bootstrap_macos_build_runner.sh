#!/bin/bash
# Register the credentialless Mac mini build account with the organization.
set +x
set -euo pipefail
umask 077

RUNNER_VERSION="2.335.0"
RUNNER_SHA256="a1b382dda2cbb00a5e78fc21e7dbf4dbcf35edf44d6fd8686c8302e6f15cd065"
RUNNER_ARCHIVE="actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}"
ORGANIZATION_URL="${FORGE_PLATFORM_ORGANIZATION_URL:-https://github.com/autonomous-engineering-system}"
RUNNER_GROUP="${FORGE_PLATFORM_RUNNER_GROUP:-forge-platform-build}"
RUNNER_LABELS="forge-platform-build"
EXPECTED_USER="${FORGE_PLATFORM_EXPECTED_BUILD_USER:-}"
SIGNER_USER="${FORGE_PLATFORM_SIGNER_ACCOUNT:-}"
RUNNER_ROOT="${FORGE_PLATFORM_RUNNER_ROOT:-$HOME/actions-runner-forge-platform-build}"
RUNNER_NAME="${FORGE_PLATFORM_RUNNER_NAME:-forge-platform-macmini-build}"

fail() { echo "RUNNER_BOOTSTRAP=FAIL mode=credentialless-build reason=$1" >&2; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || fail host-not-arm64
os_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$os_major" =~ ^[0-9]+$ && "$os_major" -ge 26 ]] || fail macos-too-old
[[ -n "$EXPECTED_USER" ]] || fail expected-build-user-required
[[ "$(id -un)" == "$EXPECTED_USER" ]] || fail build-user-mismatch
[[ -n "$SIGNER_USER" ]] || fail signer-user-required
[[ "$(id -un)" != "$SIGNER_USER" ]] || fail build-and-signer-user-must-differ
[[ -n "${ACTIONS_RUNNER_TOKEN:-}" ]] || fail ACTIONS_RUNNER_TOKEN-required
[[ "$ORGANIZATION_URL" == "https://github.com/autonomous-engineering-system" ]] || fail organization-url-mismatch
[[ "$RUNNER_GROUP" == "forge-platform-build" ]] || fail runner-group-mismatch
[[ -z "${FORGE_PLATFORM_NOTARYTOOL_PROFILE:-}" ]] || fail notary-profile-must-not-enter-build-account
[[ -z "${FORGE_PLATFORM_CODESIGN_IDENTITY:-}" ]] || fail codesign-identity-must-not-enter-build-account
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq 'Developer ID Application:'; then
  fail developer-id-visible-in-build-account
fi

mkdir -p "$RUNNER_ROOT"
chmod 700 "$RUNNER_ROOT"
cd "$RUNNER_ROOT"

if [[ ! -x ./config.sh ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl --fail --silent --show-error --location "$RUNNER_URL" --output "$tmp/$RUNNER_ARCHIVE"
  actual="$(shasum -a 256 "$tmp/$RUNNER_ARCHIVE" | awk '{print $1}')"
  [[ "$actual" == "$RUNNER_SHA256" ]] || fail runner-digest-mismatch
  tar -xzf "$tmp/$RUNNER_ARCHIVE" -C "$RUNNER_ROOT"
fi

if [[ -f .runner ]]; then
  existing_name="$(python3 -c 'import json; print(json.load(open(".runner")).get("agentName", ""))')"
  [[ "$existing_name" == "$RUNNER_NAME" ]] || fail existing-runner-name-mismatch
  echo "RUNNER_BOOTSTRAP=EXISTING mode=credentialless-build root=$RUNNER_ROOT name=$RUNNER_NAME"
else
  ./config.sh     --unattended     --url "$ORGANIZATION_URL"     --token "$ACTIONS_RUNNER_TOKEN"     --runnergroup "$RUNNER_GROUP"     --name "$RUNNER_NAME"     --no-default-labels     --labels "$RUNNER_LABELS"     --work _work
fi

if ./svc.sh status >/dev/null 2>&1; then
  ./svc.sh stop >/dev/null 2>&1 || true
else
  ./svc.sh install >/dev/null
fi
./svc.sh start >/dev/null
./svc.sh status

echo "RUNNER_BOOTSTRAP=PASS mode=credentialless-build user=$(id -un) name=$RUNNER_NAME group=$RUNNER_GROUP labels=$RUNNER_LABELS version=$RUNNER_VERSION root=$RUNNER_ROOT"
echo "RUNNER_REBOOT_PERSISTENCE=NOT_VERIFIED action=reboot-and-run-live-verifier"
