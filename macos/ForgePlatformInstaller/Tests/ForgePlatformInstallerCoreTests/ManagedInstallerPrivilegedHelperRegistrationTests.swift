import XCTest
import ServiceManagement
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPrivilegedHelperRegistrationTests: XCTestCase {
    func testXPCParentAdmissionRequiresExactFreshRegisteredVersion() throws {
        let expected = try InstallerVersion("0.3.6")
        let legacy = try InstallerVersion("0.2.4")
        XCTAssertFalse(ManagedInstallerHelperXPCParentAdmission(
            expectedVersion: nil, readVersion: { expected }
        ).admits())
        XCTAssertFalse(ManagedInstallerHelperXPCParentAdmission(
            expectedVersion: expected, readVersion: { nil }
        ).admits())
        XCTAssertFalse(ManagedInstallerHelperXPCParentAdmission(
            expectedVersion: expected, readVersion: { legacy }
        ).admits())
        XCTAssertTrue(ManagedInstallerHelperXPCParentAdmission(
            expectedVersion: expected, readVersion: { expected }
        ).admits())
    }

    func testEnabledServiceReturnsExactReadyReceiptWithoutRegistration() async throws {
        let service = HelperServiceController(statuses: [.enabled])
        let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: service
        ).ensureRegistered(expectedVersion: try! InstallerVersion("0.3.5"))
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
            ).ensureRegistered(expectedVersion: try! InstallerVersion("0.3.5"))

            XCTAssertNotNil(result.readyReceipt)
            XCTAssertEqual(service.registerCount(), 1)
            XCTAssertEqual(service.statusReadCount(), 3)
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
            ).ensureRegistered(expectedVersion: try! InstallerVersion("0.3.5"))
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
        ).ensureRegistered(expectedVersion: try! InstallerVersion("0.3.5"))

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
            ).ensureRegistered(expectedVersion: try! InstallerVersion("0.3.5"))
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
                registrar: { registered.increment() },
                parentVersionReader: { try? InstallerVersion("0.3.5") },
                idleParentVersionReader: { try? InstallerVersion("0.2.4") },
                jobAbsenceReader: { false },
                unregistrar: { registered.increment() }
            )
            XCTAssertEqual(controller.readStatus(), expected)
            XCTAssertEqual(controller.readRegisteredParentVersion(), try InstallerVersion("0.3.5"))
            XCTAssertEqual(controller.readIdleRegisteredParentVersion(), try InstallerVersion("0.2.4"))
            XCTAssertFalse(controller.readSystemJobAbsent())
            try controller.register()
            try controller.unregister()
        }
        XCTAssertEqual(registered.value(), 8)
    }

    func testEnabledOldOrUnreadableParentFailsClosed() async throws {
        for parent in [try InstallerVersion("0.2.4"), nil] {
            let service = HelperServiceController(statuses: [.enabled], parentVersion: parent)
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).ensureRegistered(expectedVersion: try InstallerVersion("0.3.5"))
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.registerCount(), 0)
        }
    }

    func testFixedSystemJobParserRejectsWrongAndAmbiguousParent() throws {
        let label = ManagedInstallerPrivilegedHelperContract.label
        let valid = """
        system/\(label) = {
            managed_by = com.apple.xpc.ServiceManagement
            "signing-identifier" => "\(label)"
            "team-identifier" => "ZEML4LPXH4"
            program identifier = Contents/Resources/forge-platform-installer-helper (mode: 2)
            parent bundle identifier = com.autonomous-engineering-system.forge-platform-installer
            parent bundle version = 0.3.5
        }
        """
        XCTAssertEqual(RegisteredInstallerHelperParentReader.parse(valid),
                       try InstallerVersion("0.3.5"))
        XCTAssertEqual(RegisteredInstallerHelperParentReader.parseIdle(
            valid + "\nstate = not running\nruns = 0\n"
        ), try InstallerVersion("0.3.5"))
        XCTAssertNil(RegisteredInstallerHelperParentReader.parseIdle(valid))
        XCTAssertNil(RegisteredInstallerHelperParentReader.parseIdle(
            valid + "\nstate = running\nruns = 1\n"
        ))
        let absentOutput = "Bad request.\nCould not find service \"\(label)\" in domain for system\n"
        XCTAssertTrue(RegisteredInstallerHelperParentReader.isAbsent(
            status: 113, output: absentOutput
        ))
        XCTAssertFalse(RegisteredInstallerHelperParentReader.isAbsent(
            status: 0, output: absentOutput
        ))
        XCTAssertFalse(RegisteredInstallerHelperParentReader.isAbsent(
            status: 113, output: absentOutput + "extra"
        ))
        XCTAssertNil(RegisteredInstallerHelperParentReader.parse(
            valid.replacingOccurrences(of: "0.3.5", with: "garbage")
        ))
        XCTAssertNil(RegisteredInstallerHelperParentReader.parse(
            valid + "\nparent bundle version = 0.3.5\n"
        ))
        XCTAssertNil(RegisteredInstallerHelperParentReader.parse(
            valid.replacingOccurrences(of: "ServiceManagement", with: "other")
        ))
        XCTAssertNil(RegisteredInstallerHelperParentReader.parse(
            valid.replacingOccurrences(of: "system/\(label)", with: "user/\(label)")
        ))
    }

    func testNativeParentReadbackIsObservationOnly() {
        // CI hosts may have no installer daemon. Either result is an observation;
        // the coordinator still rejects nil or a version other than its own.
        let observed = RegisteredInstallerHelperParentReader().readVersion()
        _ = RegisteredInstallerHelperParentReader().readIdleVersion()
        let absent = RegisteredInstallerHelperParentReader().readAbsent()
        if absent { XCTAssertNil(observed) }
        if let observed {
            XCTAssertFalse(observed.description.isEmpty)
        }
    }

    func testLegacyQualificationTransitionRequiresIdleExactParentAndIsIdempotent() async throws {
        let current = try InstallerVersion("0.3.6")
        let service = LegacyTransitionService()
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: service)
        let first = await coordinator.replaceLegacyQualification(expectedVersion: current)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(service.counts(), [1, 1])
        let absent = LegacyTransitionService(notFoundAfterUnregister: true)
        let absentResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: absent
        ).replaceLegacyQualification(expectedVersion: current)
        XCTAssertNotNil(absentResult.readyReceipt)
        XCTAssertEqual(absent.counts(), [1, 1])
        let appScopedStatus = LegacyTransitionService(reportedStatusInitiallyNotRegistered: true)
        let appScopedResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: appScopedStatus
        ).replaceLegacyQualification(expectedVersion: current)
        XCTAssertNotNil(appScopedResult.readyReceipt)
        XCTAssertEqual(appScopedStatus.counts(), [1, 1])
        let duplicate = await coordinator.replaceLegacyQualification(expectedVersion: current)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(service.counts(), [1, 1])

        for candidate in [
            LegacyTransitionService(idle: false),
            LegacyTransitionService(oldVersion: "0.2.3"),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: candidate
            ).replaceLegacyQualification(expectedVersion: current)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(candidate.counts(), [0, 0])
        }
    }

    func testLegacyQualificationTransitionFailureAndRegistrationResume() async throws {
        let current = try InstallerVersion("0.3.6")
        let denied = LegacyTransitionService(unregisterFails: true)
        let deniedResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: denied
        ).replaceLegacyQualification(expectedVersion: current)
        XCTAssertEqual(deniedResult.failure, .unregistrationFailed)
        XCTAssertEqual(denied.counts(), [1, 0])

        let drift = LegacyTransitionService(staysEnabledAfterUnregister: true)
        let driftResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: drift
        ).replaceLegacyQualification(expectedVersion: current)
        XCTAssertEqual(driftResult.failure, .statusDrift)
        XCTAssertEqual(drift.counts(), [1, 0])
        let ambiguousAbsence = LegacyTransitionService(jobAbsentReadbackFails: true)
        let ambiguousResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: ambiguousAbsence
        ).replaceLegacyQualification(expectedVersion: current)
        XCTAssertEqual(ambiguousResult.failure, .statusDrift)
        XCTAssertEqual(ambiguousAbsence.counts(), [1, 0])

        let interrupted = LegacyTransitionService(registerFails: true)
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: interrupted)
        let interruptedResult = await coordinator.replaceLegacyQualification(
            expectedVersion: current
        )
        XCTAssertEqual(interruptedResult.failure, .registrationFailed)
        XCTAssertEqual(interrupted.counts(), [1, 1])
        interrupted.allowRegistration()
        let resumed = await coordinator.ensureRegistered(expectedVersion: current)
        XCTAssertNotNil(resumed.readyReceipt)
        XCTAssertEqual(interrupted.counts(), [1, 2])
    }

    func testIdleSignedOlderReleaseTransitionRequiresExactMonotonicParent() async throws {
        let current = try InstallerVersion("0.3.8")
        let service = LegacyTransitionService(oldVersion: "0.3.7", newVersion: "0.3.8")
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: service)
        let first = await coordinator.replaceIdleOlderRegistration(expectedVersion: current)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(service.counts(), [1, 1])
        let duplicate = await coordinator.replaceIdleOlderRegistration(expectedVersion: current)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(service.counts(), [1, 1])

        for candidate in [
            LegacyTransitionService(idle: false, oldVersion: "0.3.7"),
            LegacyTransitionService(oldVersion: "0.3.6"),
            LegacyTransitionService(oldVersion: "0.3.8"),
            LegacyTransitionService(oldVersion: "0.3.9"),
            LegacyTransitionService(oldVersion: "0.2.4"),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: candidate
            ).replaceIdleOlderRegistration(expectedVersion: current)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(candidate.counts(), [0, 0])
        }
    }

    func testIdleSignedOlderReleaseTransitionResumesAfterRegistrationFailure() async throws {
        let current = try InstallerVersion("0.3.8")
        let service = LegacyTransitionService(
            oldVersion: "0.3.7", newVersion: "0.3.8", registerFails: true
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: service)
        let interrupted = await coordinator.replaceIdleOlderRegistration(expectedVersion: current)
        XCTAssertEqual(interrupted.failure, .registrationFailed)
        XCTAssertEqual(service.counts(), [1, 1])
        service.allowRegistration()
        let resumed = await coordinator.ensureRegistered(expectedVersion: current)
        XCTAssertNotNil(resumed.readyReceipt)
        XCTAssertEqual(service.counts(), [1, 2])
    }

    func testBoundedMVP0314ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.16")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.14", newVersion: "0.3.16"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0314ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0314ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.13", "0.3.15", "0.3.16"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.16"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0314ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.14", newVersion: "0.3.17"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0314ForCleanInstall(
            expectedVersion: try InstallerVersion("0.3.17")
        )
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.14", newVersion: "0.3.16",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.14", newVersion: "0.3.16",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.14", newVersion: "0.3.16",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0314ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testBoundedMVP0316ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.18")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.16", newVersion: "0.3.18"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0316ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0316ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.14", "0.3.15", "0.3.17", "0.3.18"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.18"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0316ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.16", newVersion: "0.3.17"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0316ForCleanInstall(
            expectedVersion: try InstallerVersion("0.3.17")
        )
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.16", newVersion: "0.3.18",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.16", newVersion: "0.3.18",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.16", newVersion: "0.3.18",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0316ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testBoundedMVP0318ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.19")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.18", newVersion: "0.3.19"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0318ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0318ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.16", "0.3.17", "0.3.19"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.19"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0318ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.18", newVersion: "0.3.20"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0318ForCleanInstall(
            expectedVersion: try InstallerVersion("0.3.20")
        )
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.18", newVersion: "0.3.19",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.18", newVersion: "0.3.19",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.18", newVersion: "0.3.19",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0318ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testBoundedMVP0319ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.20")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.19", newVersion: "0.3.20"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0319ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0319ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.18", "0.3.20"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.20"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0319ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.19", newVersion: "0.3.21"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0319ForCleanInstall(expectedVersion: try InstallerVersion("0.3.21"))
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.19", newVersion: "0.3.20",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.19", newVersion: "0.3.20",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.19", newVersion: "0.3.20",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0319ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testBoundedMVP0320ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.22")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.20", newVersion: "0.3.22"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0320ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0320ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.19", "0.3.21", "0.3.22"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.22"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0320ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.20", newVersion: "0.3.21"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0320ForCleanInstall(expectedVersion: try InstallerVersion("0.3.21"))
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.20", newVersion: "0.3.22",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.20", newVersion: "0.3.22",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.20", newVersion: "0.3.22",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0320ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testBoundedMVP0322ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.23")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.22", newVersion: "0.3.23"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0322ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0322ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.20", "0.3.21", "0.3.23"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.23"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0322ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.22", newVersion: "0.3.24"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0322ForCleanInstall(expectedVersion: try InstallerVersion("0.3.24"))
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.22", newVersion: "0.3.23",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.22", newVersion: "0.3.23",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.22", newVersion: "0.3.23",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0322ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testBoundedMVP0323ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.24")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.23", newVersion: "0.3.24"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0323ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0323ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.22", "0.3.24", "0.3.25"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.24"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0323ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.23", newVersion: "0.3.25"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0323ForCleanInstall(expectedVersion: try InstallerVersion("0.3.25"))
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.23", newVersion: "0.3.24",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.23", newVersion: "0.3.24",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.23", newVersion: "0.3.24",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0323ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testBoundedMVP0324ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.25")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.24", newVersion: "0.3.25"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0324ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0324ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.23", "0.3.25", "0.3.26"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.25"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0324ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.24", newVersion: "0.3.26"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0324ForCleanInstall(expectedVersion: try InstallerVersion("0.3.26"))
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.24", newVersion: "0.3.25",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.24", newVersion: "0.3.25",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.24", newVersion: "0.3.25",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0324ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testBoundedMVP0325ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.26")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.25", newVersion: "0.3.26"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0325ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0325ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.24", "0.3.26", "0.3.27"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.26"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0325ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.25", newVersion: "0.3.27"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0325ForCleanInstall(expectedVersion: try InstallerVersion("0.3.27"))
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.25", newVersion: "0.3.26",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.25", newVersion: "0.3.26",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.25", newVersion: "0.3.26",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0325ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testBoundedMVP0326ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.27")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.26", newVersion: "0.3.27"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0326ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0326ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.25", "0.3.27", "0.3.28"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.27"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0326ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.26", newVersion: "0.3.28"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0326ForCleanInstall(expectedVersion: try InstallerVersion("0.3.28"))
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.26", newVersion: "0.3.27",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.26", newVersion: "0.3.27",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.26", newVersion: "0.3.27",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0326ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testBoundedMVP0327ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.28")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.27", newVersion: "0.3.28"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0327ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0327ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.26", "0.3.28", "0.3.29"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.28"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0327ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.27", newVersion: "0.3.29"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0327ForCleanInstall(expectedVersion: try InstallerVersion("0.3.29"))
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.27", newVersion: "0.3.28",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.27", newVersion: "0.3.28",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.27", newVersion: "0.3.28",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0327ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testBoundedMVP0328ReplacementRequiresExactSourceTargetAndAbsentReadback() async throws {
        let target = try InstallerVersion("0.3.29")
        let running = LegacyTransitionService(
            idle: false, oldVersion: "0.3.28", newVersion: "0.3.29"
        )
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(service: running)
        let first = await coordinator.replaceMVP0328ForCleanInstall(expectedVersion: target)
        XCTAssertNotNil(first.readyReceipt)
        XCTAssertEqual(running.counts(), [1, 1])
        let duplicate = await coordinator.replaceMVP0328ForCleanInstall(expectedVersion: target)
        XCTAssertEqual(duplicate.failure, .registeredParentMismatch)
        XCTAssertEqual(running.counts(), [1, 1])

        for source in ["0.3.27", "0.3.29", "0.3.30"] {
            let service = LegacyTransitionService(
                idle: false, oldVersion: source, newVersion: "0.3.29"
            )
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0328ForCleanInstall(expectedVersion: target)
            XCTAssertEqual(result.failure, .registeredParentMismatch)
            XCTAssertEqual(service.counts(), [0, 0])
        }
        let wrongTarget = LegacyTransitionService(
            idle: false, oldVersion: "0.3.28", newVersion: "0.3.30"
        )
        let wrongResult = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: wrongTarget
        ).replaceMVP0328ForCleanInstall(expectedVersion: try InstallerVersion("0.3.30"))
        XCTAssertEqual(wrongResult.failure, .registeredParentMismatch)
        XCTAssertEqual(wrongTarget.counts(), [0, 0])

        for service in [
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.28", newVersion: "0.3.29",
                unregisterFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.28", newVersion: "0.3.29",
                jobAbsentReadbackFails: true
            ),
            LegacyTransitionService(
                idle: false, oldVersion: "0.3.28", newVersion: "0.3.29",
                reportedStatusInitiallyNotRegistered: true
            ),
        ] {
            let result = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
                service: service
            ).replaceMVP0328ForCleanInstall(expectedVersion: target)
            XCTAssertNil(result.readyReceipt)
            XCTAssertEqual(service.counts()[1], 0)
        }
    }

    func testRegistrationAndTransitionShareCrossProcessLease() async throws {
        let version = try InstallerVersion("0.3.6")
        let busy = RegistrationLockStub(failsAcquisition: true)
        let old = LegacyTransitionService()
        let blocked = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: old, operationLock: busy
        ).replaceLegacyQualification(expectedVersion: version)
        XCTAssertEqual(blocked.failure, .transitionBusy)
        XCTAssertEqual(old.counts(), [0, 0])

        let lease = RegistrationLockStub()
        let transition = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: old, operationLock: lease
        ).replaceLegacyQualification(expectedVersion: version)
        XCTAssertNotNil(transition.readyReceipt)
        XCTAssertEqual(lease.counts(), [1, 1])
        let ready = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: old, operationLock: lease
        ).ensureRegistered(expectedVersion: version)
        XCTAssertNotNil(ready.readyReceipt)
        XCTAssertEqual(lease.counts(), [2, 2])

        let badRelease = RegistrationLockStub(failsRelease: true)
        let releaseFailure = await ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: old, operationLock: badRelease
        ).ensureRegistered(expectedVersion: version)
        XCTAssertEqual(releaseFailure.failure, .transitionBusy)
    }
}

