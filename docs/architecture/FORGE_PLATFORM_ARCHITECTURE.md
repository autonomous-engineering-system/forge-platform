# Forge Platform Architecture

## Purpose and status

This is the canonical high-level architecture entrypoint for the Forge Platform ecosystem composition. It records product and trust boundaries needed for later work. The repository now contains a source-level Universal Installer policy kernel and native macOS wizard shell, but does not yet implement a privileged product provisioner, service mutation, provider credential flow, installer publication, or Schema 41. Its bounded composition-release evidence flow may retain a verified manifest and receipts, but it never publishes producer bytes or becomes a product runtime.

Forge Platform is a first-class product repository, not a canonical project authority repository for a customer's product. A **Canonical Project Authority Repository** is a logical product's durable topology authority; `autonomous-engineering-system/forge-platform` is the Forge-family distribution and deployment product.

Detailed decisions are recorded in the [ADRs](adr/README.md). The [ownership matrix](OWNERSHIP_MATRIX.md) is the concise authority reference.

The [Governed Engineering Knowledge Learning Loop](KNOWLEDGE_LEARNING_LOOP.md) records the independently owned Knowledge Base lifecycle and its additive cross-product integration boundary.

The Universal Installer's supported host contract is deliberately narrower
than the future component topology: it is a thin native arm64 application for
Apple Silicon Macs running macOS 26 or newer. Intel, Rosetta translation,
`x86_64` release assets, fat/universal installer executables, and macOS 25 or
older are rejected before any platform mutation. Product artifacts and future
platform expansion require their own reviewed increments; there is no fallback
architecture in the current installer release or composition schemas.

