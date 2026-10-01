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
    func register() throws
}

/// Thin ServiceManagement adapter. The daemon plist name is fixed by the
/// signed bundle contract and cannot be supplied by a wizard, CLI flag or
/// environment variable.
public final class MacOSManagedInstallerPrivilegedHelperServiceController:
    ManagedInstallerPrivilegedHelperServiceControlling, @unchecked Sendable {
    private let statusReader: @Sendable () -> SMAppService.Status
    private let registrar: @Sendable () throws -> Void
    private let parentVersionReader: @Sendable () -> InstallerVersion?

    public init() {
        let service = SMAppService.daemon(
            plistName: ManagedInstallerPrivilegedHelperContract.plistName
        )
        statusReader = { service.status }
        registrar = { try service.register() }
        parentVersionReader = { RegisteredInstallerHelperParentReader().readVersion() }
    }

    init(
        statusReader: @escaping @Sendable () -> SMAppService.Status,
        registrar: @escaping @Sendable () throws -> Void,
        parentVersionReader: @escaping @Sendable () -> InstallerVersion? = { nil }
    ) {
        self.statusReader = statusReader
        self.registrar = registrar
        self.parentVersionReader = parentVersionReader
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
}

/// Inspects only the fixed system job. The parent identity is an independent
/// ServiceManagement readback, never a version supplied by the CLI caller.
struct RegisteredInstallerHelperParentReader: Sendable {
    func readVersion() -> InstallerVersion? {
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
              process.terminationStatus == 0,
              let data = collector.collectedData(),
              let output = String(data: data, encoding: .utf8) else { return nil }
        return Self.parse(output)
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
              lines.filter({ $0 == "\"team-identifier\" => \"ZEML4LPXH4\"" }).count == 1,
              lines.filter({ $0 == "\"signing-identifier\" => \"\(ManagedInstallerPrivilegedHelperContract.label)\"" }).count == 1,
              uniqueValue("parent bundle identifier") ==
                ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
              uniqueValue("program identifier") ==
                ManagedInstallerPrivilegedHelperContract.bundleProgram + " (mode: 2)",
              let raw = uniqueValue("parent bundle version") else { return nil }
        return try? InstallerVersion(raw)
    }
}

/// Registers the bundled system daemon once and immediately reads its state
/// back from ServiceManagement. A successful API call is never treated as
/// readiness by itself: only an exact `.enabled` readback grants the helper
/// route. User approval remains an explicit non-ready state.
public actor ManagedInstallerPrivilegedHelperRegistrationCoordinator {
    private let service: any ManagedInstallerPrivilegedHelperServiceControlling

    public init(service: any ManagedInstallerPrivilegedHelperServiceControlling) {
        self.service = service
    }

    public func ensureRegistered(
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
