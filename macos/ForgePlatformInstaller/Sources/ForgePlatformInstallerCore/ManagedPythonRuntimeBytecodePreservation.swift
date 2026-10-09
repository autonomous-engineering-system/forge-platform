import CryptoKit
import Darwin
import Foundation

/// Derived bytecode is never an admitted member of a sealed runtime. Preserve
/// it outside the slot only after every archive member passes its unchanged
/// exact verifier. No Python process is started and no bytecode is executed.
struct MacOSManagedPythonRuntimeBytecodePreserver {
    let slotRoot: URL
    let expectedOwner: uid_t
    private struct Cache {
        let relative: String
        let parent: Int32
        let descriptor: Int32
        let inode: ino_t
        let names: Set<String>
    }
    func preserve(members: [ManagedPythonRuntimeArchiveMember], version: InstallerVersion) throws {
        guard geteuid() == expectedOwner,
              ManagedInstallerHelperChildExitRegistry.processWide.activeCount() == 0 else {
            throw ManagedPythonRuntimeExtractedTreeFailure.rejected
        }
        let container = open(slotRoot.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard container >= 0 else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
        defer { close(container) }
        var details = stat()
        guard fstat(container, &details) == 0, details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ManagedPythonRuntimeExtractedTreeFailure.rejected
        }
        let lock = openat(container, ".bytecode-preservation.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
        defer { close(lock) }
        guard fstat(lock, &details) == 0, details.st_uid == expectedOwner, details.st_nlink == 1,
              details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              details.st_mode & mode_t(0o7777) == mode_t(0o600), flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw ManagedPythonRuntimeExtractedTreeFailure.rejected
        }
        defer { flock(lock, LOCK_UN) }
        var caches: [Cache] = []
        defer { for cache in caches { close(cache.descriptor); close(cache.parent) } }
        let directories = [""] + members.filter { $0.kind == .directory }.map(\.path)
        let sourceFiles = Set(members.filter { $0.kind == .file && $0.path.hasSuffix(".py") }.map(\.path))
        let archivePaths = Set(members.map(\.path))
        let marker = ".cpython-\(version.major)\(version.minor)"
        for directory in directories {
            let relative = directory + "__pycache__/"
            // A cache shipped in the signed archive stays a strict member.
            if archivePaths.contains(relative) { continue }
            let parent = open(slotRoot.appendingPathComponent(directory).path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard parent >= 0 else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
            let descriptor = openat(parent, "__pycache__", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if descriptor < 0 {
                let error = errno; close(parent)
                guard error == ENOENT else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
                continue
            }
            do {
                guard fstat(descriptor, &details) == 0, details.st_uid == expectedOwner,
                      details.st_mode & mode_t(0o7777) == mode_t(0o755) else {
                    throw ManagedPythonRuntimeExtractedTreeFailure.rejected
                }
                let inode = details.st_ino
                let names = try entries(descriptor)
                guard !names.isEmpty, names.count <= 4096 else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
                for name in names {
                    let suffixes = [marker + ".pyc", marker + ".opt-1.pyc", marker + ".opt-2.pyc"]
                    guard let suffix = suffixes.first(where: { name.hasSuffix($0) }),
                          sourceFiles.contains(directory + String(name.dropLast(suffix.count)) + ".py") else {
                        throw ManagedPythonRuntimeExtractedTreeFailure.rejected
                    }
                    let file = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                    guard file >= 0 else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
                    let safe = fstat(file, &details) == 0 && details.st_uid == expectedOwner && details.st_nlink == 1
                        && details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                        && details.st_mode & mode_t(0o7777) == mode_t(0o644) && details.st_size > 16
                    close(file)
                    guard safe else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
                }
                caches.append(Cache(relative: relative, parent: parent, descriptor: descriptor, inode: inode, names: names))
            } catch { close(descriptor); close(parent); throw error }
        }
        guard !caches.isEmpty else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
        try MacOSManagedPythonRuntimeExtractedTreeVerifier(slotRoot: slotRoot, expectedOwner: expectedOwner)
            .verifyBeforeBytecodePreservation(members: members, caches: Set(caches.map(\.relative)))
        guard ManagedInstallerHelperChildExitRegistry.processWide.activeCount() == 0 else {
            throw ManagedPythonRuntimeExtractedTreeFailure.rejected
        }
        let backupName = "bytecode-preserved-" + UUID().uuidString.lowercased()
        guard mkdirat(container, backupName, 0o700) == 0 else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
        let backup = openat(container, backupName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard backup >= 0 else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
        defer { close(backup) }
        let mapping = caches.map { ["original": $0.relative, "preserved": digest($0.relative)] }
        let data = try JSONSerialization.data(withJSONObject: mapping, options: [.sortedKeys])
        let record = openat(backup, "record.json", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard record >= 0 else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
        let file = FileHandle(fileDescriptor: record, closeOnDealloc: true)
        try file.write(contentsOf: data); try file.synchronize(); try file.close()
        for cache in caches {
            guard try entries(cache.descriptor) == cache.names,
                  fstatat(cache.parent, "__pycache__", &details, AT_SYMLINK_NOFOLLOW) == 0,
                  details.st_ino == cache.inode,
                  renameatx_np(cache.parent, "__pycache__", backup, digest(cache.relative), UInt32(RENAME_EXCL)) == 0,
                  fsync(cache.parent) == 0, fsync(backup) == 0 else {
                throw ManagedPythonRuntimeExtractedTreeFailure.rejected
            }
        }
        guard fsync(container) == 0 else { throw ManagedPythonRuntimeExtractedTreeFailure.rejected }
    }
    private func digest(_ path: String) -> String { SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func entries(_ descriptor: Int32) throws -> Set<String> {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw ManagedPythonRuntimeExtractedTreeFailure.rejected
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var result = Set<String>()
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.insert(name) }
        }
        return result
    }
}
