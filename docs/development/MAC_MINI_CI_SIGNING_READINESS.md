# Native Mac mini CI and signing readiness

Assignment: `L1-FORGE-PLATFORM-MANAGED-INSTALLER-V1-20260923`.
Register: `pcvantol/forge#141`; existing delivery: `pcvantol/forge-platform#75`.
This increment changes CI gates and tests, not the release identity or product contracts.

## Execution boundaries

Ordinary pull requests run on GitHub-hosted native `macos-26`, never the
credential-bearing Mac mini. The Foundation entrypoint also executes the
CI-gate regressions. Test failures and coverage failures are hard job failures;
there is no `continue-on-error` or unsigned release fallback.

Manual Mac-mini qualification requires a workflow dispatched from protected
`main`, with workflow SHA and source SHA equal to the exact reviewed source.
A GitHub-hosted admission job checks the current main ref before a privileged
job is allocated. The integration runner uses the protected
`forge-platform-installer-integration` Environment; the signer uses the separate
`forge-platform-installer-signing` Environment. Both require the preceding job,
disable persisted checkout credentials, and recheck the current main ref after
approval. The qualification slice has an explicit exact ancestor coverage SHA.

These are workflow-level guards, NOT a complete runner access-control policy.
Labels select runners; they do not authorize code. In particular, another
PR-editable workflow in this public repository must not be able to schedule
code on the signer. Do not execute `bootstrap_macos_signing_runner.sh` or start
an existing credential-bearing runner until external dispatch isolation and
Environment protections have been inspected and proven. An additional Boolean
variable or self-written local receipt is not evidence of those protections.
Any required change in repository/organization control architecture requires an
explicitly reviewed decision; do not silently move repositories or broaden scope.

Use exclusive `forge-platform-macmini-privileged` concurrency for native qualification.
The installer release workflow has its own exclusive release concurrency and now routes
its credential-bearing signing stage to the same isolated `forge-platform-signer`
runner account. The signing stage remains intentionally blocked until live host evidence
and protected signing/notarization publication wiring are qualified.
Persistent-host cleanup/isolation and reboot persistence still require physical
runner evidence. A clean checkout does not prove a clean host. Preserve useful
signing/runner state; fresh-install acceptance needs an isolated target strategy.

## Coverage and regression gates

`check_managed_installer_swift_coverage.py` retains the existing four-file managed
slice and adds all three changed startup/self-update production files. Supplying
`--base-ref` adds every changed or newly added Swift production file (renames are
seen as delete/add); a missing/invalid supplied Git baseline fails closed.
Both native validation workflows supply an exact baseline. Missing or duplicate
coverage records, malformed counts, non-finite percentages, zero executable
lines and percentages inconsistent with counts fail closed. The actual
covered/executable ratio must be strictly greater than 80.2%; the rounded
LLVM display percentage cannot grant authority. No exclusion was added.

`tests/foundation/test_ci_gate_regressions.py` has 30 tests covering the checker,
real temporary Git diff discovery, subprocess signing/notary simulations,
wrong/ambiguous identities, failed signature/Apple-anchor checks, interrupted
signing, wrong signed Team/bundle metadata, invalid notary readback, secret-output
suppression, private-probe cleanup and workflow wiring. It runs through
`scripts/validate.sh` and through native hosted macOS CI.

The read-only SwiftUI rendering fixture follows the real currency transition
before showing execution or summary. Three additional native tests cover the
required recheck after provider verification, invalidation by a newer installer
and a failed currency readback. These are fixture/domain integration evidence,
not live provider login or product-dispatch acceptance.

## Signing readiness, not notarization acceptance

`verify_macos_signing_runner.sh` records architecture, macOS, selected Xcode,
full Xcode build version and SDK under the actual runner account. It requires a
configured notarytool Keychain profile. One exact Developer ID identity must
match the selected fingerprint/name and expected Team on the same certificate.
It signs a private test-owned app by fingerprint with closed stdin and bounded
execution, verifies the signature and Apple trust requirement, and independently
reads back the signed Team and bundle identifier. Notarytool authentication is
checked via a private JSON history readback. No private key export, Keychain ACL
change or raw credential logging is performed.

A successful readiness probe explicitly retains:

```
NOTARIZATION_ACCEPTANCE=NOT_RUN
RUNNER_REBOOT_PERSISTENCE=NOT_VERIFIED
```

Only actual Apple submission/readback for the release artifact, followed by
stapling, validation, publication and remote digest readback, can qualify the
release. Xcode GUI account configuration alone cannot promote
`installer-release-identity.json` to `READY`.

## Evidence at implementation time, 2026-09-23

The 30 Python regression tests passed in an isolated Linux execution. Coverage
of the changed Python Swift-coverage checker was 85/86 executable statements
(98.84%); the unexecuted line in that measurement is its `__main__` exit wrapper.
The subprocess CLI was separately exercised by tests. Shell syntax and workflow
YAML syntax were checked locally. This is not native macOS or real signing evidence.
The Swift rendering fixture was reconstructed from exact head
`6a39ab1fd5e90779741cbd4debb3306bd2ad787a`; its pre-edit blob hash was verified as
`81fac324592972c1ed3097a20ebd6f28fea1b37c` before applying the bounded change.
Hosted validation of the resulting commit is a separate evidence checkpoint.

No Mac-mini terminal connection was available in this execution. Consequently
runner registration, external dispatch restrictions, Environment configuration,
actual Keychain/notary access, reboot, provider login, artifact signing,
notarization and release publication were not performed. Forge/EP/Workspace
source and all production deployments remain untouched. No Mission-3, reset or
T0 is authorized by this increment.
