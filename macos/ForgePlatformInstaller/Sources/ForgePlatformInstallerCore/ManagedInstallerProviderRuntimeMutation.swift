import CryptoKit
import Foundation

public enum ManagedInstallerProviderRuntimeMutationFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

/// Closed request for one exact component-provider runtime installation. Every
/// mutable location is derived inside the privileged adapter from fixed root
/// policy plus these immutable identities. No path, command, environment value
/// or credential crosses this boundary.
public struct ManagedInstallerProviderRuntimeMutationRequest: Equatable, Sendable {
    public static let managedRootIdentity = "forge-platform-managed-provider-runtime-v1"

    public let operationID: String
    public let providerTargetID: ProviderTargetID
    public let provider: ProviderID
    public let runtime: ProviderRuntimeRequirement
    public let runtimeSlotIdentity: String
    public let providerHomeIdentity: String
    public let stagedArchiveOpaqueReference: String
    public let stagedArchiveFileIdentity: ManagedInstallerProviderStagedFileIdentity
    public let inspectionEvidenceReference: String
    public let executableArchitectures: [String]
    public let minimumMacOSVersion: InstallerVersion

    public init(
        stagedArchive: ManagedInstallerProviderStagedArchive,
        requirement: ProviderRequirement,
        inspection: ManagedInstallerProviderRuntimeArchiveInspection
    ) throws {
        guard Self.isExactComponentRequirement(requirement),
              let runtime = requirement.runtime,
              stagedArchive.providerTargetID == requirement.id,
              stagedArchive.provider == requirement.provider,
              stagedArchive.runtime == runtime,
              inspection.providerTargetID == requirement.id,
              inspection.provider == requirement.provider,
              inspection.runtime == runtime,
              inspection.executableArchitectures == ["arm64"],
              inspection.minimumMacOSVersion.major >= 26 else {
            throw ManagedInstallerProviderRuntimeMutationFailure.invalidRequest
        }
        operationID = stagedArchive.operationID
        providerTargetID = requirement.id
        provider = requirement.provider
        self.runtime = runtime
        runtimeSlotIdentity = Self.runtimeSlotIdentity(for: requirement)
        providerHomeIdentity = Self.providerHomeIdentity(for: requirement)
        stagedArchiveOpaqueReference = stagedArchive.opaqueReference
        stagedArchiveFileIdentity = stagedArchive.fileIdentity
        inspectionEvidenceReference = inspection.evidenceReference
        executableArchitectures = inspection.executableArchitectures
        minimumMacOSVersion = inspection.minimumMacOSVersion
    }

    public static func runtimeSlotIdentity(for requirement: ProviderRequirement) -> String {
        guard isExactComponentRequirement(requirement),
              let runtime = requirement.runtime else { return "" }
        return identity(
            prefix: "provider-runtime-slot",
            fields: [
                requirement.id.rawValue,
                runtime.version.description,
                runtime.artifactSHA256,
                runtime.executableRelativePath,
                runtime.executableSHA256,
            ]
        )
    }

    public static func providerHomeIdentity(for requirement: ProviderRequirement) -> String {
        guard isExactComponentRequirement(requirement) else { return "" }
        return identity(
            prefix: "provider-home",
            fields: [requirement.id.rawValue]
        )
    }

    private static func identity(prefix: String, fields: [String]) -> String {
        var material = Data("forge-platform-managed-provider-identity-v1".utf8)
        for field in fields {
            var count = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &count) { material.append(contentsOf: $0) }
            material.append(contentsOf: field.utf8)
        }
        return prefix + "-" + SHA256.hash(data: material).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func isExactComponentRequirement(
        _ requirement: ProviderRequirement
    ) -> Bool {
        requirement.credentialScope == .component
            && requirement.ownerComponent != nil
            && requirement.targetIdentity != nil
            && requirement.runtime != nil
    }
}

public struct ManagedInstallerProviderRuntimeMutationReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ready = "READY"
    }

    public let operationID: String
    public let providerTargetID: ProviderTargetID
    public let provider: ProviderID
    public let runtime: ProviderRuntimeRequirement
    public let managedRootIdentity: String
    public let runtimeSlotIdentity: String
    public let providerHomeIdentity: String
    public let executableArchitectures: [String]
    public let minimumMacOSVersion: InstallerVersion
    public let state: State
    public let evidenceReference: String

    public init(
        operationID: String,
        providerTargetID: ProviderTargetID,
        provider: ProviderID,
        runtime: ProviderRuntimeRequirement,
        managedRootIdentity: String,
        runtimeSlotIdentity: String,
        providerHomeIdentity: String,
        executableArchitectures: [String],
        minimumMacOSVersion: InstallerVersion,
        state: State,
        evidenceReference: String
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              managedRootIdentity == ManagedInstallerProviderRuntimeMutationRequest
                .managedRootIdentity,
              InstallerSelfUpdateValidation.isOpaqueReference(runtimeSlotIdentity),
              InstallerSelfUpdateValidation.isOpaqueReference(providerHomeIdentity),
              executableArchitectures == ["arm64"],
              minimumMacOSVersion.major >= 26,
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(
                  evidenceReference
              ) else {
            throw ManagedInstallerProviderRuntimeMutationFailure.invalidRequest
        }
        self.operationID = operationID
        self.providerTargetID = providerTargetID
        self.provider = provider
        self.runtime = runtime
        self.managedRootIdentity = managedRootIdentity
        self.runtimeSlotIdentity = runtimeSlotIdentity
        self.providerHomeIdentity = providerHomeIdentity
        self.executableArchitectures = executableArchitectures
        self.minimumMacOSVersion = minimumMacOSVersion
        self.state = state
        self.evidenceReference = evidenceReference
    }

    public init(
        request: ManagedInstallerProviderRuntimeMutationRequest,
        evidenceReference: String
    ) throws {
        try self.init(
            operationID: request.operationID,
            providerTargetID: request.providerTargetID,
            provider: request.provider,
            runtime: request.runtime,
            managedRootIdentity: ManagedInstallerProviderRuntimeMutationRequest
                .managedRootIdentity,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            providerHomeIdentity: request.providerHomeIdentity,
            executableArchitectures: request.executableArchitectures,
            minimumMacOSVersion: request.minimumMacOSVersion,
            state: .ready,
            evidenceReference: evidenceReference
        )
    }

    func matches(_ request: ManagedInstallerProviderRuntimeMutationRequest) -> Bool {
        operationID == request.operationID
            && providerTargetID == request.providerTargetID
            && provider == request.provider
            && runtime == request.runtime
            && managedRootIdentity == ManagedInstallerProviderRuntimeMutationRequest
                .managedRootIdentity
            && runtimeSlotIdentity == request.runtimeSlotIdentity
            && providerHomeIdentity == request.providerHomeIdentity
            && executableArchitectures == request.executableArchitectures
            && minimumMacOSVersion == request.minimumMacOSVersion
            && state == .ready
    }
}

