import Darwin
import Foundation

/// Read-only admission for the exact executable inside a staged or current
/// installer bundle.  Fat/universal containers are rejected even when they
/// contain an arm64 slice: the release contract is arm64-only bytes.
enum MacOSInstallerExecutableArchitecture {
    private static let headerByteCount = 32
    private static let expectedMagic: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe]
    private static let expectedCPUType: [UInt8] = [0x0c, 0x00, 0x00, 0x01]
    private static let executableFileType: [UInt8] = [0x02, 0x00, 0x00, 0x00]

    static func requireThinARM64Executable(in bundleURL: URL) throws {
        guard bundleURL.isFileURL,
              let bundle = Bundle(url: bundleURL),
              bundle.infoDictionary?["CFBundleExecutable"] as? String ==
                "ForgePlatformInstaller" else {
            throw MacOSInstallerExecutableArchitectureError.invalidBundleExecutable
        }
        // Foundation's `executableURL` points at the *running* CLI when it is
        // the second executable in this app. The sealed Info.plist instead
        // identifies the one fixed GUI executable covered by this contract.
        let executableURL = bundleURL.appendingPathComponent(
            "Contents/MacOS/ForgePlatformInstaller", isDirectory: false
        )
        try requireThinARM64Executable(at: executableURL)
    }

    static func requireThinARM64Executable(at executableURL: URL) throws {
        var before = stat()
        guard executableURL.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return -1 }
            return Darwin.lstat(path, &before)
        }) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (before.st_mode & mode_t(S_IXUSR)) != 0 else {
            throw MacOSInstallerExecutableArchitectureError.invalidFile
        }

        let descriptor = executableURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw MacOSInstallerExecutableArchitectureError.unreadableFile
        }
        defer { Darwin.close(descriptor) }

        var header = [UInt8](repeating: 0, count: headerByteCount)
        let readCount = header.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, headerByteCount)
        }
        var after = stat()
        guard readCount == headerByteCount,
              Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw MacOSInstallerExecutableArchitectureError.unstableFile
        }
        guard isThinARM64MachOHeader(Data(header)) else {
            throw MacOSInstallerExecutableArchitectureError.wrongArchitecture
        }
    }

    static func isThinARM64MachOHeader(_ data: Data) -> Bool {
        guard data.count >= headerByteCount else {
            return false
        }
        let bytes = [UInt8](data.prefix(headerByteCount))
        return Array(bytes[0..<4]) == expectedMagic
            && Array(bytes[4..<8]) == expectedCPUType
            && Array(bytes[12..<16]) == executableFileType
    }
}

private enum MacOSInstallerExecutableArchitectureError: Error {
    case invalidBundleExecutable
    case invalidFile
    case unreadableFile
    case unstableFile
    case wrongArchitecture
}
