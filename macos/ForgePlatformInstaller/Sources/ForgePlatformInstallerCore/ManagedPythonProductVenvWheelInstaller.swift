import CryptoKit
import Darwin
import Foundation
import os

/// Separate authority shapes for a published product instance and a new
/// deployment that does not yet have any product-owned instance identity.
private enum ManagedPythonProductVenvStagedWheel: Sendable {
    case published(
        ManagedInstallerProductWheelStagingReceipt,
        @Sendable () async -> ManagedInstallerProductWheelBinding?
    )
    case prepublication(
        ManagedInstallerPrepublicationProductWheelStagingReceipt,
        @Sendable () async -> ManagedInstallerPrepublicationProductWheelBinding?
    )

    var artifactSHA256: String {
        switch self {
        case .published(let receipt, _): receipt.binding.artifactSHA256
        case .prepublication(let receipt, _): receipt.binding.artifactSHA256
        }
    }

    var version: String {
        switch self {
        case .published(let receipt, _): receipt.binding.version
        case .prepublication(let receipt, _): receipt.binding.version
        }
    }

    var fileName: String {
        switch self {
        case .published(let receipt, _): receipt.fileName
        case .prepublication(let receipt, _): receipt.fileName
        }
    }

    var byteCount: Int {
        switch self {
        case .published(let receipt, _): receipt.byteCount
        case .prepublication(let receipt, _): receipt.byteCount
        }
    }

    func admits(
        _ request: ManagedPythonProductVenvMutationRequest,
        slotName: String
    ) async -> Bool {
        switch self {
        case .published(let receipt, let check):
            guard receipt.binding.deploymentID == request.deploymentID,
                  receipt.binding.componentIdentity == request.componentIdentity,
                  receipt.binding.venvSlotName == slotName else { return false }
            return await check() == receipt.binding
        case .prepublication(let receipt, let check):
            guard receipt.binding.deploymentID == request.deploymentID,
                  receipt.binding.componentIdentity == request.componentIdentity,
                  receipt.binding.venvIdentity == request.venvIdentity else { return false }
            return await check() == receipt.binding
        }
    }
}

