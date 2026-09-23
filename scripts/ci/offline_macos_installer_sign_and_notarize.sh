#!/bin/bash
# Offline Developer ID + notarization qualification for one exact protected-main
# Forge Platform Installer source. This command is intentionally NOT a publisher.
set +x
set -euo pipefail
umask 077

fail() {
  echo "OFFLINE_INSTALLER_SIGNING=FAIL reason=$1" >&2
  exit 1
}

[[ "${GITHUB_ACTIONS:-}" != "true" ]] || fail github-actions-forbidden
[[ -z "${RUNNER_NAME:-}" ]] || fail actions-runner-context-forbidden
[[ "$(uname -m)" == "arm64" ]] || fail host-not-arm64
[[ -n "${SOURCE_SHA:-}" && "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail exact-source-sha-required
[[ -n "${FORGE_PLATFORM_SIGNER_ACCOUNT:-}" ]] || fail signer-account-required
[[ "$(id -un)" == "$FORGE_PLATFORM_SIGNER_ACCOUNT" ]] || fail signer-account-mismatch
[[ -n "${FORGE_PLATFORM_APPLE_TEAM_ID:-}" ]] || fail team-id-required
[[ -n "${FORGE_PLATFORM_CODESIGN_IDENTITY:-}" ]] || fail codesign-identity-required
[[ -n "${FORGE_PLATFORM_NOTARYTOOL_PROFILE:-}" ]] || fail notary-profile-required
[[ -n "${FORGE_PLATFORM_RELEASE_TRUST_RESOURCE:-}" ]] || fail release-trust-resource-required
[[ -n "${FORGE_PLATFORM_COMPOSITION_CATALOG_TRUST_RESOURCE:-}" ]] || fail catalog-trust-resource-required
[[ -n "${FORGE_PLATFORM_OFFLINE_RELEASE_ROOT:-}" ]] || fail offline-release-root-required
[[ -n "${RELEASE_SEQUENCE:-}" && "$RELEASE_SEQUENCE" =~ ^[1-9][0-9]*$ ]] || fail release-sequence-required

root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail git-root-unavailable
cd "$root"
[[ "$(git rev-parse HEAD)" == "$SOURCE_SHA" ]] || fail source-head-mismatch
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail dirty-worktree
git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main >/dev/null 2>&1 || fail origin-main-fetch-failed
[[ "$(git rev-parse origin/main)" == "$SOURCE_SHA" ]] || fail source-not-current-protected-main

python3 scripts/validate_installer_version.py >/dev/null || fail installer-version-invalid
python3 scripts/validate_installer_release_identity.py --require-ready >/dev/null || fail release-identity-not-ready
python3 scripts/advance_installer_version.py \
  --verify-operation --require-operation --require-version-advance \
  --candidate-head "$SOURCE_SHA" >/dev/null || fail installer-version-operation-invalid
bash scripts/ci/verify_macos_offline_signing_host.sh >/dev/null || fail offline-signing-host-not-ready

release_root="$FORGE_PLATFORM_OFFLINE_RELEASE_ROOT"
[[ "$release_root" == /* && "$release_root" != "/" ]] || fail release-root-not-absolute
if [[ ! -e "$release_root" ]]; then
  mkdir -m 700 -p "$release_root" || fail release-root-create-failed
fi
[[ ! -L "$release_root" && -d "$release_root" ]] || fail release-root-invalid
mode="$(stat -f '%Lp' "$release_root" 2>/dev/null)" || fail release-root-stat-failed
owner="$(stat -f '%Su' "$release_root" 2>/dev/null)" || fail release-root-stat-failed
[[ "$mode" == "700" && "$owner" == "$(id -un)" ]] || fail release-root-not-private

installer_version="$(python3 - <<'PY'
import json
from pathlib import Path
value=json.loads(Path("installer-version.json").read_text(encoding="utf-8"))
print(value["version"])
PY
)"
[[ "$installer_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail installer-version-invalid
operation="installer-${installer_version}-${SOURCE_SHA}"
work="$release_root/$operation"
[[ ! -e "$work" ]] || fail operation-root-already-exists
mkdir -m 700 "$work"
private="$work/private"
mkdir -m 700 "$private"
cleanup() {
  rm -rf "$private"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Full source validation runs before any signing or notarization authority is used.
sh scripts/validate.sh >"$private/repository-validation.log" 2>&1 || fail repository-validation-failed
(
  cd macos/ForgePlatformInstaller
  swift test >"$private/swift-tests.log" 2>&1
  swift build -c release --product ForgePlatformInstaller >"$private/swift-build-gui.log" 2>&1
  swift build -c release --product forge-platform-installer >"$private/swift-build-cli.log" 2>&1
) || fail native-build-or-tests-failed

bin_dir="$(cd macos/ForgePlatformInstaller && swift build -c release --show-bin-path)"
gui="$bin_dir/ForgePlatformInstaller"
cli="$bin_dir/forge-platform-installer"
[[ -x "$gui" && -x "$cli" ]] || fail release-binaries-missing
file "$gui" | grep -Fq 'arm64' || fail gui-not-arm64
file "$cli" | grep -Fq 'arm64' || fail cli-not-arm64

provenance="$private/ForgePlatformInstallerReleaseProvenance.json"
python3 scripts/prepare_offline_installer_resources.py \
  --release-trust-resource "$FORGE_PLATFORM_RELEASE_TRUST_RESOURCE" \
  --catalog-trust-resource "$FORGE_PLATFORM_COMPOSITION_CATALOG_TRUST_RESOURCE" \
  --source-sha "$SOURCE_SHA" \
  --release-sequence "$RELEASE_SEQUENCE" \
  --output "$provenance" >"$private/provenance.log" 2>&1 \
  || fail provenance-preparation-failed

app="$work/ForgePlatformInstaller.app"
python3 scripts/package_macos_installer_app.py \
  --executable "$gui" \
  --cli-executable "$cli" \
  --sealed-release-trust-resource "$FORGE_PLATFORM_RELEASE_TRUST_RESOURCE" \
  --sealed-release-provenance-resource "$provenance" \
  --sealed-composition-catalog-trust-resource "$FORGE_PLATFORM_COMPOSITION_CATALOG_TRUST_RESOURCE" \
  --output "$app" \
  --bundle-identifier "$(python3 scripts/validate_installer_release_identity.py --field bundle_identifier)" \
  >"$private/package-app.log" 2>&1 || fail final-app-packaging-failed

# Resolve exactly one reviewed Developer ID identity from public certificate metadata.
security find-identity -v -p codesigning >"$private/identities.txt" 2>"$private/identity-error.txt" || fail identity-read-failed
identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"([^"]+)"[[:space:]]*$'
selected_hash=""
selected_name=""
matches=0
while IFS= read -r line; do
  if [[ "$line" =~ $identity_pattern ]]; then
    fingerprint="${BASH_REMATCH[1]}"
    label="${BASH_REMATCH[2]}"
    normalized="$(printf '%s' "$FORGE_PLATFORM_CODESIGN_IDENTITY" | tr '[:lower:]' '[:upper:]')"
    if [[ "$label" == "$FORGE_PLATFORM_CODESIGN_IDENTITY" || "$fingerprint" == "$normalized" ]]; then
      matches=$((matches + 1))
      selected_hash="$fingerprint"
      selected_name="$label"
    fi
  fi
done <"$private/identities.txt"
[[ "$matches" == 1 ]] || fail selected-identity-missing-or-ambiguous
[[ "$selected_name" == "Developer ID Application: "*"($FORGE_PLATFORM_APPLE_TEAM_ID)" ]] || fail selected-identity-team-mismatch

bounded() {
  local log="$1"; shift
  python3 - "$log" "$@" <<'PY'
import subprocess
import sys
with open(sys.argv[1], "wb") as output:
    try:
        completed=subprocess.run(
            sys.argv[2:],
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=output,
            timeout=1800,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise SystemExit(1)
raise SystemExit(0 if completed.returncode == 0 else 1)
PY
}

# Sign every executable code object explicitly, then seal the app bundle.
bounded "$private/codesign-cli.log" codesign --force --options runtime --timestamp --sign "$selected_hash" "$app/Contents/MacOS/forge-platform-installer" || fail cli-signing-failed
bounded "$private/codesign-gui.log" codesign --force --options runtime --timestamp --sign "$selected_hash" "$app/Contents/MacOS/ForgePlatformInstaller" || fail gui-signing-failed
bounded "$private/codesign-app.log" codesign --force --options runtime --timestamp --sign "$selected_hash" "$app" || fail app-signing-failed
bounded "$private/codesign-verify.log" codesign --verify --strict --deep "$app" || fail signed-app-verification-failed
requirement="anchor apple generic and certificate leaf[subject.OU] = \"$FORGE_PLATFORM_APPLE_TEAM_ID\" and identifier \"$(python3 scripts/validate_installer_release_identity.py --field bundle_identifier)\""
bounded "$private/codesign-requirement.log" codesign --verify --strict -R "$requirement" "$app" || fail signed-app-identity-failed

submission="$private/notary-submission.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$submission" || fail notary-submission-packaging-failed
python3 - "$private/notary.json" "$private/notary-error.log" \
  xcrun notarytool submit "$submission" \
  --keychain-profile "$FORGE_PLATFORM_NOTARYTOOL_PROFILE" \
  --wait --output-format json <<'PY' || fail notarization-submit-failed
import subprocess
import sys
stdout_path, stderr_path, *command = sys.argv[1:]
with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
    try:
        completed=subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            timeout=3600,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise SystemExit(1)
raise SystemExit(0 if completed.returncode == 0 else 1)
PY

notary_id="$(python3 - "$private/notary.json" <<'PY'
import json, re, sys
try:
    value=json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
identifier=value.get("id")
if value.get("status") != "Accepted" or not isinstance(identifier, str) or re.fullmatch(r"[0-9A-Fa-f-]{36}", identifier) is None:
    raise SystemExit(1)
print(identifier)
PY
)" || fail notarization-not-accepted

bounded "$private/staple.log" xcrun stapler staple "$app" || fail stapling-failed
bounded "$private/staple-validate.log" xcrun stapler validate -v "$app" || fail stapled-ticket-validation-failed
bounded "$private/gatekeeper.log" spctl --assess --type execute --verbose=4 "$app" || fail gatekeeper-rejected-stapled-app

asset_prefix="$(python3 scripts/validate_installer_release_identity.py --field asset_prefix)"
archive="$work/${asset_prefix}arm64.zip"
python3 scripts/package_macos_installer_archive.py \
  --app-bundle "$app" --output "$archive" >"$private/package-final-archive.log" 2>&1 \
  || fail final-archive-packaging-failed

# Critical carrier proof: the exact publishable strict ZIP must preserve enough
# notarization evidence that a newly extracted copy is still stapled and accepted.
carrier="$private/carrier-readback"
mkdir -m 700 "$carrier"
/usr/bin/ditto -x -k "$archive" "$carrier" || fail final-archive-extraction-failed
extracted_app=""
extracted_count=0
while IFS= read -r candidate; do
  extracted_count=$((extracted_count + 1))
  extracted_app="$candidate"
done < <(find "$carrier" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print)
[[ "$extracted_count" == 1 && -n "$extracted_app" ]] || fail final-archive-app-layout-invalid
bounded "$private/carrier-staple-validate.log" xcrun stapler validate -v "$extracted_app" || fail final-archive-lost-stapled-ticket
bounded "$private/carrier-gatekeeper.log" spctl --assess --type execute --verbose=4 "$extracted_app" || fail final-archive-gatekeeper-rejected

codesign -d --verbose=4 "$app" >"$private/codesign-display.txt" 2>&1 || fail codedirectory-readback-failed
code_directory="$(python3 - "$private/codesign-display.txt" <<'PY'
import re, sys
text=open(sys.argv[1], encoding="utf-8", errors="strict").read()
matches=re.findall(r"^CandidateCDHashFull sha256=([0-9a-f]{64})$", text, flags=re.MULTILINE)
if len(matches) != 1:
    raise SystemExit(1)
print(matches[0])
PY
)" || fail codedirectory-readback-invalid
archive_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$archive_sha" =~ ^[0-9a-f]{64}$ ]] || fail archive-digest-invalid

evidence="$work/offline-signing-evidence.json"
SOURCE_SHA="$SOURCE_SHA" INSTALLER_VERSION="$installer_version" ARCHIVE_NAME="$(basename "$archive")" \
ARCHIVE_SHA256="$archive_sha" CODE_DIRECTORY_SHA256="$code_directory" NOTARY_ID="$notary_id" \
TEAM_ID="$FORGE_PLATFORM_APPLE_TEAM_ID" \
BUNDLE_ID="$(python3 scripts/validate_installer_release_identity.py --field bundle_identifier)" \
python3 - "$evidence" <<'PY'
import json, os, sys
from pathlib import Path
value={
    "schema":"forge-platform.offline-installer-signing-evidence/v1",
    "source_revision":os.environ["SOURCE_SHA"],
    "installer_version":os.environ["INSTALLER_VERSION"],
    "architecture":"arm64",
    "archive_name":os.environ["ARCHIVE_NAME"],
    "archive_digest":"sha256:"+os.environ["ARCHIVE_SHA256"],
    "bundle_identifier":os.environ["BUNDLE_ID"],
    "team_identifier":os.environ["TEAM_ID"],
    "code_directory_sha256":os.environ["CODE_DIRECTORY_SHA256"],
    "notary_submission_id":os.environ["NOTARY_ID"],
    "stapled_app_validation":"PASS",
    "strict_archive_carrier_validation":"PASS",
    "publication":"NOT_PERFORMED",
}
path=Path(sys.argv[1])
path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False)+"\n", encoding="utf-8")
path.chmod(0o600)
PY

rm -rf "$private"
trap - EXIT INT TERM
echo "OFFLINE_INSTALLER_SIGNING=PASS source=$SOURCE_SHA version=$installer_version archive=$(basename "$archive")"
echo "STRICT_ARCHIVE_STAPLE_CARRIER=PASS"
echo "INSTALLER_PUBLICATION=NOT_PERFORMED evidence=$evidence"
