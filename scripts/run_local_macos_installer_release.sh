#!/bin/bash
# Execute the Apple signing/notarization/publication chain from the dedicated
# local signer account. This script must never run as a GitHub Actions runner.
set +x
set -euo pipefail
umask 077

REPOSITORY="autonomous-engineering-system/forge-platform"
fail() { echo "LOCAL_INSTALLER_RELEASE=FAIL reason=$1" >&2; exit 1; }
[[ "$#" == 2 ]] || fail usage-run-id-source-sha
RUN_ID="$1"
SOURCE_SHA="$2"
[[ "$RUN_ID" =~ ^[1-9][0-9]*$ ]] || fail invalid-run-id
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail invalid-source-sha
[[ -n "${FORGE_PLATFORM_COMPOSITION_CATALOG_URL:-}" ]] || fail composition-catalog-url-required
[[ -z "${GITHUB_ACTIONS:-}" && -z "${RUNNER_NAME:-}" ]] || fail actions-context-prohibited

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
test -z "$(git status --porcelain)" || fail signer-checkout-not-clean
test "$(git rev-parse HEAD)" = "$SOURCE_SHA" || fail signer-checkout-source-mismatch
git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
test "$(git rev-parse origin/main)" = "$SOURCE_SHA" || fail source-is-not-exact-current-main
python3 scripts/validate_installer_release_identity.py --require-ready >/dev/null ||
  fail installer-release-identity-not-ready
bash scripts/ci/verify_macos_offline_signing_host.sh

