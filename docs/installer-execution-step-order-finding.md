# Open finding: installation list begins with its bottom aggregate row

ID: `L1-INSTALL-STEP-ORDER-20261015`  
Status: **SOURCE_IMPLEMENTED / UNSIGNED_QUALIFIED — installed GUI acceptance OPEN**
Scope: GUI execution-stage presentation and truthful component progress.
Recording this finding authorizes no implementation, release or runtime action.

## Observed behavior and source correlation

The actual installation screen showed, in this order:

1. Engineering Platform — “Nog niet gestart”.
2. Forge — “Nog niet gestart”.
3. Engineering Platform en Forge installeren — “Bezig”, with the detail
   “Productoperaties, Forge↔EP-pairing en terminale readiness”.

The active bottom row appears to be a final step that starts before the rows
above it. It is actually the aggregate deployment action. The source confirms
that `InstallerState.beginManagedDeploymentExecution()` initializes the component
rows as pending and then appends a running `managed-deployment` row.
`InstallerMVPFlowView.execution` renders that array in order.

This is a proven presentation/initial-state issue. The screenshot alone does not
establish that actual product operations run in reverse order, or that either
product is currently installed, successful or failed.

## Required correction and acceptance criteria

- Put overall installation status above the component/phase list; do not present
  the aggregate deployment operation as an apparent last chronological step.
- Present actual admitted phases from top to bottom: installation preparation,
  Engineering Platform, Forge, pairing, and final readiness verification, using
  only the phases applicable to the selected route and actual execution plan.
- Give each phase/component its own pending, running, successful or failed state,
  with the corresponding clock, spinner, checkmark or cross. Separate waiting
  for a peer from an installation failure.
- Drive states from real execution evidence. A request being submitted cannot
  mark a component successful; missing telemetry cannot prove “Nog niet gestart”.
  Show an honest preparation/awaiting-status label where that is what is known.
- Show pairing and readiness as separate evidenced phases rather than hiding
  them inside one combined installation row.
- Verify through actual signed GUI screen operation that the visible order agrees
  with execution, and that a component failure leaves subsequent phases correctly
  pending/blocked. Source-only or synthetic status tests do not close this finding.

Private evidence: the actual GUI screenshot is retained under this finding ID in
LANE_1 diagnostics. No credentials or device codes are part of this finding.

Related open finding: [Codex admission delay and progress gap](installer-codex-admission-delay-finding.md).

## 2026-10-15 implementation update

The source now initializes preparation first, followed by selected components,
optional pairing and final readiness. Validated worker progress preserves that
order. Overall failure is displayed separately; actual component phase events
supply functional labels and the bar counts completed steps. See
[qualification and remaining runtime acceptance](installer-forge-prepairing-startup-qualification.md).
