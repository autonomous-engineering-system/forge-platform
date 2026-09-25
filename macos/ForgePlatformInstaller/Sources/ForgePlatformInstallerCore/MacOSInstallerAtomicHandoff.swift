@preconcurrency import AppKit
import Darwin
import Foundation

/// Launches a verified staged application without accepting a command, an
/// executable, arguments, environment variables, or a user-selected path.
/// It is intentionally internal: the only public handoff boundary receives
/// the opaque staged asset and resolves its private bundle itself.
protocol MacOSInstallerApplicationLaunching: Sendable {
    func launchFreshInstallerApplication(
        at bundleURL: URL
    ) async -> Result<Void, InstallerSelfUpdateFailure>
}

/// Native LaunchServices implementation.  `createsNewApplicationInstance`
/// prevents the running older bundle from being reused merely because the two
/// apps have the same bundle identifier.  The app URL comes solely from the
/// trusted staged-bundle resolver and is rechecked for a non-symlink `.app`
/// root immediately before it is passed to LaunchServices.
struct MacOSInstallerApplicationLauncher: MacOSInstallerApplicationLaunching {
    private static let launchTimeout: DispatchTimeInterval = .seconds(20)
    private let openApplication: @MainActor @Sendable (
        URL,
        @escaping @Sendable (Bool) -> Void
    ) -> Void

    init() {
        openApplication = { bundleURL, completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: bundleURL,
                configuration: configuration
            ) { application, error in
                completion(application != nil && error == nil)
            }
        }
    }

    init(openApplication: @escaping @MainActor @Sendable (
        URL,
        @escaping @Sendable (Bool) -> Void
    ) -> Void) {
        self.openApplication = openApplication
    }

    func launchFreshInstallerApplication(
        at bundleURL: URL
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        guard isNonSymlinkAppBundleDirectory(bundleURL) else {
            return .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed))
        }

        let launched = await awaitLaunchServicesResult(for: bundleURL)
        return launched
            ? .success(())
            : .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed))
    }

    private func awaitLaunchServicesResult(for bundleURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let completion = MacOSInstallerLaunchCompletion(continuation: continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + Self.launchTimeout
            ) {
                completion.resolve(false)
            }
            Task { @MainActor in
                openApplication(bundleURL) { launched in
                    completion.resolve(launched)
                }
            }
        }
    }

    private func isNonSymlinkAppBundleDirectory(_ bundleURL: URL) -> Bool {
        guard bundleURL.isFileURL,
              bundleURL.pathExtension.lowercased() == "app" else {
            return false
        }
        var details = stat()
        let status = bundleURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &details)
        }
        return status == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && (details.st_mode & mode_t(S_IFLNK)) == 0
    }
}

/// Resolves the LaunchServices completion and the fixed timeout exactly once.
/// The timeout means an unavailable or wedged LaunchServices request cannot
/// hold the self-update lease indefinitely.  A later callback is discarded;
/// it cannot turn a failed handoff into a successful one.
private final class MacOSInstallerLaunchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ result: Bool) {
        lock.lock()
        let currentContinuation = continuation
        continuation = nil
        lock.unlock()
        currentContinuation?.resume(returning: result)
    }
}

/// Performs the final installer-only boundary after the self-update
/// coordinator has qualified the archive.  It repeats the archive identity,
/// resolves the private bundle, binds all code-signed V1/V2 facts to the exact
/// release record, reassesses notarization, then asks LaunchServices to start
/// a separate staged app instance.  It has no product-component, provider,
/// service, venv, migration, database, or cleanup authority.
public struct MacOSVerifiedInstallerAtomicHandoff: InstallerAtomicHandoffPerforming {
    private let stagedAssetIdentityInspector: any StagedInstallerAssetIdentityInspecting
    private let bundleResolver: any MacOSStagedInstallerBundleResolving
    private let bundleInspector: any MacOSStagedInstallerBundleInspecting
    private let notarizationAssessor: any MacOSInstallerNotarizationAssessing
    private let applicationLauncher: any MacOSInstallerApplicationLaunching

    public init(
        stagedAssetIdentityInspector: any StagedInstallerAssetIdentityInspecting,
        bundleResolver: any MacOSStagedInstallerBundleResolving,
        bundleInspector: any MacOSStagedInstallerBundleInspecting = MacOSStagedInstallerBundleEvidenceInspector(),
        notarizationAssessor: any MacOSInstallerNotarizationAssessing = MacOSStapledInstallerNotarizationAssessor()
    ) {
        self.init(
            stagedAssetIdentityInspector: stagedAssetIdentityInspector,
            bundleResolver: bundleResolver,
            bundleInspector: bundleInspector,
            notarizationAssessor: notarizationAssessor,
            applicationLauncher: MacOSInstallerApplicationLauncher()
        )
    }

