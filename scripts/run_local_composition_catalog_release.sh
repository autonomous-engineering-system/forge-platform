#!/bin/bash
# Sign and publish one protected composition-catalog candidate from the local
# signer account. The catalog private key remains in this account's Keychain.
set +x
set -euo pipefail
umask 077

REPOSITORY="autonomous-engineering-system/forge-platform"
CATALOG_ASSET="ForgePlatformInstallerCompositionCatalog.json"
fail() { echo "LOCAL_COMPOSITION_CATALOG_RELEASE=FAIL reason=$1" >&2; exit 1; }
[[ "$#" == 2 ]] || fail usage-run-id-source-sha
RUN_ID="$1"
SOURCE_SHA="$2"
[[ "$RUN_ID" =~ ^[1-9][0-9]*$ ]] || fail invalid-run-id
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail invalid-source-sha
[[ -z "${GITHUB_ACTIONS:-}" && -z "${RUNNER_NAME:-}" ]] || fail actions-context-prohibited

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
test -z "$(git status --porcelain)" || fail signer-checkout-not-clean
test "$(git rev-parse HEAD)" = "$SOURCE_SHA" || fail signer-checkout-source-mismatch
git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
test "$(git rev-parse origin/main)" = "$SOURCE_SHA" || fail source-is-not-exact-current-main
python3 scripts/validate_installer_release_identity.py --require-ready >/dev/null ||
  fail installer-release-identity-not-ready

