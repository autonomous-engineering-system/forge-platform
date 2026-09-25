# Managed Installer V1 — Forge + Engineering Platform

**Assignment:** `L1-FORGE-PLATFORM-MANAGED-INSTALLER-V1-20260923`  
**Owning repository:** `autonomous-engineering-system/forge-platform`
**Producer baselines:** Forge 2.7.34 and Engineering Platform 2.3.102  
**Status:** source implementation under protected qualification; no live installation claim.

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

The EP adapter consumes the frozen 2.3.102
`engineering-platform.system-provisioner/v1` command boundary.

It delegates exact-target:

- inventory;
- create;
- status/readiness;
- update assessment;
- update execute/resume;
- repair;
- remove;
- provider registration.

EP continues to derive its service label, service account topology, CENTRAL/data
root, runtime slot, migration, backup, activation, verification, cleanup and
recovery. Forge Platform cannot inject those internals through a generic
component request.

## Forge adapter

Forge 2.7.34 has a deliberately different frozen boundary.

Forge itself owns:

- `server init`, which creates and returns the authoritative opaque instance ID;
- server/provider-context operations;
- EP execution-host configuration/preflight;
- health/readiness;
- the qualified external installed updater.

Forge Platform owns the macOS system LaunchDaemon and installed filesystem
layout assigned to it by the Forge deployment contract. The LaunchDaemon uses
an exact absolute Forge executable, exact data root, non-root service account,
loopback endpoint and private bearer-file reference.

Two important fail-closed limitations remain on the 2.7.34 producer contract:

1. **Update:** Forge publishes a durable updater but no separate product-owned
   read-only `UPDATE_AVAILABLE` assessment. Forge Platform therefore does not
   infer update authorization merely because an updater exists.
2. **Remove:** Forge 2.7.34 publishes no product-owned uninstall dispatcher.
   Forge component/deployment removal remains unsupported rather than deleting
   a Forge data root as an installer invention.

Those are producer-contract gaps, not permission for Forge Platform to
duplicate Forge lifecycle logic.

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

This is source-level composition only. The released runtime continues to inject
the unavailable route until concrete catalog, host, managed-tool and product
adapters plus the released privileged-helper wiring are qualified and
explicitly installed. It does not establish live install, signing,
notarization or product-readiness evidence.

The platform-neutral helper boundary now independently admits request v2 before
any product dispatcher can be selected. It accepts only bounded strict canonical
JSON with unique keys and the exact native fingerprint, then compares the full
installer-release identity, digest-bound Forge+EP manifest, candidate versions
and digests, required/enabled provider targets, durable deployment topology,
installed composition provenance, installed manifest versions and explicit
`upgrade_from` route. Its admitted result contains correlation objects only; it
does not contain or resolve an adapter, path, command, environment value or
credential. The concrete helper executor, resolver implementation and
released-installer wiring remain unimplemented and therefore fail closed.

After that admission boundary, a separate helper-owned resolver may now bind
the exact Forge and EP product instance identities, adapters and pairing
executor. The dispatcher rechecks the durable registry after resolution,
constructs deterministic component-operation identities from the admitted
request fingerprint, runs only the existing durable Forge+EP saga, and emits a
canonical native completion receipt only after both product receipts, pairing
and both readiness receipts exist. Fresh product identities therefore come
from the helper resolver rather than native request data. No concrete resolver,
helper process registration or released-installer wiring is supplied yet.

The native source now provides the authorized product-operation XPC boundary.
It uses a fixed privileged Mach service, requires the exact Developer ID
Application helper identity and Team ID on the client, and requires the exact
released installer bundle identity and Team ID on the listener. The transport
accepts only the bounded canonical request bytes above; the handler decodes
those bytes into the closed helper execution seam and returns only a canonical
receipt that rebinds the same request. Nil, malformed, noncanonical or
cross-request replies fail closed. This supplies no launchd registration,
concrete helper executor, product resolver or live helper evidence by itself.

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
It accepts no path, URL, raw bytes or request value. The product route resolver,
helper-process registration and released-installer process wiring are still
absent.

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
- EP 2.3.102 provisioner command correlation;
- Forge product-init identity binding;
- Forge system-service target isolation;
- fail-closed unsupported Forge update/remove semantics.

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
```

Provider interactive authentication, Developer ID signing/notarization and a
real reboot cannot be replaced by fixtures or source tests.
