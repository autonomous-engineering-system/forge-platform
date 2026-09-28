# Installer UX and release qualification V1

**Owner:** Forge Platform. **Status:** lifecycle contract `DESIGNED`; consumer
implementation, release and live acceptance `PLANNED`.
**Recorded:** 13 September 2026. **Version effect:** NO_BUMP documentation only.
[Documentary DAG](installer-ux-release-v1.json).

## Scope, evidence and deduplication

The owner supplied these requirements for the product backlog, not an order to
install software, register a runner, expose signing keys or publish a release.
This refinement consumes the [Universal Installer contract](../architecture/UNIVERSAL_MACOS_INSTALLER_CONTRACT.md)
and [ownership matrix](../architecture/OWNERSHIP_MATRIX.md); it does not create a
second provisioning engine or generic workflow-policy authority.

Current lifecycle observations: Platform `e92f4e4151080f7c2a9d4fdeba1541b1407d7907`,
EP `cfce69892278ee2b6c14412c171f5f33596acb0e`,
Forge `a78523603d6ea081d07875ea6b557e73b5d4fe63`,
Workspace `36d294836cb653361fda3972de38acce3d2970f8`.
These pins are observations, not enduring peer status or installed evidence.

| Producer | Released baseline | Lifecycle contract | Roadmap status |
| --- | --- | --- | --- |
| Forge | 2.7.37 / `forge-v2.7.37` / source `a785236…` | `forge-server-instance-lifecycle/v1` | `QUALIFIED` released-wheel evidence; consumer binding not yet qualified |
| Engineering Platform | 2.3.104 / `engineering-platform-v2.3.104` / source `cfce698…` | `engineering-platform.system-instance-lifecycle/v1` | `QUALIFIED` released-wheel evidence; consumer binding not yet qualified |

