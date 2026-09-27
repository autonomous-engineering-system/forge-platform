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
    func register() throws
}

/// Thin ServiceManagement adapter. The daemon plist name is fixed by the
/// signed bundle contract and cannot be supplied by a wizard, CLI flag or
/// environment variable.
public final class MacOSManagedInstallerPrivilegedHelperServiceController:
    ManagedInstallerPrivilegedHelperServiceControlling, @unchecked Sendable {
    private let statusReader: @Sendable () -> SMAppService.Status
    private let registrar: @Sendable () throws -> Void

    public init() {
        let service = SMAppService.daemon(
            plistName: ManagedInstallerPrivilegedHelperContract.plistName
        )
        statusReader = { service.status }
        registrar = { try service.register() }
    }

    init(
        statusReader: @escaping @Sendable () -> SMAppService.Status,
        registrar: @escaping @Sendable () throws -> Void
    ) {
        self.statusReader = statusReader
        self.registrar = registrar
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

    public func ensureRegistered() -> ManagedInstallerPrivilegedHelperRegistrationResult {
        switch service.readStatus() {
        case .enabled:
            return receipt(for: .enabled)
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
                return receipt(for: .enabled)
            case .requiresApproval:
                return receipt(for: .requiresApproval)
            case .notRegistered:
                return .failed(registrationFailed ? .registrationFailed : .statusDrift)
            case .notFound:
                return .failed(.serviceUnavailable)
            }
        }
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
