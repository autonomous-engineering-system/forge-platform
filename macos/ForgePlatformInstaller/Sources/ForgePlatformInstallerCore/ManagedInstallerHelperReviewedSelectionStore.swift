import CryptoKit
import Darwin
import Foundation

enum ManagedInstallerHelperReviewedSelectionStoreFailure: Error, Equatable, Sendable {
    case unavailable
    case conflict
    case operationInProgress
}

/// Immutable private registration of bounded reviewed choices. A duplicate
/// operation can resume only the exact same canonical selection. The caller
/// cannot choose a filename, path, command, or credential payload.
struct FileManagedInstallerHelperReviewedSelectionStore: Sendable {
    private static let lockName = ".reviewed-selection-registration.lock"
    private let rootDirectory: URL
    private let expectedOwner: uid_t
    private let completedGitTransition:
        @Sendable (String) -> ManagedInstallerManagedGitOperationRecord?

    init(
        rootDirectory: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot,
        expectedOwner: uid_t = 0,
        completedGitTransition: @escaping @Sendable (String)
            -> ManagedInstallerManagedGitOperationRecord? = { _ in nil }
    ) {
        self.rootDirectory = Self.canonicalRoot(rootDirectory)
        self.expectedOwner = expectedOwner
        self.completedGitTransition = completedGitTransition
    }

    static func production() -> Self {
        let state = ManagedInstallerHelperStateRootBootstrap.operationStateRoot(
            for: FileManagedInstallerReleasedRouteXPCService.productionRoot
        )
        let journal = FileManagedInstallerManagedGitOperationJournalStore(
            rootDirectory: state
        )
        return Self(completedGitTransition: { operationID in
            guard case .success(let record?) = journal.loadTerminal(
                operationID: operationID
            ) else { return nil }
            return record
        })
    }

