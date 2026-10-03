import Darwin
import Foundation
@preconcurrency import ServiceManagement

public enum ManagedInstallerPrivilegedHelperContract {
    public static let label = ManagedInstallerPostToolXPCHelperIdentity.signingIdentifier
    public static let plistName = label + ".plist"
    public static let bundleProgram = "Contents/Resources/forge-platform-installer-helper"
    public static let machServices = [
        MacOSManagedInstallerPostToolXPCTransport.machServiceName,
        MacOSManagedInstallerProductOperationXPCTransport.machServiceName,
        MacOSManagedInstallerReleasedRouteXPCTransport.machServiceName,
    ].sorted()
}

public enum ManagedInstallerPrivilegedHelperStatus: String, Equatable, Sendable {
    case enabled = "ENABLED"
    case requiresApproval = "REQUIRES_APPROVAL"
    case notRegistered = "NOT_REGISTERED"
    case notFound = "NOT_FOUND"
}

public enum ManagedInstallerPrivilegedHelperRegistrationFailure:
    Error, Equatable, Sendable {
    case registrationFailed
    case serviceUnavailable
    case statusDrift
    case registeredParentMismatch
    case unregistrationFailed
    case transitionBusy
}

public struct ManagedInstallerPrivilegedHelperRegistrationReceipt:
    Equatable, Sendable {
    public let label: String
    public let plistName: String
    public let bundleProgram: String
    public let machServices: [String]
    public let status: ManagedInstallerPrivilegedHelperStatus

    public init(status: ManagedInstallerPrivilegedHelperStatus) throws {
        guard status == .enabled || status == .requiresApproval else {
            throw ManagedInstallerPrivilegedHelperRegistrationFailure.statusDrift
        }
        label = ManagedInstallerPrivilegedHelperContract.label
        plistName = ManagedInstallerPrivilegedHelperContract.plistName
        bundleProgram = ManagedInstallerPrivilegedHelperContract.bundleProgram
        machServices = ManagedInstallerPrivilegedHelperContract.machServices
        self.status = status
    }
}

public enum ManagedInstallerPrivilegedHelperRegistrationResult:
    Equatable, Sendable {
    case ready(ManagedInstallerPrivilegedHelperRegistrationReceipt)
    case requiresApproval(ManagedInstallerPrivilegedHelperRegistrationReceipt)
    case failed(ManagedInstallerPrivilegedHelperRegistrationFailure)
}

public protocol ManagedInstallerPrivilegedHelperServiceControlling: Sendable {
    func readStatus() -> ManagedInstallerPrivilegedHelperStatus
    func readRegisteredParentVersion() -> InstallerVersion?
    func readIdleRegisteredParentVersion() -> InstallerVersion?
    func readSystemJobAbsent() -> Bool
    func register() throws
    func unregister() throws
}

