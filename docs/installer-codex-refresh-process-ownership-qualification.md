# Codex refresh: process ownership and request admission

## Boundary

This increment implements and qualifies source only. It does not authorize or
claim protected delivery, signing, publication, helper replacement, VM process
termination, cleanup, another installation attempt, or end-to-end acceptance.
The existing VM still runs the published 0.4.26 source. Its retained pending
record is not cleared, retired, or retrospectively marked successful.

## Proven defect

The production authentication wrapper used Foundation `Process` to start its
provider. On macOS that provider was observed in a different process group.
Renewal stopped the exact registered wrapper group, leaving the provider alive.
The dedicated-account quiescence guard then correctly refused to retire its
original authentication effect. Repeating a code request cannot repair this
state and would conceal the underlying process-ownership defect.

Repeated request admission also added avoidable latency. The former helper
renewal performed a launch admission before stopping the old session, another
for expiry reconciliation, and a complete ceremony admission before launching
its successor. Consecutive stable-plan reads repeated expensive signed-release
checks without an intervening observation or effect.

## Correction

- Authentication uses `posix_spawn` with explicit `POSIX_SPAWN_SETPGROUP` to join
  the wrapper's already private group. Standard input is `/dev/null`; only the
  two existing captured output descriptors are inherited. Other descriptors
  close at exec. The environment and arguments remain the fixed provider
  contract. Status/version probes keep their existing launch route.
- The wrapper waits for its exact child and retains the parent-loss monitor.
  The original helper still verifies the registered wrapper's kernel identity
  before signalling its group. Expiry still requires observed child exit and
  independent group/account quiescence before append-only effect retirement.
  An unknown or escaped process continues to block reconciliation.
- The same in-memory reviewed session authorizes stopping its own exact child.
  A fresh complete admission after exit checks the original target and all
  selected destinations before retiring the old reservation and starting the
  successor. This one transaction replaces repeated recursive admissions.
- Read-only provider and ceremony admission retain a stable-plan read on both
  sides of physical inspection and target resolution. An immediately repeated
  initial stable-plan read is removed. No persistent cache or reused trust
  authority crosses requests, effects, login completion or credential fanout.
- The GUI shows three actual frontend phases: installer check, existing-login
  check, and closing the old login/requesting the new code. The final phase is
  deliberately combined: the frontend does not fabricate individual helper
  progress acknowledgements. The old code disappears while renewal runs;
  duplicate clicks remain blocked. A verified login wins over renewal.

## Qualification

The real-process regression runs a private XCTest subprocess through the actual
production wrapper launcher and a synthetic provider executable. It verifies
wrapper/provider group membership, actual process absence after renewal,
byte-identical pending evidence before reconciliation, append-only retirement,
and a second synthetic challenge in the same local test. It uses no provider
credentials and makes no service-account or VM change.

With the corrected test harness, unchanged 0.4.26 production launch code fails
on the provider-group and surviving-provider assertions. The corrected launcher
passes. The test does not replace macOS account admission with a live installed
acceptance claim: account/identity drift, busy-account and uncertainty rejection
are also covered by the existing separate admission and kernel-reader tests.

The successful helper renewal now performs two full physical provider reads
rather than six. Tests assert the two reads bracket the transaction and that
account/executable/home or plan drift still rejects. This is a call-count
reduction, not a measured live-VM latency promise.

The UI tests pause real view-model awaits, verify duplicate-click suppression
and exact operation continuity, and render all three progress phases with
synthetic data. Screenshots are presentation evidence, not a real login PASS.

Final unsigned qualification: 1,790 native tests executed, with 1,789 passing,
one existing skip and zero failures. The unchanged strict executable-line gate
passes at greater than 80.2% for every production Swift file, including the new
progress view. The launcher measures 83.86%, renewal actor 87.83%, ceremony
admission 98.56%, provider readback admission 95.65%, and new progress view 100%.
The three AppKit renders were inspected with synthetic data. No CI, signed
release or live-VM refresh PASS is implied by these local results.

## Existing VM

The old orphaned Codex process and its active reservation require a separately
reviewed supported resolution. This source does not infer a safe old-child PID
from a path, reset a journal, remove credentials, or automatically adopt an old
session after helper restart. The existing GitHub/Keychain and named-operator
renewal limitations remain unchanged.
