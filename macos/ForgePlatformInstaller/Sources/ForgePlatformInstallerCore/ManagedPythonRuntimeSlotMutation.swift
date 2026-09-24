import Foundation

public enum ManagedPythonRuntimeSlotMutationFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

public struct ManagedPythonRuntimeSlotMutationRequest: Equatable, Sendable {
    public static let managedRootIdentity = "forge-platform-managed-python-v1"

    public let operationID: String
    public let runtimeIdentitySHA256: String
    public let runtimeSlotIdentity: String
    public let archiveSHA256: String
    public let stagedArchiveOpaqueReference: String
    public let stagedArchiveFileIdentity: ManagedPythonStagedFileIdentity
    public let archiveLayout: String
    public let interpreterRelativePath: String
    public let executableArchitectures: [String]
    public let minimumMacOSVersion: InstallerVersion
    public let inspectionEvidenceReference: String

    init(
        stagedAssets: ManagedPythonStagedAssetSet,
        runtime: ManagedPythonRuntimeIdentity,
        inspection: ManagedPythonRuntimeArchiveInspection
    ) throws {
        guard stagedAssets.runtimeIdentitySHA256 == runtime.identitySHA256,
              stagedAssets.assets.map(\.kind) == ManagedPythonRuntimeAssetKind.allCases,
              let archive = stagedAssets.asset(.runtimeArchive),
              archive.operationID == stagedAssets.operationID,
              archive.runtimeIdentitySHA256 == runtime.identitySHA256,
              archive.downloadIdentity == runtime.artifact,
              archive.opaqueReference == stagedAssets.opaqueReference,
              Self.inspection(inspection, matches: runtime) else {
            throw ManagedPythonRuntimeSlotMutationFailure.invalidRequest
        }
        operationID = stagedAssets.operationID
        runtimeIdentitySHA256 = runtime.identitySHA256
        runtimeSlotIdentity = Self.runtimeSlotIdentity(for: runtime.identitySHA256)
        archiveSHA256 = runtime.artifact.sha256
        stagedArchiveOpaqueReference = archive.opaqueReference
        stagedArchiveFileIdentity = archive.fileIdentity
        archiveLayout = inspection.archiveLayout
        interpreterRelativePath = inspection.interpreterPath
        executableArchitectures = inspection.executableArchitectures
        minimumMacOSVersion = inspection.minimumMacOSVersion
        inspectionEvidenceReference = inspection.evidenceReference
    }

    public static func runtimeSlotIdentity(for runtimeIdentitySHA256: String) -> String {
        guard CompositionCatalogValidation.isTaggedSHA256(runtimeIdentitySHA256) else {
            return ""
        }
        return "sha256-" + runtimeIdentitySHA256.dropFirst("sha256:".count)
    }

    private static func inspection(
        _ inspection: ManagedPythonRuntimeArchiveInspection,
        matches runtime: ManagedPythonRuntimeIdentity
    ) -> Bool {
        inspection.runtimeIdentitySHA256 == runtime.identitySHA256
            && inspection.archiveSHA256 == runtime.artifact.sha256
            && inspection.sourceSHA256 == runtime.source.sha256
            && inspection.sourceProvenanceSHA256 == runtime.sourceProvenance.sha256
            && inspection.buildProvenanceSHA256 == runtime.buildProvenance.sha256
            && inspection.archiveLayout == ManagedPythonRuntimeArchiveInspection.layout
            && inspection.interpreterPath == ManagedPythonRuntimeArchiveInspection.interpreterRelativePath
            && inspection.executableArchitectures == [ManagedPythonRuntimeIdentity.architecture]
            && inspection.minimumMacOSVersion == runtime.minimumMacOSVersion
            && inspection.implementation == ManagedPythonRuntimeIdentity.implementation
            && inspection.version == runtime.version
            && inspection.buildVariant == ManagedPythonRuntimeIdentity.buildVariant
            && inspection.pythonTag == runtime.pythonTag
            && inspection.abiTag == runtime.abiTag
            && inspection.platformTag == ManagedPythonRuntimeIdentity.platformTag
            && inspection.policyRevision == runtime.policyRevision
    }
}

public struct ManagedPythonRuntimeSlotReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ready = "READY"
    }

    public let operationID: String
    public let runtimeIdentitySHA256: String
    public let managedRootIdentity: String
    public let runtimeSlotIdentity: String
    public let archiveSHA256: String
    public let interpreterRelativePath: String
    public let executableArchitectures: [String]
    public let minimumMacOSVersion: InstallerVersion
    public let state: State
    public let evidenceReference: String

    public init(
        operationID: String,
        runtimeIdentitySHA256: String,
        managedRootIdentity: String,
        runtimeSlotIdentity: String,
        archiveSHA256: String,
        interpreterRelativePath: String,
        executableArchitectures: [String],
        minimumMacOSVersion: InstallerVersion,
        state: State,
        evidenceReference: String
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              CompositionCatalogValidation.isTaggedSHA256(runtimeIdentitySHA256),
              managedRootIdentity == ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
              runtimeSlotIdentity == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                  for: runtimeIdentitySHA256
              ),
              CompositionCatalogValidation.isTaggedSHA256(archiveSHA256),
              interpreterRelativePath == ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
              executableArchitectures == [ManagedPythonRuntimeIdentity.architecture],
              minimumMacOSVersion.major >= 26,
              Self.isEvidenceReference(evidenceReference) else {
            throw ManagedPythonRuntimeSlotMutationFailure.invalidRequest
        }
        self.operationID = operationID
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256
        self.managedRootIdentity = managedRootIdentity
        self.runtimeSlotIdentity = runtimeSlotIdentity
        self.archiveSHA256 = archiveSHA256
        self.interpreterRelativePath = interpreterRelativePath
        self.executableArchitectures = executableArchitectures
        self.minimumMacOSVersion = minimumMacOSVersion
        self.state = state
        self.evidenceReference = evidenceReference
    }

    func matches(_ request: ManagedPythonRuntimeSlotMutationRequest) -> Bool {
        operationID == request.operationID
            && runtimeIdentitySHA256 == request.runtimeIdentitySHA256
            && managedRootIdentity == ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity
            && runtimeSlotIdentity == request.runtimeSlotIdentity
            && archiveSHA256 == request.archiveSHA256
            && interpreterRelativePath == request.interpreterRelativePath
            && executableArchitectures == request.executableArchitectures
            && minimumMacOSVersion == request.minimumMacOSVersion
            && state == .ready
    }

    private static func isEvidenceReference(_ value: String) -> Bool {
        guard value.hasPrefix("receipt:"),
              (9...136).contains(value.utf8.count) else { return false }
        let suffix = value.dropFirst("receipt:".count)
        guard let first = suffix.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else { return false }
        return suffix.unicodeScalars.allSatisfy {
            isLowercaseLetterOrDigit($0) || [45, 46, 95].contains($0.value)
        }
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

/// Fixed privilege boundary for runtime-slot mutation. A concrete adapter owns
/// authorization, the trusted staging root and the installer-owned managed
/// root. It receives no caller-selected path, executable, command or
/// environment value.
public protocol ManagedPythonRuntimeSlotMutating: Sendable {
    func readRuntimeSlot(
        _ request: ManagedPythonRuntimeSlotMutationRequest
    ) async -> Result<ManagedPythonRuntimeSlotReceipt?, ManagedPythonRuntimeSlotMutationFailure>

    func installRuntimeSlot(
        _ request: ManagedPythonRuntimeSlotMutationRequest
    ) async -> Result<ManagedPythonRuntimeSlotReceipt, ManagedPythonRuntimeSlotMutationFailure>
}

/// Coordinates idempotent runtime-slot installation across a private staging
/// readback and an injected privilege boundary. A successful install response
/// is never sufficient: the archive is re-read and a separate slot readback
/// must prove the exact request before READY is returned.
public struct ManagedPythonRuntimeSlotMutationCoordinator: Sendable {
    private let staging: any ManagedPythonRuntimeAssetStaging
    private let mutation: any ManagedPythonRuntimeSlotMutating

    public init(
        staging: any ManagedPythonRuntimeAssetStaging,
        mutation: any ManagedPythonRuntimeSlotMutating
    ) {
        self.staging = staging
        self.mutation = mutation
    }

    public func ensureRuntimeSlot(
        stagedAssets: ManagedPythonStagedAssetSet,
        runtime: ManagedPythonRuntimeIdentity,
        inspection: ManagedPythonRuntimeArchiveInspection
    ) async -> Result<ManagedPythonRuntimeSlotReceipt, ManagedPythonRuntimeSlotMutationFailure> {
        do {
            let request = try ManagedPythonRuntimeSlotMutationRequest(
                stagedAssets: stagedAssets,
                runtime: runtime,
                inspection: inspection
            )
            try await verifyStagedArchive(stagedAssets, runtime: runtime)

            switch await mutation.readRuntimeSlot(request) {
            case .success(let existing?):
                guard existing.matches(request) else {
                    throw ManagedPythonRuntimeSlotMutationFailure.rejected
                }
                return .success(existing)
            case .success(nil):
                break
            case .failure(let failure):
                throw failure
            }

            switch await mutation.installRuntimeSlot(request) {
            case .success(let receipt):
                guard receipt.matches(request) else {
                    throw ManagedPythonRuntimeSlotMutationFailure.rejected
                }
            case .failure(let failure):
                throw failure
            }

            try await verifyStagedArchive(stagedAssets, runtime: runtime)
            switch await mutation.readRuntimeSlot(request) {
            case .success(let readback?):
                guard readback.matches(request) else {
                    throw ManagedPythonRuntimeSlotMutationFailure.rejected
                }
                return .success(readback)
            case .success(nil):
                throw ManagedPythonRuntimeSlotMutationFailure.rejected
            case .failure(let failure):
                throw failure
            }
        } catch let failure as ManagedPythonRuntimeSlotMutationFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    private func verifyStagedArchive(
        _ stagedAssets: ManagedPythonStagedAssetSet,
        runtime: ManagedPythonRuntimeIdentity
    ) async throws {
        guard let archive = stagedAssets.asset(.runtimeArchive) else {
            throw ManagedPythonRuntimeSlotMutationFailure.invalidRequest
        }
        switch await staging.readStagedAsset(archive, for: runtime) {
        case .success(let readback):
            let readbackSHA256 = "sha256:"
                + GitHubInstallerReleaseDescriptor.sha256(of: readback.bytes)
            guard readback.runtimeIdentitySHA256 == runtime.identitySHA256,
                  readback.kind == .runtimeArchive,
                  readback.downloadIdentity == runtime.artifact,
                  !readback.bytes.isEmpty,
                  UInt64(readback.bytes.count) == archive.fileIdentity.byteCount,
                  readbackSHA256 == archive.downloadIdentity.sha256 else {
                throw ManagedPythonRuntimeSlotMutationFailure.rejected
            }
        case .failure(.invalidRequest):
            throw ManagedPythonRuntimeSlotMutationFailure.invalidRequest
        case .failure(.unavailable):
            throw ManagedPythonRuntimeSlotMutationFailure.unavailable
        case .failure(.rejected):
            throw ManagedPythonRuntimeSlotMutationFailure.rejected
        }
    }
}
