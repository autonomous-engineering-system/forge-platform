# Installer performance investigation and improvement backlog

ID: `L1-INSTALLER-PERFORMANCE-20261015`  
Status: **PARTIAL_SOURCE_IMPLEMENTATION / UNSIGNED_QUALIFIED — runtime performance OPEN**
Applies to real signed CLI and GUI installation. This document grants no extra
release cycle, VM retry, new worker, credential route or runtime mutation.

## Observed reasons to investigate

Public installer 0.4.23 repeatedly enters full Apple signature admission before
Codex login, before product execution and during EP provider registration. A real
GUI screen showed 9:22 elapsed and a current parent journal had reached MANAGED_TOOLS.
An earlier fixed-port check was not valid evidence of product availability:
this installation uses dynamically allocated ports. Later physical checks found
EP healthy on its actual port and the Forge gateway listening. A one-second helper sample showed
`executeProductOperations -> ManagedInstallerReviewedEPProviderRegistration.register`
entering `ManagedInstallerHelperCurrentReleaseAdmission.admitWhileLocked` and
`SecStaticCodeCheckValidityWithErrors`.

The elapsed label is not a per-function timing or a completed-install duration.
A stack sample establishes the active path, not total attribution. The current
installation is not restarted to obtain a benchmark.

See [signature-admission finding](installer-codex-admission-delay-finding.md) and
[execution-step presentation finding](installer-execution-step-order-finding.md).

## Measurement first

Instrument monotonic begin/end intervals for review, provider preparation,
click-to-device-code, provider verification/fanout, runtime/tool preparation,
artifact verification/extraction, per-component provisioning/service start,
pairing and readiness. Exclude human login time from machine-work latency while
reporting both separately.

For each interval record bounded non-secret identifiers, wall time, CPU time,
I/O, byte counts, full-signature-validation count, repeated material admissions,
network/download waits, lock acquisition/wait/hold times and worker-queue waits.
Capture cold-cache and warm-cache behavior and resource contention. Never log
codes, tokens, auth caches, passwords or full process environments/arguments.

Build a dependency graph and identify its measured critical path. Compare exact
signed artifact/product versions on equivalent VM resources. State sample count
and variability; do not invent percentile estimates from one observation.

## Improvement candidates to evaluate

| Candidate | Investigation | Required boundary |
| --- | --- | --- |
| Repeated full signature/material checks | Count duplicate work in one unchanged operation context; distinguish immutable-byte validation from currentness/account checks | Preserve required revalidation and invalidate on bytes, identity, release, plan, account or path drift; no stale global trust cache |
| Downloads and artifact reads | Overlap independent downloads or reads, avoid duplicate fetching, and measure disk/network contention | Every artifact remains digest/signature bound; a cache miss/corruption uses the supported fetch path and never bypasses verification |
| Independent read-only inspections | Evaluate concurrent component/environment/space checks and immutable artifact validation | Use a consistent admitted context; repeat required currentness checks before effects; no mutation under a read-only label |
| Component-local preparation | Determine whether EP and Forge preparation genuinely have independent prerequisites and resources | Shared runtime slots, users/groups, provider homes, journals and launchd registrations require explicit ownership and synchronization |
| Lock scope | Measure time spent doing expensive verification while holding shared locks; evaluate computation outside a lock with compare-and-revalidate before commit | No check/use race, weaker admission lease, duplicate reservation or reordered durable write |
| Helper/XPC round trips | Identify redundant full rereads or transport overhead | Preserve authenticated caller binding and fresh physical evidence at each required boundary |
| UI progress delivery | Publish meaningful phase/component events and elapsed phase time while work runs | Ordered evidence, no guessed completion percentages presented as measured progress, no premature checkmarks |

These are hypotheses, not approval to parallelize mutating operations. Parallel
work can increase disk, network or Security-framework contention and must be
measured rather than assumed faster. Prefer the smallest change addressing the
largest measured contributor.

## Ordering and concurrency rules to retain

- One reviewed operation, one owner per mutable resource, one actual component
  action per admitted claim. Concurrent requests cannot double-create effects.
- Single human Codex login precedes bounded fanout and independent verification
  of each selected target. Never parallelize duplicate human login ceremonies.
- Provider verification and required tool/runtime readiness precede dependent
  product actions. Respect the actual selected product lifecycle contracts.
