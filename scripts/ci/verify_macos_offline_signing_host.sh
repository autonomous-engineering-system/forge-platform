#!/bin/bash
# Local/offline Mac mini signer readiness. This script MUST NOT run inside GitHub Actions.
# It checks signer/notary authentication readiness, not artifact notarization.
set +x
set -euo pipefail
umask 077
fail() { echo "MAC_SIGNING_READINESS=FAIL reason=$1" >&2; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || fail host-not-arm64
os_version="$(sw_vers -productVersion)"
major="${os_version%%.*}"
[[ "$major" =~ ^[0-9]+$ && "$major" -ge 26 ]] || fail macos-too-old
[[ "${GITHUB_ACTIONS:-}" != "true" ]] || fail github-actions-signing-forbidden
[[ -z "${RUNNER_NAME:-}" ]] || fail actions-runner-context-forbidden
[[ -n "${FORGE_PLATFORM_SIGNER_ACCOUNT:-}" ]] || fail signer-account-required
[[ "$(id -un)" == "$FORGE_PLATFORM_SIGNER_ACCOUNT" ]] || fail signer-account-mismatch
[[ "${FORGE_PLATFORM_APPLE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || fail invalid-team-id
[[ -n "${FORGE_PLATFORM_CODESIGN_IDENTITY:-}" ]] || fail codesign-identity-required
[[ -n "${FORGE_PLATFORM_NOTARYTOOL_PROFILE:-}" ]] || fail notarytool-profile-required

developer_dir="$(xcode-select -p)"
[[ -d "$developer_dir" ]] || fail developer-directory-unavailable
xcode_version="$(xcodebuild -version)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
[[ -n "$xcode_version" && -n "$sdk_version" ]] || fail toolchain-unavailable
xcrun notarytool --help >/dev/null
# Xcode 27's stapler prints usage and exits 64 for --help. Resolve the exact
# active-Xcode tool instead so availability is checked without invoking it.
xcrun --find stapler >/dev/null
# Xcode 27's codesign returns 2 for --version without printing a version.
# Existence is checked here; the signed probe below is the functional check.
command -v codesign >/dev/null

probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Only public certificate metadata is read. No Keychain exports or ACL changes.
security find-identity -v -p codesigning >"$probe/identities.txt" 2>"$probe/identity-error.txt" || fail identity-read-failed
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
done <"$probe/identities.txt"
[[ "$matches" == 1 ]] || fail selected-identity-missing-or-ambiguous
[[ "$selected_name" == "Developer ID Application: "*"($FORGE_PLATFORM_APPLE_TEAM_ID)" ]] || fail selected-identity-team-mismatch

mkdir -p "$probe/SigningProbe.app/Contents/MacOS"
cp /usr/bin/true "$probe/SigningProbe.app/Contents/MacOS/SigningProbe"
cat >"$probe/SigningProbe.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SigningProbe</string>
<key>CFBundleIdentifier</key><string>com.forgeplatform.ci.signing-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST
# Bound commands that can wait on Keychain, timestamping or the notary service.
# stdin is closed; errors remain in the private probe directory, never CI logs.
bounded() {
  python3 - "$probe/command.log" "$@" <<'PY'
import subprocess
import sys
with open(sys.argv[1], "wb") as log:
    try:
        result = subprocess.run(sys.argv[2:], stdin=subprocess.DEVNULL,
                                stdout=log, stderr=log, timeout=90, check=False)
        sys.exit(0 if result.returncode == 0 else 1)
    except (OSError, subprocess.TimeoutExpired):
        sys.exit(1)
PY
}
bounded codesign --force --options runtime --timestamp --sign "$selected_hash" "$probe/SigningProbe.app" || fail noninteractive-signing-failed
bounded codesign --verify --strict --deep "$probe/SigningProbe.app" || fail signature-verification-failed
requirement="anchor apple generic and certificate leaf[subject.OU] = \"$FORGE_PLATFORM_APPLE_TEAM_ID\" and identifier \"com.forgeplatform.ci.signing-probe\""
bounded codesign --verify --strict "-R=$requirement" "$probe/SigningProbe.app" || fail apple-trust-requirement-failed
codesign --display --verbose=4 "$probe/SigningProbe.app" >"$probe/display.txt" 2>&1 || fail signature-readback-failed
[[ "$(grep -c '^TeamIdentifier=' "$probe/display.txt")" == 1 ]] || fail ambiguous-signed-team
[[ "$(grep -c '^Identifier=' "$probe/display.txt")" == 1 ]] || fail ambiguous-signed-identifier
grep -Fxq "TeamIdentifier=$FORGE_PLATFORM_APPLE_TEAM_ID" "$probe/display.txt" || fail signed-team-mismatch
grep -Fxq 'Identifier=com.forgeplatform.ci.signing-probe' "$probe/display.txt" || fail signed-bundle-mismatch

bounded xcrun notarytool history --keychain-profile "$FORGE_PLATFORM_NOTARYTOOL_PROFILE" --output-format json || fail notarytool-profile-unavailable
python3 - "$probe/command.log" <<'PY' || fail invalid-notary-readback
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as source:
        payload = json.load(source)
    valid = isinstance(payload, dict) and isinstance(payload.get("history"), list)
except (OSError, ValueError):
    valid = False
sys.exit(0 if valid else 1)
PY
printf 'MAC_SIGNING_TOOLCHAIN os=%s developer_dir=%s sdk=%s\n%s\n' "$os_version" "$developer_dir" "$sdk_version" "$xcode_version"
echo "MAC_SIGNING_READINESS=PASS mode=offline-local user=$(id -un) team_id=$FORGE_PLATFORM_APPLE_TEAM_ID"
echo 'NOTARIZATION_ACCEPTANCE=NOT_RUN OFFLINE_SIGNER_REBOOT_READINESS=NOT_VERIFIED'
