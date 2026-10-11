import Foundation

/// Package backend admission is pinned to the independently verified release,
/// never a ServiceManagement version, a server receipt or an IPC field.
struct ManagedInstallerPackageHelperXPCAdmission: Sendable {
    typealias Read = @Sendable (VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperReadback?
    let release: VerifiedInstallerReleaseRecord
    private let read: Read
    init(release: VerifiedInstallerReleaseRecord) {
        self.release = release
        let reader = MacOSInstallerPackageHelperInstalledReader()
        read = { await reader.read(release: $0) }
    }
    // Internal independent-reader qualification seam, not a runtime backend.
    init(release: VerifiedInstallerReleaseRecord, read: @escaping Read) {
        self.release = release; self.read = read
    }
    func admits(expectedVersion: InstallerVersion?) async -> Bool {
        guard release.helperPackage != nil, expectedVersion == release.release.version,
              let actual = await read(release), actual.processID > 0,
              actual.releaseSequence == release.sequence,
              actual.appCodeDirectorySHA256 == release.expectedCodeDirectorySHA256 else { return false }
        return true
    }
}
