import Darwin
import Foundation

/// One context-bound post-tool observation. A concrete host adapter emits all
/// managed-tool, active-runtime and non-tool gate readbacks in one document so
/// the replanner cannot combine values from different observation epochs.
public struct ManagedInstallerPostToolReadbackSnapshot: Equatable, Sendable {
    public static let schema = "forge-platform.managed-installer-post-tool-readback/v1"
    static let maximumBytes = 128 * 1_024

    public let operationID: String
    public let sessionID: String
    public let deploymentID: String
    public let stablePlanFingerprint: String
    public let requestFingerprint: String
    public let managedTools: [ManagedToolInstalledReadback]
    public let pythonRuntime: ManagedPythonRuntimeInstalledReadback
    public let gates: [ManagedInstallerPostToolGateReadback]
    public let evidenceReference: String

    public init(
        operationID: String,
        sessionID: String,
        deploymentID: String,
        stablePlanFingerprint: String,
        requestFingerprint: String,
        managedTools: [ManagedToolInstalledReadback],
        pythonRuntime: ManagedPythonRuntimeInstalledReadback,
        gates: [ManagedInstallerPostToolGateReadback],
        evidenceReference: String
    ) throws {
        let orderedTools = managedTools.sorted { $0.identity.rawValue < $1.identity.rawValue }
        let orderedGates = gates.sorted { $0.gate.rawValue < $1.gate.rawValue }
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              ManagedPythonRuntimeStagingValidation.isOperationID(sessionID),
              ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
              ManagedPythonRuntimePostToolQualification.isFingerprint(stablePlanFingerprint),
              ManagedPythonRuntimePostToolQualification.isFingerprint(requestFingerprint),
              !orderedTools.isEmpty,
              Set(orderedTools.map(\.identity)).count == orderedTools.count,
              Set(orderedGates.map(\.gate)) == Set(ManagedInstallerPostToolGate.allCases),
              orderedGates.count == ManagedInstallerPostToolGate.allCases.count,
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidenceReference) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.operationID = operationID
        self.sessionID = sessionID
        self.deploymentID = deploymentID
        self.stablePlanFingerprint = stablePlanFingerprint
        self.requestFingerprint = requestFingerprint
        self.managedTools = orderedTools
        self.pythonRuntime = pythonRuntime
        self.gates = orderedGates
        self.evidenceReference = evidenceReference
    }

    func matches(
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) -> Bool {
        operationID == request.operationID
            && sessionID == stablePlan.session.sessionID
            && sessionID == request.sessionID
            && deploymentID == stablePlan.deployment.id
            && deploymentID == request.deploymentID
            && stablePlanFingerprint == stablePlan.fingerprint
            && requestFingerprint == request.executionRequestFingerprint
            && managedTools.map(\.identity)
                == stablePlan.session.managedTools.map(\.identity).sorted { $0.rawValue < $1.rawValue }
    }

    public func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "operation_id": .string(operationID),
            "session_id": .string(sessionID),
            "deployment_id": .string(deploymentID),
            "stable_plan_fingerprint": .string(stablePlanFingerprint),
            "request_fingerprint": .string(requestFingerprint),
            "managed_tools": .array(managedTools.map(Self.toolValue)),
            "python_runtime": Self.pythonValue(pythonRuntime),
            "gates": .array(gates.map(Self.gateValue)),
            "evidence_reference": .string(evidenceReference),
        ]))
    }

    static func decodeJSON(_ data: Data) throws -> ManagedInstallerPostToolReadbackSnapshot {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "operation_id", "session_id", "deployment_id",
                  "stable_plan_fingerprint", "request_fingerprint", "managed_tools",
                  "python_runtime", "gates", "evidence_reference",
              ]),
              fields["schema"]?.stringValue == Self.schema,
              let operationID = fields["operation_id"]?.stringValue,
              let sessionID = fields["session_id"]?.stringValue,
              let deploymentID = fields["deployment_id"]?.stringValue,
              let stablePlanFingerprint = fields["stable_plan_fingerprint"]?.stringValue,
              let requestFingerprint = fields["request_fingerprint"]?.stringValue,
              let toolValues = fields["managed_tools"]?.arrayValue,
              let pythonValue = fields["python_runtime"],
              let gateValues = fields["gates"]?.arrayValue,
              let evidenceReference = fields["evidence_reference"]?.stringValue else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        return try Self(
            operationID: operationID,
            sessionID: sessionID,
            deploymentID: deploymentID,
            stablePlanFingerprint: stablePlanFingerprint,
            requestFingerprint: requestFingerprint,
            managedTools: toolValues.map(Self.decodeTool),
            pythonRuntime: Self.decodePython(pythonValue),
            gates: gateValues.map(Self.decodeGate),
            evidenceReference: evidenceReference
        )
    }

    private static func toolValue(_ readback: ManagedToolInstalledReadback) -> StrictJSONResourceValue {
        .object([
            "identity": .string(readback.identity.rawValue),
            "state": .string(readback.state.rawValue),
            "version": readback.version.map { .string($0.description) } ?? .null,
            "artifact_sha256": readback.artifactSHA256.map { .string($0) } ?? .null,
            "managed_root_identity": readback.managedRootIdentity.map { .string($0) } ?? .null,
            "evidence_reference": .string(readback.evidenceReference),
        ])
    }

    private static func pythonValue(
        _ readback: ManagedPythonRuntimeInstalledReadback
    ) -> StrictJSONResourceValue {
        .object([
            "active_runtime_identity": readback.activeRuntimeIdentitySHA256.map {
                .string($0)
            } ?? .null,
            "active_runtime_slot": readback.activeRuntimeSlotIdentity.map {
                .string($0)
            } ?? .null,
            "retained_runtime_identities": .array(
                readback.retainedRuntimeIdentitySHA256s.map { .string($0) }
            ),
            "evidence_reference": .string(readback.evidenceReference),
        ])
    }

    private static func gateValue(
        _ readback: ManagedInstallerPostToolGateReadback
    ) -> StrictJSONResourceValue {
        .object([
            "identity": .string(readback.gate.rawValue),
            "passed": .boolean(readback.passed),
            "evidence_reference": .string(readback.evidenceReference),
        ])
    }

    private static func decodeTool(_ value: StrictJSONResourceValue) throws
        -> ManagedToolInstalledReadback {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                  "identity", "state", "version", "artifact_sha256",
                  "managed_root_identity", "evidence_reference",
              ]),
              let identityValue = fields["identity"]?.stringValue,
              let identity = ManagedToolRequirement.Identity(rawValue: identityValue),
              let stateValue = fields["state"]?.stringValue,
              let state = ManagedToolInstalledReadback.State(rawValue: stateValue),
              let evidenceReference = fields["evidence_reference"]?.stringValue else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        let versionValue = try optionalString(fields["version"])
        let artifactSHA256 = try optionalString(fields["artifact_sha256"])
        let managedRootIdentity = try optionalString(fields["managed_root_identity"])
        return try ManagedToolInstalledReadback(
            identity: identity,
            state: state,
            version: try versionValue.map(InstallerVersion.init),
            artifactSHA256: artifactSHA256,
            managedRootIdentity: managedRootIdentity,
            evidenceReference: evidenceReference
        )
    }

    private static func decodePython(_ value: StrictJSONResourceValue) throws
        -> ManagedPythonRuntimeInstalledReadback {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                  "active_runtime_identity", "active_runtime_slot",
                  "retained_runtime_identities", "evidence_reference",
              ]),
              let retainedValues = fields["retained_runtime_identities"]?.arrayValue,
              let evidenceReference = fields["evidence_reference"]?.stringValue else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        let activeIdentity = try optionalString(fields["active_runtime_identity"])
        let activeSlot = try optionalString(fields["active_runtime_slot"])
        let retained = try retainedValues.map { value -> String in
            guard let string = value.stringValue else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
            return string
        }
        return try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: activeIdentity,
            activeRuntimeSlotIdentity: activeSlot,
            retainedRuntimeIdentitySHA256s: retained,
            evidenceReference: evidenceReference
        )
    }

    private static func decodeGate(_ value: StrictJSONResourceValue) throws
        -> ManagedInstallerPostToolGateReadback {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set(["identity", "passed", "evidence_reference"]),
              let identityValue = fields["identity"]?.stringValue,
              let gate = ManagedInstallerPostToolGate(rawValue: identityValue),
              case .boolean(let passed) = fields["passed"],
              let evidenceReference = fields["evidence_reference"]?.stringValue else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        return try ManagedInstallerPostToolGateReadback(
            gate: gate,
            passed: passed,
            evidenceReference: evidenceReference
        )
    }

    private static func optionalString(_ value: StrictJSONResourceValue?) throws -> String? {
        switch value {
        case .string(let string): return string
        case .null: return nil
        default: throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
    }
}