STATE_ROOT="${FORGE_PLATFORM_SIGNER_STATE_ROOT:-$HOME/Library/Application Support/ForgePlatformSigner}"
mkdir -p "$STATE_ROOT/locks" "$STATE_ROOT/journal" "$STATE_ROOT/receipts"
chmod 700 "$STATE_ROOT" "$STATE_ROOT/locks" "$STATE_ROOT/journal" "$STATE_ROOT/receipts"
LOCK="$STATE_ROOT/locks/exclusive-offline-signing"
mkdir "$LOCK" 2>/dev/null || fail signing-concurrency-lock-held
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/forge-platform-local-release.XXXXXX")" && pwd -P)"
cleanup() {
  rm -rf "$WORK"
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v gh >/dev/null || fail gh-cli-unavailable
gh auth status --hostname github.com >/dev/null 2>&1 || fail github-auth-unavailable
mkdir -p "$WORK/metadata" "$WORK/authorization" "$WORK/candidate" "$WORK/release" "$WORK/readback"

gh run view "$RUN_ID" --repo "$REPOSITORY"   --json databaseId,headBranch,headSha,event,conclusion,workflowName,jobs,url,createdAt   >"$WORK/metadata/run.json"
# The authorization artifact itself carries the authoritative run attempt. Try
# only the GitHub run's current attempt as exposed by the API.
RUN_ATTEMPT="$(gh api "repos/$REPOSITORY/actions/runs/$RUN_ID" --jq .run_attempt)"
[[ "$RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] || fail invalid-run-attempt
AUTH_ARTIFACT="forge-platform-installer-signing-authorization-$RUN_ID-$RUN_ATTEMPT"
gh run download "$RUN_ID" --repo "$REPOSITORY" --name "$AUTH_ARTIFACT" --dir "$WORK/authorization"
AUTHORIZATION="$WORK/authorization/authorization.json"
test -f "$AUTHORIZATION" || fail authorization-artifact-missing
CANDIDATE_ARTIFACT="$(python3 -c 'import json,re,sys; v=json.load(open(sys.argv[1]))["candidate_artifact"]; print(v) if re.fullmatch(r"forge-platform-installer-candidate-[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{40}",v) else sys.exit(1)' "$AUTHORIZATION")" ||
  fail unsafe-candidate-artifact-name
gh run download "$RUN_ID" --repo "$REPOSITORY" --name "$CANDIDATE_ARTIFACT" --dir "$WORK/candidate"
python3 scripts/verify_local_signing_authorization.py   --authorization "$AUTHORIZATION"   --run-metadata "$WORK/metadata/run.json"   --candidate-directory "$WORK/candidate"   --source-sha "$SOURCE_SHA"   --run-id "$RUN_ID"   --repository "$REPOSITORY"

ARCHIVE_NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive_name"])' "$AUTHORIZATION")"
OPERATION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["operation_id"])' "$AUTHORIZATION")"
INSTALLER_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["installer_version"])' "$AUTHORIZATION")"
RELEASE_TAG="$(python3 - "$INSTALLER_VERSION" <<'PY'
import sys
from scripts.validate_installer_release_identity import load_identity
identity = load_identity(require_ready=True)
assert identity is not None
print(identity.release_tag(sys.argv[1]))
PY
)"
DESCRIPTOR_NAME="$(python3 scripts/validate_installer_release_identity.py --field release_descriptor_asset_name)"
BUNDLE_IDENTIFIER="$(python3 scripts/validate_installer_release_identity.py --field bundle_identifier)"
TEAM_IDENTIFIER="$(python3 scripts/validate_installer_release_identity.py --field team_identifier)"

mkdir "$WORK/app"
ditto -x -k "$WORK/candidate/$ARCHIVE_NAME" "$WORK/app"
APP="$WORK/app/ForgePlatformInstaller.app"
test -d "$APP" || fail unsigned-app-missing
python3 - "$APP" <<'PY' || fail unsigned-forge-update-resources-invalid
from pathlib import Path
import sys
from forge_platform.forge_update_resources import read_forge_239_update_resources, read_forge_update_resources

app = Path(sys.argv[1])
worker = app / "Contents/Resources/forge-platform-product-worker.pyz"
read_forge_update_resources(worker)
read_forge_239_update_resources(worker)
PY
test -x "$APP/Contents/MacOS/ForgePlatformInstaller" || fail unsigned-binary-missing
test -x "$APP/Contents/MacOS/forge-platform-installer" || fail unsigned-binary-missing
HELPER="$APP/Contents/Resources/forge-platform-installer-helper"
test -x "$HELPER" || fail unsigned-helper-missing
test -f "$APP/Contents/Resources/forge-platform-product-worker.pyz" ||
  fail unsigned-product-worker-missing
test -f "$APP/Contents/Library/LaunchDaemons/com.autonomous-engineering-system.forge-platform-installer.helper.plist" ||
  fail unsigned-helper-plist-missing
# Preserve V1 candidates; a candidate carrying the release-bound bootstrap
# must publish its signed companion and independently prove every readback.
HELPER_PACKAGE_NAME="forge-platform-installer-helper-arm64.pkg"
HELPER_DESCRIPTOR_NAME="ForgePlatformInstallerHelperDescriptor.json"
BOOTSTRAP_LABEL="com.autonomous-engineering-system.forge-platform-installer.bootstrap"
BOOTSTRAP="$APP/Contents/Library/LaunchServices/$BOOTSTRAP_LABEL"
QUALIFIER_PACKAGE_ARGS=()
STRUCTURE_PACKAGE_ARGS=()
PUBLICATION_PACKAGE_ARGS=()
PACKAGE_UPLOAD_ASSETS=()
PACKAGE_DOWNLOAD_ARGS=()
HAS_BOOTSTRAP=false
if [[ -e "$BOOTSTRAP" || -L "$BOOTSTRAP" ]]; then
  test -f "$BOOTSTRAP" && test ! -L "$BOOTSTRAP" && test -x "$BOOTSTRAP" || fail unsigned-bootstrap-invalid
  HAS_BOOTSTRAP=true
  source scripts/ci/macos_installer_helper_package_signing.sh
  INSTALLER_SIGNING_HASH="$(select_helper_package_identity "$WORK/metadata" "$TEAM_IDENTIFIER")" || fail installer-signing-identity-not-ready
  BOOTSTRAP_REQUIREMENT="anchor apple generic and identifier \"$BOOTSTRAP_LABEL\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\""
  codesign --force --options runtime --timestamp --identifier "$BOOTSTRAP_LABEL" --sign "$FORGE_PLATFORM_CODESIGN_IDENTITY" "$BOOTSTRAP"
  codesign --verify --strict "-R=$BOOTSTRAP_REQUIREMENT" "$BOOTSTRAP" || fail signed-bootstrap-identity-invalid
fi

codesign --force --options runtime --timestamp \
  --identifier "com.autonomous-engineering-system.forge-platform-installer.helper" \
  --sign "$FORGE_PLATFORM_CODESIGN_IDENTITY" "$HELPER"
# Sign nested code before sealing its containing app. Signing a sibling after
# the GUI can invalidate the GUI's nested-code verification on macOS.
# The helper admits the exact sealed app identifier, so bind the CLI to it.
codesign --force --options runtime --timestamp --identifier "$BUNDLE_IDENTIFIER" \
  --sign "$FORGE_PLATFORM_CODESIGN_IDENTITY" "$APP/Contents/MacOS/forge-platform-installer"
codesign --force --options runtime --timestamp \
  --sign "$FORGE_PLATFORM_CODESIGN_IDENTITY" "$APP/Contents/MacOS/ForgePlatformInstaller"
codesign --force --options runtime --timestamp \
  --sign "$FORGE_PLATFORM_CODESIGN_IDENTITY" "$APP"
HELPER_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and identifier \"com.autonomous-engineering-system.forge-platform-installer.helper\""
codesign --verify --strict "-R=$HELPER_REQUIREMENT" "$HELPER" || fail signed-helper-identity-invalid
CALLER_REQUIREMENT="anchor apple generic and identifier \"$BUNDLE_IDENTIFIER\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\""
codesign --verify --strict "-R=$CALLER_REQUIREMENT" "$APP/Contents/MacOS/ForgePlatformInstaller" || fail signed-gui-caller-identity-invalid
codesign --verify --strict "-R=$CALLER_REQUIREMENT" "$APP/Contents/MacOS/forge-platform-installer" || fail signed-cli-caller-identity-invalid
# codesign inherits the offline signer's restrictive umask for CodeResources.
# The published app may later be installed root-owned; both sealed signature
# manifests must remain readable to an ordinary user in that layout.
for code_resource in "$APP/Contents/_CodeSignature/CodeResources" "$APP/Contents/CodeResources"; do
  # Current macOS codesign emits only _CodeSignature/CodeResources. Older
  # bundles can also carry the legacy top-level copy; qualify it when present.
  if [[ "$code_resource" == "$APP/Contents/CodeResources" && ! -e "$code_resource" && ! -L "$code_resource" ]]; then
    continue
  fi
  test -f "$code_resource" && test ! -L "$code_resource" || fail signed-code-resource-invalid
  chmod 644 "$code_resource"
  test "$(stat -f %Lp "$code_resource")" = 644 || fail signed-code-resource-mode-invalid
done
codesign --verify --strict --deep "$APP"
codesign --display --verbose=6 "$APP" >"$WORK/metadata/codesign.txt" 2>&1
grep -Fxq "Identifier=$BUNDLE_IDENTIFIER" "$WORK/metadata/codesign.txt" || fail signed-bundle-mismatch
grep -Fxq "TeamIdentifier=$TEAM_IDENTIFIER" "$WORK/metadata/codesign.txt" || fail signed-team-mismatch

PRE_STAPLE="$WORK/release/pre-staple.zip"
python3 scripts/package_macos_installer_archive.py --app-bundle "$APP" --output "$PRE_STAPLE"
xcrun notarytool submit "$PRE_STAPLE"   --keychain-profile "$FORGE_PLATFORM_NOTARYTOOL_PROFILE"   --wait --output-format json >"$WORK/metadata/notary-submit.json"
NOTARY_STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$WORK/metadata/notary-submit.json")"
NOTARY_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$WORK/metadata/notary-submit.json")"
test "$NOTARY_STATUS" = "Accepted" || fail notarization-not-accepted
[[ "$NOTARY_ID" =~ ^[0-9A-Fa-f-]{36}$ ]] || fail invalid-notarization-id
NOTARY_ID="$(printf '%s' "$NOTARY_ID" | tr '[:upper:]' '[:lower:]')"
NOTARY_RECEIPT="$STATE_ROOT/receipts/notary-$OPERATION_ID.json"
if [[ -f "$NOTARY_RECEIPT" ]]; then
  cmp "$WORK/metadata/notary-submit.json" "$NOTARY_RECEIPT" ||
    fail notarization-receipt-changed-during-recovery
else
  install -m 600 "$WORK/metadata/notary-submit.json" "$NOTARY_RECEIPT"
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
# Stapling may materialize the legacy top-level CodeResources copy under the
# offline signer's umask. Qualify both manifests again after the last bundle
# mutation so the published archive remains readable when installed root-owned.
for code_resource in "$APP/Contents/_CodeSignature/CodeResources" "$APP/Contents/CodeResources"; do
  if [[ "$code_resource" == "$APP/Contents/CodeResources" && ! -e "$code_resource" && ! -L "$code_resource" ]]; then
    continue
  fi
  test -f "$code_resource" && test ! -L "$code_resource" || fail stapled-code-resource-invalid
  chmod 644 "$code_resource"
  test "$(stat -f %Lp "$code_resource")" = 644 || fail stapled-code-resource-mode-invalid
done
spctl --assess --type execute --verbose=4 "$APP" >"$WORK/metadata/gatekeeper.txt" 2>&1 ||
  fail gatekeeper-assessment-failed
codesign --verify --strict --deep "$APP"
python3 scripts/package_macos_installer_archive.py   --app-bundle "$APP" --output "$WORK/release/$ARCHIVE_NAME"

mkdir "$WORK/carrier-readback"
ditto -x -k "$WORK/release/$ARCHIVE_NAME" "$WORK/carrier-readback"
CARRIER_APP="$WORK/carrier-readback/ForgePlatformInstaller.app"
test -d "$CARRIER_APP" || fail final-archive-app-layout-invalid
for code_resource in "$CARRIER_APP/Contents/_CodeSignature/CodeResources" "$CARRIER_APP/Contents/CodeResources"; do
  if [[ "$code_resource" == "$CARRIER_APP/Contents/CodeResources" && ! -e "$code_resource" && ! -L "$code_resource" ]]; then
    continue
  fi
  test -f "$code_resource" && test ! -L "$code_resource" || fail final-archive-code-resource-invalid
  test "$(stat -f %Lp "$code_resource")" = 644 || fail final-archive-code-resource-mode-invalid
done
xcrun stapler validate -v "$CARRIER_APP" || fail final-archive-lost-stapled-ticket
spctl --assess --type execute --verbose=4 "$CARRIER_APP" || fail final-archive-gatekeeper-rejected
codesign --verify --strict --deep "$CARRIER_APP" || fail final-archive-signature-invalid
CARRIER_HELPER="$CARRIER_APP/Contents/Resources/forge-platform-installer-helper"
codesign --verify --strict "-R=$HELPER_REQUIREMENT" "$CARRIER_HELPER" ||
  fail final-archive-helper-identity-invalid
codesign --verify --strict "-R=$CALLER_REQUIREMENT" "$CARRIER_APP/Contents/MacOS/ForgePlatformInstaller" ||
  fail final-archive-gui-caller-identity-invalid
codesign --verify --strict "-R=$CALLER_REQUIREMENT" "$CARRIER_APP/Contents/MacOS/forge-platform-installer" ||
  fail final-archive-cli-caller-identity-invalid

if [[ "$HAS_BOOTSTRAP" == true ]]; then
  codesign --verify --strict "-R=$BOOTSTRAP_REQUIREMENT" "$CARRIER_APP/Contents/Library/LaunchServices/$BOOTSTRAP_LABEL" || fail final-archive-bootstrap-identity-invalid
  SIGNED_ARCHIVE_DIGEST="$(python3 - "$WORK/release/$ARCHIVE_NAME" <<'PYCODE'
from hashlib import sha256
from pathlib import Path
import sys
value=sha256()
with Path(sys.argv[1]).open("rb") as stream:
    for block in iter(lambda:stream.read(65536),b""):value.update(block)
print("sha256:"+value.hexdigest())
PYCODE
)" || fail signed-archive-digest-unavailable
  sign_helper_package "$CARRIER_APP" "$WORK/release/$ARCHIVE_NAME" "$INSTALLER_VERSION" "$SOURCE_SHA" "$WORK/release" "$WORK/metadata" "$TEAM_IDENTIFIER" "$INSTALLER_SIGNING_HASH" "$SIGNED_ARCHIVE_DIGEST" || fail helper-package-qualification-failed
  HELPER_PACKAGE_NOTARY_REFERENCE="$(python3 - "$WORK/release/helper-package-evidence.json" <<'PYCODE'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8"))["notarization_receipt_reference"])
