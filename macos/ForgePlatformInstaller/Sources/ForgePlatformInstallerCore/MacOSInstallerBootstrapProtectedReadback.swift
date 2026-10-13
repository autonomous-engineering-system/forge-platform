import Darwin
import Foundation

/// Fixed production callers select roots; qualification seams do not appear on
/// CLI/IPC. Reads are descriptor-relative and repeat full directory profiles.
enum MacOSInstallerBootstrapProtectedReadback {
    private typealias Failure = MacOSInstallerHelperPackageEffectFailure
    private static func profile(_ fd: Int32, directory: Bool, owner: uid_t) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == owner, value.st_flags == 0,
              value.st_mode & mode_t(S_IFMT) == (directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)),
              value.st_mode & 0o7777 == (directory ? 0o700 : 0o600), directory || value.st_nlink == 1,
              MacOSInstallerHelperPackageVerifier.noACL(fd) else { throw Failure.unavailable }
        return value
    }
    static func readFile(_ url: URL, owner: uid_t = 0) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unavailable }; defer { close(fd) }
        let before = try profile(fd, directory: false, owner: owner)
        let data = try readHeld(fd, before: before, owner: owner)
        var named = stat()
        guard lstat(url.path, &named) == 0, MacOSInstallerHelperPackageVerifier.same(before, named) else { throw Failure.unavailable }
        return data
    }
    private static func readHeld(_ fd: Int32, before: stat, owner: uid_t) throws -> Data {
        guard before.st_size > 0, before.st_size <= 131072,
              let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 131073), data.count == before.st_size,
              MacOSInstallerHelperPackageVerifier.same(before, try profile(fd, directory: false, owner: owner)) else { throw Failure.unavailable }
        return data
    }
    private static func names(_ fd: Int32) throws -> Set<String> {
        let copy = dup(fd)
        guard copy >= 0 else { throw Failure.unavailable }
        guard let directory = fdopendir(copy) else { close(copy); throw Failure.unavailable }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: Set<String> = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.insert(name) }
            guard result.count <= 2 else { throw Failure.unavailable }
            errno = 0
        }
        guard errno == 0 else { throw Failure.unavailable }
        return result
    }
    static func readFloors(directories: [URL], legacyAnchor: URL, owner: uid_t = 0, beforeFinalCheck: @Sendable (URL) throws -> Void = { _ in }) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for url in directories {
            let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.unavailable }; defer { close(fd) }
            let before = try profile(fd, directory: true, owner: owner)
            let selected = try names(fd)
            guard selected.contains("highest-accepted-installer-release.json"),
                  selected.isSubset(of: ["highest-accepted-installer-release.json", "legacy-release-acceptance-preserved.json"]) else { throw Failure.unavailable }
            for name in selected {
                let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard file >= 0 else { throw Failure.unavailable }; defer { close(file) }
                let beforeFile = try profile(file, directory: false, owner: owner)
                let data = try readHeld(file, before: beforeFile, owner: owner)
                var named = stat()
                guard fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      MacOSInstallerHelperPackageVerifier.same(beforeFile, named) else { throw Failure.unavailable }
                result[url.appendingPathComponent(name).path] = data
            }
            try beforeFinalCheck(url)
            var named = stat()
            guard selected == (try names(fd)), lstat(url.path, &named) == 0,
                  MacOSInstallerHelperPackageVerifier.same(before, try profile(fd, directory: true, owner: owner)),
                  MacOSInstallerHelperPackageVerifier.same(before, named) else { throw Failure.unavailable }
        }
        result[legacyAnchor.path] = try readFile(legacyAnchor, owner: owner)
        return result
    }
    static func permitsNormalCurrentAcceptance(before: [String: Data], after: [String: Data],
        advancingAnchors: Set<String>, currentSequence: UInt64) throws -> Bool {
        guard Set(before.keys) == Set(after.keys), advancingAnchors.count == 2,
              advancingAnchors.isSubset(of: Set(before.keys)) else { return false }
        for (key, oldBytes) in before {
            guard let newBytes = after[key] else { return false }
            if !advancingAnchors.contains(key) { guard oldBytes == newBytes else { return false }; continue }
            let old = try JSONDecoder().decode(InstallerReleaseAcceptance.self, from: oldBytes)
            let new = try JSONDecoder().decode(InstallerReleaseAcceptance.self, from: newBytes)
            _ = try InstallerReleaseAcceptance(sequence: old.sequence, descriptorSHA256: old.descriptorSHA256)
            _ = try InstallerReleaseAcceptance(sequence: new.sequence, descriptorSHA256: new.descriptorSHA256)
            guard new.sequence == currentSequence, new.sequence >= old.sequence,
                  new.sequence != old.sequence || new.descriptorSHA256 == old.descriptorSHA256 else { return false }
        }
        return true
    }
}
