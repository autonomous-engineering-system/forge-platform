import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderOperationLockTests: XCTestCase {
    func testSecondProcessLeaseIsBusyUntilFirstLeaseIsReleased() throws {
        let root = try providerLockRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = FileManagedInstallerProviderOperationLock(rootDirectory: root)
        let second = FileManagedInstallerProviderOperationLock(rootDirectory: root)

        let firstLease = try providerLockLease(
            first.acquireExclusiveManagedInstallerProviderOperationLock()
        )
        XCTAssertEqual(
            providerLockFailure(
                second.acquireExclusiveManagedInstallerProviderOperationLock()
            ),
            .operationInProgress
        )
        try providerLockRelease(
            firstLease.releaseExclusiveManagedInstallerProviderOperationLock()
        )
        try providerLockRelease(
            firstLease.releaseExclusiveManagedInstallerProviderOperationLock()
        )

        let secondLease = try providerLockLease(
            second.acquireExclusiveManagedInstallerProviderOperationLock()
        )
        try providerLockRelease(
            secondLease.releaseExclusiveManagedInstallerProviderOperationLock()
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                FileManagedInstallerProviderOperationLock.lockFileName
            ).path
        ))
    }

    func testRejectsSymlinkOrHardLinkedLockFile() throws {
        for hardLink in [false, true] {
            let root = try providerLockRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try providerCreatePrivateDirectory(root)
            let lockPath = root.appendingPathComponent(
                FileManagedInstallerProviderOperationLock.lockFileName
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
                try FileManager.default.createSymbolicLink(
                    at: lockPath,
                    withDestinationURL: target
                )
            }

            XCTAssertEqual(
                providerLockFailure(
                    FileManagedInstallerProviderOperationLock(rootDirectory: root)
                        .acquireExclusiveManagedInstallerProviderOperationLock()
                ),
                .unavailable
            )
        }
    }

    func testRejectsInsecureRootAndExistingLockFileModes() throws {
        for insecureRoot in [true, false] {
            let root = try providerLockRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try providerCreatePrivateDirectory(root)
            if insecureRoot {
                try providerSetMode(root, mode_t(0o755))
            } else {
                let file = root.appendingPathComponent(
                    FileManagedInstallerProviderOperationLock.lockFileName
                )
                FileManager.default.createFile(atPath: file.path, contents: Data())
                try providerSetMode(file, mode_t(0o644))
            }
            XCTAssertEqual(
                providerLockFailure(
                    FileManagedInstallerProviderOperationLock(rootDirectory: root)
                        .acquireExclusiveManagedInstallerProviderOperationLock()
                ),
                .unavailable
            )
        }
    }

    func testRejectsSpecialPermissionBitsAndCreatesPrivateObjects() throws {
        let insecure = try providerLockRoot()
        defer { try? FileManager.default.removeItem(at: insecure) }
        try providerCreatePrivateDirectory(insecure)
        try providerSetMode(insecure, mode_t(0o1700))
        XCTAssertEqual(
            providerLockFailure(
                FileManagedInstallerProviderOperationLock(rootDirectory: insecure)
                    .acquireExclusiveManagedInstallerProviderOperationLock()
            ),
            .unavailable
        )

        let created = try providerLockRoot()
        defer { try? FileManager.default.removeItem(at: created) }
        let lease = try providerLockLease(
            FileManagedInstallerProviderOperationLock(rootDirectory: created)
                .acquireExclusiveManagedInstallerProviderOperationLock()
        )
        try providerLockRelease(
            lease.releaseExclusiveManagedInstallerProviderOperationLock()
        )
        XCTAssertEqual(try providerMode(created), mode_t(0o700))
        XCTAssertEqual(
            try providerMode(created.appendingPathComponent(
                FileManagedInstallerProviderOperationLock.lockFileName
            )),
            mode_t(0o600)
        )
    }
}

private enum ProviderOperationLockTestError: Error {
    case unexpected
    case filesystem
}

private func providerLockLease(
    _ result: Result<
        any ManagedInstallerProviderOperationLock,
        ManagedInstallerProviderOperationLockFailure
    >
) throws -> any ManagedInstallerProviderOperationLock {
    switch result {
    case .success(let lease): lease
    case .failure: throw ProviderOperationLockTestError.unexpected
    }
}

private func providerLockRelease(
    _ result: Result<Void, ManagedInstallerProviderOperationLockFailure>
) throws {
    if case .failure = result { throw ProviderOperationLockTestError.unexpected }
}

private func providerLockFailure<Value>(
    _ result: Result<Value, ManagedInstallerProviderOperationLockFailure>
) -> ManagedInstallerProviderOperationLockFailure? {
    if case .failure(let failure) = result { return failure }
    return nil
}

private func providerLockRoot() throws -> URL {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-operation-lock-tests", isDirectory: true)
    try providerCreatePrivateDirectory(parent)
    return parent.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
}

private func providerCreatePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try providerSetMode(url, mode_t(0o700))
}

private func providerSetMode(_ url: URL, _ mode: mode_t) throws {
    guard Darwin.chmod(url.path, mode) == 0 else {
        throw ProviderOperationLockTestError.filesystem
    }
}

private func providerMode(_ url: URL) throws -> mode_t {
    var details = stat()
    guard Darwin.lstat(url.path, &details) == 0 else {
        throw ProviderOperationLockTestError.filesystem
    }
    return details.st_mode & mode_t(0o7777)
}
