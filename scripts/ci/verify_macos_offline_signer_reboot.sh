#!/bin/bash
# Prove that the dedicated local signer retains every required credential
# across a real reboot. This script never exports private key material.
set +x
set -euo pipefail
umask 077

fail() { echo "OFFLINE_SIGNER_REBOOT_READINESS=FAIL reason=$1" >&2; exit 1; }
[[ "$#" == 1 && ("$1" == "record" || "$1" == "verify") ]] || fail usage-record-or-verify
[[ "${GITHUB_ACTIONS:-}" != "true" && -z "${RUNNER_NAME:-}" ]] || fail actions-context-prohibited
[[ -n "${FORGE_PLATFORM_SIGNER_ACCOUNT:-}" ]] || fail signer-account-required
[[ "$(id -un)" == "$FORGE_PLATFORM_SIGNER_ACCOUNT" ]] || fail signer-account-mismatch
[[ "${FORGE_PLATFORM_APPLE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || fail team-id-required
[[ -n "${FORGE_PLATFORM_CODESIGN_IDENTITY:-}" ]] || fail codesign-identity-required
[[ -n "${FORGE_PLATFORM_NOTARYTOOL_PROFILE:-}" ]] || fail notarytool-profile-required

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail dirty-worktree
SOURCE_SHA="$(git rev-parse HEAD)"
git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main >/dev/null 2>&1 || fail origin-main-fetch-failed
[[ "$SOURCE_SHA" == "$(git rev-parse origin/main)" ]] || fail source-not-exact-current-main

python3 scripts/validate_installer_release_identity.py --require-ready >/dev/null || fail release-identity-not-ready
bash scripts/ci/verify_macos_offline_signing_host.sh >/dev/null || fail signing-host-not-ready

STATE="${FORGE_PLATFORM_SIGNER_REBOOT_STATE:-$HOME/Library/Application Support/ForgePlatformSigner/reboot-readiness.json}"
STATE_ROOT="$(dirname "$STATE")"
if [[ ! -e "$STATE_ROOT" ]]; then
  mkdir -m 700 -p "$STATE_ROOT" || fail state-root-create-failed
fi
[[ -d "$STATE_ROOT" && ! -L "$STATE_ROOT" ]] || fail state-root-invalid
[[ "$(stat -f '%Su' "$STATE_ROOT")" == "$(id -un)" ]] || fail state-root-owner-mismatch
[[ "$(stat -f '%Lp' "$STATE_ROOT")" == "700" ]] || fail state-root-mode-mismatch
[[ ! -e "$STATE" || (-f "$STATE" && ! -L "$STATE") ]] || fail state-file-invalid

WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-platform-signer-reboot.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DESCRIPTOR_TOOL="$WORK/offline-installer-descriptor-key-tool"
CATALOG_TOOL="$WORK/offline-composition-catalog-key-tool"
xcrun swiftc scripts/ci/OfflineInstallerDescriptorKeyTool.swift \
  -framework Security -framework CryptoKit -o "$DESCRIPTOR_TOOL" || fail descriptor-tool-build-failed
xcrun swiftc scripts/ci/OfflineCompositionCatalogKeyTool.swift \
  -framework Security -framework CryptoKit -o "$CATALOG_TOOL" || fail catalog-tool-build-failed
chmod 700 "$DESCRIPTOR_TOOL" "$CATALOG_TOOL"

DESCRIPTOR_IDENTIFIER="com.autonomous-engineering-system.forge-platform.installer-descriptor-key-tool"
CATALOG_IDENTIFIER="com.autonomous-engineering-system.forge-platform.composition-catalog-key-tool"
codesign --force --options runtime --timestamp --identifier "$DESCRIPTOR_IDENTIFIER" \
  --sign "$FORGE_PLATFORM_CODESIGN_IDENTITY" "$DESCRIPTOR_TOOL" >/dev/null 2>&1 \
  || fail descriptor-tool-signing-failed
codesign --force --options runtime --timestamp --identifier "$CATALOG_IDENTIFIER" \
  --sign "$FORGE_PLATFORM_CODESIGN_IDENTITY" "$CATALOG_TOOL" >/dev/null 2>&1 \
  || fail catalog-tool-signing-failed
for binding in "$DESCRIPTOR_TOOL|$DESCRIPTOR_IDENTIFIER" "$CATALOG_TOOL|$CATALOG_IDENTIFIER"; do
  tool="${binding%%|*}"
  identifier="${binding#*|}"
  requirement="anchor apple generic and certificate leaf[subject.OU] = \"$FORGE_PLATFORM_APPLE_TEAM_ID\" and identifier \"$identifier\""
  codesign --verify --strict "-R=$requirement" "$tool" >/dev/null 2>&1 || fail signing-key-tool-identity-invalid
done

python3 - \
  "$DESCRIPTOR_TOOL" release-trust/ForgePlatformInstallerReleaseTrust.json OFFLINE_DESCRIPTOR_KEY \
  "$CATALOG_TOOL" release-trust/ForgePlatformInstallerCompositionCatalogTrust.json OFFLINE_CATALOG_KEY <<'PY' \
  || fail local-signing-key-readback-failed
import json
from pathlib import Path
import subprocess
import sys

arguments = sys.argv[1:]
for offset in range(0, len(arguments), 3):
    tool, resource_path, prefix = arguments[offset:offset + 3]
    resource = json.loads(Path(resource_path).read_text(encoding="utf-8"))
    keys = resource.get("ed25519_public_keys")
    if not isinstance(keys, list) or not keys:
        raise SystemExit(1)
    for key in keys:
        if not isinstance(key, dict) or set(key) != {"key_id", "public_key_base64"}:
            raise SystemExit(1)
        result = subprocess.run(
            [tool, "public-key", key["key_id"]],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
            check=False,
        )
        expected = f"{prefix}=READY key_id={key['key_id']} public_key_base64={key['public_key_base64']}\n"
        if result.returncode != 0 or result.stdout != expected:
            raise SystemExit(1)
PY

BOOT_ID="$(sysctl -n kern.boottime)"
RELEASE_TRUST_SHA="$(python3 scripts/validate_installer_release_identity.py --field release_trust_configuration_sha256)"
CATALOG_TRUST_SHA="$(python3 -c 'import json; print(json.load(open("release-trust/ForgePlatformInstallerCompositionCatalogTrust.json"))["configuration_sha256"])')"

if [[ "$1" == "record" ]]; then
  python3 - "$STATE" "$BOOT_ID" "$SOURCE_SHA" "$FORGE_PLATFORM_SIGNER_ACCOUNT" \
    "$FORGE_PLATFORM_APPLE_TEAM_ID" "$FORGE_PLATFORM_NOTARYTOOL_PROFILE" \
    "$RELEASE_TRUST_SHA" "$CATALOG_TRUST_SHA" <<'PY'
import json
import os
from pathlib import Path
import sys

path = Path(sys.argv[1])
payload = {
    "boot_identity": sys.argv[2],
    "source_revision": sys.argv[3],
    "signer_account": sys.argv[4],
    "team_identifier": sys.argv[5],
    "notarytool_profile": sys.argv[6],
    "release_trust_configuration_sha256": sys.argv[7],
    "catalog_trust_configuration_sha256": sys.argv[8],
    "uid": os.getuid(),
}
encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"
temporary = path.with_name(path.name + ".tmp")
temporary.write_text(encoded, encoding="utf-8")
temporary.chmod(0o600)
os.replace(temporary, path)
PY
  echo "OFFLINE_SIGNER_REBOOT_BASELINE=RECORDED source_sha=$SOURCE_SHA user=$FORGE_PLATFORM_SIGNER_ACCOUNT team_id=$FORGE_PLATFORM_APPLE_TEAM_ID"
  exit 0
fi

[[ -f "$STATE" && ! -L "$STATE" ]] || fail reboot-baseline-missing
[[ "$(stat -f '%Su' "$STATE")" == "$(id -un)" ]] || fail state-file-owner-mismatch
[[ "$(stat -f '%Lp' "$STATE")" == "600" ]] || fail state-file-mode-mismatch
RECORDED_BOOT="$(python3 -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); boot=value.get("boot_identity"); print(boot) if isinstance(boot,str) and boot else sys.exit(1)' "$STATE")" \
  || fail reboot-baseline-invalid
[[ "$RECORDED_BOOT" != "$BOOT_ID" ]] || fail host-has-not-rebooted
python3 - "$STATE" "$BOOT_ID" "$SOURCE_SHA" "$FORGE_PLATFORM_SIGNER_ACCOUNT" \
  "$FORGE_PLATFORM_APPLE_TEAM_ID" "$FORGE_PLATFORM_NOTARYTOOL_PROFILE" \
  "$RELEASE_TRUST_SHA" "$CATALOG_TRUST_SHA" <<'PY' || fail reboot-evidence-mismatch
import json
import os
from pathlib import Path
import sys

try:
    value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
expected_fields = {
    "boot_identity", "source_revision", "signer_account", "team_identifier",
    "notarytool_profile", "release_trust_configuration_sha256",
    "catalog_trust_configuration_sha256", "uid",
}
if not isinstance(value, dict) or set(value) != expected_fields:
    raise SystemExit(1)
expected = {
    "source_revision": sys.argv[3],
    "signer_account": sys.argv[4],
    "team_identifier": sys.argv[5],
    "notarytool_profile": sys.argv[6],
    "release_trust_configuration_sha256": sys.argv[7],
    "catalog_trust_configuration_sha256": sys.argv[8],
    "uid": os.getuid(),
}
if any(value[key] != expected[key] for key in expected):
    raise SystemExit(1)
PY

echo "OFFLINE_SIGNER_REBOOT_READINESS=PASS source_sha=$SOURCE_SHA user=$FORGE_PLATFORM_SIGNER_ACCOUNT team_id=$FORGE_PLATFORM_APPLE_TEAM_ID notary_profile=$FORGE_PLATFORM_NOTARYTOOL_PROFILE descriptor_keys=PASS catalog_keys=PASS"