/// Thin ServiceManagement adapter. The daemon plist name is fixed by the
/// signed bundle contract and cannot be supplied by a wizard, CLI flag or
/// environment variable.
public final class MacOSManagedInstallerPrivilegedHelperServiceController:
    ManagedInstallerPrivilegedHelperServiceControlling, @unchecked Sendable {
    private let statusReader: @Sendable () -> SMAppService.Status
    private let registrar: @Sendable () throws -> Void
    private let unregistrar: @Sendable () throws -> Void
    private let parentVersionReader: @Sendable () -> InstallerVersion?
    private let idleParentVersionReader: @Sendable () -> InstallerVersion?
    private let jobAbsenceReader: @Sendable () -> Bool

    public init() {
        let service = SMAppService.daemon(
            plistName: ManagedInstallerPrivilegedHelperContract.plistName
        )
        statusReader = { service.status }
        registrar = { try service.register() }
        unregistrar = { try service.unregister() }
        parentVersionReader = { RegisteredInstallerHelperParentReader().readVersion() }
        idleParentVersionReader = { RegisteredInstallerHelperParentReader().readIdleVersion() }
        jobAbsenceReader = { RegisteredInstallerHelperParentReader().readAbsent() }
    }

    init(
        statusReader: @escaping @Sendable () -> SMAppService.Status,
        registrar: @escaping @Sendable () throws -> Void,
        parentVersionReader: @escaping @Sendable () -> InstallerVersion? = { nil },
        idleParentVersionReader: @escaping @Sendable () -> InstallerVersion? = { nil },
        jobAbsenceReader: @escaping @Sendable () -> Bool = { false },
        unregistrar: @escaping @Sendable () throws -> Void = {}
    ) {
        self.statusReader = statusReader
        self.registrar = registrar
        self.unregistrar = unregistrar
        self.parentVersionReader = parentVersionReader
        self.idleParentVersionReader = idleParentVersionReader
        self.jobAbsenceReader = jobAbsenceReader
    }

    public func readStatus() -> ManagedInstallerPrivilegedHelperStatus {
        switch statusReader() {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    public func register() throws {
        try registrar()
    }

    public func readRegisteredParentVersion() -> InstallerVersion? {
        parentVersionReader()
    }

    public func readIdleRegisteredParentVersion() -> InstallerVersion? {
        idleParentVersionReader()
    }

    public func readSystemJobAbsent() -> Bool {
        jobAbsenceReader()
    }

    public func unregister() throws {
        try unregistrar()
    }
}

/// Inspects only the fixed system job. The parent identity is an independent
/// ServiceManagement readback, never a version supplied by the CLI caller.
struct RegisteredInstallerHelperParentReader: Sendable {
    func readVersion() -> InstallerVersion? {
        guard let observation = readObservation(), observation.status == 0 else { return nil }
        return Self.parse(observation.output)
    }

    func readIdleVersion() -> InstallerVersion? {
        guard let observation = readObservation(), observation.status == 0 else { return nil }
        return Self.parseIdle(observation.output)
    }

    func readAbsent() -> Bool {
        guard let observation = readObservation() else { return false }
        return Self.isAbsent(status: observation.status, output: observation.output)
    }

    private func readObservation() -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/" + ManagedInstallerPrivilegedHelperContract.label]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collector = BoundedProcessOutputCollector(maximumBytes: 64 * 1024)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { drained.leave() }
            collector.consume(pipe.fileHandleForReading)
        }
        guard finished.wait(timeout: .now() + .seconds(5)) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + .seconds(2)) != .success {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + .seconds(2))
            }
            return nil
        }
        guard drained.wait(timeout: .now() + .seconds(2)) == .success,
              process.terminationReason == .exit,
              let data = collector.collectedData(),
              let output = String(data: data, encoding: .utf8) else { return nil }
        return (process.terminationStatus, output)
    }

    static func isAbsent(status: Int32, output: String) -> Bool {
        guard status == 113 else { return false }
        return output.trimmingCharacters(in: .whitespacesAndNewlines) ==
            "Bad request.\nCould not find service \"\(ManagedInstallerPrivilegedHelperContract.label)\" in domain for system"
    }

    static func parseIdle(_ output: String) -> InstallerVersion? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.filter({ $0 == "state = not running" }).count == 1,
              lines.filter({ $0 == "runs = 0" }).count == 1 else { return nil }
        return parse(output)
    }

    static func parse(_ output: String) -> InstallerVersion? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func uniqueValue(_ key: String) -> String? {
            let matches = lines.compactMap { line -> String? in
                let prefix = key + " = "
                return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
            }
            return matches.count == 1 ? matches[0] : nil
        }
        guard lines.first == "system/\(ManagedInstallerPrivilegedHelperContract.label) = {",
              uniqueValue("managed_by") == "com.apple.xpc.ServiceManagement",
              lines.filter({ $0 == "\"team-identifier\" => \"\(ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier)\"" }).count == 1,
              lines.filter({ $0 == "\"signing-identifier\" => \"\(ManagedInstallerPrivilegedHelperContract.label)\"" }).count == 1,
              uniqueValue("parent bundle identifier") ==
                ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
              uniqueValue("program identifier") ==
                ManagedInstallerPrivilegedHelperContract.bundleProgram + " (mode: 2)",
              let raw = uniqueValue("parent bundle version") else { return nil }
        return try? InstallerVersion(raw)
    }
}

/// Rechecks the one fixed ServiceManagement parent immediately before a
/// client request can resume or use its privileged Mach connection. The
/// expected version comes from sealed release provenance, never the request.
struct ManagedInstallerHelperXPCParentAdmission: Sendable {
    let expectedVersion: InstallerVersion?
    let readVersion: @Sendable () -> InstallerVersion?

    static func production(expectedVersion: InstallerVersion?) -> Self {
        Self(expectedVersion: expectedVersion,
             readVersion: { RegisteredInstallerHelperParentReader().readVersion() })
    }

    func admits() -> Bool {
        guard let expectedVersion else { return false }
        return readVersion() == expectedVersion
    }
}

