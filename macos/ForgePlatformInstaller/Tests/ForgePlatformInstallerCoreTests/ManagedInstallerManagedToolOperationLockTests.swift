import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerManagedToolOperationLockTests: XCTestCase {
    func testGitAndPythonUseTheSameHostLease() throws {
        let root = try lockRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FileManagedInstallerManagedToolOperationLock(rootDirectory: root)
        let python = FileManagedPythonRuntimeOperationLock(rootDirectory: root)

        let gitLease = try acquired(git.acquireExclusiveManagedToolOperationLock())
        XCTAssertEqual(failure(python.acquireExclusiveManagedPythonRuntimeOperationLock()),
                       .operationInProgress)
        XCTAssertEqual(failure(git.acquireExclusiveManagedToolOperationLock()),
                       .operationInProgress)
        try released(gitLease.releaseExclusiveManagedToolOperationLock())
        try released(gitLease.releaseExclusiveManagedToolOperationLock())

        let pythonLease = try acquiredPython(
            python.acquireExclusiveManagedPythonRuntimeOperationLock()
        )
        XCTAssertEqual(failure(git.acquireExclusiveManagedToolOperationLock()),
                       .operationInProgress)
        guard case .success = pythonLease.releaseExclusiveManagedPythonRuntimeOperationLock()
        else { throw LockTestFailure.unexpected }
        let secondGitLease = try acquired(git.acquireExclusiveManagedToolOperationLock())
        try released(secondGitLease.releaseExclusiveManagedToolOperationLock())
    }

    func testInsecureRootOrLockFileFailsClosed() throws {
        for insecureFile in [false, true] {
            let root = try lockRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            if insecureFile {
                let file = root.appendingPathComponent(
                    FileManagedPythonRuntimeOperationLock.lockFileName
                )
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: file.path, contents: Data(),
                    attributes: [.posixPermissions: NSNumber(value: 0o644)]
                ))
                XCTAssertEqual(Darwin.chmod(file.path, 0o644), 0)
            } else {
                XCTAssertEqual(Darwin.chmod(root.path, 0o755), 0)
            }
            let git = FileManagedInstallerManagedToolOperationLock(rootDirectory: root)
            XCTAssertEqual(failure(git.acquireExclusiveManagedToolOperationLock()),
                           .operationLockUnavailable)
        }
    }

    func testHostLeaseFailuresRemainFailClosed() throws {
        for (hostFailure, expected) in [
            (ManagedPythonRuntimeOperationLockFailure.operationInProgress,
             ManagedInstallerManagedToolReconciliationFailure.operationInProgress),
            (.unavailable, .operationLockUnavailable),
            (.releaseFailed, .operationLockUnavailable),
        ] {
            let git = FileManagedInstallerManagedToolOperationLock(
                hostLock: HostLockStub(result: .failure(hostFailure))
            )
            XCTAssertEqual(failure(git.acquireExclusiveManagedToolOperationLock()), expected)
        }

        let git = FileManagedInstallerManagedToolOperationLock(
            hostLock: HostLockStub(result: .success(HostLeaseStub()))
        )
        let lease = try acquired(git.acquireExclusiveManagedToolOperationLock())
        XCTAssertEqual(failure(lease.releaseExclusiveManagedToolOperationLock()),
                       .operationLockReleaseFailed)
    }

    private func lockRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-tool-host-lock-tests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        XCTAssertEqual(Darwin.chmod(parent.path, 0o700), 0)
        return parent.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }

    private func acquired(
        _ result: Result<
            any ManagedInstallerManagedToolOperationLock,
            ManagedInstallerManagedToolReconciliationFailure
        >
    ) throws -> any ManagedInstallerManagedToolOperationLock {
        guard case .success(let lease) = result else { throw LockTestFailure.unexpected }
        return lease
    }

    private func acquiredPython(
        _ result: Result<
            any ManagedPythonRuntimeOperationLock,
            ManagedPythonRuntimeOperationLockFailure
        >
    ) throws -> any ManagedPythonRuntimeOperationLock {
        guard case .success(let lease) = result else { throw LockTestFailure.unexpected }
        return lease
    }

    private func released(
        _ result: Result<Void, ManagedInstallerManagedToolReconciliationFailure>
    ) throws {
        guard case .success = result else { throw LockTestFailure.unexpected }
    }

    private func failure<T>(
        _ result: Result<T, ManagedInstallerManagedToolReconciliationFailure>
    ) -> ManagedInstallerManagedToolReconciliationFailure? {
        guard case .failure(let failure) = result else { return nil }
        return failure
    }

    private func failure<T>(
        _ result: Result<T, ManagedPythonRuntimeOperationLockFailure>
    ) -> ManagedPythonRuntimeOperationLockFailure? {
        guard case .failure(let failure) = result else { return nil }
        return failure
    }
}

private enum LockTestFailure: Error { case unexpected }

private struct HostLockStub: ManagedPythonRuntimeOperationLocking {
    let result: Result<any ManagedPythonRuntimeOperationLock,
                       ManagedPythonRuntimeOperationLockFailure>

    func acquireExclusiveManagedPythonRuntimeOperationLock()
        -> Result<any ManagedPythonRuntimeOperationLock,
                  ManagedPythonRuntimeOperationLockFailure> {
        result
    }
}

private struct HostLeaseStub: ManagedPythonRuntimeOperationLock {
    func releaseExclusiveManagedPythonRuntimeOperationLock()
        -> Result<Void, ManagedPythonRuntimeOperationLockFailure> {
        .failure(.releaseFailed)
    }
}
