import CryptoKit
import Darwin
import Foundation

struct ManagedInstallerHistoricalEvidenceBundle: Equatable, Sendable {
    let parent: ManagedPythonRuntimeParentJournalRecord
    let selection: ManagedInstallerReviewedSelection
    let originalRouteBytes: Data
    let originalAuthorityBytes: Data
    let originalOperatorBytes: Data
    let sha256ByRole: [String: String]
}

/// Reads only fixed original helper evidence. It creates no locks, files,
/// directories or staging state. Raw bytes stay private inside the helper;
/// this bundle is neither an IPC response nor a mutation permit.
struct FileManagedInstallerHistoricalEvidenceReader: Sendable {
    private let root: URL
    private let expectedOwner: uid_t
    private let rootValidator: ManagedInstallerHelperReleaseAcceptanceStore
    init(root: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot,
         expectedOwner: uid_t = 0,
         cohort: (any ManagedInstallerHelperReleaseAcceptanceCohortReading)? = nil) {
        self.root = root; self.expectedOwner = expectedOwner
        rootValidator = .init(root: root, expectedOwner: expectedOwner, cohort: cohort)
    }

    func read() throws -> ManagedInstallerHistoricalEvidenceBundle {
        guard root.isFileURL, root.baseURL == nil, root.path.hasPrefix("/"), root.path != "/" else {
            throw Failure.unavailable
        }
        let fd = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        try directory(fd, sharedRoot: true)
        let state = "state".withCString { Darwin.openat(fd, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard state >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(state) }
        try directory(state)
        var initialRoot = stat(); var initialState = stat()
        guard Darwin.fstat(fd, &initialRoot) == 0, Darwin.fstat(state, &initialState) == 0 else {
            throw Failure.unavailable
        }
        guard let parentBytes = try file("active-installer-operation.json", in: state),
              let parent = try? FileManagedPythonRuntimeRecoveryStore.decodeHistoricalEvidence(parentBytes),
              parent.state == .managedTools else { throw Failure.unavailable }
        let digest: (String) -> String = { Self.hash(Data($0.utf8)) }
        let originalName = "reviewed-selection-" + digest(parent.operationID) + ".json"
        let resumedName = "reviewed-selection-post-tool-" + digest(parent.operationID + "\u{0}" + parent.stablePlanFingerprint) + ".json"
        guard let selectionBytes = try file(resumedName, in: fd) ?? file(originalName, in: fd),
              let selection = try? ManagedInstallerReviewedSelection.decodeJSON(selectionBytes),
              selection.intent.operationID == parent.operationID,
              selection.intent.sessionID == parent.sessionID,
              selection.intent.deploymentID == parent.deploymentID,
              selection.intent.stablePlanFingerprint == parent.stablePlanFingerprint,
              selection.routeRequest.compositionIdentity == parent.compositionIdentity,
              selection.routeRequest.manifestSHA256 == parent.manifestSHA256,
              selection.componentIdentities == parent.productVirtualEnvironments.map(\.componentIdentity).sorted()
        else { throw Failure.unavailable }
        let routeName = "released-route-" + Self.hash(selection.routeRequest.canonicalJSONData()) + ".json"
        let operatorName = "reviewed-installer-user-" + digest(parent.operationID + "\u{0}" + parent.stablePlanFingerprint) + ".json"
        guard let route = try file(routeName, in: fd),
              let authority = try file("product-worker-authority.json", in: fd),
              let user = try file(operatorName, in: fd) else { throw Failure.unavailable }
        // Repeat every frozen read before returning; a mixed-generation bundle
        // cannot become the basis of historical reconstruction.
        guard try file("active-installer-operation.json", in: state) == parentBytes,
              try (file(resumedName, in: fd) ?? file(originalName, in: fd)) == selectionBytes,
              try file(routeName, in: fd) == route,
              try file("product-worker-authority.json", in: fd) == authority,
              try file(operatorName, in: fd) == user else { throw Failure.unavailable }
        try directory(fd, sharedRoot: true); try directory(state)
        var finalRoot = stat(); var finalState = stat(); var namedRoot = stat(); var namedState = stat()
        guard Darwin.fstat(fd, &finalRoot) == 0, Darwin.fstat(state, &finalState) == 0,
              root.path.withCString({ Darwin.lstat($0, &namedRoot) }) == 0,
              "state".withCString({ Darwin.fstatat(fd, $0, &namedState, AT_SYMLINK_NOFOLLOW) }) == 0,
              Self.same(initialRoot, finalRoot), Self.same(initialRoot, namedRoot),
              Self.same(initialState, finalState), Self.same(initialState, namedState)
        else { throw Failure.unavailable }
        return .init(parent: parent, selection: selection, originalRouteBytes: route,
            originalAuthorityBytes: authority, originalOperatorBytes: user,
            sha256ByRole: ["parent": Self.hash(parentBytes), "selection": Self.hash(selectionBytes),
                          "route": Self.hash(route), "authority": Self.hash(authority), "operator": Self.hash(user)])
    }

    private typealias Failure = ManagedInstallerHistoricalOperationReconstructionFailure
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func directory(_ fd: Int32, sharedRoot: Bool = false) throws {
        var s = stat()
        guard Darwin.fstat(fd, &s) == 0, s.st_uid == expectedOwner,
              s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              s.st_mode & mode_t(0o7777) == mode_t(0o700), s.st_flags == 0
        else { throw Failure.unavailable }
        if sharedRoot {
            _ = try rootValidator.validateSharedRoot(fd)
        } else if !Self.noACL(fd) { throw Failure.unavailable }
    }
    private func file(_ name: String, in directory: Int32) throws -> Data? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\u{0}") else { throw Failure.unavailable }
        let fd = name.withCString { Darwin.openat(directory, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unavailable
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard Darwin.fstat(fd, &before) == 0, before.st_uid == expectedOwner,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1,
              before.st_mode & mode_t(0o7777) == mode_t(0o600), before.st_flags == 0,
              before.st_size > 0, before.st_size <= 1024 * 1024, Self.noACL(fd) else { throw Failure.unavailable }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0, bytes.count + n <= 1024 * 1024 else { throw Failure.unavailable }
            if n == 0 { break }
            bytes.append(contentsOf: buffer.prefix(n))
        }
        var after = stat(); var named = stat()
        guard Darwin.fstat(fd, &after) == 0,
              name.withCString({ Darwin.fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              Self.same(before, after), Self.same(before, named), Self.noACL(fd),
              bytes.count == before.st_size,
              var reader = try? StrictJSONResourceReader(data: bytes),
              let value = try? reader.parseDocument(),
              StrictSignedJSON.canonicalPayload(from: value) == bytes else { throw Failure.unavailable }
        return bytes
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_gid == b.st_gid
            && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_flags == b.st_flags
            && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
            && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func noACL(_ fd: Int32) -> Bool {
        errno = 0
        guard let acl = Darwin.acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        guard Darwin.acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?; errno = 0
        return Darwin.acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == -1 && errno == EINVAL
    }
}
