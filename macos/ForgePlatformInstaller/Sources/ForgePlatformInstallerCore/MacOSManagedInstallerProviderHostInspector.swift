import CryptoKit
import Darwin
import Foundation

enum MacOSManagedInstallerProviderProbe: Equatable, Sendable {
    case version
    case authenticationStatus
}

struct MacOSManagedInstallerProviderProbeCommand: Equatable, Sendable {
    let probe: MacOSManagedInstallerProviderProbe
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

struct MacOSManagedInstallerProviderProbeResult: Equatable, Sendable {
    let exitStatus: Int32
    let standardOutput: Data?
}

protocol MacOSManagedInstallerProviderProbeRunning: Sendable {
    func runProviderProbe(
        _ command: MacOSManagedInstallerProviderProbeCommand
    ) async -> Result<
        MacOSManagedInstallerProviderProbeResult,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
}

/// Fixed command projection for the two provider CLIs admitted by the current
/// installer schema. Executable and credential-home locations come only from
/// the helper's derived component-instance layout; no request field becomes a
/// command, option, environment key or credential value.
enum MacOSManagedInstallerProviderProbeCommandFactory {
    static func command(
        provider: ProviderID,
        probe: MacOSManagedInstallerProviderProbe,
        executableURL: URL,
        providerHomeURL: URL
    ) -> MacOSManagedInstallerProviderProbeCommand {
        var environment = [
            "HOME": providerHomeURL.path,
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let arguments: [String]
        switch (provider, probe) {
        case (.codex, .version):
            environment["CODEX_HOME"] = providerHomeURL.path
            arguments = ["--version"]
        case (.codex, .authenticationStatus):
            environment["CODEX_HOME"] = providerHomeURL.path
            arguments = ["login", "status"]
        case (.githubCLI, .version):
            environment["GH_CONFIG_DIR"] = providerHomeURL.path
            arguments = ["--version"]
        case (.githubCLI, .authenticationStatus):
            environment["GH_CONFIG_DIR"] = providerHomeURL.path
            arguments = ["auth", "status", "--hostname", "github.com"]
        }
        return MacOSManagedInstallerProviderProbeCommand(
            probe: probe,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        )
    }
}

/// Executes only a command produced by the fixed factory. Version output is
/// bounded and returned solely to the strict version parser; authentication
/// output is discarded so account names, keychain details or tokens cannot
/// become installer evidence or diagnostics.
struct MacOSSystemManagedInstallerProviderProbeRunner:
    MacOSManagedInstallerProviderProbeRunning {
    private static let timeout: DispatchTimeInterval = .seconds(20)
    private static let terminationGracePeriod: DispatchTimeInterval = .seconds(2)
    private static let outputDrainTimeout: DispatchTimeInterval = .seconds(2)
    private static let maximumVersionOutputBytes = 4 * 1_024

    func runProviderProbe(
        _ command: MacOSManagedInstallerProviderProbeCommand
    ) async -> Result<
        MacOSManagedInstallerProviderProbeResult,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        await Task.detached(priority: .userInitiated) {
            Self.runSynchronously(command)
        }.value
    }

    private static func runSynchronously(
        _ command: MacOSManagedInstallerProviderProbeCommand
    ) -> Result<
        MacOSManagedInstallerProviderProbeResult,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        guard command.executableURL.isFileURL,
              command.executableURL.baseURL == nil,
              command.executableURL.path.hasPrefix("/"),
              command.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin",
              command.environment["LANG"] == "C",
              command.environment["LC_ALL"] == "C" else {
            return .failure(.rejected)
        }

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = command.environment
        let output: Pipe?
        let collector: BoundedProcessOutputCollector?
        switch command.probe {
        case .version:
            let pipe = Pipe()
            output = pipe
            collector = BoundedProcessOutputCollector(
                maximumBytes: maximumVersionOutputBytes
            )
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
        case .authenticationStatus:
            output = nil
            collector = nil
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.readbackFailed)
        }

