import Compression
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderRuntimeArchiveInspectorTests: XCTestCase {
    func testForgeContextPublishesOnlyExactDeploymentInstanceSlot() throws {
        let fixture = try ProviderArchiveFixture()
        let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
        let request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a", stagedArchive: fixture.staged,
            requirement: fixture.requirement, inspection: inspection
        )
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("forge-provider-context-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let publisher = try XCTUnwrap(MacOSManagedInstallerProviderRuntimeSlotPublisher(
            forgeContextRoot: root, expectedDeploymentID: "deployment-a",
            requirement: fixture.requirement, expectedOwner: geteuid()
        ))
        XCTAssertNil(try providerSlotReadback(publisher.readPublishedSlot(
            requirement: fixture.requirement, request: request
        )))
        let published = try providerSlotReadback(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement, request: request
        ))
        XCTAssertEqual(try XCTUnwrap(providerSlotReadback(publisher.readPublishedSlot(
            requirement: fixture.requirement, request: request
        ))), published)
        let target = root.appendingPathComponent(
            "deployments/deployment-a/providers/forge-runtime/forge-primary/codex",
            isDirectory: true
        )
        XCTAssertEqual(try Data(contentsOf: target
            .appendingPathComponent("runtime/1.2.3/bin/codex")), fixture.executable)
        XCTAssertNil(MacOSManagedInstallerProviderRuntimeSlotPublisher(
            forgeContextRoot: root, expectedDeploymentID: "deployment-a",
            requirement: try ProviderArchiveFixture(provider: .githubCLI).requirement,
            expectedOwner: geteuid()
        ))
        let foreign = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-b", stagedArchive: fixture.staged,
            requirement: fixture.requirement, inspection: inspection
        )
        XCTAssertEqual(publisher.readPublishedSlot(
            requirement: fixture.requirement, request: foreign
        ).failure, .invalidRequest)
    }

    func testForgeContextRejectsUnsafeAncestorBeforePublication() throws {
        let fixture = try ProviderArchiveFixture()
        let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
        let request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a", stagedArchive: fixture.staged,
            requirement: fixture.requirement, inspection: inspection
        )
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("forge-provider-unsafe-\(UUID().uuidString)",
                                    isDirectory: true)
        let deployments = root.appendingPathComponent("deployments", isDirectory: true)
        try FileManager.default.createDirectory(at: deployments,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertEqual(chmod(deployments.path, 0o755), 0)
        let publisher = try XCTUnwrap(MacOSManagedInstallerProviderRuntimeSlotPublisher(
            forgeContextRoot: root, expectedDeploymentID: "deployment-a",
            requirement: fixture.requirement, expectedOwner: geteuid()
        ))
        XCTAssertEqual(publisher.readPublishedSlot(
            requirement: fixture.requirement, request: request
        ).failure, .rejected)
        XCTAssertEqual(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement,
            request: request
        ).failure, .rejected)
    }
    func testEPProductRuntimePublishesToExactUnversionedInstancePath() throws {
        let fixture = try ProviderArchiveFixture(
            kind: .zip, provider: .githubCLI, target: "ep-primary",
            epCanonicalExecutable: true
        )
        let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
        let request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a", stagedArchive: fixture.staged,
            requirement: fixture.requirement, inspection: inspection
        )
        let epRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ep-provider-runtime-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: epRoot, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: epRoot) }
        XCTAssertEqual(chmod(epRoot.path, 0o700), 0)
        let providerRoot = epRoot
            .appendingPathComponent("instances/ep-primary/providers/github", isDirectory: true)
        let publisher = try XCTUnwrap(MacOSManagedInstallerProviderRuntimeSlotPublisher(
            epProductRoot: epRoot, expectedDeploymentID: "deployment-a",
            requirement: fixture.requirement, expectedOwner: geteuid()
        ))
        let published = try providerSlotReadback(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement, request: request
        ))
        XCTAssertEqual(try XCTUnwrap(providerSlotReadback(publisher.readPublishedSlot(
            requirement: fixture.requirement, request: request
        ))), published)
        XCTAssertEqual(try providerSlotReadback(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement, request: request
        )), published)
        let executable = providerRoot.appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(fixture.runtime.executableRelativePath)
        XCTAssertEqual(try Data(contentsOf: executable), fixture.executable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerRoot
            .appendingPathComponent(fixture.runtime.version.description).path))
        XCTAssertTrue(executable.path.hasSuffix(
            "/instances/ep-primary/providers/github/runtime/bin/gh"
        ))
        for directory in [
            epRoot.appendingPathComponent("instances", isDirectory: true),
            epRoot.appendingPathComponent("instances/ep-primary", isDirectory: true),
            epRoot.appendingPathComponent("instances/ep-primary/providers", isDirectory: true),
            providerRoot,
        ] {
            let details = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual(details[.posixPermissions] as? Int, 0o700)
            XCTAssertEqual(details[.ownerAccountID] as? NSNumber,
                           NSNumber(value: geteuid()))
        }
        let other = try ProviderArchiveFixture(
            kind: .zip, provider: .githubCLI, target: "ep-other",
            epCanonicalExecutable: true
        )
        XCTAssertEqual(publisher.readPublishedSlot(
            requirement: other.requirement, request: request
        ).failure, .invalidRequest)
        XCTAssertNil(MacOSManagedInstallerProviderRuntimeSlotPublisher(
            epProductRoot: epRoot, expectedDeploymentID: "deployment-a",
            requirement: try ProviderArchiveFixture().requirement,
            expectedOwner: geteuid()
        ))
        let wrongArchiveLayout = try ProviderArchiveFixture(
            kind: .zip, provider: .githubCLI, target: "ep-primary"
        )
        XCTAssertNil(MacOSManagedInstallerProviderRuntimeSlotPublisher(
            epProductRoot: epRoot, expectedDeploymentID: "deployment-a",
            requirement: wrongArchiveLayout.requirement, expectedOwner: geteuid()
        ))
    }

    func testFreshEPProviderRuntimeUsesProductInstanceRatherThanDeploymentRoot()
        throws {
        let fixture = try ProviderArchiveFixture(
            kind: .zip, provider: .githubCLI, target: "deployment-a",
            epCanonicalExecutable: true,
            ownerComponent: .engineeringPlatformServer
        )
        let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
        let request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a", stagedArchive: fixture.staged,
            requirement: fixture.requirement, inspection: inspection
        )
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "ep-fresh-provider-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let instance = ManagedInstallerProductServiceAccountPlanner.instanceID(
            deploymentID: "deployment-a",
            componentIdentity: ProviderOwnerComponent.engineeringPlatformServer.rawValue
        )
        let publisher = try XCTUnwrap(MacOSManagedInstallerProviderRuntimeSlotPublisher(
            epProductRoot: root, expectedDeploymentID: "deployment-a",
            requirement: fixture.requirement, freshProductInstanceID: instance,
            expectedOwner: geteuid()
        ))
        let published = try providerSlotReadback(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement, request: request
        ))
        XCTAssertEqual(try XCTUnwrap(providerSlotReadback(publisher.readPublishedSlot(
            requirement: fixture.requirement, request: request
        ))), published)
        let executable = root.appendingPathComponent(
            "instances/\(instance)/providers/github/runtime/bin/gh"
        )
        XCTAssertEqual(try Data(contentsOf: executable), fixture.executable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root
            .appendingPathComponent("instances/deployment-a").path))
        XCTAssertNil(MacOSManagedInstallerProviderRuntimeSlotPublisher(
            epProductRoot: root, expectedDeploymentID: "deployment-a",
            requirement: fixture.requirement,
            freshProductInstanceID: "foreign-instance", expectedOwner: geteuid()
        ))
        XCTAssertNil(MacOSManagedInstallerProviderRuntimeSlotPublisher(
            epProductRoot: root, expectedDeploymentID: "deployment-b",
            requirement: fixture.requirement,
            freshProductInstanceID: instance, expectedOwner: geteuid()
        ))
    }

    func testEPProductCodexPublishesOnlyCanonicalBinExecutable() throws {
        let fixture = try ProviderArchiveFixture(
            kind: .zip, provider: .codex, target: "ep-primary",
            ownerComponent: .engineeringPlatformServer
        )
        let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
        let request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a", stagedArchive: fixture.staged,
            requirement: fixture.requirement, inspection: inspection
        )
        let epRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ep-provider-codex-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: epRoot, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: epRoot) }
        XCTAssertEqual(chmod(epRoot.path, 0o700), 0)
        let providerRoot = epRoot
            .appendingPathComponent("instances/ep-primary/providers/codex", isDirectory: true)
        let publisher = try XCTUnwrap(MacOSManagedInstallerProviderRuntimeSlotPublisher(
            epProductRoot: epRoot, expectedDeploymentID: "deployment-a",
            requirement: fixture.requirement, expectedOwner: geteuid()
        ))
        _ = try providerSlotReadback(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement, request: request
        ))
        XCTAssertEqual(try Data(contentsOf: providerRoot
            .appendingPathComponent("runtime/bin/codex")), fixture.executable)
    }

    func testEPProductRuntimeRejectsInsecureExistingProviderRoot() throws {
        let fixture = try ProviderArchiveFixture(
            kind: .zip, provider: .githubCLI, target: "ep-primary",
            epCanonicalExecutable: true
        )
        let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
        let request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a", stagedArchive: fixture.staged,
            requirement: fixture.requirement, inspection: inspection
        )
        let epRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ep-provider-unsafe-\(UUID().uuidString)",
                                    isDirectory: true)
        let providerRoot = epRoot
            .appendingPathComponent("instances/ep-primary/providers/github", isDirectory: true)
        try FileManager.default.createDirectory(at: providerRoot,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: epRoot) }
        for directory in [
            epRoot,
            epRoot.appendingPathComponent("instances", isDirectory: true),
            epRoot.appendingPathComponent("instances/ep-primary", isDirectory: true),
            epRoot.appendingPathComponent("instances/ep-primary/providers", isDirectory: true),
        ] {
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
        }
        XCTAssertEqual(chmod(providerRoot.path, 0o755), 0)
        let publisher = try XCTUnwrap(MacOSManagedInstallerProviderRuntimeSlotPublisher(
            epProductRoot: epRoot, expectedDeploymentID: "deployment-a",
            requirement: fixture.requirement, expectedOwner: geteuid()
        ))
        XCTAssertEqual(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement, request: request
        ).failure, .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerRoot
            .appendingPathComponent("runtime").path))

        try FileManager.default.removeItem(at: providerRoot)
        let outside = epRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside,
                                                withIntermediateDirectories: false)
        XCTAssertEqual(chmod(outside.path, 0o700), 0)
        try FileManager.default.createSymbolicLink(at: providerRoot,
                                                   withDestinationURL: outside)
        XCTAssertEqual(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement, request: request
        ).failure, .rejected)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testSlotAdapterUsesExactStagingThenCachedRestartReadback() async throws {
        let fixture = try ProviderArchiveFixture()
        let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
        let request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a",
            stagedArchive: fixture.staged, requirement: fixture.requirement,
            inspection: inspection
        )
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("provider-slot-adapter-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let staging = ProviderArchiveStaging(fixture: fixture)
        let publisher = MacOSManagedInstallerProviderRuntimeSlotPublisher(
            slotsRoot: root, expectedDeploymentID: "deployment-a", expectedOwner: geteuid()
        )
        let adapter = MacOSManagedInstallerProviderRuntimeSlotAdapter(
            requirement: fixture.requirement, staging: staging, publisher: publisher
        )
        let installed = try providerSlotReadback(await adapter.installRuntimeSlot(request))
        XCTAssertEqual(installed.deploymentID, "deployment-a")
        XCTAssertEqual(installed.providerTargetID, fixture.requirement.id)
        let stagingReads = await staging.readCount()
        XCTAssertEqual(stagingReads, 1)
        let restarted = MacOSManagedInstallerProviderRuntimeSlotAdapter(
            requirement: fixture.requirement,
            staging: ProviderArchiveStaging(fixture: fixture, failure: .unavailable),
            publisher: publisher
        )
        XCTAssertEqual(try providerSlotReadback(restarted.readRuntimeSlot(request)), installed)
    }

    func testSlotAdapterRejectsStagingDriftAndFailureBeforeMutation() async throws {
        let fixture = try ProviderArchiveFixture()
        let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
        let request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a",
            stagedArchive: fixture.staged, requirement: fixture.requirement,
            inspection: inspection
        )
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("provider-slot-adapter-negative-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let publisher = MacOSManagedInstallerProviderRuntimeSlotPublisher(
            slotsRoot: root, expectedDeploymentID: "deployment-a", expectedOwner: geteuid()
        )
        for drift in ProviderArchiveStaging.Drift.allCases {
            let adapter = MacOSManagedInstallerProviderRuntimeSlotAdapter(
                requirement: fixture.requirement,
                staging: ProviderArchiveStaging(fixture: fixture, drift: drift),
                publisher: publisher
            )
            let result = await adapter.installRuntimeSlot(request)
            XCTAssertEqual(result.failure, .rejected)
        }
        for (failure, expected) in [
            (ManagedInstallerProviderRuntimeStagingFailure.invalidRequest,
             ManagedInstallerProviderRuntimeMutationFailure.invalidRequest),
            (.unavailable, .unavailable),
            (.rejected, .rejected),
        ] {
            let adapter = MacOSManagedInstallerProviderRuntimeSlotAdapter(
                requirement: fixture.requirement,
                staging: ProviderArchiveStaging(fixture: fixture, failure: failure),
                publisher: publisher
            )
            let result = await adapter.installRuntimeSlot(request)
            XCTAssertEqual(result.failure, expected)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testProviderRuntimeSlotsSurviveStagingDiscardWithExactCachedReadback() throws {
        for kind in [ProviderRuntimeArchiveKind.tarGzip, .zip] {
            let fixture = try ProviderArchiveFixture(
                kind: kind, provider: kind == .zip ? .githubCLI : .codex
            )
            let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
                .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
            let request = try ManagedInstallerProviderRuntimeMutationRequest(
                deploymentID: "deployment-a",
                stagedArchive: fixture.staged, requirement: fixture.requirement,
                inspection: inspection
            )
            let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("provider-slot-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertEqual(chmod(root.path, 0o700), 0)
            let publisher = MacOSManagedInstallerProviderRuntimeSlotPublisher(
                slotsRoot: root, expectedDeploymentID: "deployment-a", expectedOwner: geteuid()
            )
            XCTAssertNil(try providerSlotReadback(
                publisher.readPublishedSlot(requirement: fixture.requirement,
                                            request: request)
            ))
            let published = try XCTUnwrap(providerSlotReadback(publisher.publish(
                archive: fixture.archive, requirement: fixture.requirement,
                request: request
            )))
            XCTAssertEqual(published.operationID, request.operationID)
            XCTAssertEqual(published.providerTargetID, fixture.requirement.id)
            XCTAssertEqual(published.runtimeSlotIdentity, request.runtimeSlotIdentity)
            XCTAssertTrue(published.treeEvidenceReference.hasPrefix("receipt:provider-tree-"))
            XCTAssertEqual(try providerSlotReadback(publisher.readPublishedSlot(
                requirement: fixture.requirement, request: request
            )), published)
            XCTAssertEqual(try providerSlotReadback(publisher.publish(
                archive: fixture.archive, requirement: fixture.requirement,
                request: request
            )), published)
            let suffix = kind == .zip ? "zip" : "tar.gz"
            let cache = root.appendingPathComponent(
                "archive-" + fixture.runtime.artifactSHA256.dropFirst("sha256:".count)
                    + "." + suffix
            )
            XCTAssertEqual(try Data(contentsOf: cache), fixture.archive)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(
                request.runtime.version.description
            ).path))
        }
    }

    func testProviderRuntimeSlotRejectsTamperedCacheAndTree() throws {
        let fixture = try ProviderArchiveFixture()
        let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
        let request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a",
            stagedArchive: fixture.staged, requirement: fixture.requirement,
            inspection: inspection
        )
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("provider-slot-negative-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let publisher = MacOSManagedInstallerProviderRuntimeSlotPublisher(
            slotsRoot: root, expectedDeploymentID: "deployment-a", expectedOwner: geteuid()
        )
        _ = try providerSlotReadback(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement, request: request
        ))
        let file = root.appendingPathComponent(request.runtime.version.description)
            .appendingPathComponent(fixture.runtime.executableRelativePath)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(publisher.readPublishedSlot(
            requirement: fixture.requirement, request: request
        ).failure, .rejected)
        XCTAssertEqual(chmod(file.path, 0o755), 0)
        let cache = root.appendingPathComponent(
            "archive-" + fixture.runtime.artifactSHA256.dropFirst("sha256:".count)
                + ".tar.gz"
        )
        try Data("corrupt".utf8).write(to: cache)
        XCTAssertEqual(chmod(cache.path, 0o600), 0)
        XCTAssertEqual(publisher.readPublishedSlot(
            requirement: fixture.requirement, request: request
        ).failure, .rejected)
    }

    func testProviderRuntimeSlotRejectsWrongTargetAndInsecureRoot() throws {
        let fixture = try ProviderArchiveFixture()
        let other = try ProviderArchiveFixture(target: "other-instance")
        let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
        let request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a",
            stagedArchive: fixture.staged, requirement: fixture.requirement,
            inspection: inspection
        )
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("provider-slot-target-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let publisher = MacOSManagedInstallerProviderRuntimeSlotPublisher(
            slotsRoot: root, expectedDeploymentID: "deployment-a", expectedOwner: geteuid()
        )
        XCTAssertEqual(publisher.publish(
            archive: fixture.archive, requirement: other.requirement, request: request
        ).failure, .invalidRequest)
        XCTAssertEqual(publisher.readPublishedSlot(
            requirement: other.requirement, request: request
        ).failure, .invalidRequest)
        let foreignDeployment = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-b",
            stagedArchive: fixture.staged, requirement: fixture.requirement,
            inspection: inspection
        )
        XCTAssertEqual(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement,
            request: foreignDeployment
        ).failure, .invalidRequest)
        XCTAssertEqual(publisher.readPublishedSlot(
            requirement: fixture.requirement, request: foreignDeployment
        ).failure, .invalidRequest)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertEqual(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement, request: request
        ).failure, .rejected)
    }
    func testExtractsExactTarAndZipWithIndependentCompleteTreeReadback() throws {
        for kind in [ProviderRuntimeArchiveKind.tarGzip, .zip] {
            let fixture = try ProviderArchiveFixture(
                kind: kind, provider: kind == .zip ? .githubCLI : .codex
            )
            let inventory = try MacOSManagedInstallerProviderRuntimeArchiveInspector
                .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement)
            XCTAssertEqual(inventory.members.count, kind == .zip ? 4 : 3)
            let executable = try XCTUnwrap(inventory.members.first {
                $0.path == fixture.runtime.executableRelativePath
            })
            XCTAssertEqual(executable.sha256, providerTaggedDigest(fixture.executable))
            XCTAssertEqual(executable.mode & 0o111, 0o111)

            let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
                "provider-extraction-\(UUID().uuidString)", isDirectory: true
            )
            let destination = parent.appendingPathComponent("slot", isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: parent) }
            XCTAssertEqual(chmod(parent.path, 0o700), 0)
            XCTAssertEqual(chmod(destination.path, 0o700), 0)
            let extractor = MacOSManagedInstallerProviderRuntimeArchiveExtractor(
                destination: destination, expectedOwner: geteuid()
            )
            let result = try providerArchiveExtractionSuccess(extractor.extract(
                archive: fixture.archive, requirement: fixture.requirement,
                inspection: inventory.inspection
            ))
            XCTAssertEqual(result.inspection, inventory.inspection)
            XCTAssertTrue(result.treeEvidenceReference.hasPrefix("receipt:provider-tree-"))
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(
                fixture.runtime.executableRelativePath
            )), fixture.executable)
            let extractedMode = try XCTUnwrap(FileManager.default.attributesOfItem(
                atPath: destination.appendingPathComponent(
                    fixture.runtime.executableRelativePath
                ).path
            )[.posixPermissions] as? NSNumber)
            XCTAssertEqual(extractedMode.uint16Value, 0o500)
            XCTAssertEqual(extractor.extract(
                archive: fixture.archive, requirement: fixture.requirement,
                inspection: inventory.inspection
            ).failure, .rejected)
        }
    }

    func testExtractorRejectsStaleInspectionDirtyAndInsecureDestinations() throws {
        let fixture = try ProviderArchiveFixture()
        let inspection = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(fixture.archive, for: fixture.requirement).inspection
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "provider-extraction-negative-\(UUID().uuidString)", isDirectory: true
        )
        let destination = parent.appendingPathComponent("slot", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        XCTAssertEqual(chmod(destination.path, 0o700), 0)
        let extractor = MacOSManagedInstallerProviderRuntimeArchiveExtractor(
            destination: destination, expectedOwner: geteuid()
        )
        let staleInspection = try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: inspection.providerTargetID,
            provider: inspection.provider,
            runtime: inspection.runtime,
            archiveEntryCount: inspection.archiveEntryCount,
            expandedByteCount: inspection.expandedByteCount,
            executableArchitectures: inspection.executableArchitectures,
            minimumMacOSVersion: inspection.minimumMacOSVersion,
            evidenceReference: "provider-archive-inspection-stale"
        )
        XCTAssertEqual(extractor.extract(
            archive: fixture.archive, requirement: fixture.requirement,
            inspection: staleInspection
        ).failure, .rejected)
        var corrupt = fixture.archive
        corrupt[corrupt.startIndex] ^= 1
        XCTAssertEqual(extractor.extract(
            archive: corrupt, requirement: fixture.requirement, inspection: inspection
        ).failure, .rejected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: destination.path
        ), [])

        try Data("dirty".utf8).write(to: destination.appendingPathComponent("other"))
        XCTAssertEqual(extractor.extract(
            archive: fixture.archive, requirement: fixture.requirement,
            inspection: inspection
        ).failure, .rejected)
        XCTAssertEqual(MacOSManagedInstallerProviderRuntimeArchiveExtractor(
            destination: destination, expectedOwner: geteuid() + 1
        ).extract(
            archive: fixture.archive, requirement: fixture.requirement,
            inspection: inspection
        ).failure, .rejected)
        try FileManager.default.removeItem(at: destination.appendingPathComponent("other"))
        XCTAssertEqual(chmod(destination.path, 0o755), 0)
        XCTAssertEqual(extractor.extract(
            archive: fixture.archive, requirement: fixture.requirement,
            inspection: inspection
        ).failure, .rejected)
        XCTAssertEqual(chmod(destination.path, 0o700), 0)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(
            at: destination, withDestinationURL: parent
        )
        XCTAssertEqual(extractor.extract(
            archive: fixture.archive, requirement: fixture.requirement,
            inspection: inspection
        ).failure, .rejected)
    }
    func testInspectsExactTarGzipProviderArchiveWithoutExtractionOrExecution() async throws {
        let fixture = try ProviderArchiveFixture(kind: .tarGzip, provider: .codex)
        let staging = ProviderArchiveStaging(fixture: fixture)
        let result = try providerArchiveInspectionSuccess(
            await MacOSManagedInstallerProviderRuntimeArchiveInspector(staging: staging)
                .inspect(fixture.staged, for: fixture.requirement)
        )

        XCTAssertEqual(result.providerTargetID, fixture.requirement.id)
        XCTAssertEqual(result.provider, .codex)
        XCTAssertEqual(result.runtime, fixture.runtime)
        XCTAssertEqual(result.archiveEntryCount, 3)
        XCTAssertGreaterThan(result.expandedByteCount, UInt64(fixture.executable.count))
        XCTAssertEqual(result.executableArchitectures, ["arm64"])
        XCTAssertEqual(result.minimumMacOSVersion, try InstallerVersion("26.0.0"))
        XCTAssertTrue(result.evidenceReference.hasPrefix("provider-archive-inspection-"))
        let observedReadCount = await staging.readCount()
        XCTAssertEqual(observedReadCount, 1)
    }

    func testInspectsExactDeflatedZIPProviderArchiveWithoutExtractionOrExecution() async throws {
        let fixture = try ProviderArchiveFixture(kind: .zip, provider: .githubCLI)
        let inspection = try providerArchiveInspectionSuccess(
            await MacOSManagedInstallerProviderRuntimeArchiveInspector(
                staging: ProviderArchiveStaging(fixture: fixture)
            ).inspect(fixture.staged, for: fixture.requirement)
        )

        XCTAssertEqual(inspection.provider, .githubCLI)
        XCTAssertEqual(inspection.runtime.archiveKind, .zip)
        XCTAssertEqual(inspection.archiveEntryCount, 4)
        XCTAssertEqual(inspection.executableArchitectures, ["arm64"])
        XCTAssertEqual(inspection.minimumMacOSVersion, try InstallerVersion("26.0.0"))
    }

    func testMapsStagingFailuresAndRejectsUnboundReadback() async throws {
        let fixture = try ProviderArchiveFixture()
        for (failure, expected) in [
            (ManagedInstallerProviderRuntimeStagingFailure.invalidRequest, .invalidRequest),
            (.unavailable, .unavailable),
            (.rejected, .rejected),
        ] as [(
            ManagedInstallerProviderRuntimeStagingFailure,
            ManagedInstallerProviderRuntimeArchiveInspectionFailure
        )] {
            let result = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
                staging: ProviderArchiveStaging(fixture: fixture, failure: failure)
            ).inspect(fixture.staged, for: fixture.requirement)
            XCTAssertEqual(result.failure, expected)
        }

        for drift in ProviderArchiveStaging.Drift.allCases {
            let result = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
                staging: ProviderArchiveStaging(fixture: fixture, drift: drift)
            ).inspect(fixture.staged, for: fixture.requirement)
            XCTAssertEqual(result.failure, .rejected, "drift \(drift)")
        }

        let other = try ProviderArchiveFixture(provider: .githubCLI, target: "other-target")
        let mismatch = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
            staging: ProviderArchiveStaging(fixture: fixture)
        ).inspect(fixture.staged, for: other.requirement)
        XCTAssertEqual(mismatch.failure, .invalidRequest)

        let legacy = ProviderRequirement(provider: .codex, isRequired: true)
        let legacyResult = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
            staging: ProviderArchiveStaging(fixture: fixture)
        ).inspect(fixture.staged, for: legacy)
        XCTAssertEqual(legacyResult.failure, .invalidRequest)
    }

    func testRejectsTarEnvelopeLayoutPermissionDigestAndMachODrift() async throws {
        for mutation in ProviderArchiveMutation.tarCases {
            let fixture = try ProviderArchiveFixture(kind: .tarGzip, mutation: mutation)
            let result = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
                staging: ProviderArchiveStaging(fixture: fixture)
            ).inspect(fixture.staged, for: fixture.requirement)
            XCTAssertEqual(result.failure, .rejected, "mutation \(mutation)")
        }
    }

    func testRejectsZIPEnvelopeLayoutPermissionDigestAndMachODrift() async throws {
        for mutation in ProviderArchiveMutation.zipCases {
            let fixture = try ProviderArchiveFixture(
                kind: .zip,
                provider: .githubCLI,
                mutation: mutation
            )
            let result = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
                staging: ProviderArchiveStaging(fixture: fixture)
            ).inspect(fixture.staged, for: fixture.requirement)
            XCTAssertEqual(result.failure, .rejected, "mutation \(mutation)")
        }
    }

    func testInspectionModelRejectsMalformedEvidence() throws {
        let fixture = try ProviderArchiveFixture()
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: fixture.requirement.id,
            provider: fixture.requirement.provider,
            runtime: fixture.runtime,
            archiveEntryCount: 0,
            expandedByteCount: 1,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: try InstallerVersion("26.0.0"),
            evidenceReference: "reference"
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: fixture.requirement.id,
            provider: fixture.requirement.provider,
            runtime: fixture.runtime,
            archiveEntryCount: 1,
            expandedByteCount: 0,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: try InstallerVersion("26.0.0"),
            evidenceReference: "reference"
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: fixture.requirement.id,
            provider: fixture.requirement.provider,
            runtime: fixture.runtime,
            archiveEntryCount: 1,
            expandedByteCount: 1,
            executableArchitectures: ["x86_64"],
            minimumMacOSVersion: try InstallerVersion("26.0.0"),
            evidenceReference: "reference"
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: fixture.requirement.id,
            provider: fixture.requirement.provider,
            runtime: fixture.runtime,
            archiveEntryCount: 1,
            expandedByteCount: 1,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: try InstallerVersion("26.0.0"),
            evidenceReference: "bad value"
        ))
    }
}

