import CryptoKit
import Darwin
import Foundation

enum ManagedPythonRuntimeExtractedTreeFailure: Error, Equatable {
    case rejected
}

enum ManagedArchiveTreeEvidenceDomain: Sendable {
    case python
    case git

    var referencePrefix: String {
        switch self {
        case .python: "receipt:managed-python-tree-v2-"
        case .git: "receipt:managed-git-tree-v2-"
        }
    }
}

/// Independently reopens an extracted runtime tree below one helper-selected
/// private slot. No path from an XPC request is accepted: member names come
/// only from the exact archive inventory and are checked again before use.
struct MacOSManagedPythonRuntimeExtractedTreeVerifier {
    private let slotRoot: URL
    private let expectedOwner: uid_t
    private let evidenceDomain: ManagedArchiveTreeEvidenceDomain

    init(
        slotRoot: URL,
        expectedOwner: uid_t = 0,
        evidenceDomain: ManagedArchiveTreeEvidenceDomain = .python
    ) {
        self.slotRoot = slotRoot
        self.expectedOwner = expectedOwner
        self.evidenceDomain = evidenceDomain
    }

    func verify(
        members: [ManagedPythonRuntimeArchiveMember]
    ) throws -> String {
        try verifyExact(members: members, bytecodeCachesForPreservation: [])
    }

    /// Preparation only. This route never returns installed/runtime evidence;
    /// its caller must preserve the caches and then run ordinary exact verify.
    func verifyBeforeBytecodePreservation(
        members: [ManagedPythonRuntimeArchiveMember], caches: Set<String>
    ) throws {
        _ = try verifyExact(members: members, bytecodeCachesForPreservation: caches)
    }

    private func verifyExact(
        members: [ManagedPythonRuntimeArchiveMember], bytecodeCachesForPreservation: Set<String>
    ) throws -> String {
        let children = try expectedChildren(members)
        guard slotRoot.isFileURL, slotRoot.baseURL == nil,
              slotRoot.path.hasPrefix("/"), slotRoot.path != "/" else {
            throw ManagedPythonRuntimeExtractedTreeFailure.rejected
        }
        let root = slotRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
        defer { _ = Darwin.close(root) }
        let rootDetails = try secureDirectory(root, mode: 0o700)
        try requireEntries(in: root, equal: (children[""] ?? []).union(
            bytecodeCachesForPreservation.contains("__pycache__/") ? ["__pycache__"] : []))

        var binding = SHA256()
        // st_dev is a boot-local device number on macOS. A restart can change
        // it while this exact directory and every archive member remain the
        // same. Bind the fixed path and inode instead; the complete tree is
        // independently reopened and hashed below.
        append(slotRoot.path, to: &binding)
        append(String(UInt64(rootDetails.st_ino)), to: &binding)
        for member in members {
            let parent = try openParent(of: member.path, in: root)
            defer { if parent != root { _ = Darwin.close(parent) } }
            let name = lastName(member.path)
            let descriptor = name.withCString {
                Darwin.openat(
                    parent, $0,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
                        | (member.kind == .directory ? O_DIRECTORY : 0)
                )
            }
            guard descriptor >= 0 else {
                throw ManagedPythonRuntimeExtractedTreeFailure.rejected
            }
            defer { _ = Darwin.close(descriptor) }
            switch member.kind {
            case .directory:
                _ = try secureDirectory(descriptor, mode: member.mode)
                try requireEntries(in: descriptor, equal: (children[member.path] ?? []).union(
                    bytecodeCachesForPreservation.contains(member.path + "__pycache__/") ? ["__pycache__"] : []))
            case .file:
                try secureFile(descriptor, matches: member)
            }
            append(member.path, to: &binding)
            append(member.kind == .directory ? "directory" : "file", to: &binding)
            append(String(member.mode), to: &binding)
            append(String(member.byteCount), to: &binding)
            append(member.sha256 ?? "", to: &binding)
        }
        try requireEntries(in: root, equal: (children[""] ?? []).union(
            bytecodeCachesForPreservation.contains("__pycache__/") ? ["__pycache__"] : []))
        let digest = binding.finalize().map { String(format: "%02x", $0) }.joined()
        return evidenceDomain.referencePrefix + digest
    }

