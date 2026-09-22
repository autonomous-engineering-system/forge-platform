# Forge Platform

Forge Platform is the canonical, first-class repository for cross-product distribution, deployment, compatible-composition and product-provisioner coordination for installation, update, repair and uninstall, component compatibility, and installation-topology orchestration across the Forge product family. It is a peer of [Forge](https://github.com/pcvantol/forge), [Workspace](https://github.com/pcvantol/workspace), [Engineering Platform](https://github.com/pcvantol/engineering-platform), and [Technical Debt Engine](https://github.com/pcvantol/technical-debt-engine); it is not a subdirectory of Forge or an Engineering Platform installer folder.

The native Universal Installer platform contract is Apple Silicon only: one
thin arm64 executable on macOS 26 or newer, with no Intel, Rosetta, `x86_64`,
or fat/universal fallback. This is source-level qualification, not a published,
signed, notarized, or operational installer claim.

## Status

Repository foundation with bounded source-level component-operation and
release-composition evidence kernels. The component-operation contract consumes
product-owned runtime readback, exact-candidate update assessment, and
execute/resume evidence without selecting a runtime itself. A strict Universal
Installer policy kernel and native macOS SwiftUI wizard shell now exist for
self-update, signed composition selection, preflight, managed Git, exact
catalog-approved Python-runtime planning, provider gating, and read-only diffs.
The Python contract binds one immutable version/artifact/provenance/ABI identity,
requires component build-and-test evidence against it, freezes rollback state,
and assigns one isolated venv identity per product without consulting `PATH`.
A durable source-level executor now captures and re-hashes the four exact
runtime/source/provenance inputs, validates thin-arm64/macOS-26 archive evidence,
coordinates immutable runtime slots and separate product venvs through an
injected privileged adapter, resumes after interruption, and restores only the
frozen prior runtime on rollback.
A separate installer-release
framework persists immutable `PREPARED` candidate bytes before qualification,
can produce a source-only unsigned macOS `.app` candidate, and binds the exact
staged archive digest to future signed evidence and a durable installer
operation. Its release identity policy intentionally starts
`UNCONFIGURED`, so protected signing/notarization/publication gates fail closed
until the actual GitHub namespace, bundle/team identity and public-key policy
are reviewed. No production arm64 Python artifact, native transport/archive
inspector, privileged runtime adapter, or released-installer wiring is approved
yet; the executor therefore remains fail-closed in production. A signed and
notarized installer release, privileged bootstrapper, and concrete product
adapters remain unimplemented; this
repository does not publish producer product artifacts or change product
runtime behavior.

The active installer resumption scope is deliberately narrower than the full
universal lifecycle: one EP Server clean installation, without an EP Project
Agent, Forge, Workspace, provider login, upgrade, migration, rollback, removal
or cleanup. It remains planned and parked; see the
[EP Server clean-install v1 parking roadmap](docs/roadmap/EP_SERVER_CLEAN_INSTALL_V1.md).

The accepted broader topology is multi-instance: one host may contain multiple
isolated Forge Server and EP Server instances. Forge Platform manages exact
selected instance combinations as named/opaque managed deployments. A provider
login may be performed once for the human and then fanned out through supported
provider mechanisms into separately installed and independently verified
instance-owned provider contexts. Forge/EP server provider state must survive
cold reboot without user login; EP Project Agents remain user-owned per
Host/OS-user context. See
[ADR-0007](docs/architecture/adr/ADR-0007-multi-instance-deployments-and-provider-fanout.md).

## Boundary

Forge Platform consumes qualified, versioned artifacts published by product repositories and composes compatible provisioning requests and receipts. It does not rebuild their source or own product-local provisioning: for EP, its resolver/provisioner alone owns runtime and service selection, data compatibility, migration, rollback and cleanup. Forge Platform also does not own Forge, Workspace, Engineering Platform, Project Agent, TDE, generic AI-development governance, or Knowledge Base behavior.

## Entrypoints

- [Architecture](docs/architecture/README.md)
- [System architecture](docs/architecture/FORGE_PLATFORM_ARCHITECTURE.md)
- [Governed Knowledge Learning Loop](docs/architecture/KNOWLEDGE_LEARNING_LOOP.md)
- [Architecture Decision Records](docs/architecture/adr/README.md)
- [Cross-repository ownership matrix](docs/architecture/OWNERSHIP_MATRIX.md)
- [Component-operation delegation contract](docs/architecture/COMPONENT_OPERATION_DELEGATION_CONTRACT.md)
- [Universal macOS Installer contract](docs/architecture/UNIVERSAL_MACOS_INSTALLER_CONTRACT.md)
- [Managed Python runtime execution contract](docs/architecture/MANAGED_PYTHON_RUNTIME_EXECUTION_CONTRACT.md)
- [Roadmap](docs/roadmap/README.md)
- [EP Server clean-install v1 parking roadmap](docs/roadmap/EP_SERVER_CLEAN_INSTALL_V1.md)
- [MVP 1.0 roadmap](docs/roadmap/MVP_1_0.md)
- [Development and bootstrap](docs/development/README.md)
- [Governance](docs/governance/README.md)
- [TDE integration](docs/development/TDE_INTEGRATION.md)