The signed composition catalog additionally approves one exact managed-Python
runtime identity. A composition is admissible only when its full arm64/macOS-26
runtime material, every component's build/test qualification, and one isolated
venv identity per product bind that same digest. Runtime selection never uses
`PATH`; the accepted operation freezes the target and any retained rollback
identity. The source-level executor now durably coordinates exact acquisition,
archive-evidence verification, immutable runtime/venv slots, final readback and
frozen-identity rollback through injected adapters. The native source kernel
also continues an exact prepared runtime through idempotent component-venv
readiness, activation, rollback retention and final readback behind a closed
injected privilege seam. It persists the exact native `READY` receipt in a
private atomic recovery record and revalidates all venv and active-runtime
readbacks on an exact retry. A separate native terminal coordinator projects it
into the platform-neutral `COMPLETE` receipt with a cross-implementation request
fingerprint, projects the exact typed `TOOLS_VERIFIED` parent-journal evidence,
and clears pending state only after an injected parent-journal
bridge succeeds. The native file-backed parent journal now persists one exact
active `PLANNED` record as canonical private JSON, serializes access with its
own validated lock, and atomically replaces it with the exact idempotent
`MANAGED_TOOLS` evidence. A concrete native fresh replanner now derives managed
Git and Python actions, five non-tool gates and the canonical post-tool plan
fingerprint from independently injected fresh readbacks; it cannot accept a
precomputed qualification. A native parent-journal seeder now rebinds the
exact session, deployment, pre-mutation runtime plan and original managed-tool actions,
derives whether reconciliation is required, writes `PLANNED`, and requires an
identical durable readback before preparation may begin. The later activation
request must bind that plan to the exact `READY` preparation receipt. The
seeder and fresh replanner now accept one typed native stable plan rather than
a caller-supplied digest. That plan canonically binds the reviewed installer
release, session/catalog identities, exact Forge+EP inventory, provider
requirements, component diff, managed Git actions, Python readback, rollback
and venv intent; its derived fingerprint is the only stable-plan identity
persisted in the parent journal. The concrete post-tool reader accepts one
strict private snapshot, and a helper-facing single-assignment store persists
it with exclusive atomic rename and durable descriptor readback. A producer
coordinator accepts one host observation, validates its frozen context, persists
it and requires identical durable readback before the replanner can consume it.
A closed privileged-boundary adapter now derives one pathless helper request
from the stable plan and activation request, accepts exactly one canonical
snapshot response and rejects malformed, noncanonical or context-drifted
responses. A native client sends those canonical bytes only through one fixed
NSXPC interface to one fixed privileged Mach service and requires that remote
service to satisfy the exact fixed helper signing identifier and configured
Team identity on a Developer ID Application chain. A paired service handler
rejects invalid or noncanonical requests before capture and emits only a
canonical context-matched snapshot. Its named listener applies the reciprocal
requirement to the configured installer bundle and Team identities. A locked
helper-side capturer acquires the shared host mutation lease, performs exactly
one complete low-level host read, verifies the exact tool and gate sets and
binds the result to that request. A concrete fixed-file reader securely admits
one canonical helper-owned host-state document and rejects insecure filesystem
objects, unstable bytes and request-set drift. Its paired publisher atomically
replaces that fixed document, refuses to repair insecure or noncanonical prior
state, synchronizes file and directory descriptors, and requires exact durable
readback before returning the observation. The Git, Python and gate adapter
seams are now composed through one closed source coordinator that reads only the
exact request set and requires the same helper-owned epoch before and after all
reads. A first concrete managed-Git source adapter now reads one fixed,
helper-owned canonical state record through a stable descriptor. It preserves
only an explicitly recorded `ABSENT` or `UNKNOWN` state and otherwise rejects a
missing, insecure, malformed or noncanonical record; it does not inspect
caller-selected paths or `PATH`. Its paired store now publishes one typed
observation atomically, refuses to repair insecure prior state, synchronizes
file and directory descriptors and requires exact durable readback through a
closed decorator. A first concrete managed-Python source adapter now reads one
fixed helper-owned canonical state record through the same stable no-follow
boundary. It preserves the exact active runtime and slot, ordered retained
runtime identities and evidence reference; only an explicit nil runtime/slot
with no retained identities means absent. Missing, insecure, malformed,
noncanonical or internally inconsistent evidence fails closed. The live
managed-Python record store now atomically publishes only over secure canonical
prior state, synchronizes file and directory descriptors and exposes the source
observation only after exact durable readback. The live managed-Git and
managed-Python OS observers and mutation adapters, signed service registration
and released wiring are not implemented. A first
concrete gate source now reads one fixed canonical record containing exactly
all five gate identities through the same stable no-follow boundary. Missing,
insecure, malformed, incomplete, duplicate or noncanonical gate evidence fails
closed; an explicit failed gate remains valid blocking evidence. Its atomic
publisher refuses to repair insecure prior state and its decorator exposes a
gate only after the complete five-gate set has exact durable readback. Live
gate observers are not implemented. No Git or Python artifact, privileged
helper or operational runtime installation is claimed.

The source-level native parent-journal admission adapter now gates that bridge
on a fresh qualification bound to the frozen stable-plan fingerprint, exact
runtime/rollback/venv identities, all-`NO_CHANGE` tool state and product
dispatch readiness. The composition parser now also retains the exact managed
Git requirement used by that replanner. A concrete descriptor-safe file reader
now admits one strict, bounded post-tool snapshot that binds the operation,
session, deployment, stable plan, execution request, all managed-tool and
Python observations, and all five gates to one evidence epoch. It rejects
symlinks, hardlinks, permissive ownership/modes, context drift and mixed
snapshots. Its paired store requires an existing private root, writes one
context-matched `0600` record with file and directory synchronization, accepts
only exact idempotent retries and rejects conflicting evidence. A producer
coordinator then binds exactly one host observation to that store and
reader. The strict host-observation adapter, fixed privileged NSXPC client
transport, fail-closed service handler and exact signed-caller listener are
implemented together with exact signed-helper authentication on the client;
the locked single-read helper capturer is also implemented. The concrete
fixed-file host-state reader, atomic publisher, source/publish/durable-readback
coordinator and epoch-bracketed exact source collector are also implemented.
The concrete descriptor-safe managed-Git record reader, atomic publisher and
source/publish/durable-readback decorator are also implemented. Its live OS
observer and mutation route remain absent. The descriptor-safe managed-Python
record reader, atomic publisher and source/publish/durable-readback decorator
are implemented; its live OS observer and mutation route remain absent.
The descriptor-safe complete five-gate record reader, atomic publisher and
complete-set source/publish/durable-readback decorator are implemented; live
gate observers remain absent. Signed service registration, released route
wiring and mutation dispatch remain unimplemented.