public protocol ManagedInstallerPostToolSnapshotReading: Sendable {
    func readPostToolSnapshot(
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedInstallerPostToolReadbackSnapshot, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Descriptor-safe reader for one helper-produced snapshot. It never creates
/// or repairs the root or record and cannot select a caller-provided filename.
public struct FileManagedInstallerPostToolSnapshotReader: ManagedInstallerPostToolSnapshotReading {
    static let filePrefix = "post-tool-readback-"
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
    }

    public func readPostToolSnapshot(
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedInstallerPostToolReadbackSnapshot, ManagedPythonRuntimeTerminalReceiptFailure> {
        do {
            guard request.operationID == stablePlan.activationPlan.operationID else {
                return .failure(.rejected)
            }
            let root = try openSecureRoot()
            defer { _ = Darwin.close(root) }
            let fileName = Self.filePrefix + request.operationID + ".json"
            let descriptor = try openSecureSnapshot(fileName, in: root)
            defer { _ = Darwin.close(descriptor) }
            let data = try readSnapshot(descriptor)
            let snapshot = try ManagedInstallerPostToolReadbackSnapshot.decodeJSON(data)
            guard snapshot.matches(stablePlan: stablePlan, request: request) else {
                return .failure(.rejected)
            }
            return .success(snapshot)
        } catch let failure as ManagedPythonRuntimeTerminalReceiptFailure {
            return .failure(failure)
        } catch {
            return .failure(.readbackFailed)
        }
    }

    private func openSecureRoot() throws -> Int32 {
        guard rootDirectory.isFileURL,
              rootDirectory.baseURL == nil,
              rootDirectory.path.hasPrefix("/"),
              rootDirectory.path != "/" else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.readbackFailed
        }
        let descriptor = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0, Self.isSecureDirectory(descriptor) else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ManagedPythonRuntimeTerminalReceiptFailure.readbackFailed
        }
        return descriptor
    }