STATE_ROOT="${FORGE_PLATFORM_SIGNER_STATE_ROOT:-$HOME/Library/Application Support/ForgePlatformSigner}"
mkdir -p "$STATE_ROOT/locks" "$STATE_ROOT/catalog-journal"
chmod 700 "$STATE_ROOT" "$STATE_ROOT/locks" "$STATE_ROOT/catalog-journal"
LOCK="$STATE_ROOT/locks/exclusive-offline-signing"
mkdir "$LOCK" 2>/dev/null || fail signing-concurrency-lock-held
WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-platform-catalog-release.XXXXXX")"
cleanup() {
  rm -rf "$WORK"
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v gh >/dev/null || fail gh-cli-unavailable
command -v openssl >/dev/null || fail openssl-unavailable
gh auth status --hostname github.com >/dev/null 2>&1 || fail github-auth-unavailable
mkdir -p "$WORK/metadata" "$WORK/authorization" "$WORK/candidate" "$WORK/signatures" "$WORK/release" "$WORK/readback"

gh run view "$RUN_ID" --repo "$REPOSITORY" \
  --json databaseId,headBranch,headSha,event,conclusion,workflowName,jobs,url,createdAt \
  >"$WORK/metadata/run.json"
RUN_ATTEMPT="$(gh api "repos/$REPOSITORY/actions/runs/$RUN_ID" --jq .run_attempt)"
[[ "$RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] || fail invalid-run-attempt
AUTH_ARTIFACT="forge-platform-catalog-signing-authorization-$RUN_ID-$RUN_ATTEMPT"
gh run download "$RUN_ID" --repo "$REPOSITORY" --name "$AUTH_ARTIFACT" --dir "$WORK/authorization"
AUTHORIZATION="$WORK/authorization/authorization.json"
test -f "$AUTHORIZATION" || fail authorization-artifact-missing
CANDIDATE_ARTIFACT="$(python3 -c 'import json,re,sys; v=json.load(open(sys.argv[1]))["candidate_artifact"]; print(v) if re.fullmatch(r"forge-platform-composition-catalog-candidate-[1-9][0-9]*-[0-9a-f]{40}",v) else sys.exit(1)' "$AUTHORIZATION")" ||
  fail unsafe-candidate-artifact-name
gh run download "$RUN_ID" --repo "$REPOSITORY" --name "$CANDIDATE_ARTIFACT" --dir "$WORK/candidate"
python3 scripts/verify_local_catalog_authorization.py \
  --authorization "$AUTHORIZATION" \
  --run-metadata "$WORK/metadata/run.json" \
  --candidate-directory "$WORK/candidate" \
  --source-sha "$SOURCE_SHA" \
  --run-id "$RUN_ID"

CANDIDATE="$WORK/candidate/composition-catalog-candidate.json"
SEQUENCE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sequence"])' "$CANDIDATE")"
IMMUTABLE_TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["immutable_release_tag"])' "$CANDIDATE")"
STABLE_TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stable_release_tag"])' "$CANDIDATE")"
MANIFEST_ASSET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest_asset_name"])' "$CANDIDATE")"
INDEX_ASSET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["component_combination_catalog_asset_name"])' "$CANDIDATE")"
[[ "$SEQUENCE" =~ ^[1-9][0-9]*$ ]] || fail invalid-catalog-sequence
[[ "$IMMUTABLE_TAG" == "forge-platform-composition-catalog-v$SEQUENCE" ]] || fail immutable-tag-mismatch
[[ "$STABLE_TAG" == "forge-platform-composition-catalog-stable" ]] || fail stable-tag-mismatch

TRUST_RESOURCE="release-trust/ForgePlatformInstallerCompositionCatalogTrust.json"
KEY_TOOL="$WORK/metadata/offline-composition-catalog-key-tool"
xcrun swiftc scripts/ci/OfflineCompositionCatalogKeyTool.swift \
  -framework Security -framework CryptoKit -o "$KEY_TOOL"
chmod 700 "$KEY_TOOL"
TEAM_IDENTIFIER="$(python3 scripts/validate_installer_release_identity.py --field team_identifier)"
KEY_TOOL_IDENTIFIER="com.autonomous-engineering-system.forge-platform.composition-catalog-key-tool"
codesign --force --options runtime --timestamp \
  --identifier "$KEY_TOOL_IDENTIFIER" \
  --sign "$FORGE_PLATFORM_CODESIGN_IDENTITY" "$KEY_TOOL"
tool_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and identifier \"$KEY_TOOL_IDENTIFIER\""
codesign --verify --strict "-R=$tool_requirement" "$KEY_TOOL" || fail catalog-key-tool-signature-invalid

signature_args=()
while IFS= read -r key_id; do
  [[ -n "$key_id" ]] || fail empty-catalog-key-id
  envelope="$WORK/signatures/$key_id.json"
  "$KEY_TOOL" sign "$key_id" "$WORK/candidate/composition-catalog-unsigned.json" "$envelope"
  signature_args+=(--signature "$envelope")
done < <(python3 -c 'import json,sys; [print(value) for value in json.load(open(sys.argv[1]))["catalog_key_ids"]]' "$CANDIDATE")

python3 scripts/finalize_signed_composition_catalog.py \
  --candidate-directory "$WORK/candidate" \
  "${signature_args[@]}" \
  --catalog-trust "$TRUST_RESOURCE" \
  --output-directory "$WORK/release" \
  --workflow-run-id "$RUN_ID" \
  --workflow-run-attempt "$RUN_ATTEMPT"

git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
test "$(git rev-parse origin/main)" = "$SOURCE_SHA" || fail main-changed-before-publication

if gh release view "$IMMUTABLE_TAG" --repo "$REPOSITORY" --json targetCommitish,isDraft >"$WORK/metadata/immutable-release.json" 2>/dev/null; then
  test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["targetCommitish"])' "$WORK/metadata/immutable-release.json")" = "$SOURCE_SHA" ||
    fail existing-immutable-release-target-mismatch
  IMMUTABLE_RELEASE_DRAFT="$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["isDraft"]).lower())' "$WORK/metadata/immutable-release.json")"
else
  gh release create "$IMMUTABLE_TAG" --repo "$REPOSITORY" --draft \
    --target "$SOURCE_SHA" --title "Forge Platform composition catalog $SEQUENCE" \
    --notes "Immutable composition manifest, selection index and signed catalog evidence for sequence $SEQUENCE." \
    --latest=false
  IMMUTABLE_RELEASE_DRAFT=true
fi

for asset in "$MANIFEST_ASSET" "$INDEX_ASSET" "$CATALOG_ASSET"; do
  existing="$(gh release view "$IMMUTABLE_TAG" --repo "$REPOSITORY" --json assets --jq ".assets[] | select(.name == \"$asset\") | .name")"
  if [[ "$existing" == "$asset" ]]; then
    mkdir -p "$WORK/readback/immutable-existing"
    gh release download "$IMMUTABLE_TAG" --repo "$REPOSITORY" --pattern "$asset" --dir "$WORK/readback/immutable-existing"
    cmp "$WORK/release/$asset" "$WORK/readback/immutable-existing/$asset" || fail immutable-release-asset-conflict
  else
    test "$IMMUTABLE_RELEASE_DRAFT" = true || fail published-immutable-release-is-incomplete
    gh release upload "$IMMUTABLE_TAG" --repo "$REPOSITORY" "$WORK/release/$asset"
  fi