## Installed-server deployment and topology bootstrap

The accepted target deployment is defined by [ADR-0006](adr/ADR-0006-server-deployment-and-discovery.md) and the shared [instance discovery and pairing contract](INSTANCE_DISCOVERY_AND_PAIRING_CONTRACT.md). Forge Server, EP Server and Workspace Server are headless, independently installed services with separate central runtime roots, product-owned SQL/files and versioned HTTP APIs above their application services. They may share a host but not a database or direct SQL path.

Forge Platform composes verified artifacts, coordinates product-owned service-lifecycle requests/readbacks and topology bootstrap for EP-only, Forge+EP, Workspace+EP, all-server and remote-peer configurations. It calls product APIs to create product-owned bindings; it never writes product databases. The installer is not a required runtime dependency after installation. Its separately versioned self-updating native macOS artifact and signed composition-catalog boundary are defined in the [Universal macOS Installer contract](UNIVERSAL_MACOS_INSTALLER_CONTRACT.md).

Server cardinality is many, not one-per-host. One Mac may run multiple Forge
Server instances and multiple Engineering Platform Server instances. Each
instance retains an opaque product identity plus isolated service, runtime,
data/database, endpoint, provider and credential state. Forge Platform groups
the exact selected server instances into a **managed deployment** for installer
lifecycle operations. A managed deployment is installer-owned management
metadata; it does not replace product instance identity or product-owned
installation state.

For the current Forge/EP topology a managed deployment may contain one selected
Forge instance, one selected EP instance, or both. When both are present the
deployment records the intended exact peer pairing. Installer operations target
that deployment and produce an explicit desired-state diff: add component,
update, no-change, supported repair, remove component, or remove the selected
deployment. Other same-host deployments remain outside the operation.

Provider interaction follows the same instance boundary. A single human login
ceremony may provision several selected component-instance contexts, but Forge
and EP retain separate provider CLI installations, homes, durable auth state and
lifecycles. Server provider state must survive cold reboot and be usable before
any GUI user logs in. EP Project Agents remain user-owned per Host/OS-user
context and may coexist for multiple users on the same machine. See
[ADR-0007](adr/ADR-0007-multi-instance-deployments-and-provider-fanout.md).

Discovery yields an unauthenticated candidate only. Pairing verifies stable identity and creates a pinned authenticated binding; a later discovery result cannot silently replace it. Workspace Client↔Workspace Server, EP Agent↔EP Server and server-peer credentials remain separate even on localhost.

## First-class component model

| Repository | First-class authority / published component |
| --- | --- |
| `pcvantol/forge` | Forge Runtime: architecture planning and orchestration |
| `pcvantol/workspace` | Workspace Server and Workspace Client(s) |
| `pcvantol/engineering-platform` | Engineering Platform Server and Engineering Platform Project Agent |
| `pcvantol/technical-debt-engine` | Technical Debt Engine product authority |
| `autonomous-engineering-system/forge-platform` | Universal distribution, deployment, and release composition |
| `pcvantol/ai-development-contracts` | Generic AI-development contract authority |
| `pcvantol/ai-platform-engineering-knowledge-base` | Generalized and certified engineering knowledge authority |

Forge, Workspace, and Engineering Platform are peers. No product repository is a parent source authority for another.

The Knowledge Base is currently a Git-backed, repository-local CLI capability, not a Workspace/EP server role and not a current Forge Platform installer component. It owns source onboarding, observation, knowledge lifecycle, certification, and publications. Forge Platform may later distribute a qualified KB artifact, but owns neither its runtime nor its knowledge authority.