    private func openSecureSnapshot(_ fileName: String, in root: Int32) throws -> Int32 {
        let descriptor = fileName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0, Self.isSecureRegularFile(descriptor) else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ManagedPythonRuntimeTerminalReceiptFailure.readbackFailed
        }
        return descriptor
    }

    private func readSnapshot(_ descriptor: Int32) throws -> Data {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_size > 0,
              before.st_size <= ManagedInstallerPostToolReadbackSnapshot.maximumBytes else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.readbackFailed
        }
        var data = Data(count: Int(before.st_size))
        let count = try data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.readbackFailed
            }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else {
                    throw ManagedPythonRuntimeTerminalReceiptFailure.readbackFailed
                }
                offset += result
            }
            return offset
        }
        var trailing: UInt8 = 0
        guard count == data.count,
              Darwin.read(descriptor, &trailing, 1) == 0 else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.readbackFailed
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.readbackFailed
        }
        return data
    }

    private static func isSecureDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == Darwin.geteuid()
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func isSecureRegularFile(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == Darwin.geteuid()
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o600)
    }

    private static func canonicalRootDirectory(_ input: URL) -> URL {
        guard input.isFileURL,
              input.baseURL == nil,
              input.path.hasPrefix("/"),
              let resolved = input.path.withCString({ Darwin.realpath($0, nil) }) else {
            return input.standardizedFileURL
        }
        defer { Darwin.free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}
