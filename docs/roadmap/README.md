# Forge Platform roadmap

This directory is the canonical roadmap location for Forge Platform's cross-product composition product. Architecture remains authoritative for ownership, trust, topology, and runtime boundaries; roadmaps state intent, maturity, sequencing, and qualification work without changing those decisions.

## Repository hygiene and release scope — documented target

The coordinated `PROJECT_HYGIENE_AND_REPOSITORY_RECONCILIATION_V1` increment
adds the [repository-hygiene release/install boundary](../architecture/REPOSITORY_HYGIENE_RELEASE_BOUNDARY.md)
and [HY-P composition roadmap](PROJECT_HYGIENE_V1.md).
Forge reasons about project-wide branch/case evidence; EP owns host facts and
admitted cleanup. Forge Platform may consume an applicable source/operation-bound
assessment but does not become a scanner, cleanup executor or CD authority.

HY-P is PLANNED after relevant Forge/EP HY-Q qualification. Optional read-only
composition remains distinct from mutation support. Retained unrelated branches
do not block every release; actual relevant conflicts and required stale evidence
do. Installer/update/uninstall must not delete project refs or runtime case/
receipt history. All artifact/publisher/rollback and external CD gates remain
independent. No new first-canary predecessor, executable DAG, package version,
workflow, grant, runtime activation or actual cleanup is changed here.

## Canonical entrypoints

- [EP Server clean-install v1 parking roadmap](EP_SERVER_CLEAN_INSTALL_V1.md) — the current, deliberately narrow Universal Installer resumption path: one clean EP Server installation on Apple Silicon/macOS 26+, with no Project Agent, Forge, Workspace, provider login, upgrade, migration, rollback, removal, or cleanup. It is a documentary planning DAG, not a Forge execution DAG or operational-installation claim.
- [Forge Platform MVP 1.0](MVP_1_0.md) — product boundary, capability waves, a two-chain DAG that joins only at `MVP_1_0_RELEASE_READY`, the B8 → B8C → B8D → B9 → `STANDALONE_EP_VERIFIED` → `EP_EXTRACTION_CUTOVER_COMPLETE` transition gates, and separate post-verification lanes (CENTRAL relocation, EP self-hosting, and bounded multi-repository parallel execution).
- [Policy-aware composition](POLICY_GOVERNANCE_V1.md) — scoped policy/release DAG for `POLICY_GOVERNANCE_AND_EFFECTIVE_PROFILES_V1`; native Forge release planning, EP enforcement and actual published artifact evidence precede qualified production installer composition. Documentation only; implementation remains PLANNED.
- [Historical migration register](MIGRATION_REGISTER.md) — auditable classification of relevant historical DJConnect material and its canonical destination or retained status.
- [Evidence-gated component composition](../architecture/EVIDENCE_GATED_COMPONENT_COMPOSITION.md) — cross-repository sequencing seam: producer and installer implementation may proceed in parallel, while final component-manifest Actions wait for exact published artifact digest/source/qualification evidence.

The earlier stage view is retained here as orientation only; it is superseded for MVP planning by the dependency-aware capability map in [MVP 1.0](MVP_1_0.md).

The [policy-aware architecture](../architecture/POLICY_AWARE_COMPOSITION.md) keeps
Forge Platform's deployment/composition policy separate from Forge planning and
EP execution/assurance. Workspace is the human management surface, not a global
policy authority. The policy/release sub-DAG changes no executable programme DAG,
version manifest, runtime state, grant or consumed budget. Full policy UI is not
a new first-canary dependency; production compositions require their real proof.

| Earlier stage | Corresponding roadmap concern |
| --- | --- |
| 0–1 | Foundation, contracts, manifest, compatibility, and governance |
| 2–3 | Independently published product artifacts and consumer integration |
| 4–5 | macOS installation, lifecycle, diagnostics, and receipts |
| 6–7 | Distributed qualification and Windows/Linux support after MVP |

The first post-verification parallelism capability is not general fleet scheduling: it is EP-owned, capacity-bounded mutation across independent repositories, with one mutating lane per repository. It starts only after `STANDALONE_EP_VERIFIED`; same-repository worktree/disjoint-scope parallelism remains a separate later capability.

Within that lane Forge may make independent producer and Forge Platform installer Actions concurrently eligible. Forge Platform's final release-composition/manifest work remains evidence-gated: a source merge is not a substitute for the exact published artifact bytes, digest, source revision and required qualification/provenance evidence.

## Knowledge learning-loop integration

Knowledge integration is additive and remains independently owned by `pcvantol/ai-platform-engineering-knowledge-base`.

| Stage | Scope |
| --- | --- |
| K0 | Current KB truth and governed learning-loop architecture |
| K1 | Governed registration of first-class product repositories as Knowledge Sources |
| K2 | Source-specific extraction profiles and validation boundaries |
| K3 | Explicit EP and public TDE evidence-to-observation contracts |
| K4 | Forge read-only Certified Knowledge consumption contract |
| K5 | Workspace learning-loop visibility and governed control UX |
| K6 | Governed automated observation extraction, health, and drift signals |
| K7 | KB productization and optional Forge Platform distribution when qualified |

KB is currently a Git-backed repository-local CLI capability, not a Workspace/EP server role and not a current Forge Platform installer component. See the [learning-loop architecture](../architecture/KNOWLEDGE_LEARNING_LOOP.md).

## Multi-instance managed deployment refinement

[ADR-0007](../architecture/adr/ADR-0007-multi-instance-deployments-and-provider-fanout.md)
defines the broader accepted installer topology: multiple isolated Forge and EP
Server instances may coexist on one host; Forge Platform manages exact selected
instance combinations as managed deployments; provider login is deduplicated
only for the human and fans out into independently installed/verified
instance-owned provider contexts; and EP Project Agents remain user-owned per
Host/OS-user context. This is an architecture/documentation refinement and does
not unpark the current EP-only clean-install implementation DAG.

## Installer UX, read-only qualification and release refinement

The [owner-requested installer backlog](INSTALLER_UX_AND_RELEASE_QUALIFICATION_V1.md)
and [IUR documentary DAG](installer-ux-release-v1.json) add explicit OS appearance/
language/Retina behavior, five-role and Server install/Client install selection,
page validation and progress, real read-only UI tests, all-step screenshots,
strict per-file >80.2% coverage, and protected build/signing on the owner's Mac
with a release-pinned latest public stable SDK and GitHub Release readback.

Reuse existing EP system-service, Forge HTTP/Postman/drift and product-release
lanes; Workspace owns its PyPI transition. This refines FP-EP-CI-6/7/Q and the
broader MVP installer lane without expanding the parked EP-only-clean scope or
adding a first-Forge-canary prerequisite. All new implementation remains PLANNED;
no runner registration, signing, release or installation is performed here.