```mermaid
flowchart LR
  F[Forge Runtime\nplanning and intent] --> W[Workspace Server\nshared control-plane state]
  F --> EP[Engineering Platform Server\nexecution authority]
  W -->|control intent| EP
  WC[Workspace Client\nhuman UX] <--> |user/session boundary| W
  EP <--> |host/agent boundary| A[EP Project Agent\nlocal execution edge]
  WC <--> |local UX boundary| A
  FP[Forge Platform] -. installs qualified artifacts .-> F
  FP -. installs qualified artifacts .-> W
  FP -. installs qualified artifacts .-> EP
  FP -. installs qualified artifacts .-> A
  FP -. installs qualified artifacts .-> WC
```

## Product boundaries

### Forge Runtime

Forge owns product/system architecture planning, roadmap and backlog reasoning where Forge-owned, engineering intent, development-lane planning, cross-repository dependency planning, and the conceptual determination of work that may run in parallel. It does not own local repository execution, EP scheduling implementation, EP evidence/qualification, Workspace shared UI state, Project Agent behavior, or universal installation.

### Workspace Server and Workspace Client

Workspace Server is the shared control-plane and product-team state service. It owns Workspace project state, topology presentation, shared team/user status, Workspace-owned lane and scheduling UX state, sessions, and aggregation of Forge and EP information. It is not execution authority.

Workspace Client is human-facing UX. It authenticates to a Workspace Server and presents the same server-authoritative shared project state as other clients, subject to permissions. It can initiate canonical control-plane actions, but does not become shared-state authority or directly execute engineering work through an Agent.

Local facts such as repository presence, current branch, IDE availability, and installed tools may augment shared state. They never redefine authoritative product/project truth. A Workspace Client without a Project Agent is a valid first-class deployment: it supports shared views, planning/status, reports, and permitted remote actions through eligible Agents, but not local repository, host, or IDE operations.

### Engineering Platform Server and Project Agent

Engineering Platform Server is execution authority. It owns engineering admission, durable queueing/scheduling, lane admission, host/agent selection, repository lock/lease lifecycle, provider execution, validation, qualification, evidence, EP-owned Prompt History, finalization/execution state, Consumer API, and server-side Agent protocol authority. Forge and Workspace do not bypass it. It alone decides whether advertised Agent capacity becomes an admitted execution; an Agent never self-admits work merely because it has a free slot.

Engineering Platform Project Agent belongs solely to `pcvantol/engineering-platform`. One installed Agent service/process per Host/OS-user context may serve zero or more locally attached repositories. It owns the local repository/Git/filesystem boundary, attachment/discovery, host-capability discovery, bounded local execution, secure local credential handling, health, approved local IPC, and protocol communication with EP Server. For post-verification parallel execution it advertises a bounded capacity (for example `max_parallel_executions` or execution slots), but that is availability input to EP admission rather than scheduling authority. It is not owned by Forge, Workspace, or Forge Platform.

An Agent is not one binary or process per repository. A repository may later contain non-secret declarative configuration such as `.engineering/project.json`; secrets remain in OS-native secure credential storage.

## Project, repository, host, Agent, and lane model

| Domain identity | Canonical relationship |
| --- | --- |
| Project | Has exactly one Canonical Project Authority Repository and zero or more Child Repositories. |
| Repository | Belongs to one logical Project context when attached and may be available on one or more Hosts. |
| Host | A machine or environment. |
| Engineering Platform Project Agent | Local repository and execution capability on one Host; exposes zero or more repositories. |
| Execution Lane | Belongs to one Project, targets one or more repositories, has dependencies, and requires repository execution resources/locks. |

A single-repository Project is the trivial case: its Canonical Project Authority Repository is also its only source/execution repository. No separate architecture is required.

A multi-repository Project has one Canonical Project Authority Repository plus zero or more autonomous Child Repositories. Child membership is a project-topology relationship, not Git submodule or source-control subordination.

```mermaid
flowchart TD
  P[Project] --> CPA[Canonical Project Authority Repository]
  P --> I[iOS Child Repository]
  P --> A[Android Child Repository]
  P --> W[Web Child Repository]
  CPA -->|versioned topology| T[Repository membership, roles, dependencies]
  H1[Alice Mac] --> I
  H2[Bob Windows] --> A
  H3[Carol Mac] --> W
  H4[Shared Mac mini] --> CPA
```