PYCODE
)" || fail helper-package-receipt-invalid
  QUALIFIER_PACKAGE_ARGS=(--signed-helper-package "$WORK/release/$HELPER_PACKAGE_NAME" --helper-package-notarization-receipt-reference "$HELPER_PACKAGE_NOTARY_REFERENCE")
  STRUCTURE_PACKAGE_ARGS=(--helper-package "$WORK/release/$HELPER_PACKAGE_NAME" --helper-companion "$WORK/release/$HELPER_DESCRIPTOR_NAME")
  PUBLICATION_PACKAGE_ARGS=(--helper-package "$WORK/release/$HELPER_PACKAGE_NAME" --helper-package-readback "$WORK/readback/$HELPER_PACKAGE_NAME" --helper-companion "$WORK/release/$HELPER_DESCRIPTOR_NAME" --helper-companion-readback "$WORK/readback/$HELPER_DESCRIPTOR_NAME")
  PACKAGE_UPLOAD_ASSETS=("$WORK/release/$HELPER_PACKAGE_NAME" "$WORK/release/$HELPER_DESCRIPTOR_NAME")
  PACKAGE_DOWNLOAD_ARGS=(--pattern "$HELPER_PACKAGE_NAME" --pattern "$HELPER_DESCRIPTOR_NAME")
