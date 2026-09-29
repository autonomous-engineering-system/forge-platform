import Darwin
import Foundation

enum ManagedPythonRuntimeArchiveExtractionFailure: Error, Equatable {
    case rejected
    case unavailable
}

struct ManagedPythonRuntimeArchiveExtractionReadback: Equatable {
    let inspection: ManagedPythonRuntimeArchiveInspection
    let treeEvidenceReference: String
}

/// Extracts only a re-inspected, exact approved archive into a previously
/// created empty helper-owned private slot directory. The destination is
/// constructor-owned; no XPC request supplies a filesystem path or command.
struct MacOSManagedPythonRuntimeArchiveExtractor {
    private let destination: URL
    private let expectedOwner: uid_t
    private let evidenceDomain: ManagedArchiveTreeEvidenceDomain

    init(
        destination: URL,
        expectedOwner: uid_t = 0,
        evidenceDomain: ManagedArchiveTreeEvidenceDomain = .python
    ) {
        self.destination = destination
        self.expectedOwner = expectedOwner
        self.evidenceDomain = evidenceDomain
    }

    func extract(
        archive: Data,
        runtime: ManagedPythonRuntimeIdentity
    ) -> Result<ManagedPythonRuntimeArchiveExtractionReadback,
                ManagedPythonRuntimeArchiveExtractionFailure> {
        let inventory: ManagedPythonRuntimeArchiveExtractionInventory
        do {
            inventory = try MacOSManagedPythonRuntimeArchiveInspector
                .inspectArchiveForExtraction(archive, for: runtime)
        } catch {
            return .failure(.rejected)
        }
        switch materialize(archive: archive, members: inventory.members) {
        case .success(let treeEvidence):
            return .success(ManagedPythonRuntimeArchiveExtractionReadback(
                inspection: inventory.inspection,
                treeEvidenceReference: treeEvidence
            ))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Materializes only a previously admitted inventory in one empty private
    /// directory. Both Python and managed Git use this same descriptor-bound
    /// extractor and complete post-extraction tree verifier.
    func materialize(
        archive: Data,
        members: [ManagedPythonRuntimeArchiveMember]
    ) -> Result<String, ManagedPythonRuntimeArchiveExtractionFailure> {
        do {
            let directory = try openEmptyPrivateDestination()
            defer { _ = Darwin.close(directory.descriptor) }
            defer { _ = Darwin.close(directory.parent) }
            let process = Process()
            let input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = [
                "-xzf", "-", "-C", destination.path,
                "--no-same-owner", "--same-permissions", "--no-acls",
                "--no-fflags", "--no-xattrs", "--no-mac-metadata",
            ]
            process.environment = ["LANG": "C", "LC_ALL": "C", "HOME": "/var/empty"]
            process.currentDirectoryURL = URL(
                fileURLWithPath: "/var/empty", isDirectory: true
            )
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: archive)
                try input.fileHandleForWriting.close()
                process.waitUntilExit()
            } catch {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                return .failure(.unavailable)
            }
            guard process.terminationReason == .exit,
                  process.terminationStatus == 0,
                  try destinationIsSamePrivateDirectory(directory),
                  Darwin.fsync(directory.descriptor) == 0 else {
                return .failure(.rejected)
            }
            let treeEvidence = try MacOSManagedPythonRuntimeExtractedTreeVerifier(
                slotRoot: destination, expectedOwner: expectedOwner,
                evidenceDomain: evidenceDomain
            ).verify(members: members)
            guard try destinationIsSamePrivateDirectory(directory) else {
                return .failure(.rejected)
            }
            return .success(treeEvidence)
        } catch {
            return .failure(.rejected)
        }
    }

    private struct OpenedDestination {
        let descriptor: Int32
        let parent: Int32
        let name: String
        let device: dev_t
        let inode: ino_t
    }

    private func openEmptyPrivateDestination() throws -> OpenedDestination {
        guard Darwin.geteuid() == expectedOwner,
              destination.isFileURL, destination.baseURL == nil,
              destination.path.hasPrefix("/"), destination.path != "/" else {
            throw ManagedPythonRuntimeArchiveExtractionFailure.rejected
        }
        let parentURL = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw ManagedPythonRuntimeArchiveExtractionFailure.rejected
        }
        let parent = parentURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard parent >= 0 else { throw ManagedPythonRuntimeArchiveExtractionFailure.rejected }
        do {
            _ = try privateDirectory(parent)
            let child = name.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            guard child >= 0 else {
                throw ManagedPythonRuntimeArchiveExtractionFailure.rejected
            }
            do {
                let details = try privateDirectory(child)
                try requireEmpty(child)
                return OpenedDestination(
                    descriptor: child, parent: parent, name: name,
                    device: details.st_dev, inode: details.st_ino
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

    private func destinationIsSamePrivateDirectory(
        _ opened: OpenedDestination
    ) throws -> Bool {
        let current = try privateDirectory(opened.descriptor)
        var entry = stat()
        let status = opened.name.withCString {
            Darwin.fstatat(opened.parent, $0, &entry, AT_SYMLINK_NOFOLLOW)
        }
        return status == 0
            && (entry.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && entry.st_uid == expectedOwner
            && entry.st_mode & mode_t(0o7777) == mode_t(0o700)
            && current.st_dev == opened.device
            && current.st_ino == opened.inode
            && entry.st_dev == opened.device
            && entry.st_ino == opened.inode
    }

    private func privateDirectory(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ManagedPythonRuntimeArchiveExtractionFailure.rejected
        }
        return details
    }

    private func requireEmpty(_ descriptor: Int32) throws {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw ManagedPythonRuntimeArchiveExtractionFailure.rejected }
        guard let directory = fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            throw ManagedPythonRuntimeArchiveExtractionFailure.rejected
        }
        defer { _ = closedir(directory) }
        rewinddir(directory)
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else {
                    throw ManagedPythonRuntimeArchiveExtractionFailure.rejected
                }
                return
            }
            var storage = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: storage)
            let name = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(validatingCString: $0)
                }
            }
            guard name == "." || name == ".." else {
                throw ManagedPythonRuntimeArchiveExtractionFailure.rejected
            }
        }
    }
}
