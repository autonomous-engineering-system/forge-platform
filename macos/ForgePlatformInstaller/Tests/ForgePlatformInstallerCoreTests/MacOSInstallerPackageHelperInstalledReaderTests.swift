import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerPackageHelperInstalledReaderTests: XCTestCase {
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
        func record(package: Bool = true) throws -> VerifiedInstallerReleaseRecord {
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
                helperPackage: package ? try .init(sha256: String(repeating: "e", count: 64), bytes: 1024, notarizationReference: "receipt:package-notarization") : nil)
        }
    }
}
