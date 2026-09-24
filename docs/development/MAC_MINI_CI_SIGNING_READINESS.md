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
The local installer and composition-catalog publishers share one persistent
exclusive offline-signing lock, while each retains its own durable journal.
Exact-main is checked before signing and again before publication.

The catalog workflow uses the same credentialless runner group and protected
non-secret Environment handoff. Its private Ed25519 key remains a separate
this-device-only item in the local signer Keychain. Source qualification of
that route does not imply a live feed: no catalog may be published until a
reviewed composition manifest and component index bind complete immutable
producer and managed-runtime evidence. See
[`COMPOSITION_CATALOG_RELEASE.md`](COMPOSITION_CATALOG_RELEASE.md).

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

`scripts/ci/install_macos_build_runner_launchdaemon.sh` installs the configured
runner in the system launchd domain while retaining `forgebuild` as its
non-admin runtime identity. Automatic GUI login must be disabled. The official
per-user `svc.sh`/LaunchAgent path is rejected because it cannot establish
pre-login reboot persistence.

`scripts/ci/verify_macos_build_runner_reboot.sh record` captures a private
pre-reboot baseline. After an actual reboot,
`scripts/ci/verify_macos_build_runner_reboot.sh verify` requires a changed boot
identity, a running service, the exact runner name, and continued absence of a
Developer ID identity from the build account. A service status check without a
real reboot does not satisfy this gate.

The signer account has a separate two-phase verifier,
`scripts/ci/verify_macos_offline_signer_reboot.sh`. `record` captures the exact
boot identity, protected-main source, Team, notary profile and public trust
digests only after live signing/notary/key readiness. After a real reboot,
`verify` requires a changed boot identity and reruns Developer ID signing,
notary history, exact-main, descriptor-key and separately scoped catalog-key
readback before it can report `OFFLINE_SIGNER_REBOOT_READINESS=PASS`.

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
- PR #75 and its runner, coverage, service, and signing-readiness follow-ups
  through PR #84 are merged; exact protected `main` is
  `a9e0f21f5b1b5b2eca99845e94e81134339bbb4a` and its required checks are green;
- organization runner group `forge-platform-build` exists as group 3, permits
  exactly this one public repository, and is restricted to the native build and
  installer release workflows at `refs/heads/main`;
- the credentialless runner completed exact-main native tests, changed-file
  coverage, and unsigned GUI plus CLI packaging successfully after reboot.

Verified locally:

- Mac mini `macmini-m6` is Apple Silicon and runs macOS 27.0;
- standard non-admin account `forgebuild` runs the build runner as the
  no-login system LaunchDaemon
  `org.autonomous-engineering-system.forge-platform.build-runner`; automatic
  login is disabled;
- a real reboot changed the boot identity and the runner returned before login;
  the live verifier reported `BUILD_RUNNER_REBOOT_PERSISTENCE=PASS` while the
  build account still had no Developer ID identity;
- signer account `pcvantol` has Developer ID Application Team `ZEML4LPXH4` and
  the noninteractive `forge-platform-installer-notary` profile; the build
  account has neither credential;
- a temporary hardened-runtime app was signed, accepted by Apple notarization
  as submission `2e813227-d54a-4d72-a0c6-295aa9414414`, stapled, and accepted
  by Gatekeeper;
- separate descriptor and composition-catalog Ed25519 keys were provisioned as
  non-synchronizing, when-unlocked-this-device-only items under separate local
  Keychain services. Rebuilt Developer ID signed helpers read them
  noninteractively without exporting private bytes or changing Keychain ACLs;
- the public key policies, Team, bundle, and GitHub namespace now bind the
  committed `READY` identity and both strict public trust resources.

Still unverified:

- signer-account credential readiness after a subsequent reboot;
- exact release-candidate signing, Apple notarization, stapling and Gatekeeper
  acceptance for the production installer artifact;
- GitHub Release publication and remote public asset digest readback.

`installer-release-identity.json` is `READY` because the live host evidence and
matching public trust facts now exist. `READY` authorizes the protected release
flow; it does not claim that a production installer release has passed. The
remaining production artifact and publication evidence stays explicitly open
until the exact release flow completes.
