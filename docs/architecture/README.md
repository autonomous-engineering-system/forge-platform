# Architecture

Forge Platform is the distribution and deployment composition boundary for the Forge product family. It consumes published product artifacts; it does not rebuild product source or take ownership of product behavior. The complete system composition is defined in the [Forge Platform Architecture](FORGE_PLATFORM_ARCHITECTURE.md).

## Intended composition

| Product repository | Published conceptual artifact | Forge Platform responsibility |
| --- | --- | --- |
| `pcvantol/forge` | Forge Runtime | Select, verify, coordinate product-owned provisioning, and compose |
| `pcvantol/workspace` | Workspace Server and Workspace Client | Select, verify, coordinate product-owned provisioning, and compose |
| `pcvantol/engineering-platform` | Engineering Platform Server and EP Project Agent | Select, verify, coordinate EP-owned provisioning, and compose |

Each product retains ownership of its artifact build, protocol implementation, and product-specific compatibility guarantees. Forge Platform owns the validated cross-product release composition and compatibility declarations.

## Same-machine boundary

Components remain separately owned products even when installed on one machine. They communicate through their canonical APIs and protocols; no hidden in-process shortcut or direct repository-filesystem access is introduced. For example, Engineering Platform Server reaches a local EP Project Agent through the canonical agent protocol.

## Execution-lane boundary

Forge plans dependency DAGs; Engineering Platform Server remains the durable execution and admission authority. After `STANDALONE_EP_VERIFIED`, its first parallelism capability is bounded mutation across different repositories: an Agent may serve `0..N` repositories and advertise bounded capacity, while EP enforces repository/resource exclusion, admission, backpressure, evidence, and finalization. Workspace only presents or issues permitted control intent.

Forge-owned hard dependency edges and EP-owned execution-resource constraints are separate. A Forge Platform Action may therefore be logically independent and eligible while EP still delays it for capacity, or it may remain logically blocked by producer evidence even when EP has free capacity.

See the [system architecture](FORGE_PLATFORM_ARCHITECTURE.md), [ownership matrix](OWNERSHIP_MATRIX.md), and [MVP roadmap](../roadmap/MVP_1_0.md).

## Evidence-gated release composition

Installer/component support may be implemented in parallel with producer work, but final component-manifest entries require actual published artifact evidence. A source merge or guessed checksum is not enough.

The canonical target is defined in [Evidence-gated cross-repository component composition](EVIDENCE_GATED_COMPONENT_COMPOSITION.md) and the [component-manifest contract](COMPONENT_MANIFEST_CONTRACT.md). Manifest entries keep source revision distinct from the digest of the installable artifact bytes.

## Managed multi-instance deployment topology

The Universal Installer manages exact **deployment instances**, not one
machine-wide Forge or EP singleton. A host may contain multiple independently
identified Forge Server instances and multiple independently identified EP
Server instances. A Forge Platform managed deployment binds a selected
Forge/EP instance combination for create, update, add/remove-component and
remove-deployment operations while preserving product-owned lifecycle
authority. Provider authentication may be presented once to the operator and
fanned out only through supported provider mechanisms into separately owned
and independently verified per-instance provider contexts. EP Project Agents
remain user-owned and may coexist once per Host/OS-user context. See
[ADR-0007](adr/ADR-0007-multi-instance-deployments-and-provider-fanout.md).

## Universal macOS installer lifecycle

Forge Platform has a separately versioned native macOS Universal Installer and immutable qualified composition manifests; it does not build a combinatorial installer package for every Forge/Workspace/EP version combination. At every launch, an older installer must verify and hand off to a newer signed/notarized installer release before platform mutation. The signed composition catalog then selects only an installer-capable exact component set. See the [Universal macOS Installer contract](UNIVERSAL_MACOS_INSTALLER_CONTRACT.md).

The source foundation, native SwiftUI shell and platform-neutral managed-Python
executor kernel are present, but the first published installer, native Python
transport/archive inspector, privileged bootstrapper, and product-owned
execution adapters remain separately qualified work. The executor's immutable
slot, isolated-venv, interruption-resume and rollback boundary is defined in
the [managed Python runtime execution contract](MANAGED_PYTHON_RUNTIME_EXECUTION_CONTRACT.md).
No current source merge proves a live Mac installation.

The current narrow resumption target is one EP Server clean installation only;
it excludes the EP Project Agent, Forge, Workspace, provider login and all
product lifecycle mutation other than the initial clean install. Its status,
non-goals and documentary dependency DAG are recorded in the
[EP Server clean-install v1 parking roadmap](../roadmap/EP_SERVER_CLEAN_INSTALL_V1.md).

## Lifecycle boundary

The source-level component-operation contract can retain a product-owned
resolver readback, candidate update assessment, and execute/resume evidence
for an exact qualified artifact. It does not implement a product adapter or
select a runtime itself. The future platform coordinates product-owned install,
role add/remove, upgrade, repair, uninstall, health diagnostics, and deployment
receipts; privileged installer logic remains product-bound and is not a
replacement product provisioner in this foundation. For EP, Forge Platform
dispatches an exact qualified artifact/role only to the EP-owned
resolver/provisioner and consumes its correlated readbacks; EP retains service,
migration, data and cleanup authority.

Read the [system architecture](FORGE_PLATFORM_ARCHITECTURE.md), [universal macOS installer contract](UNIVERSAL_MACOS_INSTALLER_CONTRACT.md), [managed Python runtime execution contract](MANAGED_PYTHON_RUNTIME_EXECUTION_CONTRACT.md), [evidence-gated composition contract](EVIDENCE_GATED_COMPONENT_COMPOSITION.md), [governed knowledge learning loop](KNOWLEDGE_LEARNING_LOOP.md), [ADRs](adr/README.md), [cross-repository ownership matrix](OWNERSHIP_MATRIX.md), [component-manifest contract](COMPONENT_MANIFEST_CONTRACT.md), [compatibility model](COMPATIBILITY.md), [roles and presets](ROLES_AND_PRESETS.md), and [security boundary](SECURITY.md).
