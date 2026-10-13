# Customer installer wizard contract

Status: requirements from operator E2E feedback on 12 October 2026. This document
does not claim shipped support or expand source, release, credential or VM budgets.
The currently published customer GUI 0.4.14 offers only combined EP + Forge.

## Order and component selection

Flow: Welcome → Components → Prepare → Providers → Confirm → Install → Done.
Before provider authentication, offer EP, EP + Forge, and Forge. Bind the chosen
component identities through the existing verified composition coordinator and
its authoritative catalog; do not filter only visible rows or fabricate a plan.
Provider requirements follow that verified selection:

| Selection | Human authentication | Account targets |
| --- | --- | --- |
| EP | Codex, GitHub | EP instance targets |
| Forge | Codex | Forge operator target |
| EP + Forge | One Codex ceremony, GitHub for EP | Independently verified EP and Forge Codex targets; EP GitHub |

Later selectable products: Workspace Server, Workspace Client and EP Agent.
Their requirements remain future work until supported by qualified component
contracts; do not present disabled placeholders as working install routes.
After provider or installation effects, browsing prior choices never changes the
bound plan, starts a new operation or repeats authentication. Changing a choice
requires a separate supported, explicit plan transition with its own review.

## Navigation and presentation

Use the vertical glyph/status sidebar. Reached earlier steps can be clicked to
inspect their results; current-step selection returns to the live screen. Future
steps remain disabled, including stale snapshots after a same-context regression.
Keep Previous at the bottom. Use ordinary titles without earlier-results suffixes
or repetitive read-only notices. Keep the actual installer version permanently
visible in the footer. Remove the customer Technical details disclosure and raw
manifest/catalog digests, deployment IDs and inventory references from the flow.
Internal immutable evidence and trust checks remain mandatory.

## Confirmation before product installation

For each selected component, show facts from the exact reviewed execution plan:
version; absolute install/data/log paths; effective service/operator account and
whether it already exists, was created during preparation, or will be created;
service label and port; pairing effects and independent readiness checks.
Do not hardcode the operator name or invent a service account unsupported by the
component's lifecycle. Do not infer concrete physical paths from display names.
Plan changes invalidate confirmation rather than silently changing its effects.

Show estimated installed size per component, retained data, temporary download/
unpack space, peak additional space, total required free space and available
space on each target volume. Shared provider/runtime storage must not be counted
twice; independent per-account copies must be counted. Label estimates explicitly
and derive them from verified payload information and measured qualification.
Unknown estimates are shown as unknown, not zero or fabricated precision.

## Progress and latency

Active work always has a spinner or progress bar. Name the selected provider
(Codex or GitHub), then the actual functional phase. Installation substeps should
include download, verify, unpack/copy, configure/register component, start service,
pair and independently check readiness, only when the backend reports those facts.
Show a percentage when byte/item/work totals are known, with current substep and
elapsed time underneath. While an unquantified check runs, show active progress
without inventing a percentage. Remaining time is explicitly an estimate with an
uncertainty range and is updated from measured completed work; it is not a promise.
An animation or UI timer never implies a journal transition or installation PASS.

Show a persistent list with one row per selected component, plus separate pairing
and overall readiness rows. Each row has a component glyph and an explicit state:
waiting (not started), running (spinner), successful (green check), failed (red
cross and actionable reason), or blocked by an earlier failure. Completion means
an authoritative component receipt plus independent readiness, never inventory
presence alone. Preserve the final row states after failure and during navigation.
In the observed 0.4.14 failure, EP is failed at service startup, Forge is not
started, and pairing has not started. A combined generic failed row hides these
facts and is insufficient. This requires real component phase/result transport;
the frontend must not infer successful installation from timers or files.

The existing provider confirmation button currently invokes advance(), causing
provider preparation to repeat before official independent readback and ceremony
completion. A dedicated supported check/finish path and measured admission-cost
review are open work. Preserve current trust, race, target/evidence, uncertain
historical effect and one-login fanout guards; do not bypass them to make the UI fast.

## Logs and errors

Open requirement: a readable Open installation log action at success and failure,
with timestamped functional phases, elapsed durations, component result, service,
port, path and safe diagnostic codes. Authentication secrets, tokens, passwords,
device codes, raw CLI streams and arbitrary environment values must never enter
this log or export. Existing root-only recovery journals are not a customer log
and must not be copied directly to user-writable storage. Export needs an owning,
whitelisted evidence model and independent permission/secret-boundary qualification.
Errors name what failed and a safe next action; generic fix-the-Mac messages and
an indefinite spinner are insufficient.

## Qualification boundaries

Local presentation patch: reached-step buttons, clean titles, no redundant notice,
permanent version footer, selected-provider labels and removed Technical details.
Source/render qualification does not establish a published GUI install PASS.
The current source increment adds real operation-bound component status transport,
separate pairing/readiness rows, and an in-flight terminal gate. Its checks and
remaining partial-CREATE recovery boundaries are recorded in
[EP service recovery qualification](installer-ep-service-recovery-qualification.md).
Component-choice flow, exact review-path/account/space summary, backend substep/
percentage/ETA transport, readable log and latency correction remain open.
Each requires reviewed source and relevant installed E2E evidence before PASS.
