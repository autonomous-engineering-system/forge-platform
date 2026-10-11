import Darwin
import Foundation

/// Evidence of attempted actions, never permission to install or proof of readiness.
/// Installer exit and a recorded readback must still be independently interpreted
/// by the admitted root coordinator. No automatic retry or history retirement.
enum MacOSInstallerHelperPackageEffectPhase: String, Codable, CaseIterable, Sendable {
    case installIntent, installAttempted, installExited, activationAttempted, readbackRecorded
}

struct MacOSInstallerHelperPackageEffectBinding: Codable, Equatable, Sendable {
    let releaseSequence: UInt64
    let packageSHA256: String
    let packageBytes: UInt64
    let clientUID: UInt32
    let sourceRevision: String
    let provenanceSHA256: String
    let trustSHA256: String
    let appCodeDirectorySHA256: String
    init?(release: VerifiedInstallerReleaseRecord, clientUID: uid_t) {
        guard clientUID > 0, let package = release.helperPackage else { return nil }
        releaseSequence = release.sequence; packageSHA256 = package.sha256
        packageBytes = package.bytes; self.clientUID = clientUID
        sourceRevision = release.sourceRevision; provenanceSHA256 = release.provenanceSHA256
        trustSHA256 = release.expectedReleaseTrustConfigurationSHA256
        appCodeDirectorySHA256 = release.expectedCodeDirectorySHA256
    }
    var valid: Bool {
        releaseSequence > 0 && clientUID > 0 && packageBytes > 0 && packageBytes <= 512 * 1024 * 1024
        && InstallerSelfUpdateValidation.isSHA256(packageSHA256)
        && InstallerSelfUpdateValidation.isSHA256(provenanceSHA256)
        && InstallerSelfUpdateValidation.isSHA256(trustSHA256)
        && InstallerSelfUpdateValidation.isSHA256(appCodeDirectorySHA256)
        && (sourceRevision.count == 40 || sourceRevision.count == 64)
        && sourceRevision.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

struct MacOSInstallerHelperPackageEffectSnapshot: Codable, Equatable, Sendable {
    let schema: String
    let attemptID: String
    let binding: MacOSInstallerHelperPackageEffectBinding
    let phase: MacOSInstallerHelperPackageEffectPhase
    let installerExitCode: Int32?
    private var validOutcome: Bool {
        switch phase {
        case .installIntent, .installAttempted: return installerExitCode == nil
        case .installExited: return installerExitCode != nil
        case .activationAttempted, .readbackRecorded: return installerExitCode == 0
        }
    }
    var valid: Bool {
        schema == "forge-platform.helper-package-effects/v1" && binding.valid && validOutcome
        && UUID(uuidString: attemptID)?.uuidString.lowercased() == attemptID
    }
}

enum MacOSInstallerHelperPackageEffectFailure: Error, Equatable {
    case unavailable, corrupt, conflict
}

/// Append-only, root-private write-ahead history. A pending file or partial
/// publication closes admission. There is deliberately no clear/delete API.
struct MacOSInstallerHelperPackageEffectJournal: Sendable {
    private let root: URL
    private let owner: uid_t
    private static let prefix = "helper-package-effect-"
    private static let pending = "helper-package-effect-pending.json"
    private static let lock = "helper-package-effects.lock"
    private static let limit = 8192
    init() { root = BootstrapRuntimeSources.root; owner = 0 }
    // Internal source-test seam, not a CLI/IPC/environment authority selector.
    init(root: URL, owner: uid_t) { self.root = root; self.owner = owner }

    func read() -> Result<[MacOSInstallerHelperPackageEffectSnapshot], MacOSInstallerHelperPackageEffectFailure> {
        transact { try history($0) }
    }
    func begin(_ binding: MacOSInstallerHelperPackageEffectBinding)
        -> Result<MacOSInstallerHelperPackageEffectSnapshot, MacOSInstallerHelperPackageEffectFailure> {
        transact { fd in
            guard binding.valid, try history(fd).isEmpty else { throw Failure.conflict }
            let record = MacOSInstallerHelperPackageEffectSnapshot(schema: "forge-platform.helper-package-effects/v1",
                attemptID: UUID().uuidString.lowercased(), binding: binding, phase: .installIntent, installerExitCode: nil)
            try publish(record, index: 0, rootFD: fd)
            return record
        }
    }
    func append(after expected: MacOSInstallerHelperPackageEffectSnapshot,
                phase: MacOSInstallerHelperPackageEffectPhase, installerExitCode: Int32? = nil)
        -> Result<MacOSInstallerHelperPackageEffectSnapshot, MacOSInstallerHelperPackageEffectFailure> {
        transact { fd in
            let records = try history(fd)
            guard records.last == expected, records.count < MacOSInstallerHelperPackageEffectPhase.allCases.count,
                  MacOSInstallerHelperPackageEffectPhase.allCases[records.count] == phase,
                  phase == .installExited ? installerExitCode != nil : installerExitCode == nil,
                  phase != .activationAttempted || expected.installerExitCode == 0 else { throw Failure.conflict }
            let record = MacOSInstallerHelperPackageEffectSnapshot(schema: expected.schema, attemptID: expected.attemptID,
                binding: expected.binding, phase: phase,
                installerExitCode: phase == .installExited ? installerExitCode : expected.installerExitCode)
            try publish(record, index: records.count, rootFD: fd)
            return record
        }
    }
    private typealias Failure = MacOSInstallerHelperPackageEffectFailure
    private func secure(_ fd: Int32, directory: Bool) -> stat? {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == owner,
              s.st_mode & mode_t(S_IFMT) == (directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)),
              s.st_mode & 0o7777 == (directory ? 0o700 : 0o600), directory || s.st_nlink == 1,
              MacOSInstallerHelperPackageVerifier.noACL(fd) else { return nil }
        return s
    }
    private func sameRoot(_ fd: Int32) -> Bool {
        guard let held = secure(fd, directory: true) else { return false }
        var named = stat()
        return lstat(root.path, &named) == 0 && held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }
    private func transact<T>(_ body: (Int32) throws -> T) -> Result<T, Failure> {
        guard geteuid() == owner, root.isFileURL, root.baseURL == nil else { return .failure(.unavailable) }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { return .failure(.unavailable) }
        defer { _ = close(fd) }
        guard sameRoot(fd) else { return .failure(.unavailable) }
        let lockFD = openat(fd, Self.lock, O_RDWR | O_CREAT | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { return .failure(.unavailable) }
        defer { _ = close(lockFD) }
        guard secure(lockFD, directory: false) != nil, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return .failure(.unavailable) }
        defer { _ = flock(lockFD, LOCK_UN) }
        do {
            let result = try body(fd)
            guard sameRoot(fd) else { return .failure(.unavailable) }
            return .success(result)
        } catch let failure as Failure { return .failure(failure) }
        catch { return .failure(.unavailable) }
    }
    private func name(_ index: Int) -> String { Self.prefix + String(index) + ".json" }
    private func history(_ fd: Int32) throws -> [MacOSInstallerHelperPackageEffectSnapshot] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let selected = names.filter { $0.hasPrefix(Self.prefix) }
        let expected = (0..<MacOSInstallerHelperPackageEffectPhase.allCases.count).map(name)
        guard selected.allSatisfy({ expected.contains($0) }) else { throw Failure.corrupt }
        var result: [MacOSInstallerHelperPackageEffectSnapshot] = []
        for (index, phase) in MacOSInstallerHelperPackageEffectPhase.allCases.enumerated() {
            guard selected.contains(name(index)) else {
                guard selected.count == result.count else { throw Failure.corrupt }
                break
            }
            let record = try readRecord(name(index), rootFD: fd)
            guard record.phase == phase,
                  result.first.map({ $0.attemptID == record.attemptID && $0.binding == record.binding }) ?? true,
                  result.last.map({ previous in
                      if phase == .installExited { return previous.installerExitCode == nil }
                      if phase == .activationAttempted || phase == .readbackRecorded {
                          return previous.installerExitCode == 0 && record.installerExitCode == previous.installerExitCode
                      }
                      return record.installerExitCode == previous.installerExitCode
                  }) ?? true else { throw Failure.corrupt }
            result.append(record)
        }
        return result
    }
    private func encode(_ record: MacOSInstallerHelperPackageEffectSnapshot) throws -> Data {
        guard record.valid else { throw Failure.corrupt }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard !data.isEmpty, data.count <= Self.limit else { throw Failure.corrupt }
        return data
    }
    private func readRecord(_ name: String, rootFD: Int32) throws -> MacOSInstallerHelperPackageEffectSnapshot {
        let fd = openat(rootFD, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.corrupt }
        defer { _ = close(fd) }
        guard let before = secure(fd, directory: false), before.st_size > 0, before.st_size <= Self.limit else { throw Failure.corrupt }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: Self.limit + 1), data.count == before.st_size,
              let after = secure(fd, directory: false), MacOSInstallerHelperPackageVerifier.same(before, after) else { throw Failure.corrupt }
        var named = stat()
        guard fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              MacOSInstallerHelperPackageVerifier.same(before, named),
              let record = try? JSONDecoder().decode(MacOSInstallerHelperPackageEffectSnapshot.self, from: data),
              try encode(record) == data else { throw Failure.corrupt }
        return record
    }
    private func publish(_ record: MacOSInstallerHelperPackageEffectSnapshot, index: Int, rootFD: Int32) throws {
        let data = try encode(record)
        let fd = openat(rootFD, Self.pending, O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.conflict }
        defer { _ = close(fd) }
        // On failure this pending file is deliberately retained, not retried or
        // unlinked. A caller must treat unacknowledged publication as unresolved.
        guard secure(fd, directory: false) != nil else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0, sameRoot(rootFD),
              linkat(rootFD, Self.pending, rootFD, name(index), 0) == 0 else { throw Failure.unavailable }
        guard unlinkat(rootFD, Self.pending, 0) == 0, fsync(rootFD) == 0,
              try readRecord(name(index), rootFD: rootFD) == record else { throw Failure.unavailable }
    }
}
