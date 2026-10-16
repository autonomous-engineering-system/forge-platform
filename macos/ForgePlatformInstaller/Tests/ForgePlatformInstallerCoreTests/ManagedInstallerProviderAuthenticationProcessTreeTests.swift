import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore
@testable import ForgePlatformInstallerPrivilegedHelper

final class ManagedInstallerProviderAuthenticationProcessTreeTests: XCTestCase {
    // Run this test in a private XCTest subprocess, using the production
    // wrapper launcher with synthetic output and no service-account changes.
    func testProductionWrapperChildEntry() throws {
        guard let path = ProcessInfo.processInfo.environment["FPI_PROCESS_TREE_TEST_FIXTURE"] else { return }
        guard Darwin.getpgrp() == Darwin.getpid() else { Darwin._exit(78) }
        let request = ManagedInstallerProviderAccountProbeChild.Request(
            accountName: "process-test", uid: geteuid(), gid: getegid(),
            provider: "codex", probe: "authentication-login",
            executable: path + "/codex", home: path)
        Darwin._exit(ManagedInstallerProviderAccountProbeChild.launch(request))
    }

    func testRealProductionWrapperRenewalStopsProviderBeforeNewChallenge() throws {
        let root = URL(fileURLWithPath: "/private/tmp/fpi-process-tree-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("codex")
        // The child reports only its PID. Challenge data are synthetic.
        try Data("#!/bin/sh\necho $$ > \"$HOME/provider-pid\"\nprintf 'https://auth.openai.com/codex/device\\nEnter this one-time code\\nABCD-EF12\\n'\nexec /bin/sleep 30\n".utf8).write(to: fixture)
        XCTAssertEqual(chmod(fixture.path, 0o700), 0)
        let effects = FileManagedInstallerProductWorkerEffectJournal(stateRoot: root, expectedOwner: geteuid())
        let registry = ManagedInstallerHelperChildExitRegistry()
        func makeSession() -> ManagedInstallerProviderAuthenticationSession {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
            process.arguments = ["-XCTest", "ForgePlatformInstallerCoreTests.ManagedInstallerProviderAuthenticationProcessTreeTests/testProductionWrapperChildEntry", Bundle(for: Self.self).bundleURL.path]
            // An instrumented XCTest child must keep its own profiling bytes
            // inside the private fixture, never default.profraw in the checkout.
            process.environment = ["FPI_PROCESS_TREE_TEST_FIXTURE": root.path,
                "PATH": "/usr/bin:/bin", "LLVM_PROFILE_FILE": root.path + "/child-%p.profraw"]
            process.standardInput = FileHandle.nullDevice
            return ManagedInstallerProviderAuthenticationSession(provider: .codex, process: process,
                exitRegistry: registry, effectJournal: effects,
                expirationQuiescence: { group in
                    Darwin.kill(-group, 0) == -1 && errno == ESRCH
                        && Self.providerAbsent(root)
                })
        }
        let first = makeSession()
        defer { first.cancel() }
        XCTAssertNotNil(first.begin(challengeTimeout: 10, sessionTimeout: 25))
        let providerPID = try readPID(root)
        defer { if Darwin.kill(providerPID, 0) == 0 { _ = Darwin.kill(providerPID, SIGKILL) } }
        let providerGroup = Darwin.getpgid(providerPID)
        let wrapper = parentPID(providerPID)
        XCTAssertGreaterThan(wrapper, 1)
        XCTAssertEqual(providerGroup, wrapper, "Production provider must share its wrapper group")
        let original = try Data(contentsOf: root.appendingPathComponent("product-worker-effects.json"))
        XCTAssertTrue(first.requestCodeRenewal())
        for _ in 0..<200 where registry.activeCount() != 0 || !Self.providerAbsent(root) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(registry.activeCount(), 0)
        XCTAssertTrue(Self.providerAbsent(root), "Refresh must not orphan its provider")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("product-worker-effects.json")), original)
        guard Self.providerAbsent(root) else { return }
        XCTAssertTrue(first.completeExpiredReadback())
        XCTAssertFalse(try effects.readRequired().get().hasUnresolvedEffects)
        let next = makeSession()
        defer { next.cancel() }
        XCTAssertNotNil(next.begin(challengeTimeout: 10, sessionTimeout: 25))
        XCTAssertNotEqual(try readPID(root), providerPID)
        XCTAssertTrue(next.requestCodeRenewal())
        for _ in 0..<200 where registry.activeCount() != 0 || !Self.providerAbsent(root) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(Self.providerAbsent(root))
        XCTAssertTrue(next.completeExpiredReadback())
    }

    private static func providerAbsent(_ root: URL) -> Bool {
        guard let text = try? String(contentsOf: root.appendingPathComponent("provider-pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }
    private func readPID(_ root: URL) throws -> pid_t {
        try XCTUnwrap(pid_t(String(contentsOf: root.appendingPathComponent("provider-pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    private func parentPID(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return -1 }
        return pid_t(info.pbi_ppid)
    }
}