fi

codesign --display --verbose=6 "$APP" >"$WORK/metadata/codesign-final.txt" 2>&1
CODE_DIRECTORY_SHA256="$(python3 - "$WORK/metadata/codesign-final.txt" <<'PY'
import re
import sys
text=open(sys.argv[1], encoding="utf-8").read()
values=re.findall(r"^CandidateCDHashFull sha256=([0-9a-fA-F]{64})$", text, re.MULTILINE)
if len(values) != 1:
    raise SystemExit(1)
print(values[0].lower())
PY
)" || fail full-code-directory-sha256-unavailable

PUBLISHED_AT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["createdAt"])' "$WORK/metadata/run.json")"
EXPIRES_AT="$(python3 - "$PUBLISHED_AT" <<'PY'
from datetime import datetime, timedelta, timezone
import sys
value=datetime.fromisoformat(sys.argv[1].replace("Z","+00:00"))+timedelta(days=30)
print(value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00","Z"))
PY
)"
TRUST_RESOURCE="$APP/Contents/Resources/ForgePlatformInstallerReleaseTrust.json"
test -f "$TRUST_RESOURCE" || fail signed-release-trust-resource-missing
DESCRIPTOR_KEY_TOOL="$WORK/metadata/offline-installer-descriptor-key-tool"
xcrun swiftc scripts/ci/OfflineInstallerDescriptorKeyTool.swift \
  -framework Security -framework CryptoKit -o "$DESCRIPTOR_KEY_TOOL"
