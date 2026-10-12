import Darwin
import Foundation

struct MacOSInstallerStagedHelperPackage: Sendable {
    let url: URL
    let evidence: MacOSInstallerHelperPackageReadback
    fileprivate init(url: URL, evidence: MacOSInstallerHelperPackageReadback) {
        self.url = url; self.evidence = evidence
    }
}

/// Private fresh staging only. No archive extraction, authorization or helper
/// effects occur here. A failed attempt is retained; existing cache never grants
/// admission, blocks a fresh download or gets deleted as recovery.
struct MacOSInstallerHelperPackageStaging: Sendable {
    typealias Download = @Sendable (VerifiedInstallerReleaseRecord) async -> Data?
    private let root: URL
    private let download: Download
    private let verifier: MacOSInstallerHelperPackageVerifier
    init(root: URL) {
        self.root = root
        let transport = GitHubInstallerReleaseArchiveTransport()
        download = { await transport.downloadInstallerHelperPackage(for: $0) }
        verifier = .init()
    }
    // Internal source-only seam; fixed trusted runtime selects the root.
    init(root: URL, download: @escaping Download, verifier: MacOSInstallerHelperPackageVerifier) {
        self.root = root; self.download = download; self.verifier = verifier
    }
    func stage(release: VerifiedInstallerReleaseRecord, progress: @escaping InstallerHelperPreparationProgressObserver = { _ in }) async -> MacOSInstallerStagedHelperPackage? {
        guard let package = release.helperPackage, package.bytes > 0, package.bytes <= 512 * 1024 * 1024,
              root.isFileURL, root.baseURL == nil else { return nil }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { return nil }
        defer { _ = close(fd) }
        guard let before = secure(fd, directory: true), sameRoot(before) else { return nil }
        await progress(.began(.downloadingHelper))
        guard let bytes = await download(release), UInt64(bytes.count) == package.bytes,
              secure(fd, directory: true).map({ MacOSInstallerHelperPackageVerifier.same(before, $0) }) == true,
              sameRoot(before) else { return nil }
        await progress(.completed(.downloadingHelper))
        await progress(.began(.verifyingAuthenticity))
        let name = "helper-package-stage-" + UUID().uuidString.lowercased()
        guard mkdirat(fd, name, 0o700) == 0 else { return nil }
        let stage = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard stage >= 0 else { return nil }
        defer { _ = close(stage) }
        guard secure(stage, directory: true) != nil else { return nil }
        let output = openat(stage, VerifiedInstallerHelperPackage.assetName,
            O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else { return nil }
        defer { _ = close(output) }
        guard secure(output, directory: false) != nil else { return nil }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        do { try handle.write(contentsOf: bytes) } catch { return nil }
        guard fsync(output) == 0, fsync(stage) == 0, fsync(fd) == 0,
              let after = secure(fd, directory: true), sameRoot(after) else { return nil }
        let url = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent(VerifiedInstallerHelperPackage.assetName)
        guard case .success(let evidence) = verifier.verify(at: url, release: release), sameRoot(after) else { return nil }
        await progress(.completed(.verifyingAuthenticity))
        return .init(url: url, evidence: evidence)
    }
    private func secure(_ fd: Int32, directory: Bool) -> stat? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == (directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)),
              info.st_mode & 0o7777 == (directory ? 0o700 : 0o600), directory || info.st_nlink == 1,
              MacOSInstallerHelperPackageVerifier.noACL(fd) else { return nil }
        return info
    }
    private func sameRoot(_ held: stat) -> Bool {
        var named = stat()
        return lstat(root.path, &named) == 0 && MacOSInstallerHelperPackageVerifier.same(held, named)
    }
}