done
existing_operation="$(gh release view "$IMMUTABLE_TAG" --repo "$REPOSITORY" --json assets --jq '.assets[] | select(.name == "composition-catalog-operation.json") | .name')"
if [[ "$existing_operation" == "composition-catalog-operation.json" ]]; then
  mkdir -p "$WORK/readback/operation-existing"
  gh release download "$IMMUTABLE_TAG" --repo "$REPOSITORY" \
    --pattern composition-catalog-operation.json --dir "$WORK/readback/operation-existing"
  python3 - "$WORK/release/composition-catalog-operation.json" "$WORK/readback/operation-existing/composition-catalog-operation.json" <<'PY'
import json
from pathlib import Path
import sys

expected = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
observed = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
if observed.get("state") == "PUBLISHED":
    observed.pop("stable_catalog_readback_digest", None)
    observed["state"] = "QUALIFIED"
if observed != expected:
    raise SystemExit("existing operation does not bind the exact qualified candidate")
PY
else
  test "$IMMUTABLE_RELEASE_DRAFT" = true || fail published-immutable-release-lacks-operation
  gh release upload "$IMMUTABLE_TAG" --repo "$REPOSITORY" \
    "$WORK/release/composition-catalog-operation.json"
fi
mkdir -p "$WORK/readback/immutable"
gh release download "$IMMUTABLE_TAG" --repo "$REPOSITORY" \
  --pattern "$MANIFEST_ASSET" --pattern "$INDEX_ASSET" --pattern "$CATALOG_ASSET" \
  --pattern composition-catalog-operation.json --dir "$WORK/readback/immutable"
for asset in "$MANIFEST_ASSET" "$INDEX_ASSET" "$CATALOG_ASSET"; do
  cmp "$WORK/release/$asset" "$WORK/readback/immutable/$asset" || fail immutable-release-readback-mismatch
done
python3 - "$WORK/release/composition-catalog-operation.json" "$WORK/readback/immutable/composition-catalog-operation.json" <<'PY'
import json
from pathlib import Path
import sys

expected = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
observed = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
if observed.get("state") == "PUBLISHED":
    observed.pop("stable_catalog_readback_digest", None)
    observed["state"] = "QUALIFIED"
if observed != expected:
    raise SystemExit("immutable operation readback mismatch")
PY
if test "$(gh release view "$IMMUTABLE_TAG" --repo "$REPOSITORY" --json isDraft --jq .isDraft)" = true; then
  gh release edit "$IMMUTABLE_TAG" --repo "$REPOSITORY" --draft=false
fi
test "$(gh release view "$IMMUTABLE_TAG" --repo "$REPOSITORY" --json isDraft --jq .isDraft)" = false ||
  fail immutable-release-not-public

if gh release view "$STABLE_TAG" --repo "$REPOSITORY" --json isDraft >/dev/null 2>&1; then
  test "$(gh release view "$STABLE_TAG" --repo "$REPOSITORY" --json isDraft --jq .isDraft)" = false ||
    fail stable-release-is-draft
  mkdir -p "$WORK/readback/stable-previous"
  if gh release download "$STABLE_TAG" --repo "$REPOSITORY" --pattern "$CATALOG_ASSET" --dir "$WORK/readback/stable-previous" 2>/dev/null; then
    PREVIOUS_SEQUENCE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sequence"])' "$WORK/readback/stable-previous/$CATALOG_ASSET")" ||
      fail stable-catalog-is-invalid
    [[ "$PREVIOUS_SEQUENCE" =~ ^[1-9][0-9]*$ ]] || fail stable-catalog-sequence-invalid
    (( PREVIOUS_SEQUENCE <= SEQUENCE )) || fail stable-catalog-sequence-regression
    if (( PREVIOUS_SEQUENCE == SEQUENCE )); then
      cmp "$WORK/release/$CATALOG_ASSET" "$WORK/readback/stable-previous/$CATALOG_ASSET" ||
        fail stable-catalog-same-sequence-different-bytes
    fi
  fi
  gh release edit "$STABLE_TAG" --repo "$REPOSITORY" --target "$SOURCE_SHA"