The Canonical Project Authority Repository owns durable, versioned cross-repository concerns: product-wide architecture and ADRs, Forge and Workspace project definitions, membership/topology, EP project topology/configuration, appropriate product-wide AI-development projection/extension, TDE integration/profile, and cross-repository planning boundaries. It need not contain application source.

Logical topology is **Project → repositories, roles, dependencies**. Physical topology is **Repository → available Hosts and Agents**. Versioned project authority documentation/configuration must reconstruct logical topology; Workspace Server persistence is not its sole source of truth. EP uses both topologies for execution eligibility.

## Team, offline, and capability model

Team deployment is first-class: different developers can hold different repositories on different hosts, each with its own Agent. Workspace shared state spans those hosts. EP can observe Agent health, repository availability, host capabilities, and lane status without assuming every host has every checkout.

Agents may be offline. Forge planning and Workspace shared state remain available; EP may wait for an eligible host/Agent rather than infer availability. This document uses no final state-machine constant.

Agents discover host capabilities such as Xcode/iOS signing, .NET/Windows, Android SDK, Docker, Python, Node, OS, and architecture. Forge may express planning requirements; EP alone determines actual eligibility and admission.

## Execution lanes, dependencies, locks, and post-verification parallelism

Forge plans lane dependencies. EP admits executable work and enforces ordering.

The safe initial concurrency rule is **at most one mutating Execution Lane per Repository at a time**. Repository-level locks are the initial resource model:

- a lane touching `ios` locks `ios`;
- a lane touching the Canonical Project Authority Repository and `ios` locks both;
- an Android-only lane may proceed concurrently if it has no plan dependency.

Resource exclusion and plan dependency are distinct. The same repository excludes simultaneous mutation even without a planned dependency. Different repositories may still need A → B sequencing because Forge planned it. The repository lock/lease is the resource-exclusion boundary: EP durably grants, renews, releases, and recovers it; neither Forge, Workspace, nor an Agent may replace it with a local convention.

### Post-`STANDALONE_EP_VERIFIED` multi-repository parallel lane execution

The first qualified parallelism capability is **parallel mutating execution across different repositories**. It starts only after `STANDALONE_EP_VERIFIED` and is deliberately narrower than general distributed execution or same-repository concurrency.

```text
Forge DAG/dependencies ──plans──> EP Server admission/durable state
                                      ├─ repository A lock/lease → Agent slot 1 → lane A
                                      ├─ repository B lock/lease → Agent slot 2 → lane B
                                      └─ repository A busy or A → B dependency → queued
```

- Forge plans the DAG, dependencies, and intent, but is not execution authority and cannot admit a lane.
- EP matches an eligible Host and Agent capability, evaluates dependency state, repository lock/lease availability and bounded Agent capacity, then applies backpressure and fairness before admission. It owns lane-scoped evidence, validation and finalization even when several lanes run at once.
- A Project Agent may expose `0..N` repositories for its Host/OS-user context and advertises bounded executable capacity; it safely manages only the executions EP has admitted.
- Workspace presents and controls the resulting state only through its permitted control-plane and UX boundary. It does not allocate slots, grant locks, schedule work, or directly execute it.
- At most one mutating lane may hold a given repository's lease. Independent repositories may mutate in parallel only when their Forge-planned dependencies are satisfied. A multi-repository lane must hold every required repository lease before it mutates any target.

This gives direct safe acceleration for independent work in Forge, Workspace, Engineering Platform, Forge Platform, and other autonomous repositories. It does not imply that all such work is independent: Forge can still require a sequence between otherwise separately lockable repositories.

Same-repository parallel execution through multiple worktrees, declared disjoint scopes, and explicit handling of shared generated or migration resources is a later, separately qualified capability. It is not required for the first multi-repository parallelism milestone.

## Deployment, artifacts, and installer roles

Forge Platform owns universal composition, deployment profiles, component selection, manifests, validated compatibility matrix, artifact acquisition/verification, topology bootstrap, installer/updater UX, and composition receipts. It orchestrates product-owned installation provisioners; it does not duplicate a product's runtime-selection, service, migration, recovery, verification, or cleanup engine.

