import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerManagedGitArchiveExtractionTests: XCTestCase {
    func testExtractsExactGitTreeAndVerifiesEveryMaterializedMember() throws {
        let fixture = try GitArchiveFixture()
        let (root, destination) = try privateDestination()
        defer { try? FileManager.default.removeItem(at: root) }
        let extractor = MacOSManagedInstallerManagedGitArchiveExtractor(
            destination: destination, expectedOwner: geteuid()
        )

        let extracted = try success(extractor.extract(
            archive: fixture.archive, requirement: fixture.requirement
        ))
        XCTAssertEqual(extracted.inspection.archiveSHA256,
                       fixture.requirement.artifact.sha256)
        XCTAssertTrue(extracted.treeEvidenceReference.hasPrefix("receipt:managed-git-tree-"))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("bin/git")),
                       archiveMachO(mutation: nil))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(
                "libexec/git-core/git-remote-https"
            ).path
        ))
        XCTAssertEqual(failure(extractor.extract(
            archive: fixture.archive, requirement: fixture.requirement
        )), .rejected)
    }

    func testRejectsArchiveDriftBeforeCreatingFiles() throws {
        let fixture = try GitArchiveFixture()
        let (root, destination) = try privateDestination()
        defer { try? FileManager.default.removeItem(at: root) }
        var drifted = fixture.archive
        drifted[drifted.count - 9] ^= 1
        let extractor = MacOSManagedInstallerManagedGitArchiveExtractor(
            destination: destination, expectedOwner: geteuid()
        )

        XCTAssertEqual(failure(extractor.extract(
            archive: drifted, requirement: fixture.requirement
        )), .rejected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testRejectsNonemptyInsecureAndSymlinkedDestination() throws {
        let fixture = try GitArchiveFixture()
        for scenario in 0..<3 {
            let (root, destination) = try privateDestination()
            defer { try? FileManager.default.removeItem(at: root) }
            if scenario == 0 {
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: destination.appendingPathComponent("existing").path,
                    contents: Data([1])
                ))
            } else if scenario == 1 {
                XCTAssertEqual(chmod(destination.path, 0o755), 0)
            } else {
                try FileManager.default.removeItem(at: destination)
                let target = root.appendingPathComponent("actual", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                try FileManager.default.createSymbolicLink(
                    at: destination, withDestinationURL: target
                )
            }
            let extractor = MacOSManagedInstallerManagedGitArchiveExtractor(
                destination: destination, expectedOwner: geteuid()
            )
            XCTAssertEqual(failure(extractor.extract(
                archive: fixture.archive, requirement: fixture.requirement
            )), .rejected)
        }
    }

    private func privateDestination() throws -> (URL, URL) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "managed-git-archive-extraction-\(UUID().uuidString)", isDirectory: true
        )
        let destination = root.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertEqual(chmod(destination.path, 0o700), 0)
        return (root, destination)
    }

    private func success(
        _ result: Result<ManagedInstallerManagedGitArchiveExtractionReadback,
                       ManagedInstallerManagedGitArchiveExtractionFailure>
    ) throws -> ManagedInstallerManagedGitArchiveExtractionReadback {
        switch result {
        case .success(let readback): return readback
        case .failure(let failure): throw failure
        }
    }

    private func failure<T>(
        _ result: Result<T, ManagedInstallerManagedGitArchiveExtractionFailure>
    ) -> ManagedInstallerManagedGitArchiveExtractionFailure? {
        guard case .failure(let failure) = result else { return nil }
        return failure
    }
}