private func providerSlotReadback<T>(
    _ result: Result<T, ManagedInstallerProviderRuntimeMutationFailure>
) throws -> T {
    switch result {
    case .success(let value): return value
    case .failure(let failure):
        XCTFail("provider slot operation failed: \(failure)")
        throw failure
    }
}

private func providerArchiveExtractionSuccess<T>(
    _ result: Result<T, ManagedInstallerProviderRuntimeArchiveExtractionFailure>
) throws -> T {
    switch result {
    case .success(let value): return value
    case .failure(let failure):
        XCTFail("provider archive extraction failed: \(failure)")
        throw failure
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

private enum ProviderArchiveMutation: String, CaseIterable, Sendable {
    case missingExecutable
    case missingParent
    case duplicatePath
    case caseCollision
    case unsafePath
    case symbolicLink
    case permissive
    case nonExecutable
    case unreadableFile
    case unsearchableDirectory
    case executableDigest
    case wrongMachO
    case badEnvelope
    case badChecksum
    case nonZeroPadding
    case badLocalName
    case zip64
    case unsupportedFlags
    case trailingComment
    case interEntryGap
    case directoryChecksum

    static let tarCases: [Self] = [
        .missingExecutable, .missingParent, .duplicatePath, .caseCollision,
        .unsafePath, .symbolicLink, .permissive, .nonExecutable,
        .unreadableFile, .unsearchableDirectory,
        .executableDigest, .wrongMachO, .badEnvelope, .badChecksum,
        .nonZeroPadding,
    ]

    static let zipCases: [Self] = [
        .missingExecutable, .missingParent, .duplicatePath, .caseCollision,
        .unsafePath, .symbolicLink, .permissive, .nonExecutable,
        .unreadableFile, .unsearchableDirectory,
        .executableDigest, .wrongMachO, .badEnvelope, .badChecksum,
        .badLocalName, .zip64, .unsupportedFlags, .trailingComment,
        .interEntryGap, .directoryChecksum,
    ]
}

private struct ProviderArchiveFixture: Sendable {
    let archive: Data
    let executable: Data
    let runtime: ProviderRuntimeRequirement
    let requirement: ProviderRequirement
    let staged: ManagedInstallerProviderStagedArchive

    init(
        kind: ProviderRuntimeArchiveKind = .tarGzip,
        provider: ProviderID = .codex,
        target: String = "forge-primary",
        mutation: ProviderArchiveMutation? = nil,
        epCanonicalExecutable: Bool = false,
        ownerComponent: ProviderOwnerComponent? = nil
    ) throws {
        let executablePath = provider == .codex ? "bin/codex" : (
            epCanonicalExecutable ? "bin/gh" : "release/bin/gh"
        )
        executable = providerArchiveMachO(wrong: mutation == .wrongMachO)
        var entries = providerArchiveEntries(
            executablePath: executablePath,
            executable: executable,
            mutation: mutation
        )
        if mutation == .missingExecutable {
            entries.removeAll { $0.path == executablePath }
        }
        switch kind {
        case .tarGzip:
            var body = providerTar(entries)
            if mutation == .badChecksum { body[148] ^= 1 }
            if mutation == .nonZeroPadding, let firstZero = body.firstIndex(of: 0) {
                body[firstZero] = 1
            }
            archive = try providerGZIP(body, badEnvelope: mutation == .badEnvelope)
        case .zip:
            archive = try providerZIP(
                entries,
                mutation: mutation
            )
        }
        let version = try InstallerVersion(provider == .codex ? "1.2.3" : "4.5.6")
        let executableDigest = mutation == .executableDigest
            ? providerTaggedDigest(Data("wrong".utf8))
            : providerTaggedDigest(executable)
        runtime = try ProviderRuntimeRequirement(
            version: version,
            archiveKind: kind,
            artifactURL: "https://assets.example.test/provider.\(kind.rawValue)",
            artifactSHA256: providerTaggedDigest(archive),
            executableRelativePath: executablePath,
            executableSHA256: executableDigest
        )
        requirement = ProviderRequirement(
            provider: provider,
            isRequired: true,
            minimumVersion: version,
            credentialScope: .component,
            ownerComponent: ownerComponent ?? (
                provider == .codex ? .forgeRuntime : .engineeringPlatformServer
            ),
            targetIdentity: target,
            runtime: runtime
        )
        let identity = try ManagedInstallerProviderStagedFileIdentity(
            volumeReference: "volume-1",
            fileReference: "file-1",
            byteCount: UInt64(archive.count)
        )
        staged = try ManagedInstallerProviderStagedArchive(
            operationID: "provider-archive-inspection",
            providerTargetID: requirement.id,
            provider: provider,
            runtime: runtime,
            opaqueReference: "provider-archive-inspection-reference",
            fileIdentity: identity
        )
    }
}

private actor ProviderArchiveStaging: ManagedInstallerProviderRuntimeArchiveStaging {
    enum Drift: String, CaseIterable, Sendable {
        case target
        case provider
        case runtime
        case bytes
    }

    private let fixture: ProviderArchiveFixture
    private let failure: ManagedInstallerProviderRuntimeStagingFailure?
    private let drift: Drift?
    private var reads = 0

    init(
        fixture: ProviderArchiveFixture,
        failure: ManagedInstallerProviderRuntimeStagingFailure? = nil,
        drift: Drift? = nil
    ) {
        self.fixture = fixture
        self.failure = failure
        self.drift = drift
    }

    func reconcileUnrecordedStagingOperations()
        async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure> {
        .failure(.rejected)
    }

    func stageRuntimeArchive(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderStagedArchive,
        ManagedInstallerProviderRuntimeStagingFailure
    > {
        .failure(.rejected)
    }

    func readStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive,
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveReadback,
        ManagedInstallerProviderRuntimeStagingFailure
    > {
        reads += 1
        if let failure { return .failure(failure) }
        let other = try! ProviderArchiveFixture(provider: .githubCLI, target: "other")
        return .success(ManagedInstallerProviderRuntimeArchiveReadback(
            providerTargetID: drift == .target ? other.requirement.id : requirement.id,
            provider: drift == .provider ? other.requirement.provider : requirement.provider,
            runtime: drift == .runtime ? other.runtime : fixture.runtime,
            bytes: drift == .bytes ? Data("changed".utf8) : fixture.archive
        ))
    }

    func discardStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive
    ) async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure> {
        .failure(.rejected)
    }

    func readCount() -> Int { reads }
}

private enum ProviderArchiveEntry {
    case file(path: String, body: Data, mode: UInt16, deflate: Bool)
    case directory(path: String, mode: UInt16)
    case symbolicLink(path: String, target: String)

    var path: String {
        switch self {
        case .file(let path, _, _, _), .directory(let path, _), .symbolicLink(let path, _):
            return path
        }
    }
}

private func providerArchiveEntries(
    executablePath: String,
    executable: Data,
    mutation: ProviderArchiveMutation?
) -> [ProviderArchiveEntry] {
    let parentComponents = executablePath.split(separator: "/").dropLast()
    var current = ""
    var entries: [ProviderArchiveEntry] = []
    if mutation != .missingParent {
        for component in parentComponents {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            entries.append(.directory(
                path: current + "/",
                mode: mutation == .unsearchableDirectory ? 0o600 : 0o755
            ))
        }
    }
    let targetPath = mutation == .unsafePath ? "../\(executablePath)" : executablePath
    let mode: UInt16
    if mutation == .permissive {
        mode = 0o777
    } else if mutation == .nonExecutable {
        mode = 0o644
    } else {
        mode = 0o755
    }
    if mutation == .symbolicLink {
        entries.append(.symbolicLink(path: targetPath, target: "/tmp/provider"))
    } else {
        entries.append(.file(path: targetPath, body: executable, mode: mode, deflate: true))
    }
    entries.append(.file(
        path: current.isEmpty ? "README.txt" : "\(current)/README.txt",
        body: Data("provider runtime".utf8),
        mode: mutation == .unreadableFile ? 0o200 : 0o644,
        deflate: false
    ))
    if mutation == .duplicatePath {
        entries.append(.file(path: targetPath, body: executable, mode: mode, deflate: false))
    } else if mutation == .caseCollision {
        entries.append(.file(
            path: targetPath.uppercased(),
            body: executable,
            mode: mode,
            deflate: false
        ))
    }
    return entries
}

private func providerTar(_ entries: [ProviderArchiveEntry]) -> Data {
    var archive = Data()
    for entry in entries {
        let path: String
        let body: Data
        let mode: UInt16
        let type: UInt8
        let link: String
        switch entry {
        case .file(let value, let data, let permissions, _):
            (path, body, mode, type, link) = (value, data, permissions, 0x30, "")
        case .directory(let value, let permissions):
            (path, body, mode, type, link) = (value, Data(), permissions, 0x35, "")
        case .symbolicLink(let value, let target):
            (path, body, mode, type, link) = (value, Data(), 0o777, 0x32, target)
        }
        var header = Data(repeating: 0, count: 512)
        providerWrite(path, into: &header, at: 0, count: 100)
        providerWriteOctal(UInt64(mode), into: &header, at: 100, count: 8)
        providerWriteOctal(0, into: &header, at: 108, count: 8)
        providerWriteOctal(0, into: &header, at: 116, count: 8)
        providerWriteOctal(UInt64(body.count), into: &header, at: 124, count: 12)
        providerWriteOctal(0, into: &header, at: 136, count: 12)
        for index in 148..<156 { header[index] = 0x20 }
        header[156] = type
        providerWrite(link, into: &header, at: 157, count: 100)
        providerWrite("ustar", into: &header, at: 257, count: 6)
        providerWrite("00", into: &header, at: 263, count: 2)
        let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        providerWrite(String(format: "%06llo", checksum), into: &header, at: 148, count: 6)
        header[154] = 0
        header[155] = 0x20
        archive.append(header)
        archive.append(body)
        archive.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
    }
    archive.append(Data(repeating: 0, count: 1_024))
    return archive
}

private func providerGZIP(_ body: Data, badEnvelope: Bool) throws -> Data {
    var compressed = Data(count: body.count + 1_024)
    let count = compressed.withUnsafeMutableBytes { destination in
        body.withUnsafeBytes { source in
            compression_encode_buffer(
                destination.bindMemory(to: UInt8.self).baseAddress!,
                destination.count,
                source.bindMemory(to: UInt8.self).baseAddress!,
                source.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
    }
    guard count > 0 else {
        throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
    }
    compressed.removeSubrange(count..<compressed.count)
    var result = Data([badEnvelope ? 0 : 0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
    result.append(compressed)
    providerAppendLittleEndian(providerCRC32(body), to: &result)
    providerAppendLittleEndian(UInt32(truncatingIfNeeded: body.count), to: &result)
    return result
}

private func providerZIP(
    _ entries: [ProviderArchiveEntry],
    mutation: ProviderArchiveMutation?
) throws -> Data {
    struct Record {
        let name: Data
        let body: Data
        let compressed: Data
        let crc: UInt32
        let method: UInt16
        let mode: UInt16
        let localOffset: UInt32
        let directory: Bool
        let symlink: Bool
    }
    var archive = Data()
    var records: [Record] = []
    for (index, entry) in entries.enumerated() {
        let path: String
        let body: Data
        let mode: UInt16
        let deflate: Bool
        let directory: Bool
        let symlink: Bool
        switch entry {
        case .file(let value, let data, let permissions, let compressed):
            (path, body, mode, deflate, directory, symlink) = (
                value, data, permissions, compressed, false, false
            )
        case .directory(let value, let permissions):
            (path, body, mode, deflate, directory, symlink) = (
                value, Data(), permissions, false, true, false
            )
        case .symbolicLink(let value, let target):
            (path, body, mode, deflate, directory, symlink) = (
                value, Data(target.utf8), 0o777, false, false, true
            )
        }
        let name = Data(path.utf8)
        let compressed = deflate ? try providerDeflate(body) : body
        let method: UInt16 = deflate ? 8 : 0
        let crc = providerCRC32(body)
        let storedCRC: UInt32 = mutation == .directoryChecksum && directory ? 1 : crc
        let flags: UInt16 = mutation == .unsupportedFlags && index == 0 ? 1 : 0
        let extra = mutation == .zip64 && index == 0
            ? Data([0x01, 0x00, 0x00, 0x00])
            : Data()
        let localName = mutation == .badLocalName && index == 0
            ? Data(String(repeating: "x", count: name.count).utf8)
            : name
        if mutation == .interEntryGap && index == 1 { archive.append(0) }
        let localOffset = UInt32(archive.count)
        providerAppendLittleEndian(UInt32(0x0403_4b50), to: &archive)
        providerAppendLittleEndian(UInt16(20), to: &archive)
        providerAppendLittleEndian(flags, to: &archive)
        providerAppendLittleEndian(method, to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(storedCRC, to: &archive)
        providerAppendLittleEndian(UInt32(compressed.count), to: &archive)
        providerAppendLittleEndian(UInt32(body.count), to: &archive)
        providerAppendLittleEndian(UInt16(localName.count), to: &archive)
        providerAppendLittleEndian(UInt16(extra.count), to: &archive)
        archive.append(localName)
        archive.append(extra)
        archive.append(compressed)
        records.append(Record(
            name: name,
            body: body,
            compressed: compressed,
            crc: mutation == .badChecksum && index == entries.count - 1
                ? storedCRC ^ 1
                : storedCRC,
            method: method,
            mode: mode,
            localOffset: localOffset,
            directory: directory,
            symlink: symlink
        ))
    }
    let centralOffset = archive.count
    for (index, record) in records.enumerated() {
        let flags: UInt16 = mutation == .unsupportedFlags && index == 0 ? 1 : 0
        let extra = mutation == .zip64 && index == 0
            ? Data([0x01, 0x00, 0x00, 0x00])
            : Data()
        let fileType: UInt16 = record.symlink
            ? 0o120000
            : (record.directory ? 0o040000 : 0o100000)
        let external = UInt32(fileType | record.mode) << 16
        providerAppendLittleEndian(UInt32(0x0201_4b50), to: &archive)
        providerAppendLittleEndian(UInt16(0x0314), to: &archive)
        providerAppendLittleEndian(UInt16(20), to: &archive)
        providerAppendLittleEndian(flags, to: &archive)
        providerAppendLittleEndian(record.method, to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(record.crc, to: &archive)
        providerAppendLittleEndian(UInt32(record.compressed.count), to: &archive)
        providerAppendLittleEndian(UInt32(record.body.count), to: &archive)
        providerAppendLittleEndian(UInt16(record.name.count), to: &archive)
        providerAppendLittleEndian(UInt16(extra.count), to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(external, to: &archive)
        providerAppendLittleEndian(record.localOffset, to: &archive)
        archive.append(record.name)
        archive.append(extra)
    }
    let centralSize = archive.count - centralOffset
    providerAppendLittleEndian(
        mutation == .badEnvelope ? UInt32(0) : UInt32(0x0605_4b50),
        to: &archive
    )
    providerAppendLittleEndian(UInt16(0), to: &archive)
    providerAppendLittleEndian(UInt16(0), to: &archive)
    providerAppendLittleEndian(UInt16(records.count), to: &archive)
    providerAppendLittleEndian(UInt16(records.count), to: &archive)
    providerAppendLittleEndian(UInt32(centralSize), to: &archive)
    providerAppendLittleEndian(UInt32(centralOffset), to: &archive)
    let comment = mutation == .trailingComment ? Data("comment".utf8) : Data()
    providerAppendLittleEndian(UInt16(comment.count), to: &archive)
    archive.append(comment)
    return archive
}

private func providerDeflate(_ body: Data) throws -> Data {
    guard !body.isEmpty else { return Data() }
    var compressed = Data(count: body.count + 1_024)
    let count = compressed.withUnsafeMutableBytes { destination in
        body.withUnsafeBytes { source in
            compression_encode_buffer(
                destination.bindMemory(to: UInt8.self).baseAddress!,
                destination.count,
                source.bindMemory(to: UInt8.self).baseAddress!,
                source.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
    }
    guard count > 0 else {
        throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
    }
    compressed.removeSubrange(count..<compressed.count)
    return compressed
}

private func providerArchiveMachO(wrong: Bool) -> Data {
    var data = Data()
    providerAppendLittleEndian(wrong ? UInt32(0xcafe_babe) : UInt32(0xfeed_facf), to: &data)
    providerAppendLittleEndian(UInt32(0x0100_000c), to: &data)
    providerAppendLittleEndian(UInt32(0), to: &data)
    providerAppendLittleEndian(UInt32(2), to: &data)
    providerAppendLittleEndian(UInt32(1), to: &data)
    providerAppendLittleEndian(UInt32(24), to: &data)
    providerAppendLittleEndian(UInt32(0), to: &data)
    providerAppendLittleEndian(UInt32(0), to: &data)
    providerAppendLittleEndian(UInt32(0x32), to: &data)
    providerAppendLittleEndian(UInt32(24), to: &data)
    providerAppendLittleEndian(UInt32(1), to: &data)
    providerAppendLittleEndian(UInt32(26 << 16), to: &data)
    providerAppendLittleEndian(UInt32(26 << 16), to: &data)
    providerAppendLittleEndian(UInt32(0), to: &data)
    return data
}

private func providerWrite(
    _ value: String,
    into data: inout Data,
    at offset: Int,
    count: Int
) {
    let bytes = Array(value.utf8.prefix(count))
    data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
}

private func providerWriteOctal(
    _ value: UInt64,
    into data: inout Data,
    at offset: Int,
    count: Int
) {
    let encoded = String(value, radix: 8)
    let text = String(repeating: "0", count: max(0, count - encoded.count - 1)) + encoded
    providerWrite(text, into: &data, at: offset, count: count - 1)
    data[offset + count - 1] = 0
}

private func providerAppendLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data
) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func providerCRC32(_ data: Data) -> UInt32 {
    var value: UInt32 = 0xffff_ffff
    for byte in data {
        value ^= UInt32(byte)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1
        }
    }
    return value ^ 0xffff_ffff
}

private func providerTaggedDigest(_ data: Data) -> String {
    "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: data)
}

private func providerArchiveInspectionSuccess<T>(
    _ result: Result<T, ManagedInstallerProviderRuntimeArchiveInspectionFailure>
) throws -> T {
    switch result {
    case .success(let value): value
    case .failure(let failure):
        XCTFail("unexpected provider archive inspection failure: \(failure)")
        throw failure
    }
}
