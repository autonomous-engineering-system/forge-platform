import XCTest
import ServiceManagement
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPrivilegedHelperRegistrationTests: XCTestCase {
    func testEnabledServiceReturnsExactReadyReceiptWithoutRegistration() async throws {
        let service = HelperServiceController(statuses: [.enabled])
        let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: service
        ).ensureRegistered()
        let receipt = try XCTUnwrap(result.readyReceipt)

        XCTAssertEqual(receipt.label, ManagedInstallerPostToolXPCHelperIdentity.signingIdentifier)
        XCTAssertEqual(receipt.plistName, receipt.label + ".plist")
        XCTAssertEqual(
            receipt.bundleProgram,
            "Contents/Resources/forge-platform-installer-helper"
        )
        XCTAssertEqual(receipt.machServices, [
            MacOSManagedInstallerPostToolXPCTransport.machServiceName,
            MacOSManagedInstallerProductOperationXPCTransport.machServiceName,
            MacOSManagedInstallerReleasedRouteXPCTransport.machServiceName,
        ].sorted())
        XCTAssertEqual(service.registerCount(), 0)
    }

    func testNotRegisteredServiceMustRegisterAndReadBackEnabled() async {
        for initial in [
            ManagedInstallerPrivilegedHelperStatus.notRegistered,
            .notFound,
        ] {
            let service = HelperServiceController(statuses: [initial, .enabled])
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).ensureRegistered()

            XCTAssertNotNil(result.readyReceipt)
            XCTAssertEqual(service.registerCount(), 1)
            XCTAssertEqual(service.statusReadCount(), 2)
        }
    }

    func testApprovalIsExplicitlyNonReadyBeforeOrAfterRegistration() async throws {
        for statuses in [
            [ManagedInstallerPrivilegedHelperStatus.requiresApproval],
            [.notRegistered, .requiresApproval],
            [.notFound, .requiresApproval],
        ] {
            let service = HelperServiceController(statuses: statuses)
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).ensureRegistered()
            let receipt = try XCTUnwrap(result.approvalReceipt)
            XCTAssertEqual(receipt.status, .requiresApproval)
            XCTAssertEqual(service.registerCount(), statuses.count == 1 ? 0 : 1)
        }
    }

    func testRegistrationErrorStillReadsNativeApprovalStatus() async throws {
        let service = HelperServiceController(
            statuses: [.notFound, .requiresApproval],
            registrationFails: true
        )
        let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: service
        ).ensureRegistered()

        XCTAssertEqual(try XCTUnwrap(result.approvalReceipt).status, .requiresApproval)
        XCTAssertEqual(service.registerCount(), 1)
        XCTAssertEqual(service.statusReadCount(), 2)
    }

    func testMissingFailedAndDriftedRegistrationFailClosed() async {
        let cases: [(HelperServiceController, ManagedInstallerPrivilegedHelperRegistrationFailure)] = [
            (HelperServiceController(statuses: [.notFound, .notFound]), .serviceUnavailable),
            (HelperServiceController(statuses: [.notRegistered], registrationFails: true),
             .registrationFailed),
            (HelperServiceController(statuses: [.notRegistered, .notRegistered]), .statusDrift),
            (HelperServiceController(statuses: [.notRegistered, .notFound]), .serviceUnavailable),
        ]
        for (service, expected) in cases {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).ensureRegistered()
            XCTAssertEqual(result.failure, expected)
        }
    }

    func testReceiptRejectsNonTerminalStatusesAndNativeControllerConstructs() throws {
        for status in [
            ManagedInstallerPrivilegedHelperStatus.notFound,
            .notRegistered,
        ] {
            XCTAssertThrowsError(try ManagedInstallerPrivilegedHelperRegistrationReceipt(
                status: status
            ))
        }
        _ = MacOSManagedInstallerPrivilegedHelperServiceController()
    }

    func testNativeControllerMapsEveryServiceManagementStateAndForwardsRegister() throws {
        let registered = LockedCounter()
        for (native, expected) in [
            (SMAppService.Status.enabled, ManagedInstallerPrivilegedHelperStatus.enabled),
            (.requiresApproval, .requiresApproval),
            (.notRegistered, .notRegistered),
            (.notFound, .notFound),
        ] {
            let controller = MacOSManagedInstallerPrivilegedHelperServiceController(
                statusReader: { native },
                registrar: { registered.increment() }
            )
            XCTAssertEqual(controller.readStatus(), expected)
            try controller.register()
        }
        XCTAssertEqual(registered.value(), 4)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func value() -> Int { lock.withLock { count } }
}

private final class HelperServiceController:
    ManagedInstallerPrivilegedHelperServiceControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [ManagedInstallerPrivilegedHelperStatus]
    private let registrationFails: Bool
    private var registrations = 0
    private var statusReads = 0

    init(
        statuses: [ManagedInstallerPrivilegedHelperStatus],
        registrationFails: Bool = false
    ) {
        self.statuses = statuses
        self.registrationFails = registrationFails
    }

    func readStatus() -> ManagedInstallerPrivilegedHelperStatus {
        lock.withLock {
            statusReads += 1
            if statuses.count > 1 { return statuses.removeFirst() }
            return statuses.first ?? .notFound
        }
    }

    func register() throws {
        try lock.withLock {
            registrations += 1
            if registrationFails {
                throw ManagedInstallerPrivilegedHelperRegistrationFailure.registrationFailed
            }
        }
    }

    func registerCount() -> Int { lock.withLock { registrations } }
    func statusReadCount() -> Int { lock.withLock { statusReads } }
}

private extension ManagedInstallerPrivilegedHelperRegistrationResult {
    var readyReceipt: ManagedInstallerPrivilegedHelperRegistrationReceipt? {
        guard case .ready(let receipt) = self else { return nil }
        return receipt
    }
    var approvalReceipt: ManagedInstallerPrivilegedHelperRegistrationReceipt? {
        guard case .requiresApproval(let receipt) = self else { return nil }
        return receipt
    }
    var failure: ManagedInstallerPrivilegedHelperRegistrationFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}
