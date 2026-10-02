# Managed Installer V1 — Forge + Engineering Platform

**Assignment:** `L1-FORGE-PLATFORM-MANAGED-INSTALLER-V1-20260923`  
**Owning repository:** `autonomous-engineering-system/forge-platform`
**Producer qualification (2026-09-29):** Forge 2.7.38
(`0a3d6e35b01da93bb5a674ae7795558655c16c7d`) and Engineering Platform
2.3.106 (`7b99b578153ae5d72372a09db194306b49ec9f9c`) have exact
`RELEASE_COMPLETE` receipts and released-wheel lifecycle evidence in
[forge#142 revision 26](https://github.com/pcvantol/forge/issues/142#issuecomment-5887942490)
and [terminal revision 27](https://github.com/pcvantol/forge/issues/142#issuecomment-5892374672).
Existing exact Forge 2.7.37 managed instances retain lifecycle admission.
Forge 2.7.36 and EP 2.3.103/2.3.104 remain historical `GAP_PROVEN` artifacts.
EP 2.3.105 retains its own qualified evidence and inherited-cwd defect; it is
not the current consumer mutation baseline. Producer
qualification alone does not approve a production composition or live installer
claim; those remain held under [forge#141](https://github.com/pcvantol/forge/issues/141).
**Status:** source implementation under protected qualification; public
installer 0.2.4 is an earlier qualification release, not the first functional
installer. No live Forge/EP lifecycle PASS is claimed.

## Purpose

This increment turns ADR-0007's multi-instance design into one explicit
Forge Platform management boundary. The installer manages an exact **managed
deployment**, not a machine-wide Forge or EP singleton.

The current server topology permits:

- one Forge Server instance;
- one Engineering Platform Server instance; or
- both, with a separately evidenced Forge→EP pairing stage.

Multiple managed deployments and same-product instances may coexist on one Mac.

## Managed deployment authority

Forge Platform owns only:

- opaque deployment identity and optional display label;
- exact product-instance bindings;
- reviewed desired-state diff;
- non-secret product receipt references;
- cross-product pairing evidence;
- installer journal/recovery state.

Forge and EP keep their own opaque instance identities and runtime lifecycle.

The registry is optimistic-revision/CAS protected. One product instance cannot
be claimed by two managed deployments. Removing or updating one deployment
never implies mutation of another deployment.

Desired-state component actions are:

`ADD_COMPONENT`, `UPDATE`, `NO_CHANGE`, `REPAIR`, and
`REMOVE_COMPONENT`; complete deployment removal is a separate
`REMOVE_DEPLOYMENT` operation.

Lifecycle disposition is separate from topology. Removing selected software
must review one explicit product-owned operation: `PRESERVE`, `PURGE`, or
`RESTORE`. `PRESERVE` is the safe remove-software default; `PURGE` is never an
implicit fallback. A preserved component remains bound to its managed
deployment and exact product instance even though its service is absent or
inactive.

A desired action does not itself authorize dispatch. If the owning product has
not published the required lifecycle boundary, the action remains blocked.

## Provider target model

Composition v2 introduces an explicit provider target:

```text
provider identity
+ owning component
+ exact instance/pre-create target binding
+ credential scope
```

Server contexts are `component` owned. EP Project Agent contexts remain
`user` owned.

For a Forge+EP server deployment this permits two independent requirements:

```text
codex : forge-runtime                 : forge-prod : component
codex : engineering-platform-server   : ep-prod    : component
```

Provider authentication may be deduplicated only at the human ceremony layer.
The fan-out coordinator receives an ephemeral provider-supported bootstrap
handle and invokes each exact target provisioner independently. Every target
must return its own `VERIFIED` readback. The handle and credential bytes are
never stored in Forge Platform receipts.

Composition v1 remains readable as a targetless user-scoped compatibility
format. It cannot enter multi-target fan-out.

## Native macOS flow

The SwiftUI state machine now has an explicit read-only managed-deployment
selection gate before composition selection:

```text
self-update
→ deployment inventory / create-or-select
→ signed composition selection
→ host/tool preflight
→ provider targets
→ reviewed component diff
→ execution/readiness
→ summary
```

The native target-aware manifest projection verifies:

- exact manifest digest from the selected signed component-combination entry;
- exact composition identity/channel;
- exact selected component set;
- exact installer requirement;
- v1/v2 provider grammar;
- unique provider target bindings;
- server component-owned versus Project-Agent user-owned provider scope.

The SwiftUI shell never receives credentials, product commands or arbitrary
runtime paths.

## Engineering Platform adapter

The EP adapter consumes the exact released 2.3.106
`engineering-platform.system-provisioner/v1` command boundary and its additive
`engineering-platform.system-instance-lifecycle/v1` extension.
The registry can still decode exact historical 2.3.104 and 2.3.105 preserved
identities for inventory. That read-only recognition does not authorize
restore, purge or removal on those bytes. An old preserved instance needs an
independently qualified EP-owned compatible recovery route before this
installer can mutate it; it must remain blocked until then.

It delegates exact-target:

- inventory;
- create;
- status/readiness;
- update assessment;
- update execute/resume;
- repair;
- remove;
- preserve, purge, restore and lifecycle status;
- provider registration.

EP continues to derive its service label, service account topology, CENTRAL/data
root, runtime slot, migration, backup, activation, verification, cleanup and
recovery. Forge Platform cannot inject those internals through a generic
component request.

For `PRESERVE`, EP owns LaunchDaemon quiescence/removal and retains the exact
instance root, identity, CENTRAL/data, configuration, recovery material and
provider contexts. For `RESTORE`, EP validates the exact preserve operation and
release, recreates an allowed immutable runtime slot when needed, and registers
the same service inactive. Forge Platform must not start that service until EP's
normal provider registration/repair route has independently re-established
current provider evidence. `PURGE` delegates EP's existing destructive remove
and is terminal only with the product-owned purge tombstone.

## Forge adapter

Forge 2.7.38 has a deliberately different frozen boundary from EP. It retains
the existing `forge-server-runtime-lifecycle/v1` update/uninstall boundary and
adds `forge-server-instance-lifecycle/v1` for preserved instances.

Forge itself owns:

- `server init`, which creates and returns the authoritative opaque instance ID;
- server/provider-context operations;
- EP execution-host configuration/preflight;
- health/readiness;
- the qualified external installed updater.
- the read-only, exact-instance/candidate `server update-assess` decision;
- the durable exact-instance `server uninstall` and `server uninstall-status`
  dispatcher.
- exact-instance `server preserve`, `server purge`, `server restore`, and
  `server lifecycle-status` decisions.

Forge Platform owns the macOS system LaunchDaemon and installed filesystem
layout assigned to it by the Forge deployment contract. The LaunchDaemon uses
an exact absolute Forge executable, exact data root, non-root service account,
loopback endpoint and private bearer-file reference.

The installer consumes the owning assessment only from an explicitly bound
qualified lifecycle executable or external controller, exact installed artifact, qualified staged wheel
and exact product instance/installation IDs. Missing or contradictory evidence
remains `UNKNOWN` or fails closed. A positive assessment alone does not
complete the reviewed-update, updater-resume, readiness or registry gates.
For an exact public-wheel 2.7.35, 2.7.36 or 2.7.37 instance targeting the
exact 2.7.38 release, the adapter invokes the separately protected external
controller with base Python `-I` and `--assess-only`. It verifies the exact
controller source and bytes, release-complete receipt digest, selected
instance/artifact, candidate, request digest and canonical assessment digest.
The production controller binding is the corrected protected source
`e4b99a249845a547fd6b8e7e11d22467b2d0886d` with SHA-256
`6a6bb4ade3db9d1e45ba64a0d928e91013109de3243e8e2dbccfaa04a7a455b4`,
qualified in [forge#142 revision 26](https://github.com/pcvantol/forge/issues/142#issuecomment-5887942490).
The formerly pinned `bf7ae99…` controller remains historical `GAP_PROVEN`
evidence and is not admitted for a production update.
Immediately before mutation it repeats the product assessment and requires the
reviewed digest to match; the same digest is passed into the owning controller's
durable update request. Other candidate releases retain their existing
lifecycle-executable assessment route. These source gates do not establish
real released-helper execution or live update success.
The adapter accepts a completed external update only with Forge's exact
`forge-installed-update/v1` operation/request digest, selected artifact and
instance, migration evidence and installed preservation readback. A successful
process exit without that terminal receipt is rejected.
For a fresh update dispatch the adapter rechecks exact product inventory and a
new positive assessment before service mutation, stops the selected service,
delegates to Forge's updater, registers the selected resolver, restarts the
service and requires exact instance readiness. Interrupted post-updater
recovery and reviewed-assessment equivalence remain separate open gates.

The Forge adapter binds the product-owned uninstall dispatcher to one exact
instance and durable operation ID. It stops the selected LaunchDaemon, requires
Forge's terminal receipt and matching status, then removes only the
deployment-owned service definition. A same-operation replay is idempotent;
Forge alone removes verified mutable instance data. The higher-level managed
deployment remove route and GUI/CLI confirmation remain blocked until their
reviewed target, pairing and registry-commit gates are integrated and qualified.

For `PRESERVE`, Forge first proves exact identity, integrity and quiescence and
returns product-owned `UNINSTALLED_DATA_PRESERVED` evidence without deleting the
data root. Forge Platform then removes only the deployment-owned LaunchDaemon.
For `RESTORE`, Forge validates the exact prior preserve operation, complete tree
digest and same runtime/installation/instance identities, then returns
`RESTORE_VALIDATED`; Forge Platform recreates its service definition only after
that admission. For `PURGE`, Forge delegates its existing destructive uninstall
and persists the product-owned tombstone. A legacy uninstall receipt is never
reinterpreted as preserve evidence.

## Preserved-instance lifecycle state machine

Forge Platform consumes owning product receipts and lifecycle status; it never
infers lifecycle from a directory, service label, database, process or endpoint.
The managed inventory distinguishes at least:

```text
INSTALLED
UNINSTALLED_DATA_PRESERVED
PURGED_OR_ABSENT
```

`UNINSTALLED_DATA_PRESERVED` remains inventory-visible with the same opaque
deployment, component, instance, runtime and installation identities plus the
exact preserve-operation reference. It cannot enter ordinary create or be
claimed by another deployment. `PURGED_OR_ABSENT` never carries restore
authority; a later installation is a clean/new product instance state.

The reviewed lifecycle transitions are:

```text
INSTALLED --PRESERVE--> UNINSTALLED_DATA_PRESERVED
UNINSTALLED_DATA_PRESERVED --RESTORE--> INSTALLED
INSTALLED or UNINSTALLED_DATA_PRESERVED --PURGE--> PURGED_OR_ABSENT
```

Every transition binds the selected deployment revision, exact product instance,
producer version/source/artifact, operation ID, request digest, prior lifecycle
receipt and intended registry commit. Same-operation replay is idempotent;
changed request bytes, a stale deployment revision, concurrent lifecycle/update,
wrong/foreign instance evidence, tampering, symlinks or a purge tombstone fail
closed. The installer journal retains recovery references but never copies
product data or manufactures replacement lifecycle evidence. After interruption,
it reloads product status and resumes the same product operation before any
service or registry continuation.

For a paired Forge PRESERVE, the helper first durably binds the reviewed exact
deployment and Forge/EP instances to EP's product-owned consumer revocation.
It requires terminal EP status before quiescing Forge, and a replay reads the
same revocation journal and EP status before accepting the preserved registry
record. A second deployment is not a cleanup target. Paired EP PRESERVE remains
fail-closed until Forge's peer disposition has a qualified product-owned route.

Preserved configuration and provider bytes remain product-owned, but preserved
authentication is never `VERIFIED`. Restore must run fresh provider readback and,
when required, an explicit authentication/repair ceremony for each exact target.
The native RESTORE execution request now carries the reviewed prior PRESERVE
operation and receipt under a distinct canonical schema. The helper still
rejects execution before product mutation until the service, provider, pairing
and registry continuation below is implemented and independently qualified;
acceptance of the request envelope is not a terminal RESTORE result.
For a restored Forge+EP deployment, historical pairing material is only a
candidate: Forge and EP must independently prove their exact identities and the
pairing must be revalidated or re-established through the existing product-owned
pairing route before either cross-component readiness or final registry commit.

GUI and CLI consume the same inventory record, reviewed lifecycle plan, helper
request and terminal receipt. The safe action is **Remove software / keep data**
(`PRESERVE`). **Remove software and all instance data** (`PURGE`) is a separate
destructive action naming the exact deployment/component/instance and requires
fresh explicit confirmation immediately before dispatch. Cancel, timeout or
lost response does not change disposition and never converts preserve to purge.

## Durable execution

Before product dispatch, the native reviewed-operation coordinator preserves
one exact authority chain:

```text
reviewed wizard operation
→ read-only immutable stable plan
→ fresh signed installer-release currency check
→ provider/Python preparation and managed-tool reconciliation
→ reconstructed terminal MANAGED_TOOLS receipt
→ product-owned operations
```

The currency result must equal the complete installer release identity retained
by the reviewed operation; matching only the version is insufficient. A newer
release returns to the mandatory update route. A changed identity, substituted
stable plan, runtime failure or receipt from another plan stops before product
dispatch. A product completion is admitted only with nonempty passed stages and
nonempty readiness summary items.

The released-route coordinator now implements the read-only front half of that
chain. A helper-backed loader must return one immutable typed snapshot that
binds the exact deployment inventory, verified composition session, selected
deployment, all required passing host-preflight checks, the unacknowledged
Forge+EP review, initial managed-Python readback, original managed-tool actions
and a non-secret evidence reference. Inventory access clears prior authority;
preflight admits one exact snapshot; review and stable-plan preparation each
reload it and require equality before proceeding. Session, manifest,
deployment, inventory and component drift therefore fail closed before any
mutation. Direct execution on this coordinator remains unavailable: the
reviewed execution coordinator must wrap its stable-plan authority and the
privileged mutation route.

The helper transport for that loader is also source-qualified. It uses one
fixed privileged Mach service and the same exact Developer ID Application/Team
identity pair as the product-operation boundary. Inventory and route responses
are bounded strict canonical JSON. The route request carries only session,
manifest, deployment and inventory correlations; it accepts no path, command,
URL, environment value or credential. The helper response reconstructs the
typed inventory, exact passing preflight, Forge+EP review, managed-Python
readback and catalog-declared managed-tool actions. Noncanonical bytes,
unlisted deployments, correlation drift, partial responses and helper errors
fail closed. The release bundle now carries a distinct helper executable code
object and exact LaunchDaemon plist. Its released-route listener reads only
canonical evidence from one fixed helper-owned machine root. It opens that
root and each digest-derived route file without following links and requires
root ownership, `0700`/`0600` modes, one file link and stable descriptor
identity before replying. Product mutation now enters the serial managed-Python
worker executor described below. Post-tool observation still returns no
authority until its production backend is composed and qualified. The separate
verified producer that constructs route snapshots is also still absent, so a
fresh host remains fail-closed rather than accepting app-supplied state.

The durable publication primitive for that future producer is now
source-qualified. It accepts only a fully typed
`ManagedInstallerReleasedRouteSnapshot` in-process; it is not exported over
XPC and accepts no raw document, path, command, environment value or
credential. Under one non-blocking helper-owned file lease, it validates any
existing canonical state, writes `0600` temporary files with `fsync`, commits
the digest-derived route first and the inventory pointer last, then synchronizes
the private `0700` root. A crash can therefore leave an unreachable route but
cannot make inventory point at an incomplete route. Existing corrupt,
permissive, linked or noncanonical state is never silently repaired. The
catalog/registry/preflight producer that constructs the typed snapshot remains
to be composed inside the helper before this publisher grants a fresh host any
route.

The native ServiceManagement registration boundary is now explicit as well.
It fixes one `SMAppService` LaunchDaemon plist name, bundle-relative helper
program and the exact three Mach services at compile time. Registration is
followed by an independent status readback; only `ENABLED` is ready,
`REQUIRES_APPROVAL` remains visible and non-ready, and missing, failed or
drifted registration fails closed. The deterministic packager writes that
exact plist under `Contents/Library/LaunchDaemons`, places the separate thin
arm64 helper under `Contents/Resources`, and the signer signs that nested code
object first with the exact helper identifier before sealing the app. The
strict archive producer rejects a missing helper or plist. These source and
bundle controls do not treat a successful registration API return as reboot or
complete helper-backend evidence; verified route publication, product and
post-tool backend wiring, live registration and cold reboot readback are still
required.

The bundled CLI now offers `helper register` only after trusted released
startup. It requires explicit confirmation, repeats the installer-currency
read immediately before the ServiceManagement mutation and returns
`REQUIRES_APPROVAL` as a non-ready state. A changed release, missing service or
status drift remains blocked. This call path is source-qualified; a live
registration and reboot still require their own independent evidence.

### Used-helper upgrade within one boot

`L1-HELPER-UPGRADE-WITHOUT-REBOOT-V1-20261002` refines this existing helper,
self-update and recovery contract. A running or previously run daemon is not
an active product operation. Conversely, an empty process list or an absent
product journal does not close admission. Every mutating GUI, CLI and helper
XPC route must enter one helper-owned admission gate before it can begin any
effect, including worker launch, provider authentication, credential access,
selection publication and lifecycle recovery. The gate must retain an active
permit through each operation's terminal product-owned receipt or resumable
checkpoint. A request racing the close either owns a counted permit or gets
`BUSY`; unknown state and timeout get `BLOCKED` without stopping the helper.

The gate must durably bind one operation ID and generation to the exact source
and target signed artifacts, fixed SMAppService label, bundle/Team/signing
identities and caller audit/process identity. Closing admission and proving
quiescence are separate facts. The external, authorized coordinator holds an
exclusive root-owned transition journal, selects the supported service route
for the observed parent, and retains uncertain states for exact same-operation
resume. It must use new signed bundle inodes and may not edit a running signed
executable in place. `unregister`/`register` return, ENABLED status, on-disk
version and elapsed time are insufficient: completion needs observed old-job
departure, actual new process/signing/parent identity, fresh XPC inventory and
protocol readback, unchanged boot identity and unchanged product/provider/
pairing/sibling state. Duplicate invocation, changed candidate, stale epoch,
lost response and partial registration fail closed or resume the same operation;
normal exact-version product admission stays intact.

The first transition has a distinct legacy gate. The signed 0.3.13 helper has
no close/drain XPC protocol. Its product-operation endpoint can start a worker
under its own in-process `inFlight` flag; route selection, provider and other
mutations use separate paths. The 0.3.13 idle replacement requires both
`state = not running` and `runs = 0`. A new-only drain command, client-side
lock, current-release check or journal inspection cannot make those old
endpoints race-free. [Apple's SMAppService unregister contract](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister%28%29?language=objc)
states that unregister terminates a running LaunchDaemon, so unregister before
quiescence cannot itself serve as a graceful drain. The 0.3.14 target being
separately signed and staged does not alter the 0.3.13 registered parent.
Until a reviewed, supported legacy
adapter proves both admission closure and no active effects, this exact first
transition is `BLOCKED_LEGACY_TRANSITION`; no unregister, process signal,
reboot or product mutation follows from this document. This is a bound on the
observed old version, not a claim that macOS generally requires a reboot for
helper upgrades. Cold-boot/no-login acceptance remains a separate gate with
separate owner authorization.

The native core now also defines a canonical product-operation bridge for the
exact Forge+EP pair. Its request is rebuilt from that stable plan and terminal
runtime receipt and contains only reviewed identities, actions and evidence
references. It also carries the reviewed current Forge/EP instance and
installed-composition identities plus each selected candidate version and
digest, so the helper can compare them with its exact registry and
digest-pinned manifest. Artifact locators, paths, commands, environment
variables and credentials are not accepted. A terminal response must
canonically bind the request fingerprint,
stable-plan fingerprint and operation ID, include product, pairing and both
readiness receipts, and report the expected terminal state for both exact
components. Substituted, partial, malformed or noncanonical responses fail
closed before the GUI or CLI can show completion.
The shared completion projection shows a Forge↔EP relation stage only when
the canonical receipt contains the required product-owned relation evidence.
For a single-component route, no pairing success is displayed. For a paired
removal, the relation stage describes the received product evidence without
asserting that the removed instances remain linked.

This is source-level composition only. The released runtime still needs the
snapshot producer, concrete host and managed-tool adapters, reviewed execution
coordinator and product worker resource before it can complete the route. It
does not establish live install, signing, notarization or product-readiness
evidence.

The platform-neutral helper boundary now independently admits request v2 before
any product dispatcher can be selected. It accepts only bounded strict canonical
JSON with unique keys and the exact native fingerprint, then compares the full
installer-release identity, digest-bound Forge+EP manifest, candidate versions
and digests, required/enabled provider targets, durable deployment topology,
installed composition provenance, installed manifest versions and explicit
`upgrade_from` route. Its admitted result contains correlation objects only; it
does not contain or resolve an adapter, path, command, environment value or
credential. The concrete helper service and resolver implementations are now
source-qualified; signed helper-process registration and released-installer
wiring remain unimplemented and therefore fail closed.

After that admission boundary, a separate helper-owned resolver may now bind
the exact Forge and EP product instance identities, adapters and pairing
executor. The dispatcher rechecks the durable registry after resolution,
constructs deterministic component-operation identities from the admitted
request fingerprint, runs only the existing durable Forge+EP saga, and emits a
canonical native completion receipt only after both product receipts, pairing
and both readiness receipts exist. Fresh product identities therefore come
from the helper resolver rather than native request data. The concrete pinned
resolver is source-qualified; helper-process registration and released-installer
wiring are not supplied yet.

The native source now provides the authorized product-operation XPC boundary.
It uses a fixed privileged Mach service, requires the exact Developer ID
Application helper identity and Team ID on the client, and requires the exact
released installer bundle identity and Team ID on the listener. The transport
accepts only the bounded canonical request bytes above; the handler decodes
those bytes into the closed helper execution seam and returns only a canonical
receipt that rebinds the same request. Nil, malformed, noncanonical or
cross-request replies fail closed. This supplies no launchd registration or
live helper evidence by itself.

The privileged helper now connects that product-operation handler to one
serial managed-Python worker executor. It reads the active runtime slot only
from the helper-owned canonical host-state record and derives the interpreter
under one fixed runtime-slots root. It resolves one fixed bundle resource and
requires its exact `sha256:` digest from the code-sealed application
`Info.plist`. The interpreter must be a root-owned executable regular file with
one link and neither file may be group- or world-writable. Execution uses no
shell, `PATH` or inherited environment: the argument vector is fixed to
isolated Python, the environment is a five-key constant, the working directory
is `/var/empty`, request and response pipes are bounded, a fixed timeout is
enforced, and the response is decoded again against the exact request before
XPC replies. The deterministic app packager can now admit one bounded canonical
Python zipapp, copy its captured bytes to the fixed worker resource name and
bind their exact `sha256:` digest into `Info.plist`. It rejects leaf symlinks,
non-zipapps, duplicate or unordered entries, traversal names, non-regular or
non-`0644` entries, variable timestamps, encryption and oversized expansion.
The unsigned candidate workflow and local offline signer now build and supply
that worker. The strict archive producer rejects a missing or empty worker
resource. The installed product route remains fail-closed until a native
published authority and managed Python runtime are independently qualified.

The repository now also has a deterministic worker builder. It packages the
complete dependency-closed `forge_platform` Python package with one generated
`__main__.py`, fixed sorted regular `0644` ZIP entries, stored compression and
a fixed timestamp. The bounded entrypoint reads one request, invokes only a
typed `ManagedProductOperationHelperService`, emits one bounded receipt and
maps every unavailable backend or pipe failure to a silent nonzero exit. Its
default released service loader now reads only the fixed helper-owned authority
file described below. Absence or unsafe ownership, permissions, links, size,
encoding, JSON shape or byte instability remains a silent fail-closed worker
failure; merely building the zipapp therefore cannot grant product-mutation
authority.

The worker composition path can now reconstruct a manifest only from exact
canonical bytes plus a separately trusted matching digest, then pass the typed
manifest snapshot and exact native installer-release binding to one pinned
helper-service factory. That factory derives both concrete Forge/EP routes and
request admission from the same immutable manifest objects and durable
coordinator. The signed-catalog path still uses its stronger verified-selection
constructor; the digest-bound constructor makes no signature or freshness
claim and is reserved for the root-owned released authority reader.

That released reader is fixed to
`/Library/Application Support/AutonomousEngineeringSystem/ForgePlatformInstaller/product-worker-authority.json`.
The root must be owner-only `0700`; the authority must be one root-owned,
single-link, no-follow regular `0600` file and canonical strict JSON read
through a stable descriptor. It carries no executable, state, artifact,
credential or LaunchDaemon path. Those locations are derived from the fixed
root and safe deployment/instance IDs. It binds exact installer release data,
digest-matched candidate/historical manifest payloads and public route,
account, port and pairing identities. Service accounts and ports cannot be
reused across deployments. The worker reopens and rehashes the exact authority
immediately before every coordinator mutation; the native reviewed-execution
gate remains responsible for the preceding signed online installer-currentness
decision. A changed local snapshot fails closed. The native atomic publisher
now enforces exact previous-digest CAS and full typed readback of an existing
authority. A verified signed-composition and route producer must still publish
real authority; a real released snapshot and live execution remain outstanding.

Behind that transport, the platform-neutral helper service now composes the
strict decoder, helper-owned authority resolution, admission and durable
dispatcher in one closed call. Candidate and installed manifests plus the
current installer release come only from the injected helper authority. The
admission check uses the dispatcher's exact durable registry, and dispatch
rechecks that registry after route resolution before mutation. All boundary
failures become one non-secret rejection and only a bounded canonical terminal
receipt can return. An immutable authority-snapshot resolver now admits only
exact `(composition_id, manifest digest)` pairs already supplied as typed,
catalog-verified manifests and freezes the current installer release for the
helper call boundary. A concrete released-authority loader now accepts only
`VerifiedInstallerContext` and `VerifiedCompositionSelection` values produced
by the signed release/catalog boundary. It derives the native release binding,
requires all candidate manifests to share one exact current catalog, and keeps
historical same-scope selections eligible only for installed-manifest lookup.
It accepts no path, URL, raw bytes or request value. A concrete pinned product
route resolver now snapshots helper-owned typed Forge/EP adapters and pairing
executors under exact deployment IDs, rejects product-instance reuse across
routes, and allows an admitted request to select only its predeclared route.
Existing deployments must match the route's exact Forge and EP instances.
The concrete pairing executor now accepts only the typed Forge Server and EP
system-provisioner adapters, persists the exact helper-owned peer binding
through Forge, requires Forge's authenticated read-only compatibility
preflight, and independently binds EP's exact healthy instance/artifact
readback into non-secret terminal pairing evidence. A released product-route
builder now freezes exact helper-owned paths, targets, staged catalog-authorized
artifacts and pairing configuration, constructs the concrete Forge/EP adapters,
macOS LaunchDaemon supervisor and pairing executor, and composes those routes
with release/catalog authority in the closed helper builder. Native helper
registration exists, but approval and a released authority publication remain
live prerequisites. That
closed builder places the verified release/catalog authority loader and pinned
route resolver around one exact
`ManagedForgeEPInstallationCoordinator`; admission and dispatch therefore
cannot be wired to different registries or replaced with caller-owned
resolvers. This is still source-qualified wiring rather than a live production
route.

The managed-deployment operation coordinator reuses
`DurableComponentOperationCoordinator`. Each product mutation therefore keeps
its own product operation identity and resume semantics.

The deployment operation:

1. binds one reviewed deployment-plan fingerprint;
2. validates exact component/instance/action requests;
3. dispatches only through the selected product adapter;
4. preserves recoverable product receipts;
5. resumes the same component operation after interruption;
6. commits the managed-deployment registry only after all selected component
   mutations are terminal.

Cross-component pairing and full readiness remain later stages of the installer
saga; component completion alone is not a successful fresh-Mac acceptance.

## Qualification boundary

Source qualification must include Python, Swift and hosted macOS validation for:

- multiple deployment registry entries;
- no cross-deployment instance claim;
- exact-target revision conflict;
- restart/idempotent component operation recovery;
- two Codex targets under one human ceremony;
- independent target verification;
- Project Agent user scope;
- v2 manifest/session projection;
- exact credential-free managed-Python asset transport, private staging,
  no-follow readback and digest rejection;
- EP 2.3.106 provisioner and instance-lifecycle command correlation;
- Forge product-init identity binding;
- Forge system-service target isolation;
- Forge product-owned read-only update assessment, exact-target update
  execution/resume, durable legacy uninstall and preserve/purge/restore dispatch,
  including stale, ambiguous, tampered, purged, wrong-instance and
  missing-terminal-evidence failures;
- preserved inventory retention and no create-over-preserved-state;
- same-identity restore with provider and pairing revalidation;
- separate destructive confirmation with no preserve-to-purge fallback;
- same-operation interruption/restart/replay and cross-deployment isolation;
- byte-equivalent GUI/CLI/helper lifecycle plans and receipts.

A source/PR PASS is not a signed installer release and is not a live Mac
installation claim.

## Deferred live acceptance

The following can be claimed only after the separately protected installer
release and authorized physical Mac qualification:

```text
SIGNED_NOTARIZED_INSTALLER=PUBLISHED
FRESH_MAC_INSTALL=PASS
COLD_REBOOT_NO_USER_LOGIN=PASS
FORGE_SERVER_READY=PASS
EP_SERVER_READY=PASS
FORGE_EP_PAIRING=PASS
MULTI_INSTANCE_ISOLATION=PASS
FORGE_PRESERVE_RESTORE=PASS
EP_PRESERVE_RESTORE=PASS
SAME_INSTANCE_ID_AFTER_RESTORE=PASS
DATA_CONFIGURATION_PRESERVED=PASS
PROVIDER_AUTH_REVERIFIED=PASS
FORGE_EP_PAIRING_REVALIDATED=PASS
PURGE_THEN_RESTORE_REJECTED=PASS
PURGE_THEN_REINSTALL_IS_CLEAN=PASS
LIFECYCLE_CRASH_RESTART_IDEMPOTENCE=PASS
```

Provider interactive authentication, Developer ID signing/notarization and a
real reboot cannot be replaced by fixtures or source tests.
