import XCTest
@testable import ForgePlatformInstallerPrivilegedHelper

final class ForgePlatformInstallerPrivilegedHelperMainTests: XCTestCase {
    func testProcessContractAndProductionRuntimeAreFixed() throws {
        XCTAssertEqual(
            ManagedInstallerPrivilegedHelperProcessContract.installerBundleIdentifier,
            "com.autonomous-engineering-system.forge-platform-installer"
        )
        XCTAssertEqual(
            ManagedInstallerPrivilegedHelperProcessContract.appleTeamIdentifier,
            "ZEML4LPXH4"
        )
        XCTAssertNoThrow(try MacOSManagedInstallerPrivilegedHelperRuntime(
            prepareStateRoot: {}
        ))
    }

    func testProductionRuntimeFailsClosedWhenPrivateStateRootIsUnavailable() {
        XCTAssertThrowsError(try MacOSManagedInstallerPrivilegedHelperRuntime(
            prepareStateRoot: {
                throw ManagedInstallerPrivilegedHelperBootstrapError.backendUnavailable
            }
        ))
    }

    func testInjectedRuntimeActivatesParksAndInvalidatesInOrder() {
        let events = LockedHelperEvents()
        let runtime = MacOSManagedInstallerPrivilegedHelperRuntime(
            activateListeners: [
                { events.append("activate-one") },
                { events.append("activate-two") },
            ],
            invalidateListeners: [
                { events.append("invalidate-one") },
                { events.append("invalidate-two") },
            ]
        )

        let status = ForgePlatformInstallerPrivilegedHelperMain.run(
            arguments: ["forge-platform-installer-helper"],
            makeRuntime: { runtime },
            park: { events.append("park") }
        )

        XCTAssertEqual(
            events.values,
            [
                "activate-one", "activate-two", "park",
                "invalidate-two", "invalidate-one",
            ]
        )
        XCTAssertEqual(
            status,
            ForgePlatformInstallerPrivilegedHelperMain.unexpectedRunLoopReturnFailure
        )
    }

    func testInvalidInvocationAndRuntimeFailureStayClosed() {
        var factoryCalled = false
        let usage = ForgePlatformInstallerPrivilegedHelperMain.run(
            arguments: ["helper", "caller-input-is-forbidden"],
            makeRuntime: {
                factoryCalled = true
                return FakePrivilegedHelperRuntime()
            },
            park: {}
        )
        XCTAssertEqual(usage, ForgePlatformInstallerPrivilegedHelperMain.usageFailure)
        XCTAssertFalse(factoryCalled)

        let unavailable = ForgePlatformInstallerPrivilegedHelperMain.run(
            arguments: ["helper"],
            makeRuntime: {
                throw ManagedInstallerPrivilegedHelperBootstrapError.backendUnavailable
            },
            park: { XCTFail("failed bootstrap must not enter its run loop") }
        )
        XCTAssertEqual(
            unavailable,
            ForgePlatformInstallerPrivilegedHelperMain.unavailableFailure
        )
    }

    func testUnconfiguredBackendReturnsNoAuthorityOnEveryService() {
        let backend = UnavailableManagedInstallerPrivilegedHelperBackend()
        let request = Data("caller bytes are never authority".utf8)
        var responses: [Data?] = []

        backend.capturePostToolObservation(request) { responses.append($0) }
        backend.loadManagedDeploymentInventory { responses.append($0) }
        backend.loadReleasedRouteSnapshot(request) { responses.append($0) }

        XCTAssertEqual(responses.count, 3)
        XCTAssertTrue(responses.allSatisfy { $0 == nil })
    }

    func testComposedPostToolBackendRejectsMalformedRequestBeforeHostRead() async {
        let service = MacOSManagedInstallerPrivilegedHelperRuntime.makePostToolService(
            rootDirectory: URL(
                fileURLWithPath: "/private/tmp/nonexistent-forge-platform-helper-state",
                isDirectory: true
            )
        )
        let response: Data? = await withCheckedContinuation { continuation in
            service.capturePostToolObservation(Data("{}".utf8)) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertNil(response)
    }
}

private final class FakePrivilegedHelperRuntime:
    ManagedInstallerPrivilegedHelperRuntimeRunning {
    func activate() {}
    func invalidate() {}
}

private final class LockedHelperEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
