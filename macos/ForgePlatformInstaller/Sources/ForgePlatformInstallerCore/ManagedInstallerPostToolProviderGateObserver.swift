import CryptoKit
import Foundation

/// One non-secret host observation for an exact provider target. Concrete
/// inspectors own every executable location and credential-store interaction;
/// callers supply only the immutable requirement from the closed helper
/// request.
public struct ManagedInstallerProviderHostReadback: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case absent = "ABSENT"
        case installed = "INSTALLED"
        case authenticationRequired = "AUTHENTICATION_REQUIRED"
        case verified = "VERIFIED"
        case failed = "FAILED"
    }

    public let providerTargetID: ProviderTargetID
    public let state: State
    public let version: InstallerVersion?
    public let executableIdentity: String?
    public let executableSHA256: String?
    public let evidenceReference: String

    public init(
        providerTargetID: ProviderTargetID,
        state: State,
        version: InstallerVersion?,
        executableIdentity: String?,
        executableSHA256: String?,
        evidenceReference: String
    ) throws {
        guard executableIdentity.map(Self.isExecutableIdentity) ?? true,
              executableSHA256.map(CompositionCatalogValidation.isTaggedSHA256) ?? true,
              executableSHA256 == nil || executableIdentity != nil,
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(
                evidenceReference
              ) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        if state == .verified {
            guard version != nil, executableIdentity != nil else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
        } else if state == .absent {
            guard version == nil,
                  executableIdentity == nil,
                  executableSHA256 == nil else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
        }
        self.providerTargetID = providerTargetID
        self.state = state
        self.version = version
        self.executableIdentity = executableIdentity
        self.executableSHA256 = executableSHA256
        self.evidenceReference = evidenceReference
    }

    func satisfies(_ requirement: ProviderRequirement) -> Bool {
        guard providerTargetID == requirement.id,
              state == .verified,
              let version else {
            return false
        }
        if let minimumVersion = requirement.minimumVersion,
           version < minimumVersion {
            return false
        }
        if let runtime = requirement.runtime {
            return version == runtime.version
                && executableSHA256 == runtime.executableSHA256
        }
        return true
    }

    private static func isExecutableIdentity(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 47, 58, 95, 48...57, 65...90, 97...122:
                return true
            default:
                return false
            }
        }
    }
}

/// Helper-owned provider inspection seam. Implementations select fixed tools,
/// paths and noninteractive status APIs from the provider identity. They must
/// never return credentials or raw command output.
public protocol ManagedInstallerProviderHostInspecting: Sendable {
    func inspectProvider(
        _ requirement: ProviderRequirement,
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerProviderHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
}

/// Derives the provider post-tool gate from a fresh observation of every exact
/// enabled provider requirement in the helper request. Missing, unauthenticated
/// or drifted providers produce a valid blocking gate; unavailable or
/// mismatched inspection evidence fails the observation boundary.
public struct ManagedInstallerPostToolProviderGateHostReader:
    ManagedInstallerPostToolGateHostReading, Sendable {
    private let inspector: any ManagedInstallerProviderHostInspecting

    public init(inspector: any ManagedInstallerProviderHostInspecting) {
        self.inspector = inspector
    }

    public func readPostToolHostGate(
        _ gate: ManagedInstallerPostToolGate,
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolGateReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        let expectedGates = ManagedInstallerPostToolGate.allCases.sorted {
            $0.rawValue < $1.rawValue
        }
        let requirements = request.enabledProviderRequirements
        guard gate == .providers,
              request.gates == expectedGates,
              requirements == requirements.sorted(by: {
                  $0.id.rawValue < $1.id.rawValue
              }),
              Set(requirements.map(\.id)).count == requirements.count else {
            return .failure(.rejected)
        }

        var observations: [ManagedInstallerProviderHostReadback] = []
        for requirement in requirements {
            switch await inspector.inspectProvider(requirement, for: request) {
            case .success(let readback):
                guard readback.providerTargetID == requirement.id else {
                    return .failure(.rejected)
                }
                observations.append(readback)
            case .failure(let failure):
                return .failure(failure)
            }
        }

        do {
            return .success(try ManagedInstallerPostToolGateReadback(
                gate: .providers,
                passed: zip(requirements, observations).allSatisfy { requirement, readback in
                    readback.satisfies(requirement)
                },
                evidenceReference: Self.evidenceReference(
                    request: request,
                    observations: observations
                )
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    private static func evidenceReference(
        request: ManagedInstallerPostToolHostObservationRequest,
        observations: [ManagedInstallerProviderHostReadback]
    ) -> String {
        let material = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.managed-installer-provider-gate-evidence/v1"),
            "operation_id": .string(request.operationID),
            "stable_plan_fingerprint": .string(request.stablePlanFingerprint),
            "request_fingerprint": .string(request.requestFingerprint),
            "providers": .array(observations.map { observation in
                .object([
                    "identity": .string(observation.providerTargetID.rawValue),
                    "state": .string(observation.state.rawValue),
                    "version": observation.version.map {
                        .string($0.description)
                    } ?? .null,
                    "executable_identity": observation.executableIdentity.map {
                        .string($0)
                    } ?? .null,
                    "executable_sha256": observation.executableSHA256.map {
                        .string($0)
                    } ?? .null,
                    "evidence_reference": .string(observation.evidenceReference),
                ])
            }),
        ]))
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return "receipt:provider-gate-\(digest)"
    }
}

/// Routes the provider gate to its exact observer while retaining separately
/// injected readers for the other four gates.
public struct ManagedInstallerPostToolGateRoutingHostReader:
    ManagedInstallerPostToolGateHostReading, Sendable {
    private let providerGate: any ManagedInstallerPostToolGateHostReading
    private let otherGates: any ManagedInstallerPostToolGateHostReading

    public init(
        providerGate: any ManagedInstallerPostToolGateHostReading,
        otherGates: any ManagedInstallerPostToolGateHostReading
    ) {
        self.providerGate = providerGate
        self.otherGates = otherGates
    }

    public func readPostToolHostGate(
        _ gate: ManagedInstallerPostToolGate,
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolGateReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        if gate == .providers {
            return await providerGate.readPostToolHostGate(gate, for: request)
        }
        return await otherGates.readPostToolHostGate(gate, for: request)
    }
}
