import CryptoKit
import Darwin
import Foundation

enum ManagedInstallerProviderRuntimeArchiveExtractionFailure: Error, Equatable {
    case rejected
    case unavailable
}

struct ManagedInstallerProviderRuntimeArchiveExtractionReadback: Equatable {
    let inspection: ManagedInstallerProviderRuntimeArchiveInspection
    let treeEvidenceReference: String
}

/// Extracts an independently re-inspected provider archive into one empty,
/// helper-selected private directory. A complete descriptor-based tree
/// readback compares every file's bytes, mode and path with the archive
/// inventory; a tool exit status alone never establishes READY.
struct MacOSManagedInstallerProviderRuntimeArchiveExtractor {
    private let destination: URL
    private let expectedOwner: uid_t

    init(destination: URL, expectedOwner: uid_t = 0) {
        self.destination = destination
        self.expectedOwner = expectedOwner
    }

    func extract(
        archive: Data,
        requirement: ProviderRequirement,
        inspection: ManagedInstallerProviderRuntimeArchiveInspection
    ) -> Result<ManagedInstallerProviderRuntimeArchiveExtractionReadback,
                ManagedInstallerProviderRuntimeArchiveExtractionFailure> {
        let inventory: ManagedInstallerProviderRuntimeArchiveExtractionInventory
        do {
            inventory = try MacOSManagedInstallerProviderRuntimeArchiveInspector
                .inspectArchiveForExtraction(archive, for: requirement)
            guard inventory.inspection == inspection else {
                return .failure(.rejected)
            }
        } catch { return .failure(.rejected) }

        do {
            let opened = try openEmptyPrivateDestination()
            defer { _ = Darwin.close(opened.descriptor) }
            defer { _ = Darwin.close(opened.parent) }
            let temporary = try writePrivateArchive(archive, in: opened.parent)
            defer { temporary.withCString { _ = Darwin.unlinkat(opened.parent, $0, 0) } }
            let process = Process()
            switch requirement.runtime?.archiveKind {
            case .tarGzip:
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = [
                    "-xzf", opened.parentURL.appendingPathComponent(temporary).path,
                    "-C", destination.path, "--no-same-owner", "--same-permissions",
                    "--no-acls", "--no-fflags", "--no-xattrs", "--no-mac-metadata",
                ]
            case .zip:
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = [
                    "-x", "-k", "--noqtn", "--norsrc",
                    opened.parentURL.appendingPathComponent(temporary).path,
                    destination.path,
                ]
            case nil:
                return .failure(.rejected)
            }
            process.environment = ["LANG": "C", "LC_ALL": "C", "HOME": "/var/empty"]
            process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty", isDirectory: true)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch { return .failure(.unavailable) }
            guard process.terminationReason == .exit,
                  process.terminationStatus == 0,
                  try destinationIsSamePrivateDirectory(opened),
                  Darwin.fsync(opened.descriptor) == 0 else {
                return .failure(.rejected)
            }
            let treeEvidence = try MacOSManagedPythonRuntimeExtractedTreeVerifier(
                slotRoot: destination, expectedOwner: expectedOwner
            ).verify(members: inventory.members)
            guard try destinationIsSamePrivateDirectory(opened) else {
                return .failure(.rejected)
            }
            return .success(ManagedInstallerProviderRuntimeArchiveExtractionReadback(
                inspection: inspection,
                treeEvidenceReference: Self.providerTreeEvidence(
                    treeEvidence, inspection: inspection, requirement: requirement
                )
            ))
        } catch { return .failure(.rejected) }
    }

    private static func providerTreeEvidence(
        _ treeEvidence: String,
        inspection: ManagedInstallerProviderRuntimeArchiveInspection,
        requirement: ProviderRequirement
    ) -> String {
        var material = Data("forge-platform-provider-tree-v1".utf8)
        for value in [
            requirement.id.rawValue,
            inspection.evidenceReference,
            treeEvidence,
        ] {
            var count = UInt64(value.utf8.count).bigEndian
            withUnsafeBytes(of: &count) { material.append(contentsOf: $0) }
            material.append(contentsOf: value.utf8)
        }
        return "receipt:provider-tree-" + SHA256.hash(data: material).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private struct OpenedDestination {
        let descriptor: Int32
        let parent: Int32
        let parentURL: URL
        let name: String
        let device: dev_t
        let inode: ino_t
    }

    private func openEmptyPrivateDestination() throws -> OpenedDestination {
        guard Darwin.geteuid() == expectedOwner,
              destination.isFileURL, destination.baseURL == nil,
              destination.path.hasPrefix("/"), destination.path != "/" else {
            throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
        }
        let parentURL = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
        }
        let parent = parentURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard parent >= 0 else {
            throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
        }
        do {
            _ = try privateDirectory(parent)
            let child = name.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            guard child >= 0 else {
                throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
            }
            do {
                let details = try privateDirectory(child)
                try requireEmpty(child)
                return OpenedDestination(
                    descriptor: child, parent: parent, parentURL: parentURL,
                    name: name, device: details.st_dev, inode: details.st_ino
                )
            } catch {
                _ = Darwin.close(child)
                throw error
            }
        } catch {
            _ = Darwin.close(parent)
            throw error
        }
    }

    private func writePrivateArchive(_ data: Data, in parent: Int32) throws -> String {
        let name = ".provider-archive-" + UUID().uuidString.lowercased()
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                          mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
        }
        var keep = false
        defer {
            _ = Darwin.close(descriptor)
            if !keep { name.withCString { _ = Darwin.unlinkat(parent, $0, 0) } }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset),
                                         bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
                }
                offset += count
            }
        }
        var details = stat()
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              details.st_uid == expectedOwner, details.st_nlink == 1,
              details.st_mode & mode_t(0o7777) == mode_t(0o600),
              details.st_size == off_t(data.count), Darwin.fsync(parent) == 0 else {
            throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
        }
        keep = true
        return name
    }

    private func destinationIsSamePrivateDirectory(_ opened: OpenedDestination) throws -> Bool {
        let current = try privateDirectory(opened.descriptor)
        var entry = stat()
        let status = opened.name.withCString {
            Darwin.fstatat(opened.parent, $0, &entry, AT_SYMLINK_NOFOLLOW)
        }
        return status == 0
            && (entry.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && entry.st_uid == expectedOwner
            && entry.st_mode & mode_t(0o7777) == mode_t(0o700)
            && current.st_dev == opened.device && current.st_ino == opened.inode
            && entry.st_dev == opened.device && entry.st_ino == opened.inode
    }

    private func privateDirectory(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
        }
        return details
    }

    private func requireEmpty(_ descriptor: Int32) throws {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
        }
        guard let directory = Darwin.fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
        }
        defer { _ = Darwin.closedir(directory) }
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else {
                    throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
                }
                return
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                                          capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            guard name == "." || name == ".." else {
                throw ManagedInstallerProviderRuntimeArchiveExtractionFailure.rejected
            }
        }
    }
}
