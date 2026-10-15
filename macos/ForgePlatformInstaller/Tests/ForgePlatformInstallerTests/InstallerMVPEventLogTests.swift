import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstaller
@testable import ForgePlatformInstallerCore

@MainActor
final class InstallerMVPEventLogTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func state() throws -> InstallerWizardState {
        InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
    }

    func testPersistentReportIsPrivateDeduplicatedAndExcludesRawStreams() throws {
        let root = try root()
        let log = InstallerMVPEventLog(directory: root)
        var state = try state()
        state.executionStages = [ExecutionStage(id: "forge-runtime", title: "PRIVATE_TITLE",
            detail: "PRIVATE_STREAM", state: .failed("PRIVATE_ERROR"))]
        let date = Date(timeIntervalSince1970: 0)
        log.record(state: state, choice: .forge, step: .installing, at: date)
        let file = try XCTUnwrap(log.fileURL)
        let first = try Data(contentsOf: file)
        log.record(state: state, choice: .forge, step: .installing, at: date.addingTimeInterval(1))
        XCTAssertEqual(try Data(contentsOf: file), first)
        state.executionStages[0].state = .passed
        log.record(state: state, choice: .forge, step: .done, at: date.addingTimeInterval(2))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("1970-01-01T00:00:00Z"))
        XCTAssertTrue(text.contains("Forge: Mislukt"))
        XCTAssertTrue(text.contains("Forge: Geslaagd"))
        XCTAssertTrue(text.contains("Verstreken tijd: 0:02"))
        XCTAssertFalse(text.contains("PRIVATE"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertFalse(log.unavailable)
    }

    func testChangedInodeOrSymlinkNeverReceivesFurtherReportBytes() throws {
        for symlink in [false, true] {
            let root = try root()
            let log = InstallerMVPEventLog(directory: root)
            var state = try state()
            log.record(state: state, choice: .forge, step: .preparing)
            let file = try XCTUnwrap(log.fileURL)
            let foreign = root.appendingPathComponent("foreign")
            let sentinel = Data("FOREIGN_CONTENT".utf8)
            try sentinel.write(to: foreign)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: foreign.path)
            if symlink {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: foreign)
            } else {
                XCTAssertEqual(Darwin.rename(foreign.path, file.path), 0)
            }
            state.executionStages = [ExecutionStage(id: "forge-runtime", title: "Forge", detail: "", state: .running)]
            log.record(state: state, choice: .forge, step: .installing)
            XCTAssertTrue(log.unavailable)
            XCTAssertNil(log.fileURL)
            XCTAssertEqual(try Data(contentsOf: symlink ? foreign : file), sentinel)
        }
    }

    func testInsecureDirectoryAndNonFileDestinationDisableOnlyLogging() throws {
        let root = try root()
        let insecure = root.appendingPathComponent("insecure")
        try FileManager.default.createDirectory(at: insecure, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        for directory in [insecure, link, URL(string: "https://example.invalid")!] {
            let log = InstallerMVPEventLog(directory: directory)
            log.record(state: try state(), choice: .forge, step: .preparing)
            XCTAssertTrue(log.unavailable)
            XCTAssertNil(log.fileURL)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testReportHasFiniteEventAndByteBounds() throws {
        let log = InstallerMVPEventLog(directory: try root())
        let state = try state()
        for index in 0..<(InstallerMVPEventLog.maximumEvents + 10) {
            log.record(state: state, choice: .forge, step: index.isMultiple(of: 2) ? .preparing : .providers)
        }
        let bytes = try Data(contentsOf: XCTUnwrap(log.fileURL))
        XCTAssertLessThanOrEqual(bytes.count, InstallerMVPEventLog.maximumBytes)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self).components(separatedBy: "Stap: ").count - 1,
                       InstallerMVPEventLog.maximumEvents)
    }
}
