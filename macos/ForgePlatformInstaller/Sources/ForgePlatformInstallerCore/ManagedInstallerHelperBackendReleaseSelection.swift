import Foundation

/// Runtime-owned currency evidence only. No setter is exposed to wizard, CLI,
/// IPC or environment. Synchronous binding lets currency invalidation close all
/// main transports before any asynchronous inspection can continue.
final class ManagedInstallerHelperBackendReleaseSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var record: VerifiedInstallerReleaseRecord?
    func bind(_ record: VerifiedInstallerReleaseRecord?) {
        lock.lock(); defer { lock.unlock() }; self.record = record
    }
    func read() -> VerifiedInstallerReleaseRecord? {
        lock.lock(); defer { lock.unlock() }; return record
    }
}

struct ManagedInstallerHelperBackendReleaseReader: Sendable {
    let read: @Sendable () -> VerifiedInstallerReleaseRecord?
}