else
  gh release create "$STABLE_TAG" --repo "$REPOSITORY" \
    --target "$SOURCE_SHA" --title "Forge Platform stable composition catalog" \
    --notes "Mutable locator for the latest separately signed stable composition catalog. Immutable inputs remain on sequence releases." \
    --latest=false
fi

if [[ ! -f "$WORK/readback/stable-previous/$CATALOG_ASSET" ]] ||
   ! cmp -s "$WORK/release/$CATALOG_ASSET" "$WORK/readback/stable-previous/$CATALOG_ASSET"; then
  TEMP_ASSET="$CATALOG_ASSET.next-$SEQUENCE"
  cp "$WORK/release/$CATALOG_ASSET" "$WORK/release/$TEMP_ASSET"
  gh release upload "$STABLE_TAG" --repo "$REPOSITORY" --clobber "$WORK/release/$TEMP_ASSET"
  mkdir -p "$WORK/readback/stable-next"
  gh release download "$STABLE_TAG" --repo "$REPOSITORY" --pattern "$TEMP_ASSET" --dir "$WORK/readback/stable-next"
  cmp "$WORK/release/$TEMP_ASSET" "$WORK/readback/stable-next/$TEMP_ASSET" || fail stable-staged-readback-mismatch
  CANONICAL_ID="$(gh release view "$STABLE_TAG" --repo "$REPOSITORY" --json assets --jq ".assets[] | select(.name == \"$CATALOG_ASSET\") | .apiUrl" | sed -E 's#^.*/##')"
  TEMP_ID="$(gh release view "$STABLE_TAG" --repo "$REPOSITORY" --json assets --jq ".assets[] | select(.name == \"$TEMP_ASSET\") | .apiUrl" | sed -E 's#^.*/##')"
  [[ "$TEMP_ID" =~ ^[1-9][0-9]*$ ]] || fail stable-staged-asset-id-invalid
  [[ -z "$CANONICAL_ID" || "$CANONICAL_ID" =~ ^[1-9][0-9]*$ ]] || fail stable-canonical-asset-id-invalid
  if [[ -n "$CANONICAL_ID" ]]; then
    gh api -X DELETE "repos/$REPOSITORY/releases/assets/$CANONICAL_ID"
  fi
  gh api -X PATCH "repos/$REPOSITORY/releases/assets/$TEMP_ID" -f name="$CATALOG_ASSET" >/dev/null
fi

mkdir -p "$WORK/readback/stable-final"
gh release download "$STABLE_TAG" --repo "$REPOSITORY" --pattern "$CATALOG_ASSET" --dir "$WORK/readback/stable-final"
cmp "$WORK/release/$CATALOG_ASSET" "$WORK/readback/stable-final/$CATALOG_ASSET" || fail stable-public-readback-mismatch

python3 - "$WORK/release/composition-catalog-operation.json" "$WORK/readback/stable-final/$CATALOG_ASSET" <<'PY'
from hashlib import sha256
import json
from pathlib import Path
import sys

operation_path = Path(sys.argv[1])
readback = Path(sys.argv[2]).read_bytes()
operation = json.loads(operation_path.read_text(encoding="utf-8"))
actual = "sha256:" + sha256(readback).hexdigest()
if actual != operation["catalog_digest"]:
    raise SystemExit("stable catalog readback digest mismatch")
operation["state"] = "PUBLISHED"
operation["stable_catalog_readback_digest"] = actual
operation_path.write_text(
    json.dumps(operation, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n",
    encoding="utf-8",
)
PY
gh release upload "$IMMUTABLE_TAG" --repo "$REPOSITORY" --clobber \
  "$WORK/release/composition-catalog-operation.json"
mkdir -p "$WORK/readback/operation-final"
gh release download "$IMMUTABLE_TAG" --repo "$REPOSITORY" \
  --pattern composition-catalog-operation.json --dir "$WORK/readback/operation-final"
cmp "$WORK/release/composition-catalog-operation.json" \
  "$WORK/readback/operation-final/composition-catalog-operation.json" || fail operation-public-readback-mismatch

echo "LOCAL_COMPOSITION_CATALOG_RELEASE=PASS source_sha=$SOURCE_SHA run_id=$RUN_ID sequence=$SEQUENCE immutable_tag=$IMMUTABLE_TAG stable_tag=$STABLE_TAG"