/// Registers the bundled system daemon once and immediately reads its state
/// back from ServiceManagement. A successful API call is never treated as
/// readiness by itself: only an exact `.enabled` readback grants the helper
/// route. User approval remains an explicit non-ready state.
public actor ManagedInstallerPrivilegedHelperRegistrationCoordinator {
    private let service: any ManagedInstallerPrivilegedHelperServiceControlling
    private let operationLock: (any InstallerSelfUpdateOperationLocking)?

    public init(
        service: any ManagedInstallerPrivilegedHelperServiceControlling,
        operationLock: (any InstallerSelfUpdateOperationLocking)? = nil
    ) {
        self.service = service
        self.operationLock = operationLock
    }

    public static func production(
        service: any ManagedInstallerPrivilegedHelperServiceControlling
    ) -> ManagedInstallerPrivilegedHelperRegistrationCoordinator? {
        guard let root = try? MacOSInstallerUserStateRoot.prepare() else { return nil }
        return Self(service: service,
                    operationLock: FileInstallerSelfUpdateOperationLock(rootDirectory: root))
    }

    public func ensureRegistered(
        expectedVersion: InstallerVersion
    ) -> ManagedInstallerPrivilegedHelperRegistrationResult {
        withRegistrationLock {
            ensureRegisteredWhileLocked(expectedVersion: expectedVersion)
        }
    }

    private func ensureRegisteredWhileLocked(
        expectedVersion: InstallerVersion
    ) -> ManagedInstallerPrivilegedHelperRegistrationResult {
        switch service.readStatus() {
        case .enabled:
            return verifiedReady(expectedVersion: expectedVersion)
        case .requiresApproval:
            return receipt(for: .requiresApproval)
        case .notRegistered, .notFound:
            // On a fresh Mac ServiceManagement can report notFound before it
            // has ever seen the bundled daemon. Registration is the only
            // native way to distinguish that state from a missing service.
            let registrationFailed: Bool
            do {
                try service.register()
                registrationFailed = false
            } catch {
                // macOS may return operation-not-permitted while awaiting the
                // administrator's approval. The fresh native status decides.
                registrationFailed = true
            }
            switch service.readStatus() {
            case .enabled:
                return verifiedReady(expectedVersion: expectedVersion)
            case .requiresApproval:
                return receipt(for: .requiresApproval)
            case .notRegistered:
                return .failed(registrationFailed ? .registrationFailed : .statusDrift)
            case .notFound:
                return .failed(.serviceUnavailable)
            }
        }
    }

    /// One-time transition from the known idle 0.2.4 qualification daemon.
    /// A crash after unregister leaves a visible NOT_REGISTERED state; the
    /// ordinary fixed-label `register` route can safely finish from there.
    public func replaceLegacyQualification(
        expectedVersion: InstallerVersion
    ) -> ManagedInstallerPrivilegedHelperRegistrationResult {
        withRegistrationLock {
            guard let legacy = try? InstallerVersion("0.2.4") else {
                return .failed(.registeredParentMismatch)
            }
            return replaceIdleParentWhileLocked(
                expectedVersion: expectedVersion,
                minimumPriorVersion: legacy,
                maximumPriorVersion: legacy
            )
        }
    }

    /// Upgrade a previously released, signed installer helper only while its
    /// fixed ServiceManagement job has never run since boot. The sealed CLI
    /// supplies the target version; no request can choose a label or parent.
    public func replaceIdleOlderRegistration(
        expectedVersion: InstallerVersion
    ) -> ManagedInstallerPrivilegedHelperRegistrationResult {
        withRegistrationLock {
            guard let firstSupported = try? InstallerVersion("0.3.7") else {
                return .failed(.registeredParentMismatch)
            }
            return replaceIdleParentWhileLocked(
                expectedVersion: expectedVersion,
                minimumPriorVersion: firstSupported,
                maximumPriorVersion: nil
            )
        }
    }

    /// One bounded, owner-authorized clean-install recovery from the released
    /// 0.3.14 parent. The caller separately proves that this disposable host
    /// has no product or in-flight operation before using this command.
    /// ServiceManagement terminates a running daemon when unregister succeeds.
    /// A failed subsequent registration leaves the ordinary register route as
    /// recovery after independent fixed-job absence readback.
    public func replaceMVP0314ForCleanInstall(
        expectedVersion: InstallerVersion
    ) -> ManagedInstallerPrivilegedHelperRegistrationResult {
        withRegistrationLock {
            guard let target = try? InstallerVersion("0.3.16"),
                  let prior = try? InstallerVersion("0.3.14"),
                  expectedVersion == target else {
                return .failed(.registeredParentMismatch)
            }
            return replaceBoundedRunningParentWhileLocked(
                expectedVersion: expectedVersion, priorVersion: prior
            )
        }
    }

    /// One owner-authorized clean-install transition from the exact running
    /// 0.3.16 parent to the next signed MVP release. The caller proves empty
    /// product/operation state and sealed source/target bytes before invoking
    /// this command. No caller can select a different prior version or label.
    public func replaceMVP0316ForCleanInstall(
        expectedVersion: InstallerVersion
    ) -> ManagedInstallerPrivilegedHelperRegistrationResult {
        withRegistrationLock {
            guard let target = try? InstallerVersion("0.3.18"),
                  let prior = try? InstallerVersion("0.3.16"),
                  expectedVersion == target else {
                return .failed(.registeredParentMismatch)
            }
            return replaceBoundedRunningParentWhileLocked(
                expectedVersion: expectedVersion, priorVersion: prior
            )
        }
    }

    private func replaceBoundedRunningParentWhileLocked(
        expectedVersion: InstallerVersion,
        priorVersion: InstallerVersion
    ) -> ManagedInstallerPrivilegedHelperRegistrationResult {
        guard service.readStatus() == .enabled,
              service.readRegisteredParentVersion() == priorVersion,
              service.readStatus() == .enabled,
              service.readRegisteredParentVersion() == priorVersion else {
            return .failed(.registeredParentMismatch)
        }
        do {
            try service.unregister()
        } catch {
            return .failed(.unregistrationFailed)
        }
        guard service.readSystemJobAbsent() else {
            return .failed(.statusDrift)
        }
        switch service.readStatus() {
        case .notRegistered, .notFound:
            return ensureRegisteredWhileLocked(expectedVersion: expectedVersion)
        case .enabled, .requiresApproval:
            return .failed(.statusDrift)
        }
    }

    private func replaceIdleParentWhileLocked(
        expectedVersion: InstallerVersion,
        minimumPriorVersion: InstallerVersion,
        maximumPriorVersion: InstallerVersion?
    ) -> ManagedInstallerPrivilegedHelperRegistrationResult {
        let initialStatus = service.readStatus()
        guard let prior = service.readIdleRegisteredParentVersion(),
              prior >= minimumPriorVersion,
              maximumPriorVersion.map({ prior <= $0 }) ?? true,
              prior < expectedVersion,
              initialStatus != .requiresApproval,
              service.readRegisteredParentVersion() == prior,
              service.readIdleRegisteredParentVersion() == prior,
              service.readStatus() == initialStatus,
              service.readRegisteredParentVersion() == prior,
              service.readIdleRegisteredParentVersion() == prior else {
            return .failed(.registeredParentMismatch)
        }
        do {
            try service.unregister()
        } catch {
            return .failed(.unregistrationFailed)
        }
        guard service.readSystemJobAbsent() else {
            return .failed(.statusDrift)
        }
        switch service.readStatus() {
        case .notRegistered, .notFound:
            return ensureRegisteredWhileLocked(expectedVersion: expectedVersion)
        case .enabled, .requiresApproval:
            return .failed(.statusDrift)
        }
    }

    private func withRegistrationLock(
        _ operation: () -> ManagedInstallerPrivilegedHelperRegistrationResult
    ) -> ManagedInstallerPrivilegedHelperRegistrationResult {
        guard let operationLock else { return operation() }
        guard case .success(let lease) = operationLock
            .acquireExclusiveSelfUpdateOperationLock() else {
            return .failed(.transitionBusy)
        }
        let result = operation()
        guard case .success = lease.releaseExclusiveSelfUpdateOperationLock() else {
            return .failed(.transitionBusy)
        }
        return result
    }

    private func verifiedReady(
        expectedVersion: InstallerVersion
    ) -> ManagedInstallerPrivilegedHelperRegistrationResult {
        guard service.readRegisteredParentVersion() == expectedVersion,
              service.readStatus() == .enabled,
              service.readRegisteredParentVersion() == expectedVersion else {
            return .failed(.registeredParentMismatch)
        }
        return receipt(for: .enabled)
    }

    private func receipt(
        for status: ManagedInstallerPrivilegedHelperStatus
    ) -> ManagedInstallerPrivilegedHelperRegistrationResult {
        guard let value = try? ManagedInstallerPrivilegedHelperRegistrationReceipt(
            status: status
        ) else {
            return .failed(.statusDrift)
        }
        return status == .enabled ? .ready(value) : .requiresApproval(value)
    }
}
