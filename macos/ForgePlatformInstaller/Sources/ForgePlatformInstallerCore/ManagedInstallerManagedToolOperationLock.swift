import Foundation

/// Managed Git and managed Python share one installer-owned host lease. A Git
/// mutation cannot race Python preparation or its post-tool observations.
public struct FileManagedInstallerManagedToolOperationLock:
    ManagedInstallerManagedToolOperationLocking, Sendable {
    private let hostLock: any ManagedPythonRuntimeOperationLocking

    public init(rootDirectory: URL) {
        hostLock = FileManagedPythonRuntimeOperationLock(rootDirectory: rootDirectory)
    }

    init(hostLock: any ManagedPythonRuntimeOperationLocking) {
        self.hostLock = hostLock
    }

    public func acquireExclusiveManagedToolOperationLock()
        -> Result<
            any ManagedInstallerManagedToolOperationLock,
            ManagedInstallerManagedToolReconciliationFailure
        > {
        switch hostLock.acquireExclusiveManagedPythonRuntimeOperationLock() {
        case .success(let lease):
            return .success(ManagedToolHostOperationLease(hostLease: lease))
        case .failure(.operationInProgress):
            return .failure(.operationInProgress)
        case .failure(.unavailable), .failure(.releaseFailed):
            return .failure(.operationLockUnavailable)
        }
    }
}

private struct ManagedToolHostOperationLease:
    ManagedInstallerManagedToolOperationLock, Sendable {
    let hostLease: any ManagedPythonRuntimeOperationLock

    func releaseExclusiveManagedToolOperationLock()
        -> Result<Void, ManagedInstallerManagedToolReconciliationFailure> {
        switch hostLease.releaseExclusiveManagedPythonRuntimeOperationLock() {
        case .success:
            return .success(())
        case .failure:
            return .failure(.operationLockReleaseFailed)
        }
    }
}
