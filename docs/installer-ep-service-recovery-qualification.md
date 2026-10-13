# EP service preparation and partial CREATE recovery qualification

Date: 2026-10-12. Status: uncommitted source increment; no new release or VM run.

Updated 2026-10-13: the separate bounded historical helper-admission source scope
was approved. The integrated private execution admission, authenticated recovery
transport, CLI entry, component dispatch and terminal validation are now wired
and source-qualified. Signed-helper deployment and installed recovery remain OPEN.

## Observed failure

Published installer 0.4.14 started the published EP 2.3.113 CREATE but obtained no
terminal component receipt. Its parent remained at MANAGED_TOOLS and the effect
journal retained uncertainty. Forge installation was not reached. Root-created
EP data was inaccessible to the selected service account; configured logs and
service home were absent. Inventory absence does not mean effects were absent.

## Source implementation under qualification

The installer admits the exact selected service account and its current OS
identity, protects the original parent and product request identity, and grants
bounded access only to EP data, logs and service home. Unknown ACLs and account
drift block preparation. Root ownership and private file modes remain protected;
inheritance covers subsequent product-owned initialization and atomic replacement.
No EP source, product version, provider cache or trust key is changed.

A first CREATE requires the existing official provider bootstrap. Partial CREATE
admission requires the exact original product request, selected runtime, private
parent evidence and absence of a terminal receipt. A registered service, account
process, root provisioner process or competing worker reservation blocks rights
preparation. Admission records preserve the evidence; historical uncertainty is
never cleared by this route.

Component progress is private, closed-code evidence bound to the admitted native
operation. The GUI shows EP and Forge independently, then pairing and readiness.
Awaiting pairing does not mean ready. Progress cannot authorize a completion
screen or replace a terminal failure. Actual terminal validation precedes the
final successful progress update.

## Completed bounded checks

| Evidence | Result | Boundary |
| --- | --- | --- |
| Native progress, owner-bound XPC, terminal codec, wizard and execution gates | 40 tests passed | Source and presentation only |
| Python adapter, authority, dispatch, install flow, ACL and progress checks | 73 tests passed, 2 root-only checks skipped in this non-root invocation | Source only; skipped checks separately exercised below |
| Protected evidence and progress IO with real temporary root files | 10 tests passed | Isolated files; no service or product effects |
| Published EP 2.3.113 initializer repeated as root, non-owner validation and SQLite read/write | Passed | Exact published artifact, isolated paths; no service started |
| Independent review of the current service preparation and progress corrections | Scoped Quality/Security PASS | WIP review, not immutable-head or installed attestation |
| Historical source reconstruction and existing parent/operator/progress checks | 63 tests passed before the root-cohort reader correction | Source-only, no installed recovery |
| Historical evidence, root-cohort ACL, existing release acceptance and parent checks | 39 tests passed after the root-cohort reader correction | Real temporary file/profile IO, no VM effects |
| Protected evidence/progress and fresh CREATE deterministic target binding | 11 root-isolated tests passed on 2026-10-13, independently repeated | Constructor/file checks; no product execution |
| Real public 0.4.14 descriptor signature and historical origin plus existing reconstruction gates | 7 native tests passed | Real published signature; no successor executor or recovery admission |
| Historical runtime ACL, full retained snapshot and incremental tar bounds | 11 isolated tests passed; scoped independent Quality/Security PASS | Temporary files/ACLs only |
| Private native/Python readback, readonly child runner and real public origin | 12 combined native tests passed, no skips; scoped coordinator source review PASS | No recovery execution authority |
| Sole historical worker reservation with exact retained effect bytes | 10 native effect-journal tests passed; scoped independent Quality/Security PASS | Private temporary IO only; current root/name identity, flags/ACL and hash checks; uncertainty stays true; no execution caller |
| Immutable private inspection binding and coordinator storage coupling | 16 combined native historical tests passed, no skips; scoped independent Quality/Security PASS | Includes directory-sync failure followed by idempotent retry denial; no execution permit or VM publication |
| Closed read-only Python worker entry and deterministic worker build | 29 tests passed, 2 root-only skipped; those 2 passed separately | Source-only; authenticated execution still not wired |
| Combined Python historical/partial/preparation/progress checks | 28 run, 9 root-only skipped; root-only suite independently passed above | No installed execution |

Protected-file checks include duplicate/nonfinite JSON, hardlinks, broad modes,
symlink leaves and ancestors, unknown ACLs, bounds and nonregular files. Denials
preserve bytes and rights. The exact artifact initializer check does not prove
full CREATE, service startup, recovery, pairing or installed readiness.

## Required before recovery can be declared usable

1. Deliver and independently verify the new signed executor. Source now keeps
   the original native/product fingerprints, admits a separately current sealed
   helper, publishes an immutable reservation and consumes one original-operation
   claim before adapters are constructed. The existing ordinary route retains
   exact release equality. A sole child is retained until real exit, including
   timeout, under both host and helper-upgrade mutation leases. A closed recovery
   result requires the original request, both READY components, pairing and two
   readiness references before CLI success. This is source qualification only;
   no historical permit, claim or completion was written on the VM. The installed
   0.4.14 helper does not contain this route. Its ordinary upgrade gate must not
   be relaxed merely because the historical effect record is uncertain.
