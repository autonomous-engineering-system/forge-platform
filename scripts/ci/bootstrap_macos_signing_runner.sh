#!/bin/bash
set -euo pipefail

RUNNER_VERSION="2.335.0"
RUNNER_SHA256="a1b382dda2cbb00a5e78fc21e7dbf4dbcf35edf44d6fd8686c8302e6f15cd065"
RUNNER_ARCHIVE="actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}"
REPOSITORY_URL="${FORGE_PLATFORM_REPOSITORY_URL:-https://github.com/pcvantol/forge-platform}"
RUNNER_ROOT="${FORGE_PLATFORM_RUNNER_ROOT:-$HOME/actions-runner-forge-platform}"
RUNNER_NAME="${FORGE_PLATFORM_RUNNER_NAME:-forge-platform-macmini}"
RUNNER_LABELS="forge-platform-mini,forge-platform-signer"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "RUNNER_BOOTSTRAP=FAIL reason=host-not-arm64" >&2
  exit 1
fi
if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]]; then
  echo "RUNNER_BOOTSTRAP=FAIL reason=macos-too-old" >&2
  exit 1
fi
if [[ -z "${ACTIONS_RUNNER_TOKEN:-}" ]]; then
  echo "RUNNER_BOOTSTRAP=FAIL reason=ACTIONS_RUNNER_TOKEN-required" >&2
  exit 1
fi

umask 077
mkdir -p "$RUNNER_ROOT"
cd "$RUNNER_ROOT"

if [[ ! -x ./config.sh ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl --fail --silent --show-error --location "$RUNNER_URL" --output "$tmp/$RUNNER_ARCHIVE"
  actual="$(shasum -a 256 "$tmp/$RUNNER_ARCHIVE" | awk '{print $1}')"
  if [[ "$actual" != "$RUNNER_SHA256" ]]; then
    echo "RUNNER_BOOTSTRAP=FAIL reason=runner-digest-mismatch" >&2
    exit 1
  fi
  tar -xzf "$tmp/$RUNNER_ARCHIVE" -C "$RUNNER_ROOT"
fi

if [[ -f .runner ]]; then
  echo "RUNNER_BOOTSTRAP=EXISTING root=$RUNNER_ROOT"
else
  ./config.sh     --unattended     --url "$REPOSITORY_URL"     --token "$ACTIONS_RUNNER_TOKEN"     --name "$RUNNER_NAME"     --labels "$RUNNER_LABELS"     --work _work
fi

if ./svc.sh status >/dev/null 2>&1; then
  ./svc.sh stop >/dev/null 2>&1 || true
else
  ./svc.sh install >/dev/null
fi
./svc.sh start >/dev/null
./svc.sh status
echo "RUNNER_BOOTSTRAP=PASS name=$RUNNER_NAME labels=$RUNNER_LABELS version=$RUNNER_VERSION"
