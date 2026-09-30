import CryptoKit
import Darwin
import Foundation

enum ManagedInstallerForgeUpdateControllerResourceFailure: Error, Equatable, Sendable {
    case unavailable
}

/// Resolves only the exact protected Forge 2.7.38 controller in the signed
/// installer app enclosing this helper. The Python product adapter checks the
/// same source digest again immediately before assessment or mutation.
struct ManagedInstallerForgeUpdateControllerResourceResolver: Sendable {
    static let resourceName = "forge-update-controller.py"
    static let sourceKey = "ForgePlatformForgeUpdateControllerSourceRevision"
    static let digestKey = "ForgePlatformForgeUpdateControllerSHA256"
    static let sourceRevision = "e4b99a249845a547fd6b8e7e11d22467b2d0886d"
    static let digest = "sha256:6a6bb4ade3db9d1e45ba64a0d928e91013109de3243e8e2dbccfaa04a7a455b4"
    static let releaseReceiptName = "forge-release-complete-2.7.38.json"
    static let releaseSourceKey = "ForgePlatformForgeReleaseSourceRevision"
    static let releaseDigestKey = "ForgePlatformForgeReleaseCompleteSHA256"
    static let releaseSourceRevision = "0a3d6e35b01da93bb5a674ae7795558655c16c7d"
    static let releaseDigest = "sha256:7f8f4646a369ea565e52f8420df665acb64d032e5004e1b45ef7dc8427548c49"
    static let forge239ResourceName = "forge-update-controller-2.7.39.py"
    static let forge239SourceKey = "ForgePlatformForge239UpdateControllerSourceRevision"
    static let forge239DigestKey = "ForgePlatformForge239UpdateControllerSHA256"
    static let forge239SourceRevision = "ebc43dc12da27353f85c991a26da9852aa790f05"
    static let forge239Digest = "sha256:84bac133849c539a2bfae662234be93c3cd6583e841cae34eb27f3b21728fb87"
    static let forge239ReleaseReceiptName = "forge-release-complete-2.7.39.json"
    static let forge239ReleaseSourceKey = "ForgePlatformForge239ReleaseSourceRevision"
    static let forge239ReleaseDigestKey = "ForgePlatformForge239ReleaseCompleteSHA256"
    static let forge239ReleaseDigest = "sha256:078a9f09f048cbd1fd36c4d5f83a5739dfeb3c3a546ba94bb1148596135ba15f"

    private let locator: any ManagedInstallerHelperSignedParentBundleLocating

    init(locator: any ManagedInstallerHelperSignedParentBundleLocating) {
        self.locator = locator
    }

    static func forCurrentProcess() -> Self? {
        guard let locator = ManagedInstallerHelperSignedParentBundleLocator.forCurrentProcess()
        else { return nil }
        return Self(locator: locator)
    }

    func resolve() async -> Result<URL, ManagedInstallerForgeUpdateControllerResourceFailure> {
        guard case .success(let parent) = await locator.locate() else {
            return .failure(.unavailable)
        }
        return Self.verifyResource(
            in: parent.bundleURL, sourceRevision: Self.sourceRevision,
            digest: Self.digest
        )
    }

    func resolveReleaseReceipt() async -> Result<URL, ManagedInstallerForgeUpdateControllerResourceFailure> {
        guard case .success(let parent) = await locator.locate() else {
            return .failure(.unavailable)
        }
        return Self.verifyReleaseReceipt(
            in: parent.bundleURL, sourceRevision: Self.releaseSourceRevision,
            digest: Self.releaseDigest
        )
    }

    func resolveForge239ReleaseReceipt() async
        -> Result<URL, ManagedInstallerForgeUpdateControllerResourceFailure> {
        guard case .success(let parent) = await locator.locate() else {
            return .failure(.unavailable)
        }
        return Self.verifyForge239ReleaseReceipt(
            in: parent.bundleURL,
            controllerDigest: Self.forge239Digest,
            receiptDigest: Self.forge239ReleaseDigest
        )
    }

    static func verifyForge239ReleaseReceipt(
        in bundleURL: URL, controllerDigest: String, receiptDigest: String
    ) -> Result<URL, ManagedInstallerForgeUpdateControllerResourceFailure> {
        guard case .success = verifySealedResource(
            in: bundleURL, name: forge239ResourceName,
            sourceKey: forge239SourceKey, digestKey: forge239DigestKey,
            sourceRevision: forge239SourceRevision, digest: controllerDigest,
            maximum: 512 * 1_024
        ) else { return .failure(.unavailable) }
        return verifySealedResource(
            in: bundleURL, name: forge239ReleaseReceiptName,
            sourceKey: forge239ReleaseSourceKey, digestKey: forge239ReleaseDigestKey,
            sourceRevision: forge239SourceRevision, digest: receiptDigest,
            maximum: 64 * 1_024
        )
    }

    static func verifyReleaseReceipt(
        in bundleURL: URL, sourceRevision: String, digest: String,
        controllerSourceRevision: String = ManagedInstallerForgeUpdateControllerResourceResolver.sourceRevision,
        controllerDigest: String = ManagedInstallerForgeUpdateControllerResourceResolver.digest
    ) -> Result<URL, ManagedInstallerForgeUpdateControllerResourceFailure> {
        guard case .success = verifyResource(
            in: bundleURL, sourceRevision: controllerSourceRevision, digest: controllerDigest
        ) else { return .failure(.unavailable) }
        return verifySealedResource(
            in: bundleURL, name: releaseReceiptName, sourceKey: releaseSourceKey,
            digestKey: releaseDigestKey, sourceRevision: sourceRevision,
            digest: digest, maximum: 64 * 1_024
        )
    }

    /// A narrow fixture seam for testing the byte reader. Production resolve
    /// always supplies the compiled protected source and digest above.
    static func verifyResource(
        in bundleURL: URL, sourceRevision: String, digest: String
    ) -> Result<URL, ManagedInstallerForgeUpdateControllerResourceFailure> {
        verifySealedResource(
            in: bundleURL, name: resourceName, sourceKey: sourceKey,
            digestKey: digestKey, sourceRevision: sourceRevision,
            digest: digest, maximum: 512 * 1_024
        )
    }

    private static func verifySealedResource(
        in bundleURL: URL, name: String, sourceKey: String, digestKey: String,
        sourceRevision: String, digest: String, maximum: Int
    ) -> Result<URL, ManagedInstallerForgeUpdateControllerResourceFailure> {
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let infoURL = contents.appendingPathComponent("Info.plist")
        guard let infoBytes = Self.readStableRegularFile(infoURL, maximum: 1_024 * 1_024),
              let info = try? PropertyListSerialization.propertyList(
                from: infoBytes, options: [], format: nil
              ) as? [String: Any],
              info[sourceKey] as? String == sourceRevision,
              info[digestKey] as? String == digest else {
            return .failure(.unavailable)
        }
        let controller = contents.appendingPathComponent(
            "Resources/" + name, isDirectory: false
        )
        guard let bytes = Self.readStableRegularFile(controller, maximum: maximum),
              "sha256:" + SHA256.hash(data: bytes).map({ String(format: "%02x", $0) })
                .joined() == digest else {
            return .failure(.unavailable)
        }
        return .success(controller)
    }

    private static func readStableRegularFile(_ url: URL, maximum: Int) -> Data? {
        guard url.isFileURL, url.baseURL == nil, url.path.hasPrefix("/") else { return nil }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_nlink == 1, before.st_mode & mode_t(0o022) == 0,
              before.st_size > 0, before.st_size <= maximum else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + count <= maximum else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard data.count == before.st_size, Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
        return data
    }
}