/// Concrete helper-owned bridge from a freshly admitted exact staged wheel to
/// the signed worker. A reviewed-operation assembly supplies the authority
/// recheck, never an XPC path or a CLI-selected artifact.
struct MacOSManagedPythonProductVenvWheelInstaller:
    ManagedPythonProductVenvWheelInstalling, Sendable {
    private static let diagnostic = Logger(
        subsystem: "com.autonomous-engineering-system.forge-platform-installer",
        category: "runtime-activation"
    )
    private static func trace(_ value: String) {
    }
    typealias AuthorityCheck = @Sendable () async -> ManagedInstallerProductWheelBinding?
    typealias PrepublicationAuthorityCheck =
        @Sendable () async -> ManagedInstallerPrepublicationProductWheelBinding?

    private let helperRoot: URL
    private let staged: ManagedPythonProductVenvStagedWheel
    private let runtime: any ManagedPythonProductVenvRuntimeVerifying
    private let resource: any ManagedInstallerHelperSignedWorkerResourceLocating
    private let runner: any ManagedInstallerProductWheelWorkerRunning
    private let expectedOwner: uid_t

    init(
        helperRoot: URL,
        staged: ManagedInstallerProductWheelStagingReceipt,
        runtime: any ManagedPythonProductVenvRuntimeVerifying,
        resource: any ManagedInstallerHelperSignedWorkerResourceLocating,
        runner: any ManagedInstallerProductWheelWorkerRunning,
        expectedOwner: uid_t = 0,
        authorityCheck: @escaping AuthorityCheck
    ) {
        self.helperRoot = helperRoot
        self.staged = .published(staged, authorityCheck)
        self.runtime = runtime
        self.resource = resource
        self.runner = runner
        self.expectedOwner = expectedOwner
    }

    init(
        helperRoot: URL,
        staged: ManagedInstallerPrepublicationProductWheelStagingReceipt,
        runtime: any ManagedPythonProductVenvRuntimeVerifying,
        resource: any ManagedInstallerHelperSignedWorkerResourceLocating,
        runner: any ManagedInstallerProductWheelWorkerRunning,
        expectedOwner: uid_t = 0,
        authorityCheck: @escaping PrepublicationAuthorityCheck
    ) {
        self.helperRoot = helperRoot
        self.staged = .prepublication(staged, authorityCheck)
        self.runtime = runtime
        self.resource = resource
        self.runner = runner
        self.expectedOwner = expectedOwner
    }

    func installIntoPending(
        _ pending: URL, published: URL,
        request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        Self.trace("install_entered")
        guard let slot = await admit(request, published: published) else {
            Self.trace("install_admission_rejected")
            Self.diagnostic.notice("gate=wheel-install-admission")
            return .failure(.rejected)
        }
        guard pending == slot.root.appendingPathComponent(pending.lastPathComponent, isDirectory: true),
              Self.isPendingName(pending.lastPathComponent) else {
            Self.diagnostic.notice("gate=wheel-install-pending-path")
            return .failure(.rejected)
        }
        guard let interpreterSHA256 = await verifiedInterpreterDigest(request, venv: pending) else {
            Self.diagnostic.notice("gate=wheel-install-interpreter")
            return .failure(.rejected)
        }
        Self.trace("install_interpreter_verified")
        let workerRequest: ManagedInstallerProductWheelWorkerRequest
        do {
            workerRequest = try ManagedInstallerProductWheelWorkerRequest(
                action: .installPending,
                componentIdentity: request.componentIdentity,
                version: staged.version,
                artifactSHA256: staged.artifactSHA256,
                pendingName: pending.lastPathComponent,
                publishedSlotName: slot.name,
                interpreterSHA256: interpreterSHA256
            )
        } catch {
            Self.trace("worker_request_rejected")
            return .failure(.rejected)
        }
        Self.trace("worker_request_verified")
        return await execute(
            workerRequest, request: request, published: published, targetVenv: pending
        )
    }

    func readPublished(
        _ published: URL, request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        guard let slot = await admit(request, published: published) else {
            Self.diagnostic.notice("gate=wheel-read-admission")
            return .failure(.rejected)
        }
        guard let interpreterSHA256 = await verifiedInterpreterDigest(
                request, venv: slot.root.appendingPathComponent(
                    slot.name, isDirectory: true
                )
              ) else {
            Self.diagnostic.notice("gate=wheel-read-interpreter")
            return .failure(.rejected)
        }
        let workerRequest: ManagedInstallerProductWheelWorkerRequest
        do {
            workerRequest = try ManagedInstallerProductWheelWorkerRequest(
                action: .readPublished,
                componentIdentity: request.componentIdentity,
                version: staged.version,
                artifactSHA256: staged.artifactSHA256,
                pendingName: nil,
                publishedSlotName: slot.name,
                interpreterSHA256: interpreterSHA256
            )
        } catch { return .failure(.rejected) }
        let result = await execute(
            workerRequest, request: request, published: published,
            targetVenv: published
        )
        if case .failure = result {
            Self.diagnostic.notice("gate=wheel-read-worker")
        }
        return result
    }

    private func admit(
        _ request: ManagedPythonProductVenvMutationRequest,
        published: URL
    ) async -> (root: URL, name: String)? {
        let slot = MacOSManagedPythonProductVenvSlotLayout.slotName(for: request)
        let root = helperRoot.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
            isDirectory: true
        )
        guard Darwin.geteuid() == expectedOwner,
              helperRoot.isFileURL, helperRoot.baseURL == nil,
              helperRoot.path.hasPrefix("/"), helperRoot.path != "/",
              pendingFileNameIsExact(), staged.byteCount > 0,
              published == root.appendingPathComponent(slot, isDirectory: true),
              await staged.admits(request, slotName: slot) else { return nil }
        return (root, slot)
    }

    private func pendingFileNameIsExact() -> Bool {
        let artifact = staged.artifactSHA256
        return CompositionCatalogValidation.isTaggedSHA256(artifact)
            && staged.fileName == String(artifact.dropFirst("sha256:".count)) + ".artifact"
    }

    private func verifiedInterpreterDigest(
        _ request: ManagedPythonProductVenvMutationRequest,
        venv: URL
    ) async -> String? {
        guard case .success(let base) = runtime.verifiedInterpreter(for: request),
              let baseDigest = Self.digest(base, owner: expectedOwner),
              let copiedDigest = Self.digest(
                venv.appendingPathComponent("bin/python3"), owner: expectedOwner
              ), baseDigest == copiedDigest,
              case .success(let fresh) = runtime.verifiedInterpreter(for: request),
              fresh == base,
              Self.digest(base, owner: expectedOwner) == baseDigest else { return nil }
        return copiedDigest
    }

    private func execute(
        _ workerRequest: ManagedInstallerProductWheelWorkerRequest,
        request: ManagedPythonProductVenvMutationRequest,
        published: URL,
        targetVenv: URL
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        guard case .success(let interpreter) = runtime.verifiedInterpreter(for: request) else {
            Self.trace("wheel-worker-runtime-before")
            if workerRequest.action == .readPublished {
                Self.diagnostic.notice("gate=wheel-worker-runtime-before")
            }
            return .failure(.rejected)
        }
        guard case .success(let signedWorker) = await resource.locate() else {
            Self.trace("wheel-worker-resource")
            if workerRequest.action == .readPublished {
                Self.diagnostic.notice("gate=wheel-worker-resource")
            }
            return .failure(.rejected)
        }
        guard await staged.admits(
                request,
                slotName: MacOSManagedPythonProductVenvSlotLayout.slotName(for: request)
              ) else {
            Self.trace("wheel-worker-authority-before")
            if workerRequest.action == .readPublished {
                Self.diagnostic.notice("gate=wheel-worker-authority-before")
            }
            return .failure(.rejected)
        }
        let invocation = ManagedInstallerProductWorkerInvocation(
            interpreterURL: interpreter,
            trustedStateRootURL: helperRoot,
            workerURL: signedWorker.url,
            workerSHA256: signedWorker.sha256,
            expectedInterpreterOwner: expectedOwner,
            requireSingleInterpreterLink: true,
            timeoutNanoseconds: 120_000_000_000
        )
        let result = await runner.runWheelWorker(invocation, request: workerRequest)
        guard case .success(let receipt) = result else {
            Self.trace("wheel-worker-execution")
            if workerRequest.action == .readPublished {
                Self.diagnostic.notice("gate=wheel-worker-execution")
            }
            return .failure(.rejected)
        }
        guard receipt.action == workerRequest.action,
              receipt.requestSHA256 == "sha256:" + SHA256.hash(
                data: workerRequest.canonicalJSONData()
              ).map({ String(format: "%02x", $0) }).joined(),
              CompositionCatalogValidation.isTaggedSHA256(receipt.bindingEvidence),
              CompositionCatalogValidation.isTaggedSHA256(receipt.verificationEvidence),
              receipt.fileCount > 0 else {
            Self.trace("wheel-worker-receipt")
            if workerRequest.action == .readPublished {
                Self.diagnostic.notice("gate=wheel-worker-receipt")
            }
            return .failure(.rejected)
        }
        guard await staged.admits(
                request,
                slotName: MacOSManagedPythonProductVenvSlotLayout.slotName(for: request)
              ) else {
            Self.trace("wheel-worker-authority-after")
            if workerRequest.action == .readPublished {
                Self.diagnostic.notice("gate=wheel-worker-authority-after")
            }
            return .failure(.rejected)
        }
        guard published == helperRoot.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
                isDirectory: true
              ).appendingPathComponent(
                MacOSManagedPythonProductVenvSlotLayout.slotName(for: request),
                isDirectory: true
              ) else {
            Self.trace("wheel-worker-published-path")
            if workerRequest.action == .readPublished {
                Self.diagnostic.notice("gate=wheel-worker-published-path")
            }
            return .failure(.rejected)
        }
        guard case .success(let fresh) = runtime.verifiedInterpreter(for: request),
              fresh == interpreter,
              Self.digest(targetVenv.appendingPathComponent("bin/python3"),
                          owner: expectedOwner) == workerRequest.interpreterSHA256 else {
            Self.trace("wheel-worker-runtime-after")
            if workerRequest.action == .readPublished {
                Self.diagnostic.notice("gate=wheel-worker-runtime-after")
            }
            return .failure(.rejected)
        }
        return .success(receipt.bindingEvidence)
    }

    private static func digest(_ url: URL, owner: uid_t) -> String? {
        guard url.isFileURL, url.baseURL == nil else { return nil }
        let file = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard file >= 0 else { return nil }
        defer { _ = Darwin.close(file) }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == owner, before.st_nlink == 1,
              before.st_mode & mode_t(0o022) == 0,
              before.st_size > 0, before.st_size <= 100 * 1_024 * 1_024 else {
            return nil
        }
        var hash = SHA256()
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        var length = 0
        while true {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(file, $0.baseAddress, $0.count)
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 { return nil }
            if count == 0 { break }
            length += count
            if length > Int(before.st_size) { return nil }
            hash.update(data: Data(bytes.prefix(count)))
        }
        var after = stat()
        guard length == Int(before.st_size), Darwin.fstat(file, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            return nil
        }
        return "sha256:" + hash.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func isPendingName(_ name: String) -> Bool {
        guard name.hasPrefix("pending-"),
              let uuid = UUID(uuidString: String(name.dropFirst("pending-".count))) else {
            return false
        }
        return name == "pending-" + uuid.uuidString.lowercased()
    }
}
