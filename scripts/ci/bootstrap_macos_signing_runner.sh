#!/bin/bash
set -euo pipefail

RUNNER_VERSION="2.335.0"
RUNNER_SHA256="a1b382dda2cbb00a5e78fc21e7dbf4dbcf35edf44d6fd8686c8302e6f15cd065"
RUNNER_ARCHIVE="actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}"
REPOSITORY_URL="${FORGE_PLATFORM_REPOSITORY_URL:-https://github.com/pcvantol/forge-platform}"
ROLE="${FORGE_PLATFORM_RUNNER_ROLE:-}"
EXPECTED_USER="${FORGE_PLATFORM_EXPECTED_RUNNER_USER:-}"

case "$ROLE" in
  integration)
    DEFAULT_ROOT="$HOME/actions-runner-forge-platform-integration"
    DEFAULT_NAME="forge-platform-macmini-integration"
    RUNNER_LABELS="forge-platform-integration"
    ;;
  signer)
    DEFAULT_ROOT="$HOME/actions-runner-forge-platform-signer"
    DEFAULT_NAME="forge-platform-macmini-signer"
    RUNNER_LABELS="forge-platform-signer"
    ;;
  *)
    echo "RUNNER_BOOTSTRAP=FAIL reason=FORGE_PLATFORM_RUNNER_ROLE-must-be-integration-or-signer" >&2
    exit 1
    ;;
esac

RUNNER_ROOT="${FORGE_PLATFORM_RUNNER_ROOT:-$DEFAULT_ROOT}"
RUNNER_NAME="${FORGE_PLATFORM_RUNNER_NAME:-$DEFAULT_NAME}"

fail() { echo "RUNNER_BOOTSTRAP=FAIL role=$ROLE reason=$1" >&2; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || fail host-not-arm64
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]] || fail macos-too-old
[[ -n "$EXPECTED_USER" ]] || fail expected-runner-user-required
[[ "$(id -un)" == "$EXPECTED_USER" ]] || fail runner-user-mismatch
[[ -n "${ACTIONS_RUNNER_TOKEN:-}" ]] || fail ACTIONS_RUNNER_TOKEN-required

# A signer and an integration runner may share one Mac, but never one account,
# root, runner name or custom label. Keychain isolation comes from the separate
# macOS accounts; labels remain routing metadata, not a security boundary.
if [[ "$ROLE" == "signer" ]]; then
  [[ -n "${FORGE_PLATFORM_INTEGRATION_USER:-}" ]] || fail integration-user-required
  [[ "$(id -un)" != "$FORGE_PLATFORM_INTEGRATION_USER" ]] || fail signer-and-integration-user-must-differ
else
  [[ -n "${FORGE_PLATFORM_SIGNER_USER:-}" ]] || fail signer-user-required
  [[ "$(id -un)" != "$FORGE_PLATFORM_SIGNER_USER" ]] || fail integration-and-signer-user-must-differ
fi

umask 077
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
  existing_name="$(python3 - <<'PY'
import json
from pathlib import Path
try:
    value=json.loads(Path(".runner").read_text(encoding="utf-8"))
    print(value.get("agentName",""))
except Exception:
    print("")
PY
)"
  [[ "$existing_name" == "$RUNNER_NAME" ]] || fail existing-runner-name-mismatch
  echo "RUNNER_BOOTSTRAP=EXISTING role=$ROLE root=$RUNNER_ROOT name=$RUNNER_NAME"
else
  ./config.sh \
    --unattended \
    --url "$REPOSITORY_URL" \
    --token "$ACTIONS_RUNNER_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --work _work
fi

if ./svc.sh status >/dev/null 2>&1; then
  ./svc.sh stop >/dev/null 2>&1 || true
else
  ./svc.sh install >/dev/null
fi
./svc.sh start >/dev/null
./svc.sh status

echo "RUNNER_BOOTSTRAP=PASS role=$ROLE user=$(id -un) name=$RUNNER_NAME labels=$RUNNER_LABELS version=$RUNNER_VERSION root=$RUNNER_ROOT"