    private func expectedChildren(
        _ members: [ManagedPythonRuntimeArchiveMember]
    ) throws -> [String: Set<String>] {
        guard !members.isEmpty,
              members.count <= MacOSManagedPythonRuntimeArchiveInspector.maximumArchiveEntries
        else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
        var children: [String: Set<String>] = [:]
        var directories = Set<String>()
        var paths = Set<String>()
        for member in members {
            let path = member.path
            let isDirectory = member.kind == .directory
            let bare = isDirectory ? String(path.dropLast()) : path
            let parts = bare.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, path.utf8.count <= 1_024,
                  !path.hasPrefix("/"), !path.contains("\\"),
                  path.hasSuffix("/") == isDirectory,
                  !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  paths.insert(path).inserted,
                  member.mode <= 0o777,
                  member.mode & 0o022 == 0 else {
                throw ManagedPythonRuntimeExtractedTreeFailure.rejected
            }
            let parent = parts.count == 1
                ? "" : parts.dropLast().joined(separator: "/") + "/"
            guard parent.isEmpty || directories.contains(parent) else {
                throw ManagedPythonRuntimeExtractedTreeFailure.rejected
            }
            if isDirectory {
                guard member.mode & 0o500 == 0o500,
                      member.byteCount == 0, member.sha256 == nil else {
                    throw ManagedPythonRuntimeExtractedTreeFailure.rejected
                }
                directories.insert(path)
            } else {
                guard member.mode & 0o400 != 0,
                      let digest = member.sha256,
                      CompositionCatalogValidation.isTaggedSHA256(digest) else {
                    throw ManagedPythonRuntimeExtractedTreeFailure.rejected
                }
            }
            children[parent, default: []].insert(String(parts.last!))
        }
        return children
    }

    private func openParent(of path: String, in root: Int32) throws -> Int32 {
        let bare = path.hasSuffix("/") ? String(path.dropLast()) : path
        let names = bare.split(separator: "/").dropLast()
        var parent = root
        for name in names {
            let child = String(name).withCString {
                Darwin.openat(
                    parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
                )
            }
            if parent != root { _ = Darwin.close(parent) }
            guard child >= 0 else {
                throw ManagedPythonRuntimeExtractedTreeFailure.rejected
            }
            parent = child
        }
        return parent
    }

    private func lastName(_ path: String) -> String {
        let bare = path.hasSuffix("/") ? String(path.dropLast()) : path
        return String(bare.split(separator: "/").last!)
    }

    private func secureDirectory(_ descriptor: Int32, mode: UInt16) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(mode) else {
            throw ManagedPythonRuntimeExtractedTreeFailure.rejected
        }
        return details
    }

    private func secureFile(
        _ descriptor: Int32,
        matches member: ManagedPythonRuntimeArchiveMember
    ) throws {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == expectedOwner,
              before.st_nlink == 1,
              before.st_mode & mode_t(0o7777) == mode_t(member.mode),
              before.st_size == off_t(member.byteCount),
              member.byteCount <= MacOSManagedPythonRuntimeArchiveInspector
                .maximumExpandedArchiveBytes else {
            throw ManagedPythonRuntimeExtractedTreeFailure.rejected
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var count: UInt64 = 0
        while true {
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount >= 0 else {
                throw ManagedPythonRuntimeExtractedTreeFailure.rejected
            }
            if readCount == 0 { break }
            count += UInt64(readCount)
            guard count <= member.byteCount else {
                throw ManagedPythonRuntimeExtractedTreeFailure.rejected
            }
            hasher.update(data: buffer.prefix(readCount))
        }
        var after = stat()
        guard count == member.byteCount,
              Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              member.sha256 == "sha256:" + hasher.finalize().map({
                  String(format: "%02x", $0)
              }).joined() else {
            throw ManagedPythonRuntimeExtractedTreeFailure.rejected
        }
    }

    private func requireEntries(in descriptor: Int32, equal expected: Set<String>) throws {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
        guard let directory = fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            throw ManagedPythonRuntimeExtractedTreeFailure.rejected
        }
        defer { _ = closedir(directory) }
        rewinddir(directory)
        var observed = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else {
                    throw ManagedPythonRuntimeExtractedTreeFailure.rejected
                }
                break
            }
            var storage = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: storage)
            let name = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
            if name == "." || name == ".." { continue }
            guard observed.insert(name).inserted, observed.count <= expected.count else {
                throw ManagedPythonRuntimeExtractedTreeFailure.rejected
            }
        }
        guard observed == expected else {
            throw ManagedPythonRuntimeExtractedTreeFailure.rejected
        }
    }

    private func append(_ value: String, to hash: inout SHA256) {
        var length = UInt64(value.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { hash.update(data: $0) }
        hash.update(data: Data(value.utf8))
    }
}
