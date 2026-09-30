import Darwin
import XCTest
@testable import ForgePlatformInstallerPrivilegedHelper

final class ForgePlatformInstallerPrivilegedHelperMainTests: XCTestCase {
    func testAccountProbeChildAcceptsOnlyFixedProviderAndSameOwnedHome() throws {
        let root = URL(fileURLWithPath: "/private/tmp/probe-root", isDirectory: true)
        let provider = root.appendingPathComponent(
            "products/engineering-platform/instances/fpi-one/providers/github",
            isDirectory: true
        )
        let arguments = [
            "forge-platform-installer-helper",
            ManagedInstallerProviderAccountProbeChild.flag,
            "_fpi_" + String(repeating: "a", count: 20), "501", "20",
            "github-cli", "authentication-status",
            provider.appendingPathComponent("runtime/bin/gh").path,
            provider.appendingPathComponent("config").path,
        ]
        let request = try XCTUnwrap(ManagedInstallerProviderAccountProbeChild.parse(
            arguments, allowedRoot: root
        ))
        XCTAssertEqual(request.arguments,
                       ["auth", "status", "--hostname", "github.com"])
        XCTAssertEqual(request.environment["GH_CONFIG_DIR"], arguments[8])
        XCTAssertEqual(request.environment["HOME"], arguments[8])

        let forge = root.appendingPathComponent(
            "provider-contexts/deployments/deployment-one/providers/forge-runtime/"
                + "fpi-two/github-cli", isDirectory: true
        )
        var versioned = arguments
        versioned[6] = "version"
        versioned[7] = forge.appendingPathComponent("runtime/2.70.0/bin/gh").path
        versioned[8] = forge.appendingPathComponent("home").path
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.parse(
            versioned, allowedRoot: root
        )?.arguments, ["--version"])

        for (index, value) in [
            (2, "_fpi_foreign"), (3, "0"), (4, "020"),
            (5, "shell"), (6, "login"),
            (7, "/private/tmp/other/runtime/bin/gh"),
            (8, root.appendingPathComponent("other/config").path),
        ] {
            var invalid = arguments
            invalid[index] = value
            XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(
                invalid, allowedRoot: root
            ), "field \(index)")
        }
        var traversal = arguments
        traversal[7] = provider.appendingPathComponent("../runtime/bin/gh").path
        XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(
            traversal, allowedRoot: root
        ))

        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(
            arguments, allowedRoot: root, effectiveUID: { 0 },
            verifyAccount: { $0 == request }, dropPrivileges: { $0 == request },
            launch: { $0 == request ? 0 : 78 }
        ), 0)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(
            arguments, allowedRoot: root, effectiveUID: { 501 },
            verifyAccount: { _ in XCTFail("no OS read after failed UID"); return true },
            dropPrivileges: { _ in true }, launch: { _ in 0 }
        ), 78)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(
            arguments, allowedRoot: root, effectiveUID: { 0 },
            verifyAccount: { _ in false },
            dropPrivileges: { _ in XCTFail("no drop after failed account"); return true },
            launch: { _ in 0 }
        ), 78)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(
            arguments, allowedRoot: root, effectiveUID: { 0 },
            verifyAccount: { _ in true }, dropPrivileges: { _ in false },
            launch: { _ in XCTFail("no launch after failed drop"); return 0 }
        ), 78)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(arguments), 78)

        let currentName = try XCTUnwrap(Darwin.getpwuid(Darwin.getuid())?.pointee.pw_name)
        let currentAccount = ManagedInstallerProviderAccountProbeChild.Request(
            accountName: String(cString: currentName), uid: Darwin.getuid(),
            gid: Darwin.getgid(), provider: "github-cli", probe: "version",
            executable: "/usr/bin/true", home: "/private/tmp"
        )
        XCTAssertFalse(ManagedInstallerProviderAccountProbeChild.matchingLocalAccount(
            currentAccount
        ))
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(currentAccount), 0)
    }

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
        backend.loadManagedDeploymentRegistryRecord("deployment-one") {
            responses.append($0)
        }
        backend.loadReleasedRouteSnapshot(request) { responses.append($0) }
        backend.registerReviewedSelection(request) { responses.append($0) }
        backend.executeReviewedIntent(request) { responses.append($0) }
        backend.stageReviewedProviders(request) { responses.append($0) }
        backend.readReviewedProviders(request) { responses.append($0) }

        XCTAssertEqual(responses.count, 8)
        XCTAssertTrue(responses.allSatisfy { $0 == nil })
    }

    func testExternalPostToolBackendDeniesHostObservation() async {
        let service = UnavailableManagedInstallerPrivilegedHelperBackend()
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
