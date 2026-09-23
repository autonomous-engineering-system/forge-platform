#!/bin/bash
set -euo pipefail

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "MAC_SIGNING_READINESS=FAIL reason=host-not-arm64" >&2
  exit 1
fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$major" -lt 26 ]]; then
  echo "MAC_SIGNING_READINESS=FAIL reason=macos-too-old" >&2
  exit 1
fi

test -n "${RUNNER_NAME:-}"
case ",${RUNNER_LABELS:-}," in
  *,forge-platform-mini,* ) ;;
  * )
    echo "MAC_SIGNING_READINESS=FAIL reason=wrong-runner-labels" >&2
    exit 1
    ;;
esac

developer_dir="$(xcode-select -p)"
test -d "$developer_dir"
xcode_version="$(xcodebuild -version | head -n1)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
test -n "$xcode_version"
test -n "$sdk_version"
xcrun notarytool --help >/dev/null
xcrun stapler --help >/dev/null
codesign --version >/dev/null

if [[ -z "${FORGE_PLATFORM_APPLE_TEAM_ID:-}" ]]; then
  echo "MAC_SIGNING_READINESS=FAIL reason=FORGE_PLATFORM_APPLE_TEAM_ID-required" >&2
  exit 1
fi
if [[ ! "$FORGE_PLATFORM_APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "MAC_SIGNING_READINESS=FAIL reason=invalid-team-id" >&2
  exit 1
fi
if [[ -z "${FORGE_PLATFORM_CODESIGN_IDENTITY:-}" ]]; then
  echo "MAC_SIGNING_READINESS=FAIL reason=FORGE_PLATFORM_CODESIGN_IDENTITY-required" >&2
  exit 1
fi

identity_output="$(security find-identity -v -p codesigning 2>/dev/null)"
if ! grep -Fq "Developer ID Application:" <<<"$identity_output"; then
  echo "MAC_SIGNING_READINESS=FAIL reason=no-developer-id-application" >&2
  exit 1
fi
if ! grep -Fq "($FORGE_PLATFORM_APPLE_TEAM_ID)" <<<"$identity_output"; then
  echo "MAC_SIGNING_READINESS=FAIL reason=team-id-not-present-in-keychain" >&2
  exit 1
fi
if ! grep -Fq "$FORGE_PLATFORM_CODESIGN_IDENTITY" <<<"$identity_output"; then
  echo "MAC_SIGNING_READINESS=FAIL reason=configured-codesign-identity-not-present" >&2
  exit 1
fi

probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT
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
codesign --force --options runtime --timestamp --sign "$FORGE_PLATFORM_CODESIGN_IDENTITY" "$probe/SigningProbe.app" >/dev/null
codesign --verify --strict --deep "$probe/SigningProbe.app"

if [[ -n "${FORGE_PLATFORM_NOTARYTOOL_PROFILE:-}" ]]; then
  xcrun notarytool history --keychain-profile "$FORGE_PLATFORM_NOTARYTOOL_PROFILE"     >"$probe/notary-history.txt" 2>"$probe/notary-error.txt" || {
      echo "MAC_SIGNING_READINESS=FAIL reason=notarytool-profile-unavailable" >&2
      exit 1
    }
fi

echo "MAC_SIGNING_READINESS=PASS runner=$RUNNER_NAME xcode=$xcode_version sdk=$sdk_version team_id=$FORGE_PLATFORM_APPLE_TEAM_ID"