2. Obtain a supported, separately authorized quiescent state for the currently
   registered VM service. No permission or service stop is implied by this source
   increment. The current route correctly denies a registered job without a PID.
3. Qualify the complete same-operation recovery through real product receipts,
   pairing and independent readiness using the allowed installed route.

No new VM attempt, helper replacement, signing, release, source publication or
MVP completion is claimed by these checks. Original journals and replay anchors
must remain preserved. Customer log export, component choice, confirmation paths/
accounts/space, byte percentage/ETA and provider latency remain separate open
requirements in [the wizard contract](installer-customer-wizard-contract.md).

## Integrated source qualification, 2026-10-13

| Check | Result | Limit |
| --- | --- | --- |
| Historical, progress, owner-bound XPC and CLI native selection | 101 passed | Compiled unsigned source, real isolated child/pipe/files; not installed recovery |
| Integrated historical admission/service/dispatch, ordinary release gate, authority, preparation, progress and worker packaging | 84 run, 3 skipped | One root factory and two root ACL tests require the separately recorded root invocations |
| Private factory/claim plus protected original/partial evidence, as root | 34 run, 7 skipped | Seven checks specifically require a non-root reader; already exercised in non-root qualification |
| EP→Forge→pairing→two readiness receipts through the existing dispatcher | Passed | Explicitly modeled product adapters; ordinary execution of the old plan still rejected |
| Immutable claim and interrupted fsync, named directory replacement, actual child timeout drain and bounded pipe overflow | Passed | Original files and uncertainty retained; no running helper or product touched |
| Complete deterministic worker payload | Built | All new modules included; worker SHA256 `a9dc3dfadc432f6826b62632e26011c219897a5aab9fe59f0c0bbcc3bc701b7a` |

The production entry is `deployment recover-historical --operation-id <original-id>
--yes`. It is unavailable in 0.4.14. It never creates another operation or supplies
paths, commands, authority flags or credentials. The client may select only the
retained original operation; the signed helper derives all other fields and binds
the authenticated OS peer. A root peer cannot impersonate the named administrator.
`deployment-replace` is admitted only in that original parent scope for the
pairing/composition compare-and-swap commits, not for another product request.

Protected delivery, signed-helper handoff, supported EP service quiescence and one
actual same-operation recovery remain separate deployment gates. The existing VM
service is registered, so its present physical preflight remains DENY. Source
checks do not mark installer MVP, public CLI or public GUI complete.


## Integral recovery and bootstrap reconciliation source qualification

The bounded recovery increment now includes `helper reconcile-bootstrap --yes`.
It independently authenticates the existing helper, correlates its installed
bytes, original release binding, live process and read-only inventory, and
appends the existing bootstrap journal's final readback through its existing CAS.
It cannot install, activate, replace, or stop a helper. Original records and replay
floors remain active; current helper admission may advance only its two ordinary
current-release anchors.

Source qualification includes 1,731 passing native tests and executable-line
coverage strictly above 80.2% for each native production file. The expanded Python
gate includes 891 tests plus 17 isolated root-private tests. Every gated Python
file exceeds 80.2%; partial CREATE evidence reaches 95.2% and historical product
evidence reaches 97.03%. Root qualification uses temporary files, actual Darwin
file protections and ACL checks, empty provider homes and bounded test archives.
Account name projection and product/service observation in those fixtures remain
explicit source models. They do not prove installed or end-user acceptance.

Recovery preserves the original operation, credentials, journals and sticky
uncertainty. Installed qualification, protected delivery and the signed release
remain separate gates. A recovered partial installation is not proof of a clean
single-run CLI installation or a complete clean GUI installation.


### Historical inventory RPC has a protected read-only precondition

The original inventory producer can initialize a missing create candidate or
rotate a consumed candidate. Bootstrap reconciliation therefore reads the exact
existing private candidate for the original deployment and requires a genuine
empty deployment-registry snapshot before contacting the old helper. It freezes
and repeats both inputs under its exclusive host lease, before and after RPC,
in each verification, and after journal confirmation. Missing or foreign IDs,
nonempty or unknown registry contents and input drift deny before confirmation.
The source regression covers genuine temporary protected IO and preserves those
inputs; it does not exercise a live installed helper.


## Protected build qualification handoff

The isolated unsigned build account remains a non-administrator without sudo or
Developer ID access. Local Python and native tests remain mandatory. Some native
source tests require a genuine named administrator and therefore cannot execute
on that account. The protected Foundation macOS job executes those tests and
must pass strict executable-line coverage greater than 80.2% for every tracked
production Swift file before exporting a compact source-hashed measurement.

Only the fixed protected build workflows admit that measurement. They check
current protected main, their own exact in-progress run/attempt, the successful
owning Foundation push and all required jobs, the unique immutable artifact ID
and ZIP digest, exact source/tree/run binding and each production-file hash.
The existing strict coverage validator validates every admitted file. A local
caller cannot select an artifact, file, URL or threshold exemption. This is
source qualification; it grants no account, helper or product authority and is
not installed CLI/GUI evidence.

The original 0.4.15 build run 38457126604 stopped at the native coverage gate
before packaging/signing. Its failure is retained. The additional native
handoff correction and one build recovery were separately authorized; signing,
VM maintenance and original-operation recovery retain their existing limits.
