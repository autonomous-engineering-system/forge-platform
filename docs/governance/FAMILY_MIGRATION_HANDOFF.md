# Repository-family authority migration handoff

## New canonical repository

`autonomous-engineering-system/forge-platform` is the canonical first-class authority for universal multi-product installer UX, component selection, cross-product compatibility declarations, release composition, installation topology, update/repair/uninstall orchestration, diagnostics, and deployment receipts. Its architecture also records cross-product deployment, topology, and trust boundaries without taking ownership of product behavior or protocols.

## Boundary retained by product repositories

- Engineering Platform owns the EP Server artifact, EP Project Agent artifact, EP-specific packaging, clean-store bootstrap, and service-installation contract.
- Workspace owns Workspace Server, Workspace Clients, and Workspace product UX.
- Forge owns planning, architecture, and orchestration product behavior.

Forge Platform may install those artifacts but does not implement them.

## Migration candidates for family audit

The ongoing duplicate/authority audit must include this repository. Read-only discovery identified the following inputs, which remain in their source repositories until separately governed migration:

| Repository | Material | Classification |
| --- | --- | --- |
| `pcvantol/engineering-platform` | `docs/adr/0019-engineering-platform-central-installation-store.md` | `PRODUCT_LOCAL_ARTIFACT_CONTRACT` |
| `pcvantol/djconnect` | `docs/adr/0018-platform-device-distribution-and-provisioning.md` | `HISTORICAL` |
| `pcvantol/djconnect` | `docs/release/DEPLOYMENT_ARCHITECTURE.md` and release-manifest material | `MIXED` |
| `pcvantol/forge` | No universal-installer/distribution implementation lineage found | `UNRESOLVED` |
| `pcvantol/workspace` | No universal-installer/distribution implementation lineage found | `UNRESOLVED` |

Future cross-product installer/composition documentation is `FORGE_PLATFORM_FUTURE_AUTHORITY`; no source document is moved or deleted by this foundation. Future family-wide authority and duplicate audits must include Forge Platform and assess universal installer/composition material found in Forge, Workspace, or Engineering Platform against this boundary.

The canonical product roadmap is now [Forge Platform MVP 1.0](../roadmap/MVP_1_0.md). Its accompanying [historical migration register](../roadmap/MIGRATION_REGISTER.md) records the DJConnect evidence audit and prevents historical plans from accidentally becoming competing current authority.

## Standalone-transition handoff sequence

The canonical critical path is B8 attachment, then B8C live qualification with DJConnect and the Engineering Platform source checkout as two real development projects at the same CENTRAL/Project Agent, then B9's first governed execution against DJConnect. B8C proves Operations Console/project-data isolation and does not self-host EP; installed EP artifacts remain runtime authority. B9 success establishes `STANDALONE_EP_VERIFIED`.

Only after that verification may the separately governed DJConnect extraction cutover remove or retire active generic EP implementation/runtime/source duplicates. Its end gate is `EP_EXTRACTION_CUTOVER_COMPLETE`, backed by a zero-live-duplicate audit, not an indiscriminate deletion exercise. Preserve the portable repository declaration, necessary installed-EP consumer adapters, immutable prompts/receipts/provenance, `HISTORY_ONLY` legacy data under preservation policy, and migration/extraction evidence. EP self-hosting, CENTRAL relocation, and multi-repository parallel execution are separate post-verification lanes; they may progress in parallel where safe but do not dilute the cutover gate.
