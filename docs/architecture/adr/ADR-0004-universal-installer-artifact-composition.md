# ADR-0004 — Universal installer and independently published artifact composition

**Status:** Accepted

## Decision

Forge Platform composes independently published Forge Runtime, Workspace Server, Workspace Client, Engineering Platform Server, and Engineering Platform Project Agent artifacts. It owns component selection, deployment presets, artifact acquisition and verification, validated compatibility/release composition, topology bootstrap, cross-product choreography around product-owned provisioners, and composition receipts.

The native macOS Universal Installer is a separately versioned Forge Platform artifact, not one package per possible product-version combination. It consumes immutable composition manifests that declare its minimum version and required capabilities. A GitHub Release transports installer bytes, but a signed, expiring installer descriptor rooted in the bootstrapper's public-key policy is required before a newer bundle can be staged and relaunched. An old installer must hand off to a newer verified installer before it performs any platform mutation. Its signed catalog-feed locator leads to a separately signed, expiring, monotonic catalog: a compatible installer may therefore consume a newly published composition without a binary replacement, while a composition requiring an unavailable capability forces the installer update first. The detailed wire, provider, managed-tool, service, and operation rules are in the [Universal macOS Installer contract](../UNIVERSAL_MACOS_INSTALLER_CONTRACT.md).

Each product repository owns its own artifact build/publication, version, product behavior, protocol implementation, and product-specific installation provisioner. Forge Platform releases are tested compositions, not monorepo source versions. The installer provides independent Server and Local roles and the Complete Forge Platform, Server, Developer Workstation, and Custom conceptual presets.

For Engineering Platform, Forge Platform passes the complete exact selected
artifact identity and requested role to the EP-owned installation provisioner
adapter and consumes its correlated installation readback, candidate update
assessment, health proof, and cleanup receipt. The EP resolver alone selects
the runtime, executable, server, and instance and determines machine-wide
inventory/conflict coverage. Forge Platform must not create a second EP
runtime chooser, service-registration path, migration engine, cleanup engine,
or direct database writer. In particular, a Forge Platform PATH lookup or an
HTTP-reachable response cannot select or verify an EP operational runtime.

## Multi-instance refinement

[ADR-0007](ADR-0007-multi-instance-deployments-and-provider-fanout.md)
refines this decision without changing product ownership. A Mac is not a
machine-wide Forge/EP singleton: Forge Platform may manage multiple isolated
Forge and EP Server instances through exact managed-deployment bindings.
Human provider authentication may be deduplicated by the installer, but
provider CLI/runtime/auth state remains independently owned and verified per
selected component instance. EP Project Agents remain user-owned per
Host/OS-user context.

## Consequences

Forge Platform will verify trusted artifact digest and supported signature/provenance evidence, use least privilege, and avoid repository secrets. It does not compile, repackage, or install product source as a hidden monolith. The source-level component-operation consumer contract binds an exact qualified artifact (including source locator) to product readback, update assessment, execute, and resume receipts; it retains non-secret preflight/postflight and pending-recovery evidence. A local target-dispatch lock prevents duplicate Forge Platform dispatch only. It does not replace the product installation lock or prove cross-account/machine uniqueness.

The source foundation now includes strict metadata/composition planning and a native SwiftUI shell. It still does not certify a concrete EP adapter endpoint, privileged installation behavior, live artifact download, service action, migration, rollback, cleanup, code-signed installer, or published installer release. Those remain future work under the owning product contract; a future adapter must preserve the same product-operation identity through crash/reboot resume.