chmod 700 "$DESCRIPTOR_KEY_TOOL"
DESCRIPTOR_KEY_TOOL_IDENTIFIER="com.autonomous-engineering-system.forge-platform.installer-descriptor-key-tool"
codesign --force --options runtime --timestamp \
  --identifier "$DESCRIPTOR_KEY_TOOL_IDENTIFIER" \
  --sign "$FORGE_PLATFORM_CODESIGN_IDENTITY" "$DESCRIPTOR_KEY_TOOL"
descriptor_tool_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and identifier \"$DESCRIPTOR_KEY_TOOL_IDENTIFIER\""
codesign --verify --strict "-R=$descriptor_tool_requirement" "$DESCRIPTOR_KEY_TOOL" ||
  fail descriptor-key-tool-signature-invalid
python3 scripts/qualify_local_installer_release.py "${QUALIFIER_PACKAGE_ARGS[@]}"   --preparation "$WORK/candidate/installer-release-preparation.json"   --signed-archive "$WORK/release/$ARCHIVE_NAME"   --release-trust "$TRUST_RESOURCE"   --descriptor-key-tool "$DESCRIPTOR_KEY_TOOL"   --code-directory-sha256 "$CODE_DIRECTORY_SHA256"   --notarization-receipt-reference "receipt:apple-notary-$NOTARY_ID"   --catalog-url "$FORGE_PLATFORM_COMPOSITION_CATALOG_URL"   --published-at "$PUBLISHED_AT"   --expires-at "$EXPIRES_AT"   --run-id "$RUN_ID"   --journal-root "$STATE_ROOT/journal"   --output-directory "$WORK/release"

