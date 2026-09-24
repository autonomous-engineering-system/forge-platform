# Native Mac mini CI and local signing readiness

Assignment: `L1-FORGE-PLATFORM-MANAGED-INSTALLER-V1-20260923`.
Register: `pcvantol/forge#141`; delivery: `autonomous-engineering-system/forge-platform#75`.
This document distinguishes implemented controls from live evidence. A source
test, static check, or simulated Apple command is never reported as a live pass.

## Security boundary

Pull requests and ordinary validation stay on GitHub-hosted macOS runners. The
Mac mini Actions account is a credentialless build account. It has no Developer
ID private key, no notarytool profile, no descriptor-signing private key, and no
GitHub publication credential. The intended organization runner group
`forge-platform-build` is restricted to this repository and the exact reviewed
workflows on protected `main`. GitHub can create that restriction only after
both workflow files exist on `main`; the group remains absent until then.

Developer ID signing, notarization, stapling, Gatekeeper assessment, descriptor
signing, GitHub Release publication, and remote digest readback run only from a
separate local macOS signer account. That account is not an Actions runner.
Separate macOS accounts and Keychains supply the credential boundary; runner
labels are routing metadata only.

## GitHub authorization boundary

The release workflow admits only
`autonomous-engineering-system/forge-platform`, `refs/heads/main`, a protected
ref, and an exact equality between source SHA, workflow SHA, and dispatch SHA.
The credentialless Mac mini runs native tests, the enforced changed-file
coverage gate, and unsigned GUI plus CLI packaging.

A later GitHub-hosted job uses the protected
`forge-platform-installer-signing` Environment. It contains no Apple or
publication secret and performs no signing. After required-reviewer approval it
emits a non-secret authorization bound to the exact run, run attempt, workflow
SHA, source SHA, candidate artifact name, archive name and archive digest. The
local signer accepts the candidate only after independently reading back the
successful workflow and both required job conclusions from GitHub.

The organization runner group and workflow concurrency serialize build routing.
The local signer has an additional persistent exclusive signing lock and a
durable installer release journal. Exact-main is checked before signing and
again before publication.

## Local Apple and publication chain

`scripts/ci/verify_macos_offline_signing_host.sh` refuses every Actions context. Under
the exact configured signer account it selects one Developer ID Application
identity, verifies the Team ID, signs a private probe noninteractively, verifies
the Apple requirement and signed metadata, and checks the notarytool Keychain
profile through bounded private output. It never exports a private key, reads a
password into logs, or changes a Keychain ACL.

`scripts/run_local_macos_installer_release.sh` then performs the authorized
release chain:

1. verify exact protected-main GitHub authorization and candidate digest;
2. recheck local signer readiness and acquire exclusive local concurrency;
3. sign GUI, CLI and app with hardened runtime and secure timestamp;
4. verify bundle, Team, signature and full CodeDirectory SHA-256;
5. submit with the noninteractive notarytool Keychain profile and require
   `Accepted`;
6. staple, validate, run Gatekeeper assessment, and rebuild the final archive;
7. create and cryptographically Ed25519-sign the exact release descriptor;
8. structurally verify descriptor, code-signed provenance, archive and durable
   qualification operation;
9. create an exact-target draft GitHub Release, upload, download and compare all
   assets;
10. record publication evidence, publish the draft, download the public assets,
    and compare every byte again.

Descriptor keys are stored as this-device-only items in the dedicated signer
account Keychain. The reviewed helper exposes only their public keys and
signatures; it never exports private key bytes or weakens a Keychain ACL. Each
public key must match the code-signed public release-trust resource.

## Reboot persistence

`scripts/ci/verify_macos_build_runner_reboot.sh record` captures a private
pre-reboot baseline. After an actual reboot,
`scripts/ci/verify_macos_build_runner_reboot.sh verify` requires a changed boot
identity, a running service, the exact runner name, and continued absence of a
Developer ID identity from the build account. A service status check without a
real reboot does not satisfy this gate.

## Current live evidence, 2026-09-24

Verified in GitHub:

- repository transferred to
  `autonomous-engineering-system/forge-platform` and remains public;
- organization Actions defaults are read-only and restricted to reviewed
  actions, full commit SHAs, and approval for all external contributors;
- repository-level self-hosted runners are disabled at organization level;
- protected Environment `forge-platform-installer-signing` exists, requires
  reviewer `pcvantol`, has admin bypass disabled, has no secrets, and allows
  only branch `main`;
- GitHub rejected creation of `forge-platform-build` while both allowlisted
  workflow files exist only on PR #75, reporting that the first exact workflow
  does not exist at `refs/heads/main`. No group or broader temporary workflow
  access was created. The safe order is protected merge first, then exact-main
  group creation, then credentialless runner registration.

Verified locally:

- Mac mini `macmini-m6` is Apple Silicon and runs macOS 27.0;
- shell and Python syntax checks pass for the new controls;
- workflow YAML parses successfully;
- 8 runner policy tests, 31 CI gate regressions, and 4 release workflow tests
  pass in local simulation.

Still unverified:

- organization runner group creation and its live workflow restriction;
- credentialless build-account registration and first real workflow run;
- real post-reboot runner persistence;
- dedicated signer-account Developer ID/keychain/notary readiness;
- exact real artifact signing, Apple notarization acceptance, stapling and
  Gatekeeper acceptance;
- GitHub Release publication and remote public asset digest readback.

Accordingly `installer-release-identity.json` remains exactly
`UNCONFIGURED`. It may become `READY` only after the live signer evidence,
public Team/bundle/key policy, and matching public release-trust resource have
been reviewed and committed.
