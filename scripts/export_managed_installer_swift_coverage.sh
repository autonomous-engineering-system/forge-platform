#!/bin/bash
# Export one LLVM coverage document spanning every SwiftPM installer test bundle.
set +x
set -euo pipefail
umask 077

fail() { echo "MANAGED_INSTALLER_SWIFT_COVERAGE_EXPORT=FAIL reason=$1" >&2; exit 1; }
[[ "$#" == 1 ]] || fail output-path-required
output="$1"
[[ "$output" == /* && "$output" != *$'\n'* ]] || fail output-path-must-be-absolute
output_parent="$(dirname "$output")"
[[ -d "$output_parent" && ! -L "$output_parent" ]] || fail output-parent-invalid
[[ ! -e "$output" && ! -L "$output" ]] || fail output-already-exists

reported="$(swift test --show-codecov-path)"
[[ "$reported" == /* && -f "$reported" && ! -L "$reported" ]] || fail swiftpm-coverage-path-invalid
coverage_root="$(dirname "$reported")"
products_root="$(dirname "$coverage_root")"
profile="$coverage_root/default.profdata"
[[ -f "$profile" && ! -L "$profile" ]] || fail merged-profile-unavailable

binaries=()
aggregate_product="ForgePlatformInstallerPackageTests"
aggregate_binary="$products_root/$aggregate_product.xctest/Contents/MacOS/$aggregate_product"
if [[ -f "$aggregate_binary" && -x "$aggregate_binary" && ! -L "$aggregate_binary" ]]; then
  # Xcode 26 emits one aggregate SwiftPM test bundle.
  binaries+=("$aggregate_binary")
else
  # Xcode 27 emits one bundle per explicit test target.
  products=(
    ForgePlatformInstallerTests
    ForgePlatformInstallerCoreTests
    ForgePlatformInstallerCLITests
  )
  for product in "${products[@]}"; do
    binary="$products_root/$product.xctest/Contents/MacOS/$product"
    [[ -f "$binary" && -x "$binary" && ! -L "$binary" ]] || fail "test-bundle-unavailable-$product"
    binaries+=("$binary")
  done
fi

coverage_objects=("${binaries[0]}")
for binary in "${binaries[@]:1}"; do
  coverage_objects+=(-object "$binary")
done

temporary="$(mktemp "$output_parent/.swift-coverage.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
xcrun llvm-cov export \
  -instr-profile="$profile" \
  "${coverage_objects[@]}" >"$temporary"

python3 - "$temporary" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
if not isinstance(payload, dict) or not isinstance(payload.get("data"), list) or not payload["data"]:
    raise SystemExit("combined LLVM coverage has no data")
if not any(isinstance(block, dict) and isinstance(block.get("files"), list) and block["files"] for block in payload["data"]):
    raise SystemExit("combined LLVM coverage has no files")
PY

mv "$temporary" "$output"
trap - EXIT
echo "MANAGED_INSTALLER_SWIFT_COVERAGE_EXPORT=PASS bundles=${#binaries[@]} output=$output"
