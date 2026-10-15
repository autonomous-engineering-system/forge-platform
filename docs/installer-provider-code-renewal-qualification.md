# Provider device-code renewal: bounded source qualification

Date: 2026-10-15. Base: `259c259a3709e745fc98dc6a4e8851c67a893973`.
Authority: the user's explicit request to add a safe renewal route. Scope is
installer source and unsigned qualification. No publication, signing cycle,
helper replacement, VM retry, account mutation or historical journal reset.

## Installed finding and historical boundary

A real Codex ceremony on 0.4.23 reached its 15-minute deadline. The helper killed
its authentication group and persisted `uncertain=true`. A subsequent request
for the same operation spent several minutes in signature admission, then returned
`provider-authentication-required` without a challenge. Provider status remained
AUTHENTICATION_REQUIRED. The operation's parent journal remained PLANNED.

The old v1 effect record has no retained authentication-specific terminal proof.
Its uncertainty is NOT reclassified, removed, or made retryable by this change.
The already affected VM remains blocked. This increment cannot be installed over
that state or authorize its cleanup by itself. No new code was obtained on the VM.

## Implemented route

1. The existing helper admits a fixed Codex file-backed login under a dedicated
   component account. The route does not apply to GitHub/Keychain ceremonies or
   to a named operator account (including Forge-only authentication).
2. A real parsed challenge establishes the private process group. The helper
   captures its kernel owner and process incarnation before any later deadline
   signal. An unproven or changed process identity remains uncertain and is not
   signalled by the new path.
3. A controlled deadline, or a normal nonzero Codex exit after that challenge,
   becomes a retained expired ceremony. It is not an authenticated result. The
   actual termination callback must run; the effect reservation stays active.
4. On another request for the SAME operation and provider target, the helper
   independently re-admits the original immutable plan, account, executable and
   provider home, and requires fresh AUTHENTICATION_REQUIRED readback. A crossed
   target, plan drift or now-VERIFIED target cannot use this route.
5. The old group must be absent and a fresh kernel account-process query must
   show no process at all under the dedicated UID. Escaped descendants under that
   account also block renewal. Both checks are repeated before retiring the ID.
6. Under the existing effect lock, the helper requires the exact sole active ID
   and `uncertain=false`. It exclusively creates and fsyncs an immutable expiry
   receipt containing the original canonical effect-record bytes. Only then can
   it retire that one reservation. No uncertainty flag is cleared.
7. The normal admission path starts a new provider-owned ceremony. Existing
   single-login EP/Forge fanout and independent verification remain required.
   Code values, provider output and credential files do not enter receipts.

The same supported CLI `deployment apply --deployment <same-id>` path requests
renewal; it must be interactive (without `--json`/`--non-interactive`). No new
operation, direct provider invocation, fixture backend, trust exception or cache
copy is introduced. The GUI already calls the same reviewed helper entrance;
no live GUI renewal claim is made here.

## Failure and restart behavior

Unknown historical uncertainty, missing session identity, active account/group,
failed physical readback, concurrent reservation, failed journal/receipt write,
receipt collision and helper restart before terminal proof remain closed.
An expiry before the first challenge reply, or an explicit cancellation of an
already expired session, retains the only session-bound renewal proof.
A crash after receipt creation but before ID retirement leaves the reservation
unresolved. Receipts cannot authorize replay or reconstruct a lost session.
Unexpected signals, oversized/missing challenges, unsupported accounts/providers
and uncertain bootstrap effects retain existing sticky negative evidence.

## Qualification

Command (unsigned local source/process qualification):

```sh
swift test --package-path macos/ForgePlatformInstaller --filter 'ManagedInstallerProviderAuthenticationRenewalTests|ManagedInstallerProviderAuthenticationSessionTests|ManagedInstallerProductWorkerEffectJournalTests|ManagedInstallerFreshInstallRuntimeAdmissionTests|ManagedInstallerHelperChildExitRegistryTests|ManagedInstallerReleasedRouteXPCTests'
```

Final result: **91 tests, zero failures, zero skips**.

| Evidence | Result | Boundary |
| --- | --- | --- |
| Real local process-group deadline, termination callback and second child launch | PASS | Synthetic device prompt, no official provider login |
| Natural unsuccessful exit after a challenge | PASS | Requires fresh admission; not successful authentication |
| Real kernel UID/group quiescence reader | PASS | Live UID denied; unused UID accepted; no account creation |
| Same-operation actor renewal and crossed/VERIFIED target denial | PASS | Modeled immutable plan/provider observations |
| Canonical original bytes preserved, collision/replay/concurrency/legacy uncertainty denial | PASS | Real private local file journal |
| Existing child-exit, provider-session and released XPC regressions | PASS | Local unsigned tests |
| Published CLI/GUI renewal on clean VM; single-provider named-user renewal | NOT QUALIFIED | Requires separate delivery/runtime scope; named-user path remains unsupported |

This is a qualification addendum to `roadmap/installer-feature-test-matrix-v1.json`,
not a LIVE_PASS for its provider or installation cases. Slow signature admission
and a specific user-facing diagnostic for a nil challenge remain separate findings.

## Open performance finding

The real GUI pre-login delay is tracked separately in
[the Codex admission-delay finding](installer-codex-admission-delay-finding.md).
Status: OPEN; recording it does not establish a performance fix or runtime PASS.