        let outputGroup = DispatchGroup()
        if let output, let collector {
            outputGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { outputGroup.leave() }
                collector.consume(output.fileHandleForReading)
            }
        }
        guard termination.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if termination.wait(timeout: .now() + terminationGracePeriod) != .success {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                guard termination.wait(timeout: .now() + terminationGracePeriod) == .success else {
                    return .failure(.readbackFailed)
                }
            }
            return .failure(.readbackFailed)
        }
        guard outputGroup.wait(timeout: .now() + outputDrainTimeout) == .success,
              process.terminationReason == .exit else {
            return .failure(.readbackFailed)
        }
        let captured: Data?
        if let collector {
            guard let data = collector.collectedData() else {
                return .failure(.readbackFailed)
            }
            captured = data
        } else {
            captured = nil
        }
        return .success(MacOSManagedInstallerProviderProbeResult(
            exitStatus: process.terminationStatus,
            standardOutput: captured
        ))
    }
}

/// Concrete helper-side inspector for component-owned provider contexts. The
/// configured root is selected when the helper is assembled. Every remaining
/// path segment is derived from already validated immutable identities in the
/// canonical request; user-scoped legacy requirements remain ineligible until
/// an exact OS-user authority is added to that request schema.
public struct MacOSManagedInstallerProviderHostInspector:
    ManagedInstallerProviderHostInspecting, Sendable {
    private static let maximumExecutableBytes = 512 * 1_024 * 1_024

    private let rootDirectory: URL
    private let runner: any MacOSManagedInstallerProviderProbeRunning

    public init(rootDirectory: URL) {
        self.init(
            rootDirectory: rootDirectory,
            runner: MacOSSystemManagedInstallerProviderProbeRunner()
        )
    }

    init(
        rootDirectory: URL,
        runner: any MacOSManagedInstallerProviderProbeRunning
    ) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
        self.runner = runner
    }

    public func inspectProvider(
        _ requirement: ProviderRequirement,
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerProviderHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        guard request.enabledProviderRequirements.contains(requirement),
              requirement.credentialScope == .component,
              let owner = requirement.ownerComponent,
              let targetIdentity = requirement.targetIdentity,
              let runtime = requirement.runtime else {
            return .failure(.rejected)
        }
        let layout = Layout(
            rootDirectory: rootDirectory,
            deploymentID: request.deploymentID,
            owner: owner,
            targetIdentity: targetIdentity,
            provider: requirement.provider,
            runtime: runtime
        )

        let before: ExecutableEvidence
        do {
            guard let evidence = try executableEvidence(for: layout) else {
                return readback(
                    requirement: requirement,
                    request: request,
                    state: .absent,
                    version: nil,
                    evidence: nil
                )
            }
            before = evidence
        } catch {
            return .failure(.readbackFailed)
        }

        guard before.sha256 == runtime.executableSHA256 else {
            return readback(
                requirement: requirement,
                request: request,
                state: .installed,
                version: nil,
                evidence: before
            )
        }
        do {
            try validateProviderHome(for: layout)
        } catch {
            return .failure(.readbackFailed)
        }

        let versionCommand = MacOSManagedInstallerProviderProbeCommandFactory.command(
            provider: requirement.provider,
            probe: .version,
            executableURL: layout.executableURL,
            providerHomeURL: layout.providerHomeURL
        )
        let versionResult: MacOSManagedInstallerProviderProbeResult
        switch await runner.runProviderProbe(versionCommand) {
        case .success(let result): versionResult = result
        case .failure(let failure): return .failure(failure)
        }
        guard versionResult.exitStatus == 0,
              let output = versionResult.standardOutput,
              let version = Self.version(from: output, provider: requirement.provider) else {
            return readback(
                requirement: requirement,
                request: request,
                state: .failed,
                version: nil,
                evidence: before
            )
        }

        let afterVersion: ExecutableEvidence
        do {
            guard let observed = try executableEvidence(for: layout),
                  observed == before else {
                return .failure(.readbackFailed)
            }
            afterVersion = observed
        } catch {
            return .failure(.readbackFailed)
        }
        guard version == runtime.version else {
            return readback(
                requirement: requirement,
                request: request,
                state: .installed,
                version: version,
                evidence: afterVersion
            )
        }

        let authCommand = MacOSManagedInstallerProviderProbeCommandFactory.command(
            provider: requirement.provider,
            probe: .authenticationStatus,
            executableURL: layout.executableURL,
            providerHomeURL: layout.providerHomeURL
        )
        let authResult: MacOSManagedInstallerProviderProbeResult
        switch await runner.runProviderProbe(authCommand) {
        case .success(let result): authResult = result
        case .failure(let failure): return .failure(failure)
        }
        let afterAuthentication: ExecutableEvidence
        do {
            guard let observed = try executableEvidence(for: layout),
                  observed == before else {
                return .failure(.readbackFailed)
            }
            afterAuthentication = observed
        } catch {
            return .failure(.readbackFailed)
        }
        let state: ManagedInstallerProviderHostReadback.State
        switch authResult.exitStatus {
        case 0: state = .verified
        case 1: state = .authenticationRequired
        default: state = .failed
        }
        return readback(
            requirement: requirement,
            request: request,
            state: state,
            version: version,
            evidence: afterAuthentication
        )
    }

    private func readback(
        requirement: ProviderRequirement,
        request: ManagedInstallerPostToolHostObservationRequest,
        state: ManagedInstallerProviderHostReadback.State,
        version: InstallerVersion?,
        evidence: ExecutableEvidence?
    ) -> Result<
        ManagedInstallerProviderHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        do {
            return .success(try ManagedInstallerProviderHostReadback(
                providerTargetID: requirement.id,
                state: state,
                version: version,
                executableIdentity: evidence?.identity,
                executableSHA256: evidence?.sha256,
                evidenceReference: Self.evidenceReference(
                    requirement: requirement,
                    request: request,
                    state: state,
                    version: version,
                    evidence: evidence
                )
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    static func version(from data: Data, provider: ProviderID) -> InstallerVersion? {
        guard !data.isEmpty,
              data.count <= 4 * 1_024,
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 }),
              let firstLine = text.split(whereSeparator: \Character.isNewline).first else {
            return nil
        }
        let fields = firstLine.split(whereSeparator: \Character.isWhitespace)
        let rawVersion: Substring
        switch provider {
        case .githubCLI:
            guard fields.count >= 3, fields[0] == "gh", fields[1] == "version" else {
                return nil
            }
            rawVersion = fields[2]
        case .codex:
            guard fields.count >= 2,
                  fields[0] == "codex" || fields[0] == "codex-cli" else {
                return nil
            }
            rawVersion = fields[1]
        }
        return try? InstallerVersion(String(rawVersion))
    }

    private func executableEvidence(for layout: Layout) throws -> ExecutableEvidence? {
        let root: Int32
        do {
            root = try openRoot()
        } catch InspectionError.absent {
            return nil
        }
        defer { _ = Darwin.close(root) }

        var current = root
        var ownedDescriptors: [Int32] = []
        defer { ownedDescriptors.forEach { _ = Darwin.close($0) } }
        do {
            for segment in layout.executableDirectorySegments {
                let next = try openDirectory(segment, at: current)
                ownedDescriptors.append(next)
                current = next
            }
            let descriptor = try openExecutable(layout.executableFileName, at: current)
            defer { _ = Darwin.close(descriptor) }
            return try hashExecutable(descriptor, identityMaterial: layout.identityMaterial)
        } catch InspectionError.absent {
            return nil
        }
    }

    private func validateProviderHome(for layout: Layout) throws {
        let root = try openRoot()
        defer { _ = Darwin.close(root) }
        var current = root
        var ownedDescriptors: [Int32] = []
        defer { ownedDescriptors.forEach { _ = Darwin.close($0) } }
        for segment in layout.providerTargetDirectorySegments + ["home"] {
            let next = try openDirectory(segment, at: current)
            ownedDescriptors.append(next)
            current = next
        }
    }

    private func openRoot() throws -> Int32 {
        guard rootDirectory.isFileURL,
              rootDirectory.baseURL == nil,
              rootDirectory.path.hasPrefix("/"),
              rootDirectory.path != "/" else {
            throw InspectionError.insecure
        }
        let descriptor = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw InspectionError.absent }
            throw InspectionError.insecure
        }
        guard Self.isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw InspectionError.insecure
        }
        return descriptor
    }

    private func openDirectory(_ name: String, at parent: Int32) throws -> Int32 {
        guard Self.isSafePathSegment(name) else { throw InspectionError.insecure }
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw InspectionError.absent }
            throw InspectionError.insecure
        }
        guard Self.isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw InspectionError.insecure
        }
        return descriptor
    }

    private func openExecutable(_ name: String, at parent: Int32) throws -> Int32 {
        guard Self.isSafePathSegment(name) else { throw InspectionError.insecure }
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw InspectionError.absent }
            throw InspectionError.insecure
        }
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              Self.isSecureExecutable(details) else {
            _ = Darwin.close(descriptor)
            throw InspectionError.insecure
        }
        return descriptor
    }

    private func hashExecutable(
        _ descriptor: Int32,
        identityMaterial: Data
    ) throws -> ExecutableEvidence {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Self.isSecureExecutable(before),
              before.st_size > 0,
              before.st_size <= off_t(Self.maximumExecutableBytes) else {
            throw InspectionError.insecure
        }
        var hasher = SHA256()
        var count = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
        while true {
            let readCount = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw InspectionError.insecure
            }
            count += readCount
            guard count <= Self.maximumExecutableBytes else {
                throw InspectionError.insecure
            }
            hasher.update(data: Data(buffer.prefix(readCount)))
        }
        var after = stat()
        guard count == before.st_size,
              Darwin.fstat(descriptor, &after) == 0,
              Self.sameFile(before, after),
              Self.isSecureExecutable(after) else {
            throw InspectionError.insecure
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let identityDigest = SHA256.hash(data: identityMaterial).map {
            String(format: "%02x", $0)
        }.joined()
        return ExecutableEvidence(
            identity: "provider-executable-\(identityDigest)",
            sha256: "sha256:\(digest)"
        )
    }

    private static func evidenceReference(
        requirement: ProviderRequirement,
        request: ManagedInstallerPostToolHostObservationRequest,
        state: ManagedInstallerProviderHostReadback.State,
        version: InstallerVersion?,
        evidence: ExecutableEvidence?
    ) -> String {
        let material = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.macos-provider-observation/v1"),
            "operation_id": .string(request.operationID),
            "deployment_id": .string(request.deploymentID),
            "stable_plan_fingerprint": .string(request.stablePlanFingerprint),
            "provider_target": .string(requirement.id.rawValue),
            "state": .string(state.rawValue),
            "version": version.map { .string($0.description) } ?? .null,
            "executable_identity": evidence.map { .string($0.identity) } ?? .null,
            "executable_sha256": evidence.map { .string($0.sha256) } ?? .null,
        ]))
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return "receipt:provider-observation-\(digest)"
    }

    private static func isSecureDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == Darwin.geteuid()
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func isSecureExecutable(_ details: stat) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == Darwin.geteuid()
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o500)
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func isSafePathSegment(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 384 && value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 45, 46, 95, 48...57, 65...90, 97...122: return true
            default: return false
            }
        }
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

    private struct Layout: Sendable {
        let rootDirectory: URL
        let deploymentID: String
        let owner: ProviderOwnerComponent
        let targetIdentity: String
        let provider: ProviderID
        let runtime: ProviderRuntimeRequirement

        var providerTargetDirectorySegments: [String] {
            [
                "deployments", deploymentID, "providers", owner.rawValue,
                targetIdentity, provider.rawValue,
            ]
        }

        var executableDirectorySegments: [String] {
            providerTargetDirectorySegments
                + ["runtime", runtime.version.description]
                + runtime.executableRelativePath.split(separator: "/").dropLast().map(String.init)
        }

        var executableFileName: String {
            String(runtime.executableRelativePath.split(separator: "/").last!)
        }

        var providerHomeURL: URL {
            providerTargetDirectorySegments.reduce(rootDirectory) {
                $0.appendingPathComponent($1, isDirectory: true)
            }.appendingPathComponent("home", isDirectory: true)
        }

        var executableURL: URL {
            let runtimeRoot = (providerTargetDirectorySegments
                + ["runtime", runtime.version.description]).reduce(rootDirectory) {
                    $0.appendingPathComponent($1, isDirectory: true)
                }
            return runtime.executableRelativePath.split(separator: "/").reduce(runtimeRoot) {
                $0.appendingPathComponent(String($1), isDirectory: false)
            }
        }

        var identityMaterial: Data {
            Data([
                deploymentID, owner.rawValue, targetIdentity, provider.rawValue,
                runtime.version.description, runtime.executableRelativePath,
                runtime.executableSHA256,
            ].joined(separator: "\u{0}").utf8)
        }
    }

    private struct ExecutableEvidence: Equatable, Sendable {
        let identity: String
        let sha256: String
    }

    private enum InspectionError: Error {
        case absent
        case insecure
    }
}
