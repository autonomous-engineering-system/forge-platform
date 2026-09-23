# Cross-repository ownership matrix

| Concept | Canonical repository | Consumer repositories | Notes |
| --- | --- | --- | --- |
| Forge planning and engineering intent | `pcvantol/forge` | Workspace, Engineering Platform | Forge plans; EP executes admitted actions. |
| Workspace shared product/project state | `pcvantol/workspace` | Forge, Engineering Platform, Workspace Clients | Server-authoritative; clients do not create divergent truth. |
| Workspace Client | `pcvantol/workspace` | Forge Platform coordinates its product-owned provisioning | Human UX; may operate without a local Agent. |
| EP execution, admission, scheduling, repository lock/lease lifecycle, evidence, and lane finalization | `pcvantol/engineering-platform` | Forge, Workspace | EP is the durable execution and admission authority, including actual parallel-lane admission, backpressure/fairness, host/capability matching, and lane-scoped evidence/finalization. |
| Engineering Platform Project Agent | `pcvantol/engineering-platform` | Workspace consumer integration; Forge Platform coordinates EP-owned provisioning | One process per Host/OS-user context, serving 0..N repositories and advertising bounded execution capacity/slots; it does not self-admit execution. |
| Forge DAG and cross-repository dependency planning | `pcvantol/forge` | Engineering Platform, Workspace | Forge plans dependencies and parallelizable intent; EP alone decides executable ordering/admission and enforces repository resource exclusion. |
| Multi-repository parallel lane capability | `pcvantol/engineering-platform` | Forge plans; Workspace presents/permitted-controls; Forge Platform qualifies a supported composition | First form is parallel mutation only across different repositories, with one mutating lease-holder per repository. Same-repository worktree/disjoint-scope parallelism is separate and later. |
| EP Local Project Agent API | `pcvantol/engineering-platform` | Workspace consumer/adapter | Forge Platform owns neither protocol nor adapter. |
| EP Server/CENTRAL relocation, export-import, and lifecycle semantics | `pcvantol/engineering-platform` | Forge Platform installer/composition UX; Workspace/Forge as contract consumers where applicable | EP owns quiescence, integrity, snapshot/restore, compatibility, identity/trust transition, recovery, and qualification. Forge Platform may orchestrate the published contract but never owns the migration engine or CENTRAL data semantics. |
| B8C multi-project Operations Console qualification | `pcvantol/engineering-platform` | Forge Platform retains composed qualification evidence; DJConnect and EP source checkout are the two development projects | Same CENTRAL/Agent attaches the two real repositories after B8. EP owns project selector, `project_id` scoping and fail-closed data isolation; this is not disposable-fixture testing or EP self-hosted execution. |
| B8D consumer-to-CENTRAL submission ingress | `pcvantol/engineering-platform` | Project adapters, Forge, Workspace, CLI, and legacy Inbox are authenticated transport consumers | EP owns the one canonical submission/admission/lifecycle service. HTTP JSON, CLI, and any retained legacy file Inbox converge there; no adapter has independent execution semantics. This is distinct from the Server↔Project Agent execution protocol. |
| First B9 governed execution and `STANDALONE_EP_VERIFIED` | `pcvantol/engineering-platform` | DJConnect as first target; Forge Platform records composition evidence | CENTRAL → Agent → DJConnect isolated worktree → provider/Codex → validation/qualification/evidence/finalization. EP remains installed-artifact runtime authority. |
| DJConnect EP extraction cutover/finalization | `pcvantol/djconnect` | Engineering Platform supplies installed consumer/runtime contract; Forge Platform records canonical sequencing | Begins only after `STANDALONE_EP_VERIFIED`. Its `EP_EXTRACTION_CUTOVER_COMPLETE` gate requires a zero-live-duplicate audit, while protected consumer declarations and historical evidence remain. |
| EP self-hosted development execution | `pcvantol/engineering-platform` | Forge Platform may qualify a supported composition | Separate post-`STANDALONE_EP_VERIFIED` lane. Installed EP governs EP-source development; B8C attachment and B9 DJConnect execution do not demonstrate it. |
| Technical Debt Engine | `pcvantol/technical-debt-engine` | Product repositories | Standalone delivery/integration authority. |
| Generic AI-development contracts | `pcvantol/ai-development-contracts` | Product repositories | Generated projection plus local extension. |
| Generalized/certified engineering knowledge | `pcvantol/ai-platform-engineering-knowledge-base` | Product repositories | Knowledge lifecycle authority. |
| Knowledge Sources | Knowledge Base | Source repositories | Registered sources remain autonomous and read-only to KB operations. |
| Engineering Observations | Knowledge Base | Approved source/evidence producers | Evidence only; not reusable authoritative knowledge. |
| Knowledge Candidates / Concepts / Generalized Knowledge | Knowledge Base | Governance reviewers | Lifecycle proposals/interpretations; not Certified Knowledge. |
| Certified Knowledge / knowledge certification | Knowledge Base governance | Forge, Workspace, EP consumers | Independent governed promotion; no producer self-certifies. |
| Knowledge extraction | Knowledge Base | Approved Knowledge Sources | Current extractor reads a shallow Git clone and writes observations in KB. |
| Knowledge consumption | Knowledge Base | Forge, Workspace, EP future consumers | Read-only and traceable; direct KB internal-file coupling is not a cross-product contract. |
| EP evidence export | Engineering Platform + Knowledge Base | TDE, Project Agents | Explicit future contract; EP remains evidence producer. |
| Forge knowledge consumption | Forge + Knowledge Base | Workspace, EP | Explicit future read-only consumer contract. |
| Workspace knowledge UX | Workspace + Knowledge Base | Users | Workspace displays/controls; KB retains lifecycle authority. |
| KB distribution | Knowledge Base; Forge Platform when qualified | Forge Platform | KB must first publish a supported artifact and operating model. |
| Universal installer, managed-deployment topology and deployment composition | `autonomous-engineering-system/forge-platform` | Forge, Workspace, Engineering Platform artifacts | Composes qualified published artifacts and manages the installer-owned binding between exact selected component instances. Multiple Forge and EP Server instances may coexist on one host. Forge Platform inventories deployments, reviews add/update/no-change/repair/remove diffs, coordinates provider-authentication fan-out and invokes only product-owned or explicitly delegated target operations. Provider login may be deduplicated for the human, but each server instance retains its own provider runtime/auth lifecycle. For EP it consumes the EP-owned provisioner/resolver readback, exact-candidate update assessment, and execute/resume receipt; EP remains authority for runtime selection, service/data/migration/cleanup and instance health. Forge Platform's target lock is duplicate-dispatch coordination, never a second product installation lock or migration engine. |
| Cross-product compatibility matrix | `autonomous-engineering-system/forge-platform` | Product artifacts/releases | Product repos own individual protocol implementation. |
| Canonical Project topology | A Project's Canonical Project Authority Repository | Workspace, Forge, Engineering Platform | Not owned by `autonomous-engineering-system/forge-platform`; Git-reconstructable. |
| Mission progression and review cadence | `pcvantol/forge` | Workspace presents; EP consumes released Actions | Project defaults and approved Mission assignments resolve to concrete requirements; no successor bypass. |
| Delivery Control Contract | Project authority repository; actual external gate/configuration remains with its owner | Forge, EP, Workspace, Forge Platform | Separates environment/target, trigger, approval and deployment authorities; a declaration cannot mint external rights. |
| Existing CD/release approval, production execution and rollback | Declared project/organization delivery authority | Qualified consumer adapters | Trigger permission is not approval or deployment permission; Workspace must not duplicate the same external Human Gate. |

## Delivery scope clarification

[Delivery authority and promotion gates](DELIVERY_AUTHORITY_AND_PROMOTION_GATES.md)
refines generic deployment wording in the architecture: Forge Platform's product
composition authority is not global authority over customer pipelines. Preserve
existing external gates, credentials and actual decision evidence. Only explicit
bounded delegation permits a request or target operation; no provider/installer
fallback when the external owner is unavailable. This is target architecture,
not proof that external adapters or management UI have been implemented.