It consumes independently published artifacts and does not compile or repackage product source as a hidden monolith:

| Product repository | Artifact ownership |
| --- | --- |
| Forge | Forge Runtime artifact |
| Workspace | Workspace Server and Workspace Client artifacts |
| Engineering Platform | Engineering Platform Server and Engineering Platform Project Agent artifacts |
| Forge Platform | Validated composition and distribution of those artifacts |

A Forge Platform release is a tested composition, not a monorepo source version. Each product owns its version and protocol implementation; Forge Platform owns the cross-product compatibility declaration used for a platform release/install.

For an Engineering Platform component, Forge Platform supplies the complete
exact qualified artifact identity and requested role to an EP-owned provisioner
adapter, then consumes its correlated installation readback, update assessment,
and health/cleanup evidence. The EP resolver alone selects the operational
runtime, executable, server, and instance; it also determines candidate
compatibility and machine-wide conflict coverage. Forge Platform may retain
those product-issued identities for a composition receipt. Forge Platform never selects an EP runtime through `PATH`.
The Forge Platform request and durable record retain the full qualified artifact
(including locator and qualification evidence); product-issued readback,
assessment, and receipt data retain only the exact version/source-revision/digest
correlation. A product endpoint therefore cannot silently replace composition
provenance while still proving the bytes it selected.
It does not use HTTP reachability, local package discovery, service
registrations, or EP databases, and does not leave a parallel EP operational environment behind.
An incomplete inventory or ambiguous instance ownership cannot prove that a
selected EP target is safe to manage. Machine-wide inventory must enumerate
coexisting instances and detect collisions; multiple unambiguous EP instances
are a supported topology, not an error.

The adapter is a source-level consumer contract until Engineering Platform
publishes and qualifies a concrete provisioner endpoint. Its durable operation
record and target-dispatch lock coordinate only Forge Platform's own requests;
they do not replace EP's installation lock, migration/rollback/cleanup engine,
or crash/reboot recovery authority.

### CENTRAL transition and future relocation boundary

The historical DJConnect-hosted EP to standalone CENTRAL transition is clean-slate: it creates a fresh official Schema 41 CENTRAL database and new standalone identities. No legacy database is migrated into CENTRAL. The explicitly retained legacy store is immutable forensic history, not runtime input or a fallback authority.

After `STANDALONE_EP_VERIFIED`, Engineering Platform may define and qualify a supported standalone CENTRAL relocation capability for moving an existing operational CENTRAL to another host, first concretely MacBook to Mac mini. Engineering Platform alone owns export/import, admission quiescence, integrity and compatibility checks, snapshot/restore, new-host binding, recovery, health qualification, and Agent endpoint/trust transition semantics. Operational CENTRAL history may be portable only under that EP-owned contract.

Host-local state is not portable by default: launchd definitions/state, PIDs, locks, sockets, caches, absolute host paths, host diagnostics, and other machine-specific runtime material must be regenerated or explicitly handled by Engineering Platform. Before implementation, EP must decide and publish whether logical CENTRAL identity is portable and how it relates to newly established physical Server installation and host identities. Agent endpoint rebind, re-pairing, stale-trust invalidation, and credential rotation are likewise EP-owned contract behavior.

Forge Platform may compose the user journey around qualified EP artifacts—for example, choosing a new CENTRAL or invoking an EP-provided restore/relocate flow—and retain deployment receipts. It is not an owner of CENTRAL migration, data, trust, Agent credential, or recovery semantics.

Installable roles remain independent:

| Role class | Components |
| --- | --- |
| Server | Forge Runtime; Workspace Server; Engineering Platform Server |
| Local | Engineering Platform Project Agent; Workspace Client |

Conceptual presets are Complete Forge Platform, Server, Developer Workstation, and Custom. A Project Agent may be installed without a Workspace Client (for example, a dedicated Linux, Windows, or Xcode host), and a Workspace Client may be installed without an Agent. A typical developer workstation has both, with independent trust relationships.