    init(
        stagedAssetIdentityInspector: any StagedInstallerAssetIdentityInspecting,
        bundleResolver: any MacOSStagedInstallerBundleResolving,
        bundleInspector: any MacOSStagedInstallerBundleInspecting,
        notarizationAssessor: any MacOSInstallerNotarizationAssessing,
        applicationLauncher: any MacOSInstallerApplicationLaunching
    ) {
        self.stagedAssetIdentityInspector = stagedAssetIdentityInspector
        self.bundleResolver = bundleResolver
        self.bundleInspector = bundleInspector
        self.notarizationAssessor = notarizationAssessor
        self.applicationLauncher = applicationLauncher
    }

    public func handOffAtomicallyAndRelaunch(
        operation: InstallerSelfUpdateOperationIdentity,
        currentBundle: CurrentInstallerBundleIdentity,
        stagedAsset: StagedInstallerAsset,
        release: VerifiedInstallerReleaseRecord
    ) async -> Result<InstallerSelfUpdateHandoffReceipt, InstallerSelfUpdateFailure> {
        guard isConsistentHandoffRequest(
            operation: operation,
            currentBundle: currentBundle,
            stagedAsset: stagedAsset,
            release: release
        ) else {
            return .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed))
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        }

        let bundleURL: URL
        switch await bundleResolver.resolveStagedInstallerBundle(stagedAsset) {
        case .success(let resolvedBundleURL):
            bundleURL = resolvedBundleURL
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed))
        }

        guard let evidence = await inspectMatchingEvidence(
            at: bundleURL,
            for: release
        ) else {
            return .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed))
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        }

        switch await notarizationAssessor.assessNotarization(
            of: bundleURL,
            receiptReference: release.notarizationReference
        ) {
        case .success:
            break
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        }

        // Re-read all sealed evidence after external Gatekeeper/stapler work.
        // The archive identity and private resolver are both still current, so
        // a replacement at either boundary cannot inherit an earlier verdict.
        guard let finalEvidence = await inspectMatchingEvidence(
            at: bundleURL,
            for: release
        ), finalEvidence == evidence else {
            return .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed))
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        }

        switch await applicationLauncher.launchFreshInstallerApplication(at: bundleURL) {
        case .success:
            do {
                return .success(try InstallerSelfUpdateHandoffReceipt(
                    operation: operation,
                    handoffReference: handoffReference(for: operation),
                    activatedCodeDirectorySHA256: finalEvidence.codeSigning.codeDirectorySHA256
                ))
            } catch {
                return .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed))
            }
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed))
        }
    }

    private func isConsistentHandoffRequest(
        operation: InstallerSelfUpdateOperationIdentity,
        currentBundle: CurrentInstallerBundleIdentity,
        stagedAsset: StagedInstallerAsset,
        release: VerifiedInstallerReleaseRecord
    ) -> Bool {
        operation.matches(release)
            && stagedAsset.releaseAssetName == release.githubAsset.assetName
            && currentBundle.bundleIdentifier == release.expectedBundleIdentifier
            && currentBundle.teamIdentifier == release.expectedTeamIdentifier
            && release.release.version > currentBundle.version
            && release.sequence > currentBundle.acceptedReleaseSequence
    }

    private func stagedAssetIdentityIsCurrent(_ stagedAsset: StagedInstallerAsset) async -> Bool {
        switch await stagedAssetIdentityInspector.inspectStagedInstallerAssetIdentity(stagedAsset) {
        case .success(let observedIdentity):
            return observedIdentity == stagedAsset.fileIdentity
        case .failure:
            return false
        }
    }

    private func inspectMatchingEvidence(
        at bundleURL: URL,
        for release: VerifiedInstallerReleaseRecord
    ) async -> MacOSStagedInstallerBundleEvidence? {
        switch await bundleInspector.inspectStagedInstallerBundle(at: bundleURL) {
        case .success(let evidence):
            guard evidence.codeSigning.bundleIdentifier == release.expectedBundleIdentifier,
                  evidence.codeSigning.teamIdentifier == release.expectedTeamIdentifier,
                  evidence.codeSigning.installerVersion == release.release.version,
                  evidence.codeSigning.codeDirectorySHA256 == release.expectedCodeDirectorySHA256,
                  evidence.releaseTrustConfiguration.configurationSHA256
                    == release.expectedReleaseTrustConfigurationSHA256,
                  evidence.releaseTrustConfiguration.expectedBundleIdentifier
                    == release.expectedBundleIdentifier,
                  evidence.releaseTrustConfiguration.expectedTeamIdentifier
                    == release.expectedTeamIdentifier,
                  evidence.releaseProvenance.matches(release.provenanceExpectation),
                  evidence.releaseProvenance.releaseTrustConfigurationSHA256
                    == evidence.releaseTrustConfiguration.configurationSHA256 else {
                return nil
            }
            return evidence
        case .failure:
            return nil
        }
    }

    private func handoffReference(for operation: InstallerSelfUpdateOperationIdentity) -> String {
        // Both pieces are already validated public operation metadata.  This
        // reference is neither a URL nor a path and contains no process ID,
        // user name, product identity, or credential.
        "macos-nsworkspace-relaunch-v1:\(operation.operationIdentifier)"
    }
}