python3 scripts/verify_installer_release_evidence.py "${STRUCTURE_PACKAGE_ARGS[@]}"   --operation "$WORK/release/installer-release-operation.json"   --descriptor "$WORK/release/$DESCRIPTOR_NAME"   --archive "arm64=$WORK/release/$ARCHIVE_NAME"   --source-sha "$SOURCE_SHA"   --operation-id "$OPERATION_ID"   --installer-version "$INSTALLER_VERSION"   --channel "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["channel"])' "$WORK/candidate/installer-candidate.json")"   --release-sequence "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["release_sequence"])' "$AUTHORIZATION")"   --policy-revision "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["policy_revision"])' "$WORK/candidate/installer-candidate.json")"   --provenance-sha256 "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["provenance_sha256"])' "$WORK/candidate/installer-candidate.json")"   --release-trust-configuration-sha256 "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["release_trust_configuration_sha256"])' "$WORK/candidate/installer-candidate.json")"   --github-repository "$REPOSITORY"   --release-tag "$RELEASE_TAG"   --descriptor-asset-name "$DESCRIPTOR_NAME"   --bundle-identifier "$BUNDLE_IDENTIFIER"   --team-identifier "$TEAM_IDENTIFIER"   --asset-prefix "$(python3 scripts/validate_installer_release_identity.py --field asset_prefix)"

git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
test "$(git rev-parse origin/main)" = "$SOURCE_SHA" || fail main-changed-before-publication
if gh release view "$RELEASE_TAG" --repo "$REPOSITORY" --json isDraft,targetCommitish >"$WORK/metadata/release.json" 2>/dev/null; then
  test "$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["isDraft"]).lower())' "$WORK/metadata/release.json")" = true ||
    fail existing-release-is-not-draft
  test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["targetCommitish"])' "$WORK/metadata/release.json")" = "$SOURCE_SHA" ||
    fail existing-draft-target-mismatch
else
  gh release create "$RELEASE_TAG" --repo "$REPOSITORY" --draft     --target "$SOURCE_SHA" --title "Forge Platform Installer $INSTALLER_VERSION"     --notes "Exact locally signed and notarized installer release for $SOURCE_SHA."