    func register(
        _ selection: ManagedInstallerReviewedSelection,
        admittedPlan: ManagedInstallerStablePlan
    ) throws {
        guard try ManagedInstallerReviewedSelection(stablePlan: admittedPlan) == selection else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.conflict
        }
        let root = try openRoot()
        defer { Darwin.close(root) }
        let lock = try acquireLock(root)
        defer {
            _ = flock(lock, LOCK_UN)
            Darwin.close(lock)
        }
        let name = Self.fileName(for: selection.intent.operationID)
        if let existing = try read(named: name, root: root) {
            if existing == selection.canonicalJSONData() { return }
            let prior = try ManagedInstallerReviewedSelection.decodeJSON(existing)
            guard admitsCompletedGitTransition(
                from: prior, to: selection, admittedPlan: admittedPlan
            ) else {
                throw ManagedInstallerHelperReviewedSelectionStoreFailure.conflict
            }
            let resumed = Self.postToolFileName(for: selection.intent)
            if let current = try read(named: resumed, root: root) {
                guard current == selection.canonicalJSONData() else {
                    throw ManagedInstallerHelperReviewedSelectionStoreFailure.conflict
                }
                return
            }
            try writeNew(selection.canonicalJSONData(), named: resumed, root: root)
            return
        }
        try writeNew(selection.canonicalJSONData(), named: name, root: root)
    }

    func load(
        for intent: ManagedInstallerReviewedExecutionIntent
    ) throws -> ManagedInstallerReviewedSelection {
        let root = try openRoot()
        defer { Darwin.close(root) }
        let resumed = try read(named: Self.postToolFileName(for: intent), root: root)
        guard let bytes = try resumed
            ?? read(named: Self.fileName(for: intent.operationID), root: root),
              let selection = try? ManagedInstallerReviewedSelection.decodeJSON(bytes),
              selection.intent == intent else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        return selection
    }

    private static func fileName(for operationID: String) -> String {
        let digest = SHA256.hash(data: Data(operationID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "reviewed-selection-\(digest).json"
    }

    private static func postToolFileName(
        for intent: ManagedInstallerReviewedExecutionIntent
    ) -> String {
        let bound = intent.operationID + "\u{0}" + intent.stablePlanFingerprint
        let digest = SHA256.hash(data: Data(bound.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "reviewed-selection-post-tool-\(digest).json"
    }

    /// A completed, helper-owned Git mutation can advance the physical host
    /// from the prior reviewed INSTALL to a new reviewed NO_CHANGE state.
    /// Preserve the original registration and admit only that exact transition;
    /// every other changed review for the same operation remains a conflict.
    private func admitsCompletedGitTransition(
        from prior: ManagedInstallerReviewedSelection,
        to current: ManagedInstallerReviewedSelection,
        admittedPlan: ManagedInstallerStablePlan
    ) -> Bool {
        let old = prior.intent
        let new = current.intent
        guard old.operationID == new.operationID,
              old.stablePlanFingerprint != new.stablePlanFingerprint,
              old.deploymentID == new.deploymentID,
              old.sessionID == new.sessionID,
              old.installerVersion == new.installerVersion,
              old.installerReleaseSHA256 == new.installerReleaseSHA256,
              prior.routeRequest == current.routeRequest,
              prior.componentIdentities == current.componentIdentities,
              prior.enabledProviderTargetIDs == current.enabledProviderTargetIDs,
              prior.pairingTarget == current.pairingTarget,
              !admittedPlan.deployment.exists,
              Set(admittedPlan.reviewedOperation.components.map(\.componentID))
                == Set(current.componentIdentities),
              admittedPlan.reviewedOperation.components.count
                == current.componentIdentities.count,
              admittedPlan.reviewedOperation.components.allSatisfy({
                  $0.change == .install && $0.installedVersion == nil
                      && $0.updateAssessmentReference == nil
              }),
              admittedPlan.originalManagedToolActions.count == 1,
              let action = admittedPlan.originalManagedToolActions.first,
              action.requirement.identity == .git,
              action.action == .noChange,
              let active = action.initialReadback,
              active.state == .active,
              active.matches(action.requirement),
              let terminal = completedGitTransition(old.operationID),
              terminal.phase == .complete,
              terminal.operationID == old.operationID,
              terminal.stablePlanFingerprint == old.stablePlanFingerprint,
              terminal.action == .install,
              terminal.targetVersion == action.requirement.version,
              terminal.targetArtifactSHA256 == action.requirement.artifact.sha256,
              terminal.finalReadbackEvidenceReference == active.evidenceReference
        else { return false }
        return true
    }

    private func openRoot() throws -> Int32 {
        guard rootDirectory.isFileURL, rootDirectory.baseURL == nil,
              rootDirectory.path.hasPrefix("/") else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        let root = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        var details = stat()
        guard Darwin.fstat(root, &details) == 0,
              isDirectory(details) else {
            Darwin.close(root)
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        return root
    }

    private func acquireLock(_ root: Int32) throws -> Int32 {
        let lock = Self.lockName.withCString {
            Darwin.openat(root, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW_ANY,
                          mode_t(0o600))
        }
        guard lock >= 0 else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        var details = stat()
        guard Darwin.fstat(lock, &details) == 0, isFile(details) else {
            Darwin.close(lock)
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock)
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.operationInProgress
        }
        return lock
    }

    private func read(named name: String, root: Int32) throws -> Data? {
        let file = name.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        defer { Darwin.close(file) }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0,
              isFile(before), before.st_size > 0,
              before.st_size <= ManagedInstallerReviewedSelection.maximumBytes else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(file, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= ManagedInstallerReviewedSelection.maximumBytes else {
                throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
            }
        }
        var after = stat()
        guard Darwin.fstat(file, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              data.count == Int(before.st_size) else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        return data
    }

    private func writeNew(_ data: Data, named name: String, root: Int32) throws {
        guard !data.isEmpty, data.count <= ManagedInstallerReviewedSelection.maximumBytes else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        let temporary = ".pending-reviewed-\(UUID().uuidString.lowercased())"
        let file = temporary.withCString {
            Darwin.openat(root, $0,
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                          mode_t(0o600))
        }
        guard file >= 0 else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        var keepTemporary = true
        defer {
            Darwin.close(file)
            if keepTemporary {
                _ = temporary.withCString { Darwin.unlinkat(root, $0, 0) }
            }
        }
        guard Darwin.fchmod(file, mode_t(0o600)) == 0 else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
                }
                offset += Int(count)
            }
        }
        guard Darwin.fsync(file) == 0 else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        let renamed = temporary.withCString { source in
            name.withCString { destination in
                Darwin.renameatx_np(root, source, root, destination,
                                    UInt32(RENAME_EXCL))
            }
        }
        guard renamed == 0, Darwin.fsync(root) == 0 else {
            throw ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable
        }
        keepTemporary = false
    }

    private func isDirectory(_ details: stat) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == expectedOwner
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func canonicalRoot(_ input: URL) -> URL {
        let standardized = input.standardizedFileURL
        guard standardized.isFileURL, standardized.baseURL == nil,
              let resolved = standardized.path.withCString({ Darwin.realpath($0, nil) })
        else { return standardized }
        defer { Darwin.free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func isFile(_ details: stat) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == expectedOwner
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o600)
    }
}
