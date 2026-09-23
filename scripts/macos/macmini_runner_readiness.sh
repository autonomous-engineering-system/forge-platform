#!/bin/bash
set -euo pipefail

OUT="${1:-}"
[[ "$(uname -m)" == "arm64" ]] || { echo "Mac mini qualification runner is not arm64" >&2; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$major" -ge 26 ]] || { echo "Mac mini qualification runner requires macOS 26+" >&2; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild unavailable" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "xcrun unavailable" >&2; exit 1; }
command -v security >/dev/null 2>&1 || { echo "security unavailable" >&2; exit 1; }

xcode_path="$(xcode-select -p)"
xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
swift_version="$(xcrun swift --version | head -1)"
codesign_version="$(codesign --version)"
notarytool_state="AVAILABLE"
if ! xcrun notarytool help >/dev/null 2>&1; then
  notarytool_state="UNAVAILABLE"
fi

identity_line="$(security find-identity -v -p codesigning 2>/dev/null   | grep 'Developer ID Application:'   | head -1 || true)"
[[ -n "$identity_line" ]] || {
  echo "No Developer ID Application identity is visible to the runner user" >&2
  exit 1
}
identity_sha1="$(printf '%s\n' "$identity_line" | awk '{print $2}')"
identity_name="$(printf '%s\n' "$identity_line" | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]+[[:space:]]+"([^"]+)".*/\1/')"
team_id="$(printf '%s\n' "$identity_name" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"
[[ "$identity_sha1" =~ ^[0-9A-F]{40}$ ]] || {
  echo "Developer ID identity SHA-1 could not be parsed" >&2
  exit 1
}
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || {
  echo "Developer ID Team ID could not be parsed from the certificate common name" >&2
  exit 1
}
[[ "$notarytool_state" == "AVAILABLE" ]] || {
  echo "xcrun notarytool is unavailable" >&2
  exit 1
}

json="$(
  /usr/bin/python3 - "$identity_sha1" "$identity_name" "$team_id" "$xcode_path" "$xcode_version" "$swift_version" "$codesign_version" <<'PY'
import json, platform, subprocess, sys
identity_sha1, identity_name, team_id, xcode_path, xcode_version, swift_version, codesign_version = sys.argv[1:]
print(json.dumps({
    "schema": "forge-platform.macmini-runner-readiness/v1",
    "architecture": platform.machine(),
    "macos_version": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
    "xcode_path": xcode_path,
    "xcode_version": xcode_version,
    "swift_version": swift_version,
    "codesign_version": codesign_version,
    "developer_id_application": {
        "certificate_sha1": identity_sha1,
        "common_name": identity_name,
        "team_id": team_id,
    },
    "notarytool": "AVAILABLE",
}, indent=2, sort_keys=True))
PY
)"

if [[ -n "$OUT" ]]; then
  mkdir -p "$(dirname "$OUT")"
  printf '%s\n' "$json" > "$OUT"
  chmod 600 "$OUT"
else
  printf '%s\n' "$json"
fi