fi

gh release upload "$RELEASE_TAG" --repo "$REPOSITORY" --clobber   "$WORK/release/$ARCHIVE_NAME"   "$WORK/release/$DESCRIPTOR_NAME"   "$WORK/release/installer-release-operation.json" "${PACKAGE_UPLOAD_ASSETS[@]}"
gh release download "$RELEASE_TAG" --repo "$REPOSITORY"   --pattern "$ARCHIVE_NAME" --pattern "$DESCRIPTOR_NAME" "${PACKAGE_DOWNLOAD_ARGS[@]}"   --dir "$WORK/readback"
cmp "$WORK/release/$ARCHIVE_NAME" "$WORK/readback/$ARCHIVE_NAME"
cmp "$WORK/release/$DESCRIPTOR_NAME" "$WORK/readback/$DESCRIPTOR_NAME"
if [[ "$HAS_BOOTSTRAP" == true ]]; then
  cmp "$WORK/release/$HELPER_PACKAGE_NAME" "$WORK/readback/$HELPER_PACKAGE_NAME"
  cmp "$WORK/release/$HELPER_DESCRIPTOR_NAME" "$WORK/readback/$HELPER_DESCRIPTOR_NAME"
fi

python3 scripts/record_local_installer_publication.py "${PUBLICATION_PACKAGE_ARGS[@]}"   --operation "$WORK/release/installer-release-operation.json"   --descriptor "$WORK/release/$DESCRIPTOR_NAME"   --descriptor-readback "$WORK/readback/$DESCRIPTOR_NAME"   --archive "$WORK/release/$ARCHIVE_NAME"   --archive-readback "$WORK/readback/$ARCHIVE_NAME"   --run-id "$RUN_ID"   --journal-root "$STATE_ROOT/journal"   --output "$WORK/release/installer-release-operation-published.json"
cp "$WORK/release/installer-release-operation-published.json"   "$WORK/release/installer-release-operation.json"
gh release upload "$RELEASE_TAG" --repo "$REPOSITORY" --clobber   "$WORK/release/installer-release-operation.json"
rm -f "$WORK/readback/installer-release-operation.json"
gh release download "$RELEASE_TAG" --repo "$REPOSITORY"   --pattern installer-release-operation.json --dir "$WORK/readback"
cmp "$WORK/release/installer-release-operation-published.json"   "$WORK/readback/installer-release-operation.json"

gh release edit "$RELEASE_TAG" --repo "$REPOSITORY" --draft=false
test "$(gh release view "$RELEASE_TAG" --repo "$REPOSITORY" --json isDraft --jq .isDraft)" = false
mkdir "$WORK/public-readback"
gh release download "$RELEASE_TAG" --repo "$REPOSITORY"   --pattern "$ARCHIVE_NAME" --pattern "$DESCRIPTOR_NAME"   --pattern installer-release-operation.json "${PACKAGE_DOWNLOAD_ARGS[@]}" --dir "$WORK/public-readback"
cmp "$WORK/release/$ARCHIVE_NAME" "$WORK/public-readback/$ARCHIVE_NAME"
cmp "$WORK/release/$DESCRIPTOR_NAME" "$WORK/public-readback/$DESCRIPTOR_NAME"
if [[ "$HAS_BOOTSTRAP" == true ]]; then
  cmp "$WORK/release/$HELPER_PACKAGE_NAME" "$WORK/public-readback/$HELPER_PACKAGE_NAME"
  cmp "$WORK/release/$HELPER_DESCRIPTOR_NAME" "$WORK/public-readback/$HELPER_DESCRIPTOR_NAME"
fi
cmp "$WORK/release/installer-release-operation-published.json"   "$WORK/public-readback/installer-release-operation.json"

echo "LOCAL_INSTALLER_RELEASE=PASS source_sha=$SOURCE_SHA run_id=$RUN_ID tag=$RELEASE_TAG archive=$ARCHIVE_NAME"
