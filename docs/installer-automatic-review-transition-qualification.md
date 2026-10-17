# Automatic customer-wizard composition review

Status: SOURCE_QUALIFIED_UNSIGNED; no protected delivery, public release or installed acceptance is claimed.
Baseline: public installer 0.4.28, protected source `5e326404d9166f4cb8f5dd88fe94f37b5101c09c`.

## Observed failure and evidence boundary

The actual public GUI advanced automatically after normal macOS helper authorization, without a manual helper recheck. It then remained on **Producten controleren…** with disabled provider actions. That exact rendering branch projects pending composition review without an in-flight review request. No provider authentication or product execution had started.

The original macOS/SwiftUI event ordering was not instrumented. The source reproduction establishes a control-flow gap matching the observed idle/pending screen; it does not claim to reconstruct the original OS event trace. Ordinary mounted transitions and asynchronous preflight completion already passed on the unchanged source.

The preparation driver previously advanced only one synchronous gate per observation. Advancing from provider selection to review did not request the review in that invocation. Progress depended on another SwiftUI state observation, even when the intermediate state had not been drawn.

## Behavioral reproduction

`testMountedCustomerWizardDoesNotNeedSecondObservationToStartReview` delivers one production preparation observation before the next AppKit/SwiftUI frame, then lets the genuinely mounted customer wizard run. On unchanged production source it fails two behavioral expectations: the coordinator receives zero review requests and the wizard remains pending without an active request. No provider code, helper or product is involved.

`testMountedCustomerWizardAutomaticallyRequestsCompositionReview` independently checks asynchronous preflight completion through the mounted production view. The model does not receive a manual review call or a manual downstream advance.

## Bounded correction

The existing driver now settles at most the two immediately available read-only gates (passed preflight and provider selection) before dispatching the next preparation action in the same invocation. Entering review therefore requests the exact session-bound review immediately. The existing domain `canAdvance` checks remain mandatory. No timer, repeated host admission, provider staging, authentication, execution, journal change or recovery authority is added.

Automatic review is requested only while its status is pending. A compatible result is retained; an incompatible result remains visible and requires the existing explicit retry action. The existing in-flight guard and per-view request flag remain in place. This also prevents a second mounted observer from issuing a redundant read after completion.

## Unsigned qualification

26 tests PASS: 23 customer-wizard rendering/interaction/preparation tests and 3 existing route integration tests. Both new continuously mounted regressions pass. The spy explicitly fails on provider actions, provider staging or product execution. Existing checks cover unstarted preparation, accepted session, unresolved helper/preflight, provider action in flight, fresh currency, reviewed context and explicit execution. Existing compatible and failed reviews are not automatically requested again.

Command: `swift test --package-path macos/ForgePlatformInstaller --filter 'InstallerWizardReadOnlyRenderingTests|InstallerEndToEndRouteTests'`.

This is a focused local unsigned qualification, not a fresh complete protected coverage-gate run or a signed artifact qualification. No new release, helper replacement, VM cleanup, VM installer invocation, credential action or journal mutation was performed for this increment. The existing VM attempt remains preserved and blocked. Live provider refresh and end-to-end installation remain unqualified by this change.
