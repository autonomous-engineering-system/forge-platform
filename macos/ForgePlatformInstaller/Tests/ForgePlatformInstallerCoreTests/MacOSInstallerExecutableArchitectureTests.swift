import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerExecutableArchitectureTests: XCTestCase {
    func testAcceptsOnlyThinARM64MachOExecutableHeaders() {
        XCTAssertTrue(MacOSInstallerExecutableArchitecture.isThinARM64MachOHeader(thinARM64Header()))
        XCTAssertFalse(MacOSInstallerExecutableArchitecture.isThinARM64MachOHeader(x86_64Header()))
        XCTAssertFalse(MacOSInstallerExecutableArchitecture.isThinARM64MachOHeader(fatHeader()))
        XCTAssertFalse(MacOSInstallerExecutableArchitecture.isThinARM64MachOHeader(Data(repeating: 0, count: 31)))
    }

    func testRejectsWrongExecutableArchitectureFromAnActualBundlePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-platform-installer-architecture-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("ForgePlatformInstaller.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleExecutable": "ForgePlatformInstaller",
            "CFBundleIdentifier": "com.example.ForgePlatformInstaller",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1.0.0",
            "LSMinimumSystemVersion": "26.0",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macOS.appendingPathComponent("ForgePlatformInstaller")
        try x86_64Header().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertThrowsError(
            try MacOSInstallerExecutableArchitecture.requireThinARM64Executable(in: bundle)
        )

        let validBundle = root.appendingPathComponent("ValidInstaller.app", isDirectory: true)
        try FileManager.default.copyItem(at: bundle, to: validBundle)
        try thinARM64Header().write(to: validBundle.appendingPathComponent(
            "Contents/MacOS/ForgePlatformInstaller"
        ))
        XCTAssertNoThrow(
            try MacOSInstallerExecutableArchitecture.requireThinARM64Executable(in: validBundle)
        )

        let wrongInfoBundle = root.appendingPathComponent("WrongInfo.app", isDirectory: true)
        try FileManager.default.copyItem(at: validBundle, to: wrongInfoBundle)
        var wrongInfo = info
        wrongInfo["CFBundleExecutable"] = "forge-platform-installer"
        try PropertyListSerialization.data(
            fromPropertyList: wrongInfo, format: .xml, options: 0
        ).write(to: wrongInfoBundle.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(
            try MacOSInstallerExecutableArchitecture.requireThinARM64Executable(in: wrongInfoBundle)
        )

        // Use a separate inode for the positive path so this assertion does
        // not depend on Foundation's Bundle or file-resource caches after the
        // rejected bundle inspection above.
        let validExecutable = root.appendingPathComponent("valid-arm64-executable")
        try thinARM64Header().write(to: validExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: validExecutable.path)
        XCTAssertNoThrow(
            try MacOSInstallerExecutableArchitecture.requireThinARM64Executable(at: validExecutable)
        )
        let alias = root.appendingPathComponent("arm64-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: validExecutable)
        XCTAssertThrowsError(
            try MacOSInstallerExecutableArchitecture.requireThinARM64Executable(at: alias)
        )
    }

    private func thinARM64Header() -> Data {
        Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01, 0, 0, 0, 0, 2, 0, 0, 0] + Array(repeating: 0, count: 16))
    }

    private func x86_64Header() -> Data {
        Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01, 3, 0, 0, 0, 2, 0, 0, 0] + Array(repeating: 0, count: 16))
    }

    private func fatHeader() -> Data {
        Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2] + Array(repeating: 0, count: 24))
    }
}