/// Fixed privilege boundary for provider runtime installation. A concrete
/// adapter owns authorization, exact archive extraction, the trusted staging
/// root, the installer-owned runtime root and provider-home creation.
public protocol ManagedInstallerProviderRuntimeMutating: Sendable {
    func readInstalledProviderRuntime(
        _ request: ManagedInstallerProviderRuntimeMutationRequest
    ) async -> Result<
        ManagedInstallerProviderRuntimeMutationReceipt?,
        ManagedInstallerProviderRuntimeMutationFailure
    >

    func installProviderRuntime(
        _ request: ManagedInstallerProviderRuntimeMutationRequest
    ) async -> Result<
        ManagedInstallerProviderRuntimeMutationReceipt,
        ManagedInstallerProviderRuntimeMutationFailure
    >
}

/// Coordinates idempotent provider-runtime installation across exact staging
/// readback and an injected privilege seam. A successful install response is
/// insufficient: staged bytes are re-read after mutation and a separate final
/// installed-runtime readback must match the complete request before `READY`.
public struct ManagedInstallerProviderRuntimeMutationCoordinator: Sendable {
    private let staging: any ManagedInstallerProviderRuntimeArchiveStaging
    private let mutation: any ManagedInstallerProviderRuntimeMutating

    public init(
        staging: any ManagedInstallerProviderRuntimeArchiveStaging,
        mutation: any ManagedInstallerProviderRuntimeMutating
    ) {
        self.staging = staging
        self.mutation = mutation
    }

    public func ensureProviderRuntime(
        stagedArchive: ManagedInstallerProviderStagedArchive,
        requirement: ProviderRequirement,
        inspection: ManagedInstallerProviderRuntimeArchiveInspection
    ) async -> Result<
        ManagedInstallerProviderRuntimeMutationReceipt,
        ManagedInstallerProviderRuntimeMutationFailure
    > {
        do {
            let request = try ManagedInstallerProviderRuntimeMutationRequest(
                stagedArchive: stagedArchive,
                requirement: requirement,
                inspection: inspection
            )
            try await verifyStagedArchive(stagedArchive, requirement: requirement)

            switch await mutation.readInstalledProviderRuntime(request) {
            case .success(let existing?):
                guard existing.matches(request) else {
                    throw ManagedInstallerProviderRuntimeMutationFailure.rejected
                }
                return .success(existing)
            case .success(nil): break
            case .failure(let failure): throw failure
            }

            switch await mutation.installProviderRuntime(request) {
            case .success(let receipt):
                guard receipt.matches(request) else {
                    throw ManagedInstallerProviderRuntimeMutationFailure.rejected
                }
            case .failure(let failure): throw failure
            }

            try await verifyStagedArchive(stagedArchive, requirement: requirement)
            switch await mutation.readInstalledProviderRuntime(request) {
            case .success(let readback?):
                guard readback.matches(request) else {
                    throw ManagedInstallerProviderRuntimeMutationFailure.rejected
                }
                return .success(readback)
            case .success(nil):
                throw ManagedInstallerProviderRuntimeMutationFailure.rejected
            case .failure(let failure): throw failure
            }
        } catch let failure as ManagedInstallerProviderRuntimeMutationFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    private func verifyStagedArchive(
        _ stagedArchive: ManagedInstallerProviderStagedArchive,
        requirement: ProviderRequirement
    ) async throws {
        switch await staging.readStagedRuntimeArchive(stagedArchive, for: requirement) {
        case .success(let readback):
            guard readback.providerTargetID == requirement.id,
                  readback.provider == requirement.provider,
                  readback.runtime == requirement.runtime,
                  !readback.bytes.isEmpty,
                  UInt64(readback.bytes.count) == stagedArchive.fileIdentity.byteCount,
                  Self.taggedSHA256(readback.bytes) == stagedArchive.runtime.artifactSHA256 else {
                throw ManagedInstallerProviderRuntimeMutationFailure.rejected
            }
        case .failure(.invalidRequest):
            throw ManagedInstallerProviderRuntimeMutationFailure.invalidRequest
        case .failure(.unavailable):
            throw ManagedInstallerProviderRuntimeMutationFailure.unavailable
        case .failure(.rejected):
            throw ManagedInstallerProviderRuntimeMutationFailure.rejected
        }
    }

    private static func taggedSHA256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