private final class RegistrationLockStub:
    InstallerSelfUpdateOperationLocking, InstallerSelfUpdateOperationLock, @unchecked Sendable {
    private let lock = NSLock()
    private let failsAcquisition: Bool
    private let failsRelease: Bool
    private var acquisitions = 0
    private var releases = 0

    init(failsAcquisition: Bool = false, failsRelease: Bool = false) {
        self.failsAcquisition = failsAcquisition
        self.failsRelease = failsRelease
    }

    func acquireExclusiveSelfUpdateOperationLock()
        -> Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure> {
        lock.withLock { acquisitions += 1 }
        return failsAcquisition
            ? .failure(InstallerSelfUpdateFailure(.selfUpdateOperationLockUnavailable))
            : .success(self)
    }

    func releaseExclusiveSelfUpdateOperationLock() -> Result<Void, InstallerSelfUpdateFailure> {
        lock.withLock { releases += 1 }
        return failsRelease
            ? .failure(InstallerSelfUpdateFailure(.selfUpdateOperationLockUnavailable))
            : .success(())
    }

    func counts() -> [Int] { lock.withLock { [acquisitions, releases] } }
}

private final class LegacyTransitionService:
    ManagedInstallerPrivilegedHelperServiceControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private var currentIsNew = false
    private var unregisterCount = 0
    private var registerCount = 0
    private var registerFails: Bool
    private let unregisterFails: Bool
    private let staysEnabledAfterUnregister: Bool
    private let notFoundAfterUnregister: Bool
    private let reportedStatusInitiallyNotRegistered: Bool
    private let jobAbsentReadbackFails: Bool
    private let idle: Bool
    private let oldVersion: String
    private let newVersion: String

    init(idle: Bool = true, oldVersion: String = "0.2.4", newVersion: String = "0.3.6",
         unregisterFails: Bool = false, registerFails: Bool = false,
         staysEnabledAfterUnregister: Bool = false,
         notFoundAfterUnregister: Bool = false,
         reportedStatusInitiallyNotRegistered: Bool = false,
         jobAbsentReadbackFails: Bool = false) {
        self.idle = idle
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.unregisterFails = unregisterFails
        self.registerFails = registerFails
        self.staysEnabledAfterUnregister = staysEnabledAfterUnregister
        self.notFoundAfterUnregister = notFoundAfterUnregister
        self.reportedStatusInitiallyNotRegistered = reportedStatusInitiallyNotRegistered
        self.jobAbsentReadbackFails = jobAbsentReadbackFails
    }

    func readStatus() -> ManagedInstallerPrivilegedHelperStatus {
        lock.withLock {
            if enabled && currentIsNew { return .enabled }
            if enabled { return reportedStatusInitiallyNotRegistered ? .notRegistered : .enabled }
            return notFoundAfterUnregister ? .notFound : .notRegistered
        }
    }

    func readRegisteredParentVersion() -> InstallerVersion? {
        lock.withLock { try? InstallerVersion(currentIsNew ? newVersion : oldVersion) }
    }

    func readIdleRegisteredParentVersion() -> InstallerVersion? {
        lock.withLock { idle && enabled && !currentIsNew ? try? InstallerVersion(oldVersion) : nil }
    }

    func readSystemJobAbsent() -> Bool {
        lock.withLock { !enabled && !jobAbsentReadbackFails }
    }

    func unregister() throws {
        try lock.withLock {
            unregisterCount += 1
            if unregisterFails { throw ManagedInstallerPrivilegedHelperRegistrationFailure.unregistrationFailed }
            if !staysEnabledAfterUnregister { enabled = false }
        }
    }

    func register() throws {
        try lock.withLock {
            registerCount += 1
            if registerFails { throw ManagedInstallerPrivilegedHelperRegistrationFailure.registrationFailed }
            enabled = true
            currentIsNew = true
        }
    }

    func allowRegistration() { lock.withLock { registerFails = false } }
    func counts() -> [Int] { lock.withLock { [unregisterCount, registerCount] } }
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
    private let parentVersion: InstallerVersion?

    init(
        statuses: [ManagedInstallerPrivilegedHelperStatus],
        registrationFails: Bool = false,
        parentVersion: InstallerVersion? = try! InstallerVersion("0.3.5")
    ) {
        self.statuses = statuses
        self.registrationFails = registrationFails
        self.parentVersion = parentVersion
    }

    func readStatus() -> ManagedInstallerPrivilegedHelperStatus {
        lock.withLock {
            statusReads += 1
            if statuses.count > 1 { return statuses.removeFirst() }
            return statuses.first ?? .notFound
        }
    }

    func readRegisteredParentVersion() -> InstallerVersion? { parentVersion }
    func readIdleRegisteredParentVersion() -> InstallerVersion? { parentVersion }
    func readSystemJobAbsent() -> Bool { false }

    func register() throws {
        try lock.withLock {
            registrations += 1
            if registrationFails {
                throw ManagedInstallerPrivilegedHelperRegistrationFailure.registrationFailed
            }
        }
    }

    func unregister() throws {}

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
