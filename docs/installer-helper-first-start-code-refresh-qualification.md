# Helper first-start acknowledgement and explicit Codex code refresh

Status: SOURCE_QUALIFIED; not a published or installed acceptance result.
Baseline: installer 0.4.25, protected source `700aec711398fe79e9b40888ded6bd00c0d61403`.

## First-start defect and correction

A clean first helper preparation can stop after package exit 0 and activation, without receiving verified running acknowledgement. A subsequent manual helper check independently admits the installed helper. `MacOSInstallerHelperPackagePreparation` previously returned `unresolved` immediately after the missing acknowledgement.

After that single submitted attempt, preparation now performs at most three independent installed-helper reads, separated by 250 ms when no result is available. Each read retains current app/release, reviewed epoch, operator and cancellation checks. Foreign evidence remains rejected. No stage, authorization, installation or activation is repeated. Successful readback completes the displayed preparation stages. Historical bootstrap records are not synthesized, erased or rewritten.

The precise reason the original bootstrap did not acknowledge activation is not claimed to be a proven timing race. The corrected frontend closes the demonstrated control-flow gap using the same authority as the supported manual check.

## Code refresh

The customer device-code screen has an explicit **Ververs code** action. It hides the old code while checking the same reviewed operation. A successful existing login is completed and returned before attempting renewal. Duplicate clicks, changed installer currency, foreign readback and stale reviewed context cannot start renewal.

A separate typed `renewReviewedProviderAuthentication` call crosses the existing coordinator, authenticated XPC and named-operator ownership boundary. Renewal is a new ceremony for upgrade-drain admission, not a terminal-completion exemption. Older transports and unsupported authentication sessions reject it.

For the existing supported Codex file-backed session under a dedicated component account, the helper freshly re-admits the exact original target, requests the existing bounded expiry mechanism, waits for its registered child-exit observation, then uses the existing append-only expiry receipt and fresh physical status checks before requesting a new official challenge. No provider credential material is sent to the frontend or added to diagnostics.

### Remaining renewal limits

GitHub/Keychain sessions and Codex sessions under a named operator do not yet have the same admitted expiry/quiescence route. Their renewal remains rejected; the GUI retains a refresh/status action and does not restore an invalidated code. This increment must not be described as full provider-renewal acceptance. Historical uncertain records are not cleared. A helper crash that loses the original in-memory session still requires separately admitted recovery.

## Qualification

132 relevant tests passed: 23 GUI/AppKit tests and 109 helper/provider/route tests. These cover the real effect-journal writer, package coordinator, missing acknowledgement, delayed and absent readback, foreign release, revoked operator/epoch/current app, cancellation, one authorization/install/activation, code replacement UI, repeated clicks, completed-login precedence, and exact-session Codex renewal with a real disposable child and preserved old effect bytes.

The new first-start regression fails behaviorally against unchanged 0.4.25 source and passes with the correction. Additional XPC regressions exercise explicit renewal through an anonymous test connection, malformed input, ownership and upgrade-drain refusal. These source test connections are not published trust or runtime acceptance evidence.

An actual AppKit render of the customer code screen was visually inspected. Synthetic test challenge values are used only for source rendering. This is not a live GUI installation PASS.

## Delivery boundary

No public source delivery, release cycle, helper transition or new VM operation is included in this source qualification. The existing manual GUI test still uses published 0.4.25. The separate Forge projectless scheduler readiness defect remains open with its existing source owner.


## Follow-up: real process-tree refresh regression (2026-10-16)

The public 0.4.26 GUI advanced automatically past helper preparation, but its
first real Codex refresh did not complete. The authentication wrapper exited
while its provider survived, reparented to PID 1 in a separate process group.
The original effect reservation correctly remained active. Earlier synthetic
session tests did not exercise the production wrapper's Foundation `Process`
launch and therefore did not establish real process-tree renewal acceptance.

The source follow-up is documented in
[Codex refresh process ownership qualification](installer-codex-refresh-process-ownership-qualification.md).
It is an unsigned source qualification, not a published installer or live-VM
refresh PASS. The running VM, its pending authentication record and historical
journals are retained. No manual process signal or new installer attempt is
included in this source increment.
