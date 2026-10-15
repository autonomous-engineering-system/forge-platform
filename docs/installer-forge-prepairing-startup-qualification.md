# Forge startup before installation pairing: source qualification

Date: 2026-10-15. Parent source: `43e68f3`. Public installed observation: 0.4.23.
Status: **SOURCE_IMPLEMENTED / UNSIGNED_QUALIFIED; published runtime acceptance OPEN**.
Authority: the user requested autonomous implementation of the recorded findings
and correction of the failed installation. Historical journals, worker uncertainty,
release budgets and runtime maintenance limits remain in force.

## Root cause and physical evidence boundary

A released Forge 2.8.1 installation profile can correctly report its provider
ready while its scheduler waits for an unconfigured installation peer with
`PeerConfigurationError`. That intermediate product contract is reproduced by
the source regression below. Machine-specific diagnostics and historical
operation records are retained privately, outside public source documentation.

The installer had two related defects:

1. Startup queried the legacy readiness profile, whereas later readback already
   selected the qualified installation-only profile.
2. The pre-pairing barrier required service readiness. The released scheduler
   cannot be ready without its peer, while pairing was scheduled only after that
   barrier. This circular dependency prevented the following pairing step.

This evidence proves neither a completed installation nor completed pairing.
The original failed operation is not retried, rewritten or made replayable by
this source correction. Its unresolved worker result remains unresolved.

## Implemented correction

- One profile selection method is shared by startup and readback. The exact
  qualified released 2.8.1 artifact uses `/v1/readiness/installation`; legacy
  artifacts retain their existing profile. Endpoint authentication, no-redirect
  policy, response bounds and exact runtime identity validation remain intact.
- Before pairing, the exact installation contract may report an intermediate
  `INSTALLED_UNPAIRED / AWAITING_PEER` state. Provider readiness is required.
  The scheduler must either be ready or report precisely `NOT_READY` with
  `PeerConfigurationError`. Unknown failures, wrong instance, contradictory
  booleans, extra project/execution authority and invalid peer state still fail.
- The official product `installation-peer show` must independently confirm
  `NOT_CONFIGURED` and `execution_ready=false`. A configured or unknown peer
  cannot use this missing-peer classification.
- The install receipt does not claim terminal readiness. The existing pairing
  and final-readiness gates remain responsible for real connected results.
- A closed Forge startup failure code reaches the GUI without copying raw
  command output, process environments, credentials or device codes.

No Forge/EP source, lifecycle implementation, trust key, credential route,
service account, installed file, helper or live operation was changed.

## Progress and performance findings implemented in the same source increment

- Ordered preparation, selected components, pairing (when selected together) and
  final-readiness rows. Overall failure is separate from the chronological list.
- The first row represents preparation, rather than a bottom aggregate falsely
  appearing to execute before EP. Pending rows say what they are waiting for.
- Actual adapter events publish service preparation, official component creation,
  registration, start and service/provider verification. Fixed codes cross the
  existing private progress route; arbitrary product streams remain forbidden.
- A progress bar counts completed steps, explicitly labelled as completed steps;
  it is not a guessed elapsed-time percentage or completion-time promise.
- Provider preparation text describes local preparation/checks rather than
  implying a slow provider login request has already started.
- Three independent sealed-resource reads overlap. Each keeps both original
  full signature checks, plus the existing outer parent checks. A regression
  requires all six calls and overlapping first checks. No trust cache is added.
- Fixed-name monotonic timing logs cover sealed-resource reads, current-release
  admission, existing provider-target admission and product-worker execution.
  These logs contain only phase name and milliseconds, no target or credential.
- The follow-up provider-admission consolidation is now implemented and unsigned
  qualified after the user's instruction to continue. Initial dual-Codex full
  group reads fall from seven to two; three plan loads and two physical-target
  resolutions bracket the transaction. The unchanged full reader independently
  rejects every material/currentness failure position. See
  [its qualification](installer-provider-admission-consolidation-proposal.md).

The earlier bounded device-code renewal commits are retained. Their historical
uncertainty restrictions are unchanged; they do not repair this failed worker.

## Qualification

- A source regression run against the original `execute` method reproduces
  selection of the legacy profile. The identical regression passes with the
  correction, including installed-awaiting-peer and later connected readback.
- **102 Python tests PASS, zero failures/skips**, including isolated root-owned
  journal IO, official pairing adapters, managed dispatch and account bootstrap.
- **86 Swift tests PASS, zero failures/skips**: 78 core and 8 presentation tests,
  including code-renewal regressions, chronology, closed progress decoding,
  sealed-resource/current-release admission and monotonic timing.
- Unsigned app and CLI compile successfully as part of these tests.
- `git diff --check` passes. No CI threshold has been lowered or bypassed.

These are source/process/file-IO results, not installed end-to-end results or a
performance speedup claim. Real unsigned GUI operation could not be performed
because the screen-control runtime exits during initialization; no tool trust
configuration was weakened to work around that limitation. The existing helper
progress visual-check screen is not accepted as installation evidence.

## Remaining acceptance and authority

1. Admission-consolidation source qualification is complete: the combined suite
   now has 143 passing Swift tests. Retain exact-source proof for protected review.
2. Protected source review and delivery; the prior numerical release cycle is
   already consumed. This source increment does not allocate another cycle.
3. A separately authorized bounded VM maintenance/install run, with preserved
   failed journals and replay anchors; do not retry this uncertain operation.
4. Real signed clean CLI then clean GUI execution, actual component paths,
   accounts, services, provider status, installation-only binding and final
   readiness; actual click-to-code and phase durations before claiming speedup.
5. Full lifecycle/combination matrix rows stay open wherever real evidence is
   absent. No public MVP completion receipt is authorized by source tests.