```mermaid
flowchart LR
  FR[Forge Runtime artifact] --> M[Qualified Forge Platform composition]
  WS[Workspace Server artifact] --> M
  WC[Workspace Client artifact] --> M
  EPS[EP Server artifact] --> M
  EPA[EP Project Agent artifact] --> M
  M --> S[Selected server and local roles]
  S --> R[Installation receipt]
```

## Trust and runtime boundaries

There are three distinct relationships:

1. **Workspace Client ↔ Workspace Server:** user/client/session trust. LAN presence is not authorization.
2. **Project Agent ↔ EP Server:** host/agent execution trust. Agent identity and credentials are independent of Workspace user authentication.
3. **Workspace Client ↔ local Project Agent:** machine-local repository/host UX integration. It may expose health/version, local project attachment, repository metadata/status, host/tool capability, IDE opening, and other approved local UX operations. It cannot bypass EP admission, provider execution, durable scheduling, finalization/merge authority, direct task execution, or TDE.

The future **EP Local Project Agent API Contract** is owned by Engineering Platform; Workspace owns its consumer/adapter implementation. Forge Platform owns neither side of that protocol.

Knowledge-specific boundaries are separate from these three relationships. A Knowledge Source is read-only to KB operations; KB lifecycle writes occur in the KB repository or an explicit output location. Certified Knowledge is consumed read-only and traceably. Execution outcomes, Agent facts, Forge planning outputs, and TDE evidence are not Certified Knowledge unless independently promoted through the KB lifecycle and governed certification.

Co-location changes no authority. An EP Server and Project Agent on the same machine still use the canonical Agent↔Server contract; EP Server does not directly access local repositories. Localhost never implies trust or authentication bypass.

The family runtime rule is: **source checkouts develop, test, and build; published/installed artifacts run.** In particular, an Engineering Platform source checkout never becomes runtime authority.

### Two-project B8C qualification and extraction boundary

Immediately after B8, CENTRAL and the same Project Agent qualify their real multi-project behavior using two attached development projects: DJConnect and the Engineering Platform source checkout. The latter is an ordinary development repository/project declared by `.engineering-platform/repository.json`; it is not a disposable fixture and it is not a self-hosted execution target. The installed EP Server/Agent artifacts remain the only runtime authority. B8C must prove project-selector behavior, strict `project_id` isolation for queue/runs/reports/Prompt History/evidence/status, correct distinction between installation-wide diagnostics and project data, browser refresh/deep-link/selection safety, and fail-closed absence of cross-project leakage.

B9 subsequently exercises the first governed execution only for DJConnect: CENTRAL → Project Agent → DJConnect isolated worktree → provider/Codex → validation, qualification, evidence, and finalization. A successful B9 establishes `STANDALONE_EP_VERIFIED`. Only then may DJConnect retire its active generic EP implementation/runtime/source duplicates under a zero-live-duplicate audit. That audit protects historical prompts, receipts, provenance, the `HISTORY_ONLY` legacy database, migration/extraction evidence, `.engineering-platform/repository.json`, and necessary DJConnect-specific installed-EP consumer adapters. It does not permit historical evidence to be erased or the EP source checkout to become runtime authority.

After `STANDALONE_EP_VERIFIED`, EP self-hosting, CENTRAL relocation, and multi-repository parallelism are separate qualification lanes. They may be planned in parallel with the DJConnect cleanup, but none replaces or changes its independently auditable `EP_EXTRACTION_CUTOVER_COMPLETE` end gate.

## Explicitly open implementation questions

The following are intentionally not canonicalized here:

- Workspace↔local-Agent transport and IPC mechanism;
- Project topology manifest schema;
- network discovery protocol;
- concrete authentication and pairing mechanisms;
- detailed Agent protocol and Local Agent API;
- Workspace Server persistence implementation;
- durable scheduling API;
- same-repository parallel execution contract.

## Terminology

Use these terms consistently: **Forge Runtime**, **Workspace Server**, **Workspace Client**, **Engineering Platform Server**, **Engineering Platform Project Agent**, **Forge Platform**, **Project**, **Canonical Project Authority Repository**, **Child Repository**, **Host**, and **Execution Lane**. “Adapter” is only a consumer/UX term where needed; the runtime component is the Engineering Platform Project Agent.
