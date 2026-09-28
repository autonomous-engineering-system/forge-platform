import Darwin
import Foundation

struct ManagedInstallerHelperSignedWorkerResource: Equatable, Sendable {
    let url: URL
    let sha256: String
}

protocol ManagedInstallerHelperSignedWorkerResourceLocating: Sendable {
    func locate() async -> Result<
        ManagedInstallerHelperSignedWorkerResource,
        ManagedInstallerProductWorkerFailure
    >
}

/// The worker bytes and their digest come from the helper's own signed app.
/// A second full signature inspection rejects a bundle replaced during the
/// resource lookup. The worker runner independently checks the file digest
/// immediately before invocation.
struct ManagedInstallerHelperSignedWorkerResourceLocator:
    ManagedInstallerHelperSignedWorkerResourceLocating, Sendable {
    private let parentLocator: any ManagedInstallerHelperSignedParentBundleLocating

    init(parentLocator: any ManagedInstallerHelperSignedParentBundleLocating) {
        self.parentLocator = parentLocator
    }

    func locate() async -> Result<
        ManagedInstallerHelperSignedWorkerResource,
        ManagedInstallerProductWorkerFailure
    > {
        guard case .success(let parent) = await parentLocator.locate(),
              let bundle = Bundle(url: parent.bundleURL),
              let worker = bundle.url(
                forResource: FileManagedInstallerProductWorkerInvocationResolver
                    .workerResourceName,
                withExtension: FileManagedInstallerProductWorkerInvocationResolver
                    .workerResourceExtension
              ),
              worker.resolvingSymlinksInPath() == parent.bundleURL.appendingPathComponent(
                "Contents/Resources/forge-platform-product-worker.pyz"
              ).resolvingSymlinksInPath(),
              worker.isFileURL, worker.baseURL == nil,
              isRegularFileWithoutSymlink(worker),
              let digest = bundle.object(
                forInfoDictionaryKey: FileManagedInstallerProductWorkerInvocationResolver
                    .workerDigestInfoKey
              ) as? String,
              CompositionCatalogValidation.isTaggedSHA256(digest),
              case .success(let confirmedParent) = await parentLocator.locate(),
              confirmedParent == parent else {
            return .failure(.unavailable)
        }
        return .success(ManagedInstallerHelperSignedWorkerResource(
            url: worker, sha256: digest
        ))
    }

    private func isRegularFileWithoutSymlink(_ url: URL) -> Bool {
        var details = stat()
        return Darwin.lstat(url.path, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_nlink == 1
    }
}

/// Resolves the active managed Python slot only after the worker resource is
/// independently selected from the helper's signed parent. Neither the GUI
/// nor CLI can supply the worker path or digest through an XPC request.
struct ManagedInstallerHelperSignedWorkerInvocationResolver:
    ManagedInstallerProductWorkerInvocationResolving, Sendable {
    private let resourceLocator: any ManagedInstallerHelperSignedWorkerResourceLocating
    private let stateRoot: URL
    private let authorityReader: any ManagedInstallerProductWorkerAuthorityReading

    init(
        resourceLocator: any ManagedInstallerHelperSignedWorkerResourceLocating,
        stateRoot: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot,
        authorityReader: any ManagedInstallerProductWorkerAuthorityReading =
            FileManagedInstallerProductWorkerAuthorityReader()
    ) {
        self.resourceLocator = resourceLocator
        self.stateRoot = stateRoot
        self.authorityReader = authorityReader
    }

    init() {
        let parentLocator: any ManagedInstallerHelperSignedParentBundleLocating
        if let current = ManagedInstallerHelperSignedParentBundleLocator.forCurrentProcess() {
            parentLocator = current
        } else {
            parentLocator = ManagedInstallerHelperUnavailableParentLocator()
        }
        self.init(resourceLocator: ManagedInstallerHelperSignedWorkerResourceLocator(
            parentLocator: parentLocator
        ))
    }

    func resolveProductWorkerInvocation() async -> Result<
        ManagedInstallerProductWorkerInvocation,
        ManagedInstallerProductWorkerFailure
    > {
        guard case .success(let worker) = await resourceLocator.locate() else {
            return .failure(.unavailable)
        }
        return FileManagedInstallerProductWorkerInvocationResolver(
            stateRoot: stateRoot,
            workerURL: worker.url,
            workerSHA256: worker.sha256,
            authorityReader: authorityReader
        ).resolveProductWorkerInvocation()
    }
}

private struct ManagedInstallerHelperUnavailableParentLocator:
    ManagedInstallerHelperSignedParentBundleLocating {
    func locate() async -> Result<
        ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure
    > {
        .failure(.unavailable)
    }
}