`QUALIFIED` above applies only to the owning product releases. It does not
promote any Forge Platform adapter, composition, installer release or live Mac
scenario. `DESIGNED` below means the consumer semantics are frozen in these
canonical documents without source/release evidence; `PLANNED` means no such
consumer implementation claim is made.
Forge 2.7.36 and EP 2.3.103 remain historical `GAP_PROVEN` producer artifacts;
the exact remediated-wheel handoff is [forge#142 revision 24](https://github.com/pcvantol/forge/issues/142#issuecomment-5873771111).

| Request | Existing owner/lane | Disposition |
| --- | --- | --- |
| EP service independent of user login | EP roadmap OI-5a/b foundation and OI-5d -> privileged provisioner/service-migration order; Universal Installer system-domain contract | Already planned; no duplicate EP programme. Require actual boot/logout and same-instance readback before claiming delivered. |
| Forge aggregate degraded health | Forge F2/FH status services | Refined in Forge's companion `FORGE_AGGREGATE_HEALTH_V1.md`; consume only its qualified health scope. |
| Forge HTTP/OpenAPI/Postman/CI drift | Forge FH-CONTRACT/SERVICES/HTTP/CLI/Q and HT-05 | Already specified; preserve existing nodes and tests rather than another API programme. |
| Workspace publication on PyPI | Workspace production-release/deployment lane | New owning WPK refinement replaces installable source-bundle delivery; Platform consumes exact published role artifacts. |
| Installer appearance, profiles, wizard, tests and runner | Existing Universal Installer UI/qualification/release lanes | The concrete acceptance refinements below; not proof that missing behavior is implemented. |
| Installer GitHub Releases | Existing installer-release contract and FP-EP-CI-7 | Already targeted; complete protected signing/notarization/publication and readback, no second publisher. |

The [EP-only clean-install parking scope](EP_SERVER_CLEAN_INSTALL_V1.md) remains
unchanged. Full component combinations belong to the broader MVP-INST-001
horizon, not new prerequisites for the first EP-only clean install or Forge
canary. Apply shared wizard/test/release requirements to the actually shipped
profile subset; unavailable broader profiles cannot be represented as supported.
This document does not unpark live work or change the Console process topology.

## IUR-CONTRACT: profiles and shared release semantics

One product-owned component/profile registry drives selection, labels, valid
combinations, dependencies, summary, plan, qualification and manifest mapping.
Use the five existing roles: EP Server, Forge Server, Workspace Server,
Workspace Client and EP Project Agent. The owner's term **EP client** maps in
this UX to **EP Client (Project Agent)**, not a sixth product, daemon, protocol
alias or new execution authority. Actual package/component IDs remain those
of the verified catalog and owning contracts.

| Aggregate selection | Individual roles selected |
| --- | --- |
| Server install | EP Server + Forge Server + Workspace Server |
| Client install | Workspace Client + EP Client (Project Agent) |
| Both | Union of those five roles |
| Custom | Explicit supported component selection |

These are selection conveniences, never opaque additional artifacts. Show each
checkbox and why it is required/optional/unavailable. Derive aggregate checked,
unselected and mixed states from the individual choices. After changing a
choice recompute one exact plan and require review; preserve valid user choices
and show dependency changes rather than silently enabling installation/removal.
Workspace Client alone remains valid. Client-only does not imply local servers;
remote dependencies require qualified discovery/pairing or configured bindings.
Reject invalid combinations and explain missing peer/capability/artifact evidence.
Selecting Server install must not silently degrade to the only currently available
EP component; show the unavailable selection and offer an explicit EP-only choice.
Unchecking an existing installation is NOT uninstall authority. Removal needs its
own supported, reviewed product operation; clean-install never becomes migration.

Release/publish reuse follows the existing [canonical version policy](../architecture/CANONICAL_PRODUCT_VERSIONING.md)
and product-owned release-operation flows. Maintain a versioned applicability
matrix for EP, Forge, Workspace, the native installer and composition artifacts:
exact protected source, one version operation, build identity, required unit/
integration/security checks, applicable API drift, installed-artifact tests,
immutable digests/provenance, publisher identity, registry/readback, and durable
PUBLISHED versus RELEASE_COMPLETE/cleanup. Reuse qualified helpers/workflow
contracts where possible; product wrappers retain product-specific languages,
platforms, permissions and registry adapters. Detect semantic projection drift;
explicit N/A requires a reason and must not remove a required check. Do not
copy another product's stale status or change its workflows from this repository.
Forge/EP and future installable Workspace use their PyPI lanes; installer bytes
and release descriptor use GitHub Releases. No release is triggered by this
backlog document or by a version bump alone.

## IUR-INSTANCE: managed deployments, multi-instance targets and provider fan-out

The installer is not a one-installation-per-Mac wizard. The same host may
contain multiple Forge Server instances and multiple EP Server instances.
Before a mutable operation, the wizard inventories product-owned instances and
Forge Platform managed-deployment records, then requires one explicit target:

- create a new managed deployment; or
- select one existing managed deployment to manage.

For the current Forge/EP server topology the selected deployment may contain
one Forge Server instance, one EP Server instance, or both. Every product
instance retains its own opaque identity; the deployment's optional display
name is not authority.

The profile/component page computes desired state for that exact deployment.
The reviewed diff must distinguish at least:

- `ADD_COMPONENT`;
- `UPDATE`;
- `NO_CHANGE`;
- qualified `REPAIR`;
- `REMOVE_COMPONENT`; and
- `REMOVE_DEPLOYMENT`.

No action is implicitly machine-wide. Updating or removing one deployment must
prove that every other same-host Forge/EP instance remains outside the target
set. Removing the Forge component from one deployment is not "uninstall Forge
from this Mac".

Provider UX is grouped by the **human authentication ceremony**, while status
and completion are tracked per owning component instance. Example for a
Forge+EP server deployment:

```text
Codex
  required by Forge <forge-instance>
  required by EP    <ep-instance>
  [Authenticate once]

  Forge <forge-instance>  VERIFIED
  EP    <ep-instance>     VERIFIED

GitHub
  required by EP <ep-instance>
  [Authenticate once]

  EP <ep-instance>        VERIFIED
```

One authentication may fan out only through a provider-supported mechanism.
It creates no shared runtime context: each selected server instance receives
its own provider CLI installation, provider home/configuration, durable auth
state and lifecycle. The wizard advances only when every enabled target context
is independently `VERIFIED`.

Forge/EP server provider contexts are system/component-owned and must pass
cold-reboot readiness with no interactive user login. EP Project Agent
provider/credential contexts remain user-owned per Host/OS-user context;
multiple users on one machine may each have an independent Agent.

The native SwiftUI app is the interactive first-install/lifecycle UX. A future
CLI surface must consume the same managed-deployment inventory, composition
session, provider fan-out coordinator, reviewed diff, product adapters and
receipts. CLI and GUI may differ in presentation but not in mutation semantics.

This section refines the broader Universal Installer target only. The parked
EP-only clean-install v1 remains a narrower qualification slice and does not
establish singleton cardinality or provider scope.

## IUR-LIFECYCLE: preserve, purge and restore

The first production installer treats software removal and instance-data
deletion as different operations. Its minimum product-owned state projection is:

```text
INSTALLED
UNINSTALLED_DATA_PRESERVED
PURGED_OR_ABSENT
```

The safe GUI/CLI action **Remove software / keep data** dispatches `PRESERVE`.
It removes or deactivates only the selected instance's software/service according
to the owning product contract while retaining data, configuration and the same
opaque instance identity. A preserved instance remains in deployment inventory,
cannot be claimed by another deployment, and is offered as **Restore existing
installation**, never as an ordinary fresh install.

**Remove software and all instance data** dispatches `PURGE`. It is a separate
destructive route requiring fresh confirmation that names the exact deployment,
component and instance and explains that restore will be impossible. There is no
default or failure fallback from preserve to purge. A later install after terminal
purge is a clean/new product instance state; it does not reuse preservation
evidence merely because a caller proposes the same display label or identifier.

`RESTORE` names one exact product-owned preserve operation. Admission requires
the same instance identity, compatible exact version/source/artifact, unchanged
preserved data evidence, supported schema/integrity, no foreign deployment claim,
no purge tombstone and no unsafe link/tamper/drift. Forge Platform stores only
receipt references and journal state; it does not inspect or rewrite product
data, CENTRAL, provider homes, service definitions owned by EP, or lifecycle
control roots.

Resource ownership remains asymmetric and explicit:

| Resource/action | Forge owner | EP owner | Forge Platform responsibility |
| --- | --- | --- | --- |
| Mutable data/config and lifecycle evidence | Forge | EP | retain exact receipt references only |
| Service definition | Forge Platform | EP | remove/recreate Forge LaunchDaemon only after owning admission; never synthesize EP service state |
| Immutable runtime slots | Forge contract | EP contract | select only exact qualified composition artifacts |
| Provider context/auth bytes | Forge | EP | orchestrate fresh verification; never read/store credentials |
| Forge↔EP pairing | each product verifies its side | each product verifies its side | orchestrate product-owned revalidation and bind non-secret evidence |
| EP Project Agents | not applicable | user-owned outside Server instance | never preserve, purge or rewrite as part of Server lifecycle |

Preserved provider/auth state is `PRESERVED_REQUIRES_REVERIFICATION`, never
`VERIFIED`. Restore runs fresh per-instance provider readback and an explicit
authentication/repair route when needed. For Forge+EP, historical pairing is a
candidate only; both exact restored identities and the product-owned pairing
must pass again before readiness or registry commit.

One durable lifecycle plan binds the deployment revision, exact instance and
artifact identities, operation/request digests, intended disposition and prior
receipt. GUI, CLI, privileged helper and product adapters use that same plan and
terminal receipt grammar. Same-operation restart/relaunch/reboot resumes without
double mutation. Stale revision, changed request, concurrent update/lifecycle,
wrong instance, tamper, symlink, foreign root, purge-after-preserve race, lost
response or conflicting terminal evidence fails closed and remains recoverable.
The installer commits lifecycle state to its CAS registry only after owning
terminal receipt and required service/provider/pairing/readiness continuation.

## IUR-WIZARD: OS appearance, language, clarity and gates

Follow macOS appearance by default, including live light/dark changes. Use native
semantic colors, legible contrast, accessible focus/keyboard navigation and
scalable assets/text. Qualify 1x/2x backing scales, display changes and Retina
rendering without blurry assets or clipped/truncated controls. Respect the
existing thin arm64/macOS-26-or-newer floor; newest SDK does not raise that floor.

Select the best supported language from OS preferred languages, handling region
variants and a documented English fallback when none is supported. Provide the
existing en/nl/de/fr/es set, including titles, descriptions, validation, errors,
actions, progress, accessibility labels and final summaries. No raw error codes
or mixed-language fallback as user-facing prose; safe diagnostic identifiers may
be available in details. OS-language selection is not a mutation of OS settings.

Every real wizard page has a clear title, step position, purpose, what the
installer is doing versus what the user must do, primary/secondary actions,
progress and back/cancel behavior. Derive page order from actual applicable
steps: self-update, deployment selection/creation, composition/profile,
preflight/tools, required provider authentication plus per-target verification,
reviewed diff, execution/readiness and summary. Do not fake completed skipped
steps. Use measured progress when a denominator exists and indeterminate progress
otherwise; no invented percentage or finish time.

Validate every page with the same owning/domain checks used for execution.
Disable Next only with a clear actionable reason; explain the offending choice,
missing permission/tool/capability, affected step and supported remediation.
Keep inputs across recoverable errors. Cover pending, empty, warning, blocked,
canceled, timeout/offline, retryable failure and terminal partial failure.
Do not report HTTP success, a running PID, a selected checkbox or package download
as completed installation. Display actual product receipts and readiness evidence.

## IUR-READONLY: real UI, no target mutation

Provide an explicit read-only inspection/preview mode and use it for native UI
integration tests. It runs the SAME wizard, navigation, validation, localization,
selection and plan-rendering code, not a separate mock wizard or screenshot app.
Composition-time capability restriction removes all mutators; disabling buttons
alone is insufficient. Attempts to bypass UI controls must still be denied.

No self-update/handoff, product install/update/repair/remove, venv/tool/account/
service change, provider login, credential write, pairing, product API mutation,
accepted-catalog write or production operation receipt is permitted. Live mode
may use supported bounded read-only inventory. CI uses deterministic external
inventory/catalog/provider observations and effect-boundary adapters in isolated
fixture roots, never the owner's live installation, keys or data. Real internal
trust/validation is not bypassed: fixtures obey the real contract and cannot
install production trust or turn simulated completion into genuine evidence.

An execution page may preview typed WOULD_INSTALL/WOULD_UPDATE outcomes or show
clearly marked simulated external progress to exercise UI states; it must never
emit a canonical COMPLETE installation receipt. Persist only explicit test-owned
logs/screenshots/results in isolated output, not live installer anchors/journals.
Mode is pinned for the session; transition to real execution needs a new explicit
session with fresh actual readback/authority, not a UI toggle that reuses a test
plan. Prove zero forbidden calls AND unchanged protected filesystem/service/
credential/API state on success, failure, cancel, relaunch and attempted bypass.
Read-only UI qualification does not replace separately authorized real install,
upgrade, migration, cleanup, reboot or recovery tests.

## IUR-UX-Q and IUR-COVERAGE: test and screenshot evidence

Use real native UI automation (XCTest/XCUITest or a qualified equivalent) alongside
Swift-domain, Python-coordinator, schema/protocol, integration and negative tests.
Exercise every declared wizard page and conditional branch: aggregate/individual
profiles, remote/client-only, provider prerequisites, invalid combinations, stale
inventory, inaccessible services, network loss, insufficient permissions, cancel,
back/forward, restart, read-only mutation rejection and partial failure. Retain
existing signature/catalog/exact-artifact/no-second-provisioner negative tests.

The owner's minimum is strictly **>80.2% per production source file**, not a
repository average and not >=80.2 after rounding. Cover Swift UI/domain and
Python/other installer production code, including release/provisioner adapters
where instrumentable. Use exact covered/executable counts; zero-execution files
cannot disappear from the inventory. Report branch coverage where supported,
but do not silently substitute it for line coverage. Generated/vendor/declarative
files with no executable lines have explicit reviewed classification and other
checks, not blanket exclusions. No exclusion merely to pass the threshold.
Retain any stricter owning requirement. Missing/partial coverage evidence fails
the gate; printed rounded 80.2 is not proof of >80.2. Do not weaken existing gates.

Capture screenshots of ALL wizard pages and applicable variants from the real
app in the read-only UI suite. Keep a manifest with step/state/profile, locale,
appearance, backing scale, source SHA, installer version, runner/toolchain and
image digest. Store redacted screenshots and test-result bundles as CI artifacts
on success and failure. Fail coverage of the screenshot inventory when a required
page/state is absent. Cover all five languages, both appearances and Retina/scale
transitions with a declared matrix; no claim that a screenshot proves installation.
No fabricated/rendered substitute images or real credentials/personal paths.

## IUR-RUNNER: owner's Mac, current public SDK and protected signing

The requested build/sign host is a **self-hosted GitHub Actions runner on the
owner's Mac**, using the existing Xcode signing configuration. This is a target
and owner-reported configuration, not discovered runner/key availability. At
implementation, verify the exact registered runner/repository access, macOS/arm64,
Xcode path/build, macOS SDK version/build and supported deployment target. Resolve
the latest public stable Xcode/macOS SDK from Apple's release information at
release preparation; exclude beta/RC-only toolchains. Pin that observed toolchain
for the operation and retries; record provenance rather than silently changing
SDK mid-release or hardcoding an unverified latest-version claim.

Use the existing configured identity after verifying Developer ID distribution,
Team/bundle identity, key access and notarization under the ACTUAL runner account.
Xcode GUI success alone is not unattended CI signing proof. Do not create/export
keys, scrape authfiles, weaken Keychain permissions or install/update Xcode as a
side effect of a build. Missing access yields a precise readiness failure and
requires the corresponding host setup, not a secrets fallback.

Separate ordinary untrusted PR validation from the privileged release route.
Do not execute fork/untrusted PR code on the Mac with signing keys or access to
live installations. Admit only reviewed exact-source release jobs through
restricted runner selection and protected release authority, pinned actions,
least permissions, isolated work/output and exclusive signing concurrency.
Environment approval is not isolation from another job already on the host.
Qualify runner cleanup and cross-job isolation; no arbitrary repository workflows
may target this signer. Read-only UX does not make hostile code safe.

Native UI tests may require an explicitly available test GUI session; record
that requirement separately from build/signing and from installed server boot
independence. Do not change automatic-login or OS privacy/consent settings as
part of CI. Headless EP/Forge/Workspace system-service qualification must not
be inferred from tests run while the owner is logged in.

Implementation references, checked separately from repository evidence:
[GitHub secure workflow use](https://docs.github.com/en/actions/reference/security/secure-use),
[Apple Xcode/SDK requirements](https://developer.apple.com/xcode/system-requirements),
and [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## IUR-RELEASE and IUR-INSTALL-Q: finish lines

Extend the existing installer release operation, not a second release script:
exact reviewed source/toolchain -> unsigned candidate -> applicable tests and
coverage -> protected Developer ID signing -> notarization/stapling and signature
verification -> immutable GitHub Release assets/descriptor/checksums/provenance
-> remote download and exact-byte/identity verification -> retained release receipt
and scoped cleanup closure. Preserve PREPARED/QUALIFIED/PUBLISHED/RELEASE_COMPLETE,
CLEANUP_PENDING and the current release-trust/catalog requirements. Signing changes
bytes: bind unsigned candidate to the final signed/stapled artifact with explicit
provenance; never equate their digests. Publish only to the configured verified
namespace/version; retries retain identities and cannot overwrite different bytes.

Real installation qualification remains separate and uses only an explicitly
authorized clean test target and the selected product-owned contracts. EP system
service tests must prove boot without GUI login, logout independence, correct
account/root/instance/readiness and safe conflict/migration behavior. Existing
user-scoped Agents and provider credentials do not become system-scoped merely
because the Server does. Broader profile qualification consumes each selected
product's artifact/provisioner/health evidence; it does not wait for unrelated
components, and EP-only success is not all-profile success.

### First-release lifecycle acceptance matrix

These scenarios run only against an explicitly authorized fresh Mac/test
deployment after a protected signed/notarized installer release exists. Fixtures,
source tests and producer qualification do not satisfy them.

| Scenario | Required evidence before `LIVE_QUALIFIED` |
| --- | --- |
| Forge preserve → relaunch/reboot → restore | same Forge instance/runtime/installation IDs; data/config unchanged; service/readiness restored |
| EP preserve → relaunch/reboot → restore | same EP instance ID and CENTRAL/data/config; provider state demoted then freshly verified; inactive restore before repair/start |
| Paired Forge+EP preserve/restore | each exact identity retained; provider contexts independently reverified; pairing revalidated/re-established; both readiness PASS |
| Purge installed or preserved instance | exact selected root removed by owning product; tombstone/readback terminal; restore rejected |
| Install after purge | clean/new product instance state; no old data/config/provider/pairing resurrection |
| Crash/lost response at every lifecycle phase | same operation resumes; no duplicate service/data mutation; terminal replay byte-equivalent |
| Negative identity/evidence matrix | stale review, wrong deployment/instance, tamper, link, foreign root, artifact/source/schema drift and changed request all rejected |
| Concurrency/isolation | update/preserve/purge/restore conflicts rejected; sibling instances and unrelated deployments byte/state unchanged |
| GUI/CLI parity | same reviewed target/disposition/helper request and terminal receipt; purge confirmation cannot be bypassed |
| Recovery and failure | partial service/provider/pairing failure remains recoverable and never commits installed/ready state prematurely |

## Documentary DAG joins

The exact machine-readable joins are canonical in
[`installer-ux-release-v1.json`](installer-ux-release-v1.json). In summary:

```text
qualified Forge/EP lifecycle releases
  -> producer rebaseline
  -> preserved inventory
  -> restore + purge planning
  -> helper/product adapters
  -> provider/pairing revalidation
  -> GUI/CLI parity
  -> production composition
  -> signed installer release
  -> fresh-Mac preserve/restore/purge acceptance
  -> terminal handoff
```

The existing joins remain: IUR-CONTRACT -> IUR-WIZARD + IUR-READONLY; both ->
IUR-UX-Q. IUR-READONLY -> IUR-COVERAGE. IUR-RUNNER is independently plannable.
UX, coverage, runner and lifecycle production composition join at the signed
release; release precedes both general install qualification and lifecycle live
acceptance.

These refine existing FP-EP-CI-6/7/Q for its selected scope and MVP-INST-001 for
the broader horizon; they are not reverse dependencies on completed umbrella
programmes. Keep existing product, clock/trust, signing and clean-host authority
gates where applicable. External producer evidence is conditional on selected
roles, not a dependency on every product being finished. Only the four owning
Forge/EP producer contract/release nodes are `QUALIFIED`; consumer nodes are
`DESIGNED` or `PLANNED` with no consumer qualification receipts. No runner,
signer, workflow, product installation, installer release, active Mission or
executable DAG changes here.
