import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerPackageHelperInstalledReaderTests: XCTestCase {
    func testInstalledHelperAndMetadataFIFOsFailBeforeTrustWithoutBlocking() async throws {
        for kind in ["helper", "info", "daemon"] {
            let f = try Fixture()
            defer { f.remove() }
            let path: URL
            switch kind {
            case "helper": path = f.helper
            case "info": path = f.app.appendingPathComponent("Contents/Info.plist")
            default: path = f.daemon
            }
            try FileManager.default.removeItem(at: path)
            XCTAssertEqual(mkfifo(path.path, 0o600), 0)
            // A delayed writer bounds a regressed blocking open. The source
            // fixture is never an installed/trusted helper or service.
            let releaseBlockedReader = DispatchGroup()
            releaseBlockedReader.enter()
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                let writer = open(path.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW)
                if writer >= 0 { _ = close(writer) }
                releaseBlockedReader.leave()
            }
            let reader = f.reader(bundle: { _ in
                XCTFail("Nonregular installed evidence must not reach sealed trust inspection")
                return nil
            })
            let start = Date()
            let result = await reader.read(release: try f.record())
            XCTAssertNil(result, kind)
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, kind)
            XCTAssertEqual(releaseBlockedReader.wait(timeout: .now() + .seconds(5)), .success)
        }
    }

    func testFilesCanBeVerifiedBeforeActivationWithoutClaimingRunningReadiness() async throws {
        let f = try Fixture(); defer { f.remove() }
        let reader = f.reader(process: .some(nil), job: .some(nil))
        let files = await reader.readFiles(release: try f.record())
        XCTAssertEqual(files?.releaseSequence, 12)
        XCTAssertEqual(files?.appCodeDirectorySHA256, String(repeating: "b", count: 64))
        let ready = await reader.read(release: try f.record())
        XCTAssertNil(ready)
        let unsupported = await reader.readFiles(release: try f.record(package: false))
        XCTAssertNil(unsupported)
        let unsigned = await f.reader(evidence: .some(nil)).readFiles(release: try f.record())
        XCTAssertNil(unsigned)
    }
    func testFilesReadbackRejectsMutationOrForeignSealBeforeActivation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let evidence = try f.evidence()
        let changed = f.reader(bundle: { _ in
            try? Data("changed daemon".utf8).write(to: f.daemon)
            return evidence
        })
        let denied = await changed.readFiles(release: try f.record())
        XCTAssertNil(denied)
        let wrong = try MacOSInstallerBundleCodeSigningEvidence(bundleIdentifier: "com.example.foreign",
            installerVersion: InstallerVersion("1.2.3"), teamIdentifier: "ZEML4LPXH4",
            codeDirectorySHA256: String(repeating: "b", count: 64))
        let second = try Fixture(); defer { second.remove() }
        let foreign = await second.reader(evidence: wrong).readFiles(release: try second.record())
        XCTAssertNil(foreign)
    }

    func testIndependentLayoutJobProcessAndReleaseReadback() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let result = await f.reader().read(release: try f.record())
        XCTAssertEqual(result?.processID, 42)
        XCTAssertEqual(result?.releaseSequence, 12)
        XCTAssertEqual(result?.appCodeDirectorySHA256, String(repeating: "b", count: 64))
        let denied = [
            await f.reader().read(release: try f.record(package: false)),
            await f.reader(evidence: .some(nil)).read(release: try f.record()),
            await f.reader(process: .some(nil)).read(release: try f.record()),
            await f.reader(job: .some(nil)).read(release: try f.record()),
        ]
        for value in denied { XCTAssertNil(value) }
        let wrong = try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: "com.example.wrong", installerVersion: InstallerVersion("1.2.3"),
            teamIdentifier: "ZEML4LPXH4", codeDirectorySHA256: String(repeating: "b", count: 64))
        let wrongResult = await f.reader(evidence: wrong).read(release: try f.record())
        XCTAssertNil(wrongResult)
    }

    func testRootTreeLinksPermissionsOwnerAndMissingLeavesAreRejected() async throws {
        for kind in ["file-link", "directory-link", "hardlink", "writable", "missing-helper", "missing-info", "wrong-owner", "malformed-plist", "writable-daemon", "unexecutable"] {
            let f = try Fixture()
            defer { f.remove() }
            let contents = f.app.appendingPathComponent("Contents")
            switch kind {
            case "file-link":
                try FileManager.default.removeItem(at: f.helper)
                try FileManager.default.createSymbolicLink(at: f.helper, withDestinationURL: f.daemon)
            case "directory-link":
                let resources = contents.appendingPathComponent("Resources")
                let retained = f.base.appendingPathComponent("retained")
                try FileManager.default.moveItem(at: resources, to: retained)
                try FileManager.default.createSymbolicLink(at: resources, withDestinationURL: retained)
            case "hardlink": XCTAssertEqual(link(f.helper.path, f.base.appendingPathComponent("alias").path), 0)
            case "writable": XCTAssertEqual(chmod(f.helper.path, 0o777), 0)
            case "missing-helper": try FileManager.default.removeItem(at: f.helper)
            case "missing-info": try FileManager.default.removeItem(at: contents.appendingPathComponent("Info.plist"))
            case "malformed-plist": try Data("malformed plist".utf8).write(to: f.daemon)
            case "writable-daemon": XCTAssertEqual(chmod(f.daemon.path, 0o666), 0)
            case "unexecutable": XCTAssertEqual(chmod(f.helper.path, 0o644), 0)
            default: break
            }
            let reader = f.reader(owner: kind == "wrong-owner" ? getuid() + 1 : getuid())
            let result = await reader.read(release: try f.record())
            XCTAssertNil(result, kind)
        }
    }

    func testMutationDuringSealedInspectionAndProcessRestartRejectAcknowledgment() async throws {
        for daemonChange in [true, false] {
            let f = try Fixture()
            defer { f.remove() }
            let evidence = try f.evidence()
            let reader = f.reader(bundle: { _ in
                if daemonChange {
                    try? Data("changed daemon".utf8).write(to: f.daemon)
                } else {
                    try? Data("changed helper".utf8).write(to: f.helper)
                }
                return evidence
            })
            let result = await reader.read(release: try f.record())
            XCTAssertNil(result)
        }
        let f = try Fixture()
        defer { f.remove() }
        let probe = ProbeCounter()
        let reader = f.reader(processRead: { pid, _, _ in
            .init(processID: pid, startSeconds: probe.next(), startMicroseconds: 1)
        })
        let result = await reader.read(release: try f.record())
        XCTAssertNil(result)
    }

    func testDaemonRequiresExactlyTheFixedRootProgramAndThreeBooleanServices() throws {
        let f = try Fixture()
        defer { f.remove() }
        XCTAssertTrue(MacOSInstallerPackageHelperInstalledReader.validDaemon(try f.daemonData(), executable: f.helper))
        for kind in ["extra-key", "wrong-label", "arguments", "association", "service", "integer", "false"] {
            var fields = f.daemonFields()
            switch kind {
            case "extra-key": fields["EnvironmentVariables"] = ["OVERRIDE": "value"]
            case "wrong-label": fields["Label"] = "com.example.other"
            case "arguments": fields["ProgramArguments"] = [f.helper.path, "--other"]
            case "association": fields["AssociatedBundleIdentifiers"] = "com.example.other"
            case "service": fields["MachServices"] = ["com.example.other": true]
            case "integer": fields["MachServices"] = Dictionary(uniqueKeysWithValues: ManagedInstallerPrivilegedHelperContract.machServices.map { ($0, 1) })
            case "false": fields["MachServices"] = Dictionary(uniqueKeysWithValues: ManagedInstallerPrivilegedHelperContract.machServices.map { ($0, false) })
            default: break
            }
            let data = try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
            XCTAssertFalse(MacOSInstallerPackageHelperInstalledReader.validDaemon(data, executable: f.helper), kind)
        }
        XCTAssertFalse(MacOSInstallerPackageHelperInstalledReader.validDaemon(Data("bad".utf8), executable: f.helper))
    }

    func testJobRequiresOuterFixedPathsRunningPIDAndNoSMBackend() throws {
        let f = try Fixture()
        defer { f.remove() }
        XCTAssertEqual(MacOSInstallerPackageHelperInstalledReader.parseJob(f.job(), executable: f.helper, daemon: f.daemon), 42)
        for text in [
            f.job().replacingOccurrences(of: "state = running", with: "state = not running"),
            f.job().replacingOccurrences(of: "pid = 42", with: "pid = -1"),
            f.job().replacingOccurrences(of: "pid = 42", with: "pid = 042"),
            f.job().replacingOccurrences(of: f.helper.path, with: "/other/helper"),
            f.job().replacingOccurrences(of: f.daemon.path, with: "/other/daemon"),
            f.job() + "\n\tpid = 43",
            f.job() + "\n\tmanaged_by = com.apple.xpc.ServiceManagement",
            f.job() + "\n\tmanaged_by = first\n\tmanaged_by = second",
            "other = {}",
        ] {
            XCTAssertNil(MacOSInstallerPackageHelperInstalledReader.parseJob(text, executable: f.helper, daemon: f.daemon))
        }
        let nested = f.job() + "\n\t\tstate = not running\n\t\tpid = 99"
        XCTAssertEqual(MacOSInstallerPackageHelperInstalledReader.parseJob(nested, executable: f.helper, daemon: f.daemon), 42)
    }

    func testPlatformInspectorRejectsWrongPIDOwnerPathAndUnsignedCurrentProcess() {
        let current = getpid()
        XCTAssertNil(MacOSInstallerPackageHelperInstalledReader.inspectProcess(-1, executable: URL(fileURLWithPath: "/none"), team: "ZEML4LPXH4"))
        XCTAssertNil(MacOSInstallerPackageHelperInstalledReader.inspectProcess(current, executable: URL(fileURLWithPath: "/none"), team: "invalid"))
        XCTAssertNil(MacOSInstallerPackageHelperInstalledReader.inspectProcess(current, executable: URL(fileURLWithPath: "/none"), team: "ZEML4LPXH4"))
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        XCTAssertGreaterThan(proc_pidpath(current, &bytes, UInt32(bytes.count)), 0)
        let path = URL(fileURLWithPath: String(cString: bytes))
        XCTAssertNil(MacOSInstallerPackageHelperInstalledReader.inspectProcess(current, executable: path, team: "ZEML4LPXH4", expectedOwner: getuid()))
    }

    func testProductionAssemblyUsesOnlyFixedInstallerAndInitialLaunchctlActions() async throws {
        let f = try Fixture(); defer { f.remove() }
        let (package, release, _, _) = try installFixture(f)
        let calls = InstallProbe()
        let actions = MacOSInstallerHelperPackageProductionActions(admitted: { _, _ in true },
            namespaceClean: { true }, verifier: .init(check: { _, _ in true }), reader: f.reader(),
            activationNamespaceClean: { true }, run: { tool, args in calls.add(tool + " " + args.joined(separator: "|")); return 0 }).assemble()
        XCTAssertTrue(actions.admitted(getuid(), release)); XCTAssertTrue(actions.namespaceClean())
        XCTAssertTrue(actions.activationNamespaceClean()); XCTAssertTrue(actions.verifyPackage(package, release))
        XCTAssertFalse(actions.verifyPackage(package, try f.record()))
        let exit = await actions.install(package); XCTAssertEqual(exit, 0)
        let files = await actions.readFiles(release); XCTAssertEqual(files?.releaseSequence, 12)
        let activated = await actions.activate(); XCTAssertEqual(activated, 0)
        let running = await actions.readRunning(release); XCTAssertEqual(running?.processID, 42)
        XCTAssertEqual(calls.items, ["/usr/sbin/installer -pkg|" + package.url.path + "|-target|/",
            "/bin/launchctl bootstrap|system|" + MacOSInstallerPackageHelperInstalledReader.daemon.path,
            "/bin/launchctl kickstart|system/" + ManagedInstallerPrivilegedHelperContract.label])
        for exit in [Int32(1), nil] {
            let refused = InstallProbe()
            let failed = MacOSInstallerHelperPackageProductionActions(admitted: { _, _ in true }, namespaceClean: { true },
                verifier: .init(check: { _, _ in true }), reader: f.reader(), activationNamespaceClean: { true },
                run: { tool, args in refused.add(tool + " " + args.joined(separator: "|")); return exit }).assemble()
            let result = await failed.activate(); XCTAssertNil(result)
            XCTAssertEqual(refused.items.count, 1)
            XCTAssertTrue(refused.items[0].contains(" bootstrap|"))
        }
        let production = MacOSInstallerHelperPackageProductionActions().assemble()
        // Source test is not the fixed installed, signed root bootstrap process.
        XCTAssertFalse(production.admitted(0, release)); XCTAssertFalse(production.admitted(getuid(), release))
    }
    func testInitialActivationRefusesLegacySMPathAndAnythingExceptExactAbsentJob() throws {
        let f = try Fixture(); defer { f.remove() }
        let legacy = f.base.appendingPathComponent("legacy-helper")
        let absent = "Bad request.\nCould not find service \"" + ManagedInstallerPrivilegedHelperContract.label + "\" in domain for system\n"
        XCTAssertTrue(MacOSInstallerHelperPackageProductionActions.initialActivationNamespaceClean(legacyTool: legacy, job: { absent }))
        for text in [nil, "", "service running", absent + "extra", absent.replacingOccurrences(of: "system", with: "user")] {
            XCTAssertFalse(MacOSInstallerHelperPackageProductionActions.initialActivationNamespaceClean(legacyTool: legacy, job: { text }))
        }
        for kind in ["regular", "fifo", "dangling-link", "directory"] {
            switch kind {
            case "regular": try Data().write(to: legacy)
            case "fifo": XCTAssertEqual(mkfifo(legacy.path, 0o600), 0)
            case "dangling-link": try FileManager.default.createSymbolicLink(atPath: legacy.path, withDestinationPath: "/source-only-missing")
            default: try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
            }
            XCTAssertFalse(MacOSInstallerHelperPackageProductionActions.initialActivationNamespaceClean(legacyTool: legacy, job: { XCTFail("Legacy namespace must fail before job inspection"); return absent }))
            try FileManager.default.removeItem(at: legacy)
        }
    }
    func testEffectChildObservesExitAndLaunchFailureWithoutOutputOrForcedTermination() {
        XCTAssertEqual(MacOSInstallerHelperPackageEffectChild.run("/usr/bin/true", []), 0)
        XCTAssertEqual(MacOSInstallerHelperPackageEffectChild.run("/usr/bin/false", []), 1)
        XCTAssertNil(MacOSInstallerHelperPackageEffectChild.run("/source-only/nonexistent-tool", []))
        XCTAssertNil(MacOSInstallerHelperPackageEffectChild.run("/bin/sleep", ["0.2"], timeout: .milliseconds(1)))
        // Let this source-test child end naturally; no helper/installer/launchctl
        // is launched and no kill, bootout or reboot is used by the test.
        Thread.sleep(forTimeInterval: 0.3)
    }

    // Source action seams only: no installer or launchctl process is run here.
    func testInstallCoordinatorRequiresDurableOrderAndFreshIndependentReadback() async throws {
        let f = try Fixture(); defer { f.remove() }
        let (package, release, store, lock) = try installFixture(f)
        let probe = InstallProbe()
        let service = installCoordinator(f, probe: probe, store: store, lock: lock)
        let result = await service.install(package, release: release, admission: .init(isCurrent: { true }), admittedClientUID: getuid())
        XCTAssertEqual(result?.processID, 42)
        XCTAssertEqual(probe.items, ["install", "files", "activate", "running"])
        XCTAssertEqual(try store.read().get().map(\.phase), MacOSInstallerHelperPackageEffectPhase.allCases)
        let repeatResult = await service.install(package, release: release, admission: .init(isCurrent: { true }), admittedClientUID: getuid())
        XCTAssertNil(repeatResult)
        XCTAssertEqual(probe.items, ["install", "files", "activate", "running"])
    }
    func testInstallCoordinatorFailurePreservesAttemptWithoutRetryOrFalseReadiness() async throws {
        for failure in ["admission", "namespace", "package", "launch", "exit", "files", "activation-namespace", "activation", "running", "foreign-running"] {
            let f = try Fixture(); defer { f.remove() }
            let (package, release, store, lock) = try installFixture(f)
            let probe = InstallProbe()
            let service = installCoordinator(f, probe: probe, store: store, lock: lock, failure: failure)
            let result = await service.install(package, release: release, admission: .init(isCurrent: { true }), admittedClientUID: getuid())
            XCTAssertNil(result, failure)
            let history = try store.read().get()
            let expected: MacOSInstallerHelperPackageEffectPhase?
            switch failure {
            case "admission", "namespace", "package": expected = nil
            case "launch": expected = .installAttempted
            case "exit", "files", "activation-namespace": expected = .installExited
            default: expected = .activationAttempted
            }
            XCTAssertEqual(history.last?.phase, expected, failure)
            if failure == "exit" { XCTAssertEqual(history.last?.installerExitCode, 42) }
            let before = probe.items
            let repeated = await service.install(package, release: release, admission: .init(isCurrent: { true }), admittedClientUID: getuid())
            XCTAssertNil(repeated)
            XCTAssertEqual(probe.items, before, failure)
        }
    }
    func testInstallCoordinatorBlocksRootPeerForeignReleaseAndBusyMutationLease() async throws {
        let f = try Fixture(); defer { f.remove() }
        let (package, release, store, lock) = try installFixture(f)
        let probe = InstallProbe()
        let service = installCoordinator(f, probe: probe, store: store, lock: lock)
        let root = await service.install(package, release: release, admission: .init(isCurrent: { true }), admittedClientUID: 0)
        XCTAssertNil(root)
        let foreign = await service.install(package, release: try f.record(), admission: .init(isCurrent: { true }), admittedClientUID: getuid())
        XCTAssertNil(foreign)
        let lease = try lock.acquireExclusiveSelfUpdateOperationLock().get()
        let busy = await service.install(package, release: release, admission: .init(isCurrent: { true }), admittedClientUID: getuid())
        XCTAssertNil(busy)
        _ = try lease.releaseExclusiveSelfUpdateOperationLock().get()
        XCTAssertEqual(probe.items, [])
        XCTAssertEqual(try store.read().get(), [])
    }
    func testInstallCoordinatorSerializesAcrossSuspendedChildAndChecksRevocationBeforeActivation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let (package, release, store, lock) = try installFixture(f)
        let entered = expectation(description: "source action suspended")
        let gate = InstallGate(entered: entered)
        let probe = InstallProbe()
        let service = installCoordinator(f, probe: probe, store: store, lock: lock, suspended: gate)
        let first = Task { await service.install(package, release: release, admission: .init(isCurrent: { true }), admittedClientUID: getuid()) }
        await fulfillment(of: [entered], timeout: 3)
        let second = await service.install(package, release: release, admission: .init(isCurrent: { true }), admittedClientUID: getuid())
        XCTAssertNil(second)
        XCTAssertEqual(try store.read().get().last?.phase, .installAttempted)
        await gate.finish()
        let result = await first.value
        XCTAssertEqual(result?.processID, 42)
        XCTAssertEqual(probe.items.filter { $0 == "install" }.count, 1)
        let other = try Fixture(); defer { other.remove() }
        let (p2, r2, j2, l2) = try installFixture(other)
        let revoked = InstallProbe()
        let denied = installCoordinator(other, probe: revoked, store: j2, lock: l2, failure: "revoke-after-files")
        let nilResult = await denied.install(p2, release: r2, admission: .init(isCurrent: { true }), admittedClientUID: getuid())
        XCTAssertNil(nilResult)
        XCTAssertEqual(revoked.items, ["install", "files"])
        XCTAssertEqual(try j2.read().get().last?.phase, .installExited)
    }
    func testExplicitImportToInstallationNeedsFreshReleaseAndConnectionEvidence() async throws {
        for failure in ["", "peer", "changed-feed", "lost-running"] {
            let f = try Fixture(); defer { f.remove() }
            let (package, release, store, lock) = try installFixture(f)
            let anchor = try CurrentInstallerBundleIdentity(version: release.release.version, acceptedReleaseSequence: release.sequence,
                channel: release.channel, sourceRevision: release.sourceRevision, bundleIdentifier: release.expectedBundleIdentifier,
                teamIdentifier: release.expectedTeamIdentifier, codeDirectorySHA256: release.expectedCodeDirectorySHA256,
                provenanceSHA256: release.provenanceSHA256, releaseTrustConfigurationSHA256: release.expectedReleaseTrustConfigurationSHA256)
            let feed = InstallFeed(first: release, later: failure == "changed-feed" ? try f.record(package: false) : release)
            let importer = MacOSInstallerHelperBootstrapImportCoordinator(anchor: anchor, feed: feed, lock: lock,
                peerAdmitted: { _ in true }, namespaceClean: { true }, importPackage: { _, _, _ in package }, reverify: { _, _ in true })
            let probe = InstallProbe()
            let installer = installCoordinator(f, probe: probe, store: store, lock: lock, failure: failure == "lost-running" ? "running" : "")
            let request = try JSONSerialization.data(withJSONObject: ["schema": "forge-platform.bootstrap-import/v1",
                "source": f.base.appendingPathComponent("source").appendingPathComponent(VerifiedInstallerHelperPackage.assetName).path,
                "release_sequence": release.sequence, "package_sha256": release.helperPackage!.sha256])
            let result = await importer.handleInstallation(request, connectionUID: getuid(),
                admission: .init(isCurrent: { failure != "peer" }), installer: installer)
            if failure.isEmpty {
                let receipt = try XCTUnwrap(result)
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt) as? [String: Any])
                XCTAssertEqual(fields["status"] as? String, "HELPER_RUNNING_VERIFIED")
                XCTAssertEqual(fields["installation_ready"] as? Bool, true)
                XCTAssertEqual(fields["process_id"] as? Int, 42)
                XCTAssertNil(fields["source"]); XCTAssertNil(fields["uid"])
                XCTAssertEqual(try store.read().get().last?.phase, .readbackRecorded)
                let repeated = await importer.handleInstallation(request, connectionUID: getuid(), admission: .init(isCurrent: { true }), installer: installer)
                XCTAssertNil(repeated) // No blind retry of the recorded attempt.
            } else {
                XCTAssertNil(result, failure)
                XCTAssertEqual(try store.read().get().last?.phase, failure == "lost-running" ? .activationAttempted : nil)
            }
        }
    }
    func testCurrentConnectionRevocationAfterInstallerExitBlocksFilesAndActivation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let (package, release, store, lock) = try installFixture(f)
        let probe = InstallProbe(), service = installCoordinator(f, probe: probe, store: store, lock: lock)
        let result = await service.install(package, release: release,
            admission: .init(isCurrent: { !probe.items.contains("install") }), admittedClientUID: getuid())
        XCTAssertNil(result)
        XCTAssertEqual(probe.items, ["install"])
        XCTAssertEqual(try store.read().get().last?.phase, .installExited)
    }
    private actor InstallFeed: SignedInstallerReleaseFeedVerifying {
        let first: VerifiedInstallerReleaseRecord; let later: VerifiedInstallerReleaseRecord
        var count = 0
        init(first: VerifiedInstallerReleaseRecord, later: VerifiedInstallerReleaseRecord) { self.first = first; self.later = later }
        func latestVerifiedInstallerRelease() async -> Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure> {
            count += 1; return .success(count == 1 ? first : later)
        }
    }

    func testBootstrapClientRequiresIndependentMatchingRunningEvidence() async throws {
        let f = try Fixture(); defer { f.remove() }
        let release = try f.record()
        let claim = try bootstrapClaim(release)
        let source = f.base.appendingPathComponent(VerifiedInstallerHelperPackage.assetName)
        let observed = InstallProbe()
        let client = MacOSInstallerHelperPackageBootstrapClient(request: { bytes in
            let request = MacOSInstallerHelperBootstrapImportRequest.decode(bytes)
            XCTAssertEqual(request?.source, source); XCTAssertEqual(request?.sequence, release.sequence)
            XCTAssertEqual(request?.packageSHA256, release.helperPackage?.sha256)
            observed.add("request"); return claim
        }, readInstalled: { record in observed.add("read"); return await f.reader().read(release: record) })
        let ready = await client.install(source: source, release: release)
        XCTAssertEqual(ready?.processID, 42); XCTAssertEqual(observed.items, ["request", "read"])
        for mismatch in [true, false] {
            let denied = MacOSInstallerHelperPackageBootstrapClient(request: { _ in claim }, readInstalled: { record in
                mismatch ? .init(releaseSequence: record.sequence, appCodeDirectorySHA256: record.expectedCodeDirectorySHA256, processID: 43) : nil
            })
            let result = await denied.install(source: source, release: release); XCTAssertNil(result)
        }
        let unsupported = await client.install(source: source, release: try f.record(package: false))
        let invalidPath = await client.install(source: f.base.appendingPathComponent("other.pkg"), release: release)
        let remote = await client.install(source: URL(string: "https://example.invalid/file.pkg")!, release: release)
        XCTAssertNil(unsupported); XCTAssertNil(invalidPath); XCTAssertNil(remote)
        XCTAssertEqual(observed.items, ["request", "read"])
        // Constructing production client does not connect, authorize or install.
        _ = MacOSInstallerHelperPackageBootstrapClient()
    }
    func testBootstrapClientRefusesHostileOrImportOnlyReceiptsBeforeInstalledRead() async throws {
        let f = try Fixture(); defer { f.remove() }
        let release = try f.record(), claim = try bootstrapClaim(release)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: claim) as? [String: Any])
        var candidates = [Data(), Data([255]), Data(repeating: 32, count: 8193), Data("{}".utf8),
            Data("{\"schema\":\"a\",\"schema\":\"b\"}".utf8)]
        for key in ["schema", "status", "release_sequence", "app_code_directory_sha256", "process_id", "installation_ready", "extra"] {
            var fields = original
            switch key {
            case "release_sequence": fields[key] = 13
            case "process_id": fields[key] = Int64(Int32.max) + 1
            case "installation_ready": fields[key] = 1
            default: fields[key] = "wrong"
            }
            candidates.append(try JSONSerialization.data(withJSONObject: fields))
        }
        for pid in ["-1", "0", "true", "42.0"] {
            candidates.append(Data(String(decoding: claim, as: UTF8.self).replacingOccurrences(of: "\"process_id\":42", with: "\"process_id\":" + pid).utf8))
        }
        for bytes in candidates {
            let denied = MacOSInstallerHelperPackageBootstrapClient(request: { _ in bytes }, readInstalled: { _ in
                XCTFail("Invalid helper claim must fail before installed read"); return nil
            })
            let result = await denied.install(source: f.base.appendingPathComponent(VerifiedInstallerHelperPackage.assetName), release: release)
            XCTAssertNil(result)
        }
        let unavailable = MacOSInstallerHelperPackageBootstrapClient(request: { _ in nil }, readInstalled: { _ in XCTFail("No reply"); return nil })
        let nilResult = await unavailable.install(source: f.base.appendingPathComponent(VerifiedInstallerHelperPackage.assetName), release: release)
        XCTAssertNil(nilResult)
    }
    private func bootstrapClaim(_ release: VerifiedInstallerReleaseRecord) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": "forge-platform.bootstrap-install-receipt/v1",
            "status": "HELPER_RUNNING_VERIFIED", "release_sequence": release.sequence,
            "app_code_directory_sha256": release.expectedCodeDirectorySHA256, "process_id": 42,
            "installation_ready": true], options: [.sortedKeys])
    }

    private func installFixture(_ f: Fixture) throws -> (MacOSInstallerImportedHelperPackage, VerifiedInstallerReleaseRecord,
        MacOSInstallerHelperPackageEffectJournal, FileInstallerSelfUpdateOperationLock) {
        let source = f.base.appendingPathComponent("source"), stage = f.base.appendingPathComponent("stage"), journal = f.base.appendingPathComponent("journal")
        for url in [source, stage, journal] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY)
            guard fd >= 0, let acl = acl_init(0) else { throw CocoaError(.fileWriteUnknown) }
            defer { _ = close(fd); _ = acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        let bytes = Data("source-only-package".utf8)
        let path = source.appendingPathComponent(VerifiedInstallerHelperPackage.assetName)
        try bytes.write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0)
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW_ANY)
        guard fd >= 0, let acl = acl_init(0) else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = close(fd); _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let release = try f.record(packageSHA: digest, packageBytes: UInt64(bytes.count))
        let importer = MacOSInstallerHelperPackageRootImporter(root: stage, owner: getuid(), verifier: .init(check: { _, _ in true }))
        return (try XCTUnwrap(importer.importPackage(from: path, admittedClientUID: getuid(), release: release)), release,
            .init(root: journal, owner: getuid()), .init(rootDirectory: journal))
    }
    private func installCoordinator(_ f: Fixture, probe: InstallProbe, store: MacOSInstallerHelperPackageEffectJournal,
        lock: any InstallerSelfUpdateOperationLocking, failure: String = "", suspended: InstallGate? = nil)
        -> MacOSInstallerHelperPackageInstallCoordinator {
        .init(lock: lock, journal: store, actions: .init(
            admitted: { _, _ in failure != "admission" && !(failure == "revoke-after-files" && probe.items.contains("files")) },
            namespaceClean: { failure != "namespace" }, verifyPackage: { _, _ in failure != "package" },
            install: { _ in XCTAssertEqual(try? store.read().get().last?.phase, .installAttempted); probe.add("install"); if let suspended { await suspended.wait() }; return failure == "launch" ? nil : (failure == "exit" ? 42 : 0) },
            readFiles: { release in probe.add("files"); return failure == "files" ? nil : await f.reader().readFiles(release: release) },
            activationNamespaceClean: { failure != "activation-namespace" },
            activate: { XCTAssertEqual(try? store.read().get().last?.phase, .activationAttempted); probe.add("activate"); return failure == "activation" ? 1 : 0 },
            readRunning: { release in
                probe.add("running")
                if failure == "running" { return nil }
                if failure == "foreign-running" { return .init(releaseSequence: 99, appCodeDirectorySHA256: release.expectedCodeDirectorySHA256, processID: 42) }
                return await f.reader().read(release: release)
            }))
    }
    private final class InstallProbe: @unchecked Sendable {
        private let lock = NSLock(); private var storage: [String] = []
        var items: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        func add(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    }
    private actor InstallGate {
        let entered: XCTestExpectation
        var continuation: CheckedContinuation<Void, Never>?
        init(entered: XCTestExpectation) { self.entered = entered }
        func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
        func finish() { continuation?.resume(); continuation = nil }
    }

    private final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count: UInt64 = 0
        func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    private struct Fixture: Sendable {
        let base: URL
        let shelf: URL
        let app: URL
        let helper: URL
        let daemon: URL
        init() throws {
            guard let physical = FileManager.default.temporaryDirectory.path.withCString({ realpath($0, nil) }) else { throw CocoaError(.fileReadUnknown) }
            defer { free(physical) }
            base = URL(fileURLWithPath: String(cString: physical), isDirectory: true).appendingPathComponent("package-helper-reader-" + UUID().uuidString)
            shelf = base.appendingPathComponent("shelf", isDirectory: true)
            app = shelf.appendingPathComponent(MacOSInstallerPackageHelperInstalledReader.appName, isDirectory: true)
            helper = app.appendingPathComponent(ManagedInstallerPrivilegedHelperContract.bundleProgram)
            daemon = base.appendingPathComponent(ManagedInstallerPrivilegedHelperContract.plistName)
            try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("source-assurance helper".utf8).write(to: helper)
            try Data("source-assurance info".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try daemonData().write(to: daemon)
            let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey])!
            let nodes = [base] + enumerator.allObjects.compactMap { $0 as? URL }
            for url in nodes {
                let isDirectory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
                XCTAssertEqual(chmod(url.path, isDirectory ? 0o755 : 0o644), 0)
                let fd = open(url.path, O_RDONLY | O_CLOEXEC)
                guard fd >= 0, let acl = acl_init(0) else { throw CocoaError(.fileReadUnknown) }
                defer { _ = close(fd); _ = acl_free(UnsafeMutableRawPointer(acl)) }
                guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw CocoaError(.fileWriteUnknown) }
            }
            XCTAssertEqual(chmod(helper.path, 0o755), 0)
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
        func daemonFields() -> [String: Any] {
            ["Label": ManagedInstallerPrivilegedHelperContract.label, "ProgramArguments": [helper.path],
             "AssociatedBundleIdentifiers": ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
             "MachServices": Dictionary(uniqueKeysWithValues: ManagedInstallerPrivilegedHelperContract.machServices.map { ($0, true) })]
        }
        func daemonData() throws -> Data { try PropertyListSerialization.data(fromPropertyList: daemonFields(), format: .xml, options: 0) }
        func job() -> String {
            "system/" + ManagedInstallerPrivilegedHelperContract.label + " = {\n\tstate = running\n\tprogram = " + helper.path + "\n\tpath = " + daemon.path + "\n\tpid = 42\n}"
        }
        func evidence() throws -> MacOSInstallerBundleCodeSigningEvidence {
            try .init(bundleIdentifier: ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
                      installerVersion: InstallerVersion("1.2.3"), teamIdentifier: "ZEML4LPXH4",
                      codeDirectorySHA256: String(repeating: "b", count: 64))
        }
        func reader(owner: uid_t = getuid(),
                    evidence: MacOSInstallerBundleCodeSigningEvidence?? = nil,
                    process: MacOSInstallerPackageHelperProcess?? = nil, job: String?? = nil,
                    bundle: MacOSInstallerPackageHelperInstalledReader.BundleRead? = nil,
                    processRead: MacOSInstallerPackageHelperInstalledReader.ProcessRead? = nil) -> MacOSInstallerPackageHelperInstalledReader {
            let bundleValue = evidence ?? (try? self.evidence())
            let processValue = process ?? MacOSInstallerPackageHelperProcess(processID: 42, startSeconds: 123, startMicroseconds: 1)
            let jobValue = job ?? self.job()
            return .init(shelf: shelf, daemon: daemon, owner: owner,
                readBundle: bundle ?? { _ in bundleValue }, readJob: { jobValue },
                readProcess: processRead ?? { _, _, _ in processValue })
        }
        func record(package: Bool = true, packageSHA: String = String(repeating: "e", count: 64), packageBytes: UInt64 = 1024) throws -> VerifiedInstallerReleaseRecord {
            let asset = try GitHubInstallerReleaseAsset(repository: "pcvantol/forge-platform", tag: "installer-v1.2.3", assetName: "Installer.app.zip")
            let release = VerifiedInstallerRelease(version: try InstallerVersion("1.2.3"), releasePage: asset.releasePage,
                assetName: asset.assetName, sha256: String(repeating: "f", count: 64), signingKeyID: "release-key")
            return try .init(release: release, sequence: 12, channel: .stable,
                sourceRevision: String(repeating: "a", count: 40),
                expectedBundleIdentifier: ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
                expectedTeamIdentifier: "ZEML4LPXH4", expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
                policyRevision: "release/v1", capabilities: ["composition/v1"],
                provenanceSHA256: String(repeating: "c", count: 64),
                expectedReleaseTrustConfigurationSHA256: String(repeating: "d", count: 64),
                compositionCatalogFeed: try .init(url: "https://catalog.example.invalid/stable.json"),
                notarizationReference: "receipt:app-notarization", githubAsset: asset,
                helperPackage: package ? try .init(sha256: packageSHA, bytes: packageBytes, notarizationReference: "receipt:package-notarization") : nil)
        }
    }
}
