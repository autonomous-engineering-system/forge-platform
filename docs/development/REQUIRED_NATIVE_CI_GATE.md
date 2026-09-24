# Native tests as an actual merge prerequisite

Assignment: `L1-FORGE-PLATFORM-MANAGED-INSTALLER-V1-20260923`, existing PR #75.

## Measured starting point

At `3caa68be81781dd27fb6a58f789f31455e8b2976`, GitHub-hosted native run
`35865059468`, job `107194450543`, passed 30 CI-gate regressions, all 265 Swift
tests and every enforced changed-file coverage threshold, including the app
startup bridge at 263/273 executable lines (96.336996%). No exclusion was added.
Foundation, CodeQL, canonical versioning and TDE also passed at that source.
These are native hosted and fixture results, not Mac-mini or release evidence.

Public readback of active main ruleset `22000450` showed one required check:
`Foundation validation`. The separate Swift job was not independently required.
A green standalone native workflow therefore did not make native tests a merge
prerequisite under the actual current ruleset.

## Required-check wiring

Foundation now executes the entire Python repository validation and invokes the
native macOS suite as a local reusable workflow from the same commit. Native
validation retains its exact Git baseline, line-count-authoritative strict
>80.2% gate and all test/screenshot steps. Both suites are GitHub-hosted with
read-only contents permissions; neither receives signing credentials. There is
no duplicated independent native PR trigger, path filter or allowed failure.

The final job retains the exact existing required context `Foundation validation`.
It uses `always()` and needs both suites. Only two explicit `success` results
permit its PASS. Failed, skipped, cancelled, absent or unknown results fail.
The existing strict-main ruleset and its no-bypass protections are unchanged.

Four additional tests execute the actual inline shell gate across 64 result
pairs plus missing environment values, and verify workflow and entrypoint
binding. They join the previous 30 regressions in both Foundation and native CI.
This measures rejection control flow; it does not claim that a GitHub workflow
was deliberately cancelled or that a forbidden merge was attempted.

Native execution of this aggregation revision must be read back separately.
Its status is not inferred from the preceding successful source. This is an
implementation-time checkpoint; final measured evidence is recorded in PR #75
and the canonical `pcvantol/forge#141` register.

Mac-mini terminal access, runner registration, external dispatch authorization,
protected Environment server-side setup, real runner-account Keychain/notary
readiness and reboot persistence remain unverified. Do not activate the signer
bootstrap on the strength of labels or workflow text. No production release,
provider login, signing, notarization, producer mutation, Mission-3, reset or T0
is performed by this increment.
