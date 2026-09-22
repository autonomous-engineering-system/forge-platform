# ADR-0007 — Multi-instance managed deployments and provider authentication fan-out

**Status:** Accepted

## Context

Forge Platform must support more than one Forge Server instance and more than one
Engineering Platform Server instance on the same macOS host. A server instance is
not synonymous with a machine installation: each instance has its own stable
identity, service lifecycle, mutable state, provider runtimes, provider
authentication state, configuration, endpoints, logs and recovery material.

Forge Server and Engineering Platform Server are headless system services. On
macOS each selected server instance must run as a system-domain `LaunchDaemon`
and must be able to become ready after a cold reboot before any interactive user
logs in. Provider execution required by that server instance therefore cannot
depend on a logged-in user's home directory, login Keychain session or GUI
process.

Engineering Platform Project Agents have the opposite ownership boundary. They
are user-owned components: one Agent context may exist per Host/OS-user context,
and multiple users on one machine may each install and run their own Agent. An
Agent starts with its owning user session and retains user-scoped local
repository and credential state. Server and Agent cardinality are independent.

The native Forge Platform Installer already models a provider gate, but its
current source-level provider requirement is identified only by provider
(`codex` or `github-cli`) and assumes user-scoped credentials. That model
cannot represent one human Codex login that provisions two independently owned
Codex contexts for a selected Forge instance and EP instance.

## Decision

### Managed deployment is the installer management unit

Forge Platform introduces a **managed deployment** as the installer-owned
management binding for a selected set of product instances. For the current
Forge/EP server topology a deployment may contain:

- zero or one Forge Server instance;
- zero or one Engineering Platform Server instance; and
- when both are present, one explicit Forge-to-EP peer binding between those
  exact instances.

At least one server component is present in a managed deployment. A deployment
has its own opaque stable identity plus an optional human-readable label.
Product instance identities remain product-owned and are never replaced by the
deployment identity.

Examples on one Mac are valid:

```text
deployment production
  Forge forge-prod
  EP    ep-prod

deployment development
  Forge forge-dev
  EP    ep-dev

deployment ep-only
  EP    ep-lab
```

The installer inventories existing managed deployments and lets the operator
select one exact deployment to create or manage. Management is expressed as a
reviewed desired-state diff, not as a machine-wide product action:

- add a Forge or EP component instance;
- update one or both selected component instances;
- retain a component unchanged;
- remove one selected component instance;
- repair an explicitly supported unhealthy component; or
- remove the complete selected deployment.

Removing one deployment never implies removing another instance or deployment
on the same host.

### Server instances are fully isolated

Every Forge Server and EP Server instance has distinct mutable ownership. At
minimum the following are instance-scoped:

- opaque product instance identity and optional instance label;
- `launchd` service identity;
- service account/security context;
- runtime selection and product-owned data root;
- database/CENTRAL state;
- ports/endpoints and product configuration;
- logs, cache, backups, locks and recovery state;
- provider runtime installations;
- provider configuration/authentication state; and
- peer bindings and installation/update receipts.

Different instances may consume identical immutable artifact bytes or a
deduplicated installer-owned download cache, but they do not share mutable
runtime slots, provider homes, credentials, product databases or upgrade
lifecycles.

Forge and EP are symmetric in cardinality: a host may contain multiple Forge
Server instances and multiple EP Server instances.

### Provider login is deduplicated only at the human interaction layer

Provider tooling and provider authentication are projected from the exact
component instances selected in the managed deployment.

A provider may require only one interactive human authentication ceremony for
one installer operation. The trusted installer coordinator may fan the
resulting provider-authorized bootstrap into multiple selected component
contexts, but each target context remains independently installed, owned,
persisted and verified.

For example, installing one Forge instance plus one EP instance may result in:

```text
interactive Codex login: 1x
  -> Forge-instance-owned Codex CLI + provider home + auth state
  -> EP-instance-owned    Codex CLI + provider home + auth state

interactive GitHub login: 1x
  -> EP-instance-owned GitHub CLI + provider home + auth state
```

If only EP is selected, only the EP-owned provider contexts are provisioned. If
only Forge is selected, only the Forge-owned provider contexts are provisioned.

The invariant is:

> Provider authentication may be deduplicated for the human, but provider
> runtime, configuration, credential state, verification and lifecycle are
> never deduplicated across owning component instances.

The installer must use a provider-supported bootstrap or transfer mechanism. It
must not assume that an opaque credential file can safely be copied. Every
target context is independently validated after fan-out. A successful human
login is not sufficient evidence that either target context is ready.

The current identity-only/user-scoped provider schema is therefore an
implementation gap. Future composition/provider contracts must identify the
owning component instance (or an immutable target binding) separately from the
provider identity and must admit system/component-owned credential scope for
server instances.

### Cold-boot provider readiness is required for server instances

A completed Forge or EP Server installation must not depend on any interactive
macOS login after installation. Qualification for a server instance includes a
cold reboot with no GUI user login and proof that:

- its system-domain `LaunchDaemon` starts;
- its exact provider executable(s) resolve from the instance-owned context;
- its durable provider authentication is usable without a user login;
- provider readiness is independently verified for that instance; and
- the instance reaches its product-owned health/readiness state.

Provider secret material remains outside Forge Platform receipts, logs and
composition metadata. The product/provider adapter owns the secure storage and
refresh semantics for its instance.

### EP Project Agents remain user-owned and multi-user

Engineering Platform Project Agents are not converted into system services.
Each Agent remains scoped to one Host/OS-user context and may serve zero or more
repositories for that user. Multiple users on the same machine may each have an
independent Agent installation/context.

Agent state, local repository bindings and user-scoped credentials are isolated
per macOS user. A user Agent never borrows the EP Server's system provider
credentials merely because both run on the same host.

After a reboot with no user logged in, Forge/EP Server instances may be healthy
while all user Project Agents are correctly absent. Agent availability begins
when the owning user session starts.

### Native GUI and CLI share one orchestration core

The native SwiftUI `ForgePlatformInstaller.app` remains the primary interactive
first-install and lifecycle UX. A future CLI entrypoint must consume the same
trusted composition/session, managed-deployment inventory, provider fan-out,
product-operation adapters, receipts and readiness gates. GUI and CLI are two
frontends over one installer orchestration contract, not separate installation
engines.

### Product-owned lifecycle routes remain authoritative

Forge Platform owns cross-product orchestration and the managed-deployment
record. Forge and EP continue to own their installation/update/migration/
activation/verification/cleanup semantics. Existing qualified product-owned
update routes are reused through adapters; the installer does not implement a
second product migration or rollback engine.

## Consequences

- Machine-wide singleton assumptions for Forge Server or EP Server are invalid.
  Inventory and conflict detection must be instance-aware.
- Human-friendly instance/deployment names are labels; opaque identities remain
  authoritative.
- Ports, service labels, data roots and provider contexts must be allocated or
  selected without collision across same-product instances.
- The existing composition/provider schema and native provider state machine
  require a later governed implementation revision to represent
  component-instance-owned provider contexts and system-service credential
  scope.
- The parked EP-only clean-install v1 roadmap remains a deliberately narrow
  qualification slice. It does not constrain the broader multi-instance target
  or make user-scoped provider credentials canonical for server deployments.
- Installer acceptance must cover create, add-component, update,
  remove-component and remove-deployment flows against multiple coexisting
  deployments, including negative isolation tests.
