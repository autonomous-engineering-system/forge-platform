#!/bin/bash
# Source-only library for the protected offline signer. No standalone action.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "HELPER_PACKAGE_SIGNING=FAIL reason=protected-caller-required" >&2
  exit 64
fi

select_helper_package_identity() {
  local private="$1" team="$2"
  [[ -n "${FORGE_PLATFORM_INSTALLER_SIGNING_IDENTITY:-}" ]] || return 1
  /usr/bin/security find-identity -v -p basic >"$private/installer-identities.txt" 2>"$private/installer-identity-error.txt" || return 1
  python3 - "$private/installer-identities.txt" "$team" <<'PYCODE'
import os,sys
from pathlib import Path
from scripts.installer_package_signing_metadata import select_installer_identity
with Path(sys.argv[1]).open(encoding="utf-8") as stream:
    raw=stream.read(65537)
try:print(select_installer_identity(raw,os.environ["FORGE_PLATFORM_INSTALLER_SIGNING_IDENTITY"],sys.argv[2]))
except (ValueError,KeyError):raise SystemExit(1)
PYCODE
}

sign_helper_package() {
  local app="$1" archive="$2" version="$3" source="$4" destination="$5" private="$6" team="$7" identity="$8" archive_digest="$9"
  local unsigned="$private/helper-package-candidate.pkg"
  local package="$destination/forge-platform-installer-helper-arm64.pkg"
  local receipt="$destination/helper-package-evidence.json"
  [[ ! -e "$package" && ! -L "$package" && ! -e "$receipt" && ! -L "$receipt" ]] || return 1
  [[ "$identity" =~ ^[0-9A-F]{40}$ && "$team" =~ ^[A-Z0-9]{10}$ && "$archive_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  python3 scripts/prepare_macos_helper_package.py --app-bundle "$app" \
    --output "$unsigned" --version "$version" --source-revision "$source" \
    >"$private/helper-package-candidate.json" 2>"$private/helper-package-candidate-error.log" || return 1
  # Refuse a mismatched candidate before any package signing/notary effect.
  python3 - "$unsigned" "$archive" "$version" "$source" "$archive_digest" <<'PYCODE'
from hashlib import sha256
import os,sys
from pathlib import Path
from types import SimpleNamespace
from scripts.installer_helper_package_payload import verify_payload
from scripts.verify_installer_release_evidence import _bundled_release_provenance
archive=Path(sys.argv[2]);provenance=_bundled_release_provenance(archive)
preparation=SimpleNamespace(installer_version=sys.argv[3],source_revision=sys.argv[4],provenance_sha256=provenance.provenance_sha256)
digest=sys.argv[5]
fd=os.open(sys.argv[1],os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW)
try:verify_payload(fd,archive=archive,preparation=preparation,archive_digest=digest)
finally:os.close(fd)
PYCODE
  [[ "$?" == 0 ]] || return 1
  bounded "$private/productsign.log" /usr/bin/productsign --sign "$identity" --timestamp "$unsigned" "$package" || return 1
  chmod 600 "$package" || return 1
  python3 - "$private/helper-package-notary.json" "$private/helper-package-notary-error.log" "$package" <<'PYCODE'
import os,subprocess,sys
with open(sys.argv[1],"wb") as output,open(sys.argv[2],"wb") as error:
    try:
        result=subprocess.run(["/usr/bin/xcrun","notarytool","submit",sys.argv[3],"--keychain-profile",os.environ["FORGE_PLATFORM_NOTARYTOOL_PROFILE"],"--wait","--output-format","json"],stdin=subprocess.DEVNULL,stdout=output,stderr=error,timeout=3600,check=False)
    except (OSError,subprocess.TimeoutExpired,KeyError):raise SystemExit(1)
raise SystemExit(0 if result.returncode==0 else 1)
PYCODE
  [[ "$?" == 0 ]] || return 1
  local notary
  notary="$(python3 - "$private/helper-package-notary.json" <<'PYCODE'
from pathlib import Path
import sys
from scripts.installer_package_signing_metadata import accepted_notary_identifier
try:
    with Path(sys.argv[1]).open("rb") as stream:print(accepted_notary_identifier(stream.read(65537)))
except (OSError,ValueError):raise SystemExit(1)
PYCODE
)" || return 1
  bounded "$private/helper-package-staple.log" /usr/bin/xcrun stapler staple "$package" || return 1
  # The existing inspector independently rechecks Apple Installer/team, staple,
  # Gatekeeper, all payload bytes and archive/provenance binding after signing.
  python3 - "$package" "$archive" "$version" "$source" "$team" "$notary" "$receipt" "$archive_digest" <<'PYCODE'
from hashlib import sha256
import json,os,sys
from pathlib import Path
from types import SimpleNamespace
from scripts.verified_installer_helper_package import read_descriptor
from scripts.verify_installer_release_evidence import _bundled_release_provenance
archive=Path(sys.argv[2]);provenance=_bundled_release_provenance(archive)
preparation=SimpleNamespace(installer_version=sys.argv[3],source_revision=sys.argv[4],provenance_sha256=provenance.provenance_sha256)
value=read_descriptor(Path(sys.argv[1]),team=sys.argv[5],notarization_reference="receipt:apple-notary-"+sys.argv[6],archive=archive,preparation=preparation,archive_digest=sys.argv[8])
with open(sys.argv[7],"x",encoding="utf-8") as stream:
    json.dump(value,stream,sort_keys=True,separators=(",",":"),allow_nan=False);stream.write("\n");stream.flush();os.fsync(stream.fileno())
os.chmod(sys.argv[7],0o600)
PYCODE
}
