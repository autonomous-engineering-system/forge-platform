import CryptoKit
import Darwin
import Foundation

protocol ManagedInstallerProductWorkerPortProbing: Sendable {
    func isAvailableOnLoopback(_ port: Int) -> Bool
}

/// The released product routes bind IPv4 loopback. A successful probe only
/// selects a port; the product's own bind and readiness remain authoritative.
struct MacOSManagedInstallerProductWorkerPortProbe:
    ManagedInstallerProductWorkerPortProbing, Sendable {
    func isAvailableOnLoopback(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

/// The instance ID is stable across retry. Once a route is published its port
/// is read from the canonical authority, never selected a second time.
struct ManagedInstallerFreshProductWorkerPortAllocator: Sendable {
    private static let firstPort = 20_000
    private static let portCount = 40_000
    private static let maximumProbes = 128
    private let probe: any ManagedInstallerProductWorkerPortProbing

    init(probe: any ManagedInstallerProductWorkerPortProbing) {
        self.probe = probe
    }

    func allocate(
        instanceID: String,
        excluded: Set<Int>,
        existing: Int? = nil
    ) -> Int? {
        guard ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(instanceID),
              excluded.allSatisfy({ (1...65_535).contains($0) }) else { return nil }
        if let existing {
            return (1...65_535).contains(existing) && !excluded.contains(existing)
                ? existing : nil
        }
        let digest = SHA256.hash(data: Data(
            ("forge-platform.product-worker-port/v1:" + instanceID).utf8
        ))
        let start = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        for offset in 0..<Self.maximumProbes {
            let port = Self.firstPort
                + (Int(start) + offset) % Self.portCount
            if !excluded.contains(port) && probe.isAvailableOnLoopback(port) {
                return port
            }
        }
        return nil
    }
}

/// Constructs only a single-product route from reviewed, receipt-bound
/// helper data. Combined deployments require a separately authorized pairing
/// record and therefore cannot enter this path.
struct ManagedInstallerFreshSingleProductWorkerRouteBuilder: Sendable {
    private let ports: ManagedInstallerFreshProductWorkerPortAllocator

    init(ports: ManagedInstallerFreshProductWorkerPortAllocator) {
        self.ports = ports
    }

    func build(
        plan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        accounts: [ManagedInstallerProductServiceAccountReadback],
        activation: ManagedPythonRuntimeActivationReceipt,
        venvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        prior: ManagedInstallerProductWorkerAuthoritySnapshot?
    ) -> ManagedInstallerProductWorkerAuthoritySnapshot? {
        guard accounts.count == 1, venvEvidence.count == 1,
              plan.reviewedOperation.components.count == 1,
              let claim = accounts.first?.claim,
              let evidence = venvEvidence.first,
              claim.componentIdentity == evidence.request.componentIdentity,
              prior?.routes.contains(where: {
                  $0.deploymentID == plan.deployment.id
              }) != true,
              let release = ManagedInstallerProductWorkerReleaseBinding.workerRelease(
                  for: plan.reviewedOperation.currentInstallerRelease
              ),
              let manifest = try? ManagedInstallerProductWorkerManifestAuthority(
                  digest: plan.session.manifestSHA256,
                  canonicalPayload: material.manifestBytes
              ) else { return nil }
        let priorSingles = prior?.singleRoutes ?? []
        let priorTarget = priorSingles.first {
            $0.deploymentID == plan.deployment.id
        }
        let excluded = Set((prior?.routes ?? []).flatMap {
            [$0.forgeBindPort, $0.engineeringPlatformBindPort]
        } + priorSingles.filter {
            $0.deploymentID != plan.deployment.id
        }.map(\.bindPort))
        guard let port = ports.allocate(
            instanceID: claim.instanceID, excluded: excluded,
            existing: priorTarget?.bindPort
        ) else { return nil }
        let route = try? ManagedInstallerProductWorkerSingleRouteAuthority(
            deploymentID: plan.deployment.id,
            componentIdentity: claim.componentIdentity,
            instanceID: claim.instanceID,
            serviceAccount: claim.accountName,
            bindPort: port,
            artifactSHA256: claim.productArtifactSHA256,
            forgeInstallationID: claim.componentIdentity == "forge-runtime"
                ? claim.instanceID : nil,
            engineeringPlatformDisplayLabel:
                claim.componentIdentity == "engineering-platform-server"
                    ? (plan.deployment.label ?? plan.deployment.id) : nil,
            venvSlotName: MacOSManagedPythonProductVenvSlotLayout.slotName(
                for: evidence.request
            )
        )
        guard let route else { return nil }
        let candidates = prior?.candidateManifests ?? []
        let snapshot = try? ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: release,
            candidateManifests: candidates.contains(manifest)
                ? candidates : candidates + [manifest],
            installedManifests: prior?.installedManifests ?? [],
            routes: prior?.routes ?? [],
            singleRoutes: priorSingles.filter {
                $0.deploymentID != plan.deployment.id
            } + [route]
        )
        guard let snapshot,
              ManagedInstallerFreshProductWorkerAuthorityAdmission.accepts(
                  plan: plan, material: material, snapshot: snapshot,
                  priorAuthority: prior, accounts: accounts,
                  activation: activation, venvEvidence: venvEvidence
              ) else { return nil }
        return snapshot
    }
}

/// Builds the existing two-product worker route from receipt-bound identities.
/// The pairing binding must come from a separate helper-owned, product-qualified
/// source; this builder never guesses a consumer or credential reference.
struct ManagedInstallerFreshPairedProductWorkerRouteBuilder: Sendable {
    private let ports: ManagedInstallerFreshProductWorkerPortAllocator

    init(ports: ManagedInstallerFreshProductWorkerPortAllocator) {
        self.ports = ports
    }

    func build(
        plan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        accounts: [ManagedInstallerProductServiceAccountReadback],
        activation: ManagedPythonRuntimeActivationReceipt,
        venvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        pairing: ManagedInstallerProductWorkerPairingAuthority,
        prior: ManagedInstallerProductWorkerAuthoritySnapshot?
    ) -> ManagedInstallerProductWorkerAuthoritySnapshot? {
        guard plan.reviewedOperation.components.count == 2,
              let reviewedPairing = plan.reviewedOperation.pairingTarget,
              pairing.projectID == reviewedPairing.projectID,
              pairing.repositoryID == reviewedPairing.repositoryID,
              pairing.repositoryIdentity == reviewedPairing.repositoryIdentity,
              accounts.count == 2, venvEvidence.count == 2,
              Set(accounts.map(\.claim.componentIdentity))
                == Set(["forge-runtime", "engineering-platform-server"]),
              Set(venvEvidence.map(\.request.componentIdentity))
                == Set(["forge-runtime", "engineering-platform-server"]),
              let forge = accounts.first(where: {
                  $0.claim.componentIdentity == "forge-runtime"
              })?.claim,
              let ep = accounts.first(where: {
                  $0.claim.componentIdentity == "engineering-platform-server"
              })?.claim,
              let forgeVenv = venvEvidence.first(where: {
                  $0.request.componentIdentity == "forge-runtime"
              })?.request,
              let epVenv = venvEvidence.first(where: {
                  $0.request.componentIdentity == "engineering-platform-server"
              })?.request,
              forge.instanceID != ep.instanceID,
              forge.accountName != ep.accountName,
              prior?.singleRoutes.contains(where: {
                  $0.deploymentID == plan.deployment.id
              }) != true,
              let release = ManagedInstallerProductWorkerReleaseBinding.workerRelease(
                  for: plan.reviewedOperation.currentInstallerRelease
              ),
              let manifest = try? ManagedInstallerProductWorkerManifestAuthority(
                  digest: plan.session.manifestSHA256,
                  canonicalPayload: material.manifestBytes
              ) else { return nil }
        let existing = prior?.routes.first(where: {
            $0.deploymentID == plan.deployment.id
        })
        let priorPairs = prior?.routes ?? []
        let priorSingles = prior?.singleRoutes ?? []
        let otherPorts = Set(priorPairs.filter {
            $0.deploymentID != plan.deployment.id
        }.flatMap { [$0.forgeBindPort, $0.engineeringPlatformBindPort] }
            + priorSingles.map(\.bindPort))
        guard let forgePort = ports.allocate(
            instanceID: forge.instanceID, excluded: otherPorts,
            existing: existing?.forgeBindPort
        ), let epPort = ports.allocate(
            instanceID: ep.instanceID, excluded: otherPorts.union([forgePort]),
            existing: existing?.engineeringPlatformBindPort
        ) else { return nil }
        let route = try? ManagedInstallerProductWorkerRouteAuthority(
            deploymentID: plan.deployment.id,
            forgeInstanceID: forge.instanceID,
            forgeInstallationID: forge.instanceID,
            forgeServiceAccount: forge.accountName,
            forgeBindPort: forgePort,
            forgeArtifactSHA256: forge.productArtifactSHA256,
            engineeringPlatformArtifactSHA256: ep.productArtifactSHA256,
            engineeringPlatformInstanceID: ep.instanceID,
            engineeringPlatformDisplayLabel: plan.deployment.label
                ?? plan.deployment.id,
            engineeringPlatformServiceAccount: ep.accountName,
            engineeringPlatformBindPort: epPort,
            pairing: pairing,
            forgeVenvSlotName: MacOSManagedPythonProductVenvSlotLayout.slotName(
                for: forgeVenv
            ),
            engineeringPlatformVenvSlotName:
                MacOSManagedPythonProductVenvSlotLayout.slotName(for: epVenv)
        )
        guard let route, existing == nil || existing == route else { return nil }
        let candidates = prior?.candidateManifests ?? []
        guard let snapshot = try? ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: release,
            candidateManifests: candidates.contains(manifest)
                ? candidates : candidates + [manifest],
            installedManifests: prior?.installedManifests ?? [],
            routes: priorPairs.filter { $0.deploymentID != plan.deployment.id }
                + [route],
            singleRoutes: priorSingles
        ), ManagedInstallerFreshProductWorkerAuthorityAdmission.accepts(
            plan: plan, material: material, snapshot: snapshot,
            priorAuthority: prior, accounts: accounts,
            activation: activation, venvEvidence: venvEvidence
        ) else { return nil }
        return snapshot
    }
}
