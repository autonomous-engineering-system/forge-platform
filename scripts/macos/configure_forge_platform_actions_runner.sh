#!/bin/bash
set -euo pipefail

REPOSITORY="${FORGE_PLATFORM_RUNNER_REPOSITORY:-pcvantol/forge-platform}"
RUNNER_NAME="${FORGE_PLATFORM_RUNNER_NAME:-forge-platform-macmini}"
CUSTOM_LABEL="${FORGE_PLATFORM_RUNNER_LABEL:-forge-platform-macmini}"
RUNNER_ROOT="${FORGE_PLATFORM_RUNNER_ROOT:-$HOME/actions-runner-forge-platform}"
WORK_DIR="${FORGE_PLATFORM_RUNNER_WORKDIR:-_work}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$(id -u)" -ne 0 ]] || fail "configure the GitHub runner as the signing user, never root"
[[ "$(uname -m)" == "arm64" ]] || fail "Mac mini runner must be native arm64"
command -v gh >/dev/null 2>&1 || fail "GitHub CLI is required for one-time runner registration"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"

gh auth status --hostname github.com >/dev/null 2>&1   || fail "gh must already be authenticated to github.com as a repository administrator"

if [[ -e "$RUNNER_ROOT" && ! -d "$RUNNER_ROOT" ]]; then
  fail "runner root exists but is not a directory: $RUNNER_ROOT"
fi
mkdir -p "$RUNNER_ROOT"
chmod 700 "$RUNNER_ROOT"
cd "$RUNNER_ROOT"

if [[ -f .runner ]]; then
  printf 'Runner is already configured at %s\n' "$RUNNER_ROOT"
  ./svc.sh status || true
  exit 0
fi

tag="$(gh api repos/actions/runner/releases/latest --jq '.tag_name')"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "unexpected GitHub Actions runner release tag"
version="${tag#v}"
asset="actions-runner-osx-arm64-${version}.tar.gz"
asset_url="$(gh api repos/actions/runner/releases/latest --jq ".assets[] | select(.name == \"$asset\") | .browser_download_url")"
asset_digest="$(gh api repos/actions/runner/releases/latest --jq ".assets[] | select(.name == \"$asset\") | .digest")"
[[ "$asset_url" == "https://github.com/actions/runner/releases/download/$tag/$asset" ]]   || fail "runner release asset URL is not canonical"
[[ "$asset_digest" =~ ^sha256:[0-9a-f]{64}$ ]]   || fail "runner release asset has no canonical GitHub SHA-256 digest"

tmp="$(mktemp -d "$RUNNER_ROOT/.bootstrap.XXXXXX")"
registration_token=""
cleanup() {
  registration_token=""
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

curl --fail --location --proto '=https' --tlsv1.2   "$asset_url" -o "$tmp/$asset"
actual="sha256:$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
[[ "$actual" == "$asset_digest" ]] || fail "GitHub Actions runner package digest mismatch"

tar -xzf "$tmp/$asset" -C "$RUNNER_ROOT"
[[ -x ./config.sh && -x ./svc.sh ]] || fail "runner package is incomplete"

registration_token="$(gh api --method POST "repos/$REPOSITORY/actions/runners/registration-token" --jq '.token')"
[[ -n "$registration_token" ]] || fail "GitHub did not issue a runner registration token"

./config.sh   --unattended   --replace   --url "https://github.com/$REPOSITORY"   --token "$registration_token"   --name "$RUNNER_NAME"   --labels "$CUSTOM_LABEL"   --work "$WORK_DIR"

registration_token=""

./svc.sh install
./svc.sh start
./svc.sh status

printf '\nConfigured repository runner:\n'
printf '  repository: %s\n' "$REPOSITORY"
printf '  name:       %s\n' "$RUNNER_NAME"
printf '  label:      %s\n' "$CUSTOM_LABEL"
printf '  root:       %s\n' "$RUNNER_ROOT"
printf '  service:    %s\n' "$(cat .service 2>/dev/null || printf unknown)"
printf '\nNo registration token or signing secret was persisted by this script.\n'
