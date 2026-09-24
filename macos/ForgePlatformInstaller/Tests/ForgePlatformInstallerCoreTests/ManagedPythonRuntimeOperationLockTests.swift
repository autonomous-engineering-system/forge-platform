import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeOperationLockTests: XCTestCase {
    func testSecondProcessLeaseIsBusyUntilFirstLeaseIsReleased() throws {
        let root = try managedPythonLockRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = FileManagedPythonRuntimeOperationLock(rootDirectory: root)
        let second = FileManagedPythonRuntimeOperationLock(rootDirectory: root)

        let firstLease = try lockLease(first.acquireExclusiveManagedPythonRuntimeOperationLock())
        XCTAssertEqual(
            lockFailure(second.acquireExclusiveManagedPythonRuntimeOperationLock()),
            .operationInProgress
        )
        try lockRelease(firstLease.releaseExclusiveManagedPythonRuntimeOperationLock())
        try lockRelease(firstLease.releaseExclusiveManagedPythonRuntimeOperationLock())

        let secondLease = try lockLease(second.acquireExclusiveManagedPythonRuntimeOperationLock())
        try lockRelease(secondLease.releaseExclusiveManagedPythonRuntimeOperationLock())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                FileManagedPythonRuntimeOperationLock.lockFileName
            ).path
        ))
    }

    func testRejectsSymlinkOrHardLinkedLockFile() throws {
        for hardLink in [false, true] {
            let root = try managedPythonLockRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try managedPythonCreatePrivateDirectory(root)
            let lockPath = root.appendingPathComponent(
                FileManagedPythonRuntimeOperationLock.lockFileName
            )
            let target = root.appendingPathComponent("target")
            FileManager.default.createFile(
                atPath: target.path,
                contents: Data(),
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            )
            if hardLink {
                XCTAssertEqual(Darwin.link(target.path, lockPath.path), 0)
            } else {
                try FileManager.default.createSymbolicLink(at: lockPath, withDestinationURL: target)
            }

            let operationLock = FileManagedPythonRuntimeOperationLock(rootDirectory: root)
            XCTAssertEqual(
                lockFailure(operationLock.acquireExclusiveManagedPythonRuntimeOperationLock()),
                .unavailable
            )
        }
    }

    func testRejectsInsecureRootAndExistingLockFileModes() throws {
        for insecureRoot in [true, false] {
            let root = try managedPythonLockRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try managedPythonCreatePrivateDirectory(root)
            if insecureRoot {
                try managedPythonSetMode(root, mode_t(0o755))
            } else {
                let file = root.appendingPathComponent(
                    FileManagedPythonRuntimeOperationLock.lockFileName
                )
                FileManager.default.createFile(atPath: file.path, contents: Data())
                try managedPythonSetMode(file, mode_t(0o644))
            }

            let operationLock = FileManagedPythonRuntimeOperationLock(rootDirectory: root)
            XCTAssertEqual(
                lockFailure(operationLock.acquireExclusiveManagedPythonRuntimeOperationLock()),
                .unavailable
            )
        }
    }

    func testRejectsRootWithSpecialPermissionBitsAndCreatesPrivateObjects() throws {
        let insecure = try managedPythonLockRoot()
        defer { try? FileManager.default.removeItem(at: insecure) }
        try managedPythonCreatePrivateDirectory(insecure)
        try managedPythonSetMode(insecure, mode_t(0o1700))
        XCTAssertEqual(
            lockFailure(
                FileManagedPythonRuntimeOperationLock(rootDirectory: insecure)
                    .acquireExclusiveManagedPythonRuntimeOperationLock()
            ),
            .unavailable
        )

        let created = try managedPythonLockRoot()
        defer { try? FileManager.default.removeItem(at: created) }
        let lease = try lockLease(
            FileManagedPythonRuntimeOperationLock(rootDirectory: created)
                .acquireExclusiveManagedPythonRuntimeOperationLock()
        )
        try lockRelease(lease.releaseExclusiveManagedPythonRuntimeOperationLock())
        XCTAssertEqual(try managedPythonMode(created), mode_t(0o700))
        XCTAssertEqual(
            try managedPythonMode(created.appendingPathComponent(
                FileManagedPythonRuntimeOperationLock.lockFileName
            )),
            mode_t(0o600)
        )
    }
}

private enum ManagedPythonRuntimeOperationLockTestError: Error {
    case unexpected
    case filesystem
}

private func lockLease(
    _ result: Result<any ManagedPythonRuntimeOperationLock, ManagedPythonRuntimeOperationLockFailure>
) throws -> any ManagedPythonRuntimeOperationLock {
    switch result {
    case .success(let lease): return lease
    case .failure: throw ManagedPythonRuntimeOperationLockTestError.unexpected
    }
}

private func lockRelease(
    _ result: Result<Void, ManagedPythonRuntimeOperationLockFailure>
) throws {
    if case .failure = result { throw ManagedPythonRuntimeOperationLockTestError.unexpected }
}

private func lockFailure<Value>(
    _ result: Result<Value, ManagedPythonRuntimeOperationLockFailure>
) -> ManagedPythonRuntimeOperationLockFailure? {
    if case .failure(let failure) = result { return failure }
    return nil
}

private func managedPythonLockRoot() throws -> URL {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("managed-python-operation-lock-tests", isDirectory: true)
    try managedPythonCreatePrivateDirectory(parent)
    return parent.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
}

private func managedPythonCreatePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try managedPythonSetMode(url, mode_t(0o700))
}

private func managedPythonSetMode(_ url: URL, _ mode: mode_t) throws {
    guard Darwin.chmod(url.path, mode) == 0 else {
        throw ManagedPythonRuntimeOperationLockTestError.filesystem
    }
}

private func managedPythonMode(_ url: URL) throws -> mode_t {
    var details = stat()
    guard Darwin.lstat(url.path, &details) == 0 else {
        throw ManagedPythonRuntimeOperationLockTestError.filesystem
    }
    return details.st_mode & mode_t(0o7777)
}