- Pairing waits for both required peer identities/readiness; final readiness
  waits for all prerequisites. An absent peer is not successful pairing.
- Preserve journal write-ahead order, replay protection, terminal child evidence,
  uncertainty, lock ownership, account isolation and security-sensitive checks.
- Cancellation/failure must stop admission of dependent work and retain honest
  per-component state. Do not repeat a possibly applied effect for performance.

## Completion evidence

1. Before/after measurements for the exact changed boundary on actual signed CLI
   and GUI; same composition and declared resource/cache conditions.
2. Absolute elapsed times, critical-path reduction and resource/validation counts;
   establish numerical targets from the baseline before claiming improvement.
3. Same required identity, trust, provider, account, path, service, pairing and
   readiness readbacks. No lower safety/test gate or hidden unsupported route.
4. Targeted concurrency/fault tests for duplicate admission, material drift,
   simultaneous shared-resource requests, interrupted downloads, helper restart,
   cancellation and component failure while another independent task runs.
5. Accurate GUI phases and component states; diagnostics sufficient to explain a
   slow or failed step. Keep the complete installation/lifecycle test matrix open
   where real route evidence is still missing.

Source-only tests, warmer cache, a green build, or a faster animation do not prove
an installed end-to-end performance improvement. Current status remains OPEN.

## 2026-10-15 bounded source result

Independent sealed-resource readers now overlap while retaining every original
signature check. Fixed-name monotonic phase durations support actual attribution
on the next qualified runtime run. Ordered real component/subphase progress is
implemented. No measured signed-runtime speedup is claimed.

The separately authorized recursive provider-admission consolidation is now
implemented and unsigned qualified. An exact old/new source comparison admits
the same targets with seven versus two full initial group reads. Fresh material,
currentness, account, executable, home and drift checks remain; this is not a
signed-runtime speedup claim. See the
[admission qualification](installer-provider-admission-consolidation-proposal.md).


## Single-invocation interactive CLI provider continuation (15 October)

The normal interactive CLI frontend now keeps `deployment apply` in the same
verified composition session while the operator completes official provider
sign-in. The ephemeral challenge is still written only to the controlling TTY.
Human confirmation is followed by a fresh installer-currentness check and an
independent helper readback bound to the original operation, target set and
stable plan. A final fresh currentness check still precedes product execution.

There is at most one ceremony per selected target per invocation; no polling
loop, authentication retry, new operation or product retry is added. A target
that remains unverified, changed prior verification, a foreign challenge,
installer drift, unavailable readback or cancellation stops before execution.
Codex fanout remains helper-owned and independently verified. JSON and
non-interactive callers retain the one-step interaction-required result and
never enter a human callback. Existing callers without the optional interaction
callback retain their previous behavior; the shipping CLI main enables it.

The source coordinator regression demonstrates two distinct provider ceremonies
with one inventory/session/preflight/review/stage sequence and one product call,
rather than rerunning preparation for each login. Negative regressions cover
cancellation, unverified human acknowledgement, foreign operation binding,
installer drift and non-interactive isolation. This removes application-level
repetition; it does not cache release trust or remove helper admission gates.

Unsigned Swift tests and offscreen AppKit rendering pass. There is no signed
runtime before/after timing for this change yet. Parallel mutations, shared-lock
admissions and provider ceremonies remain sequential. Required path/account/
space presentation and measured ETA are tracked as OPEN in the
[customer wizard contract](installer-customer-wizard-contract.md).


## GUI authentication confirmation: no repeated staging (15 October follow-up)

The GUI's confirmation path previously entered the general advance action and
called provider staging again before each independent readback. The source now
retains the exact operation/receipt context and performs only a fresh currency
check followed by the existing helper read/finish operation. Environment staging
and a new login ceremony are not part of this action. A prepared read counts as
in-flight; duplicate clicks are ignored until it completes. A changed review,
installer or foreign readback blocks without creating another operation.

A coordinator regression holds the read response in flight, clicks confirmation
and navigation repeatedly, then releases independent verified evidence. It
observes exactly one initial stage, one initial read plus one confirmation read,
one original ceremony, and zero product executions. Negative cases cover
installer updates, foreign fingerprint and review invalidation while awaiting
the response. Actual signed GUI elapsed-time improvement remains unmeasured.
