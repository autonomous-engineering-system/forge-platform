import CryptoKit
import Darwin
import Foundation

/// Concrete helper-owned bridge from a freshly admitted exact staged wheel to
/// the signed worker. A reviewed-operation assembly supplies the authority
/// recheck, never an XPC path or a CLI-selected artifact.
struct MacOSManagedPythonProductVenvWheelInstaller:
    ManagedPythonProductVenvWheelInstalling, Sendable {
    typealias AuthorityCheck = @Sendable () async -> ManagedInstallerProductWheelBinding?

    private let helperRoot: URL
    private let staged: ManagedInstallerProductWheelStagingReceipt
    private let runtime: any ManagedPythonProductVenvRuntimeVerifying
    private let resource: any ManagedInstallerHelperSignedWorkerResourceLocating
    private let runner: any ManagedInstallerProductWheelWorkerRunning
    private let authorityCheck: AuthorityCheck
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
        self.staged = staged
        self.runtime = runtime
        self.resource = resource
        self.runner = runner
        self.expectedOwner = expectedOwner
        self.authorityCheck = authorityCheck
    }

    func installIntoPending(
        _ pending: URL, published: URL,
        request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        guard let slot = await admit(request, published: published),
              pending == slot.root.appendingPathComponent(
                pending.lastPathComponent, isDirectory: true
              ),
              Self.isPendingName(pending.lastPathComponent),
              let interpreterSHA256 = await verifiedInterpreterDigest(
                request, venv: pending
              ) else { return .failure(.rejected) }
        let workerRequest: ManagedInstallerProductWheelWorkerRequest
        do {
            workerRequest = try ManagedInstallerProductWheelWorkerRequest(
                action: .installPending,
                componentIdentity: request.componentIdentity,
                version: staged.binding.version,
                artifactSHA256: staged.binding.artifactSHA256,
                pendingName: pending.lastPathComponent,
                publishedSlotName: slot.name,
                interpreterSHA256: interpreterSHA256
            )
        } catch { return .failure(.rejected) }
        return await execute(
            workerRequest, request: request, published: published, targetVenv: pending
        )
    }

    func readPublished(
        _ published: URL, request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        guard let slot = await admit(request, published: published),
              let interpreterSHA256 = await verifiedInterpreterDigest(
                request, venv: slot.root.appendingPathComponent(
                    slot.name, isDirectory: true
                )
              ) else { return .failure(.rejected) }
        let workerRequest: ManagedInstallerProductWheelWorkerRequest
        do {
            workerRequest = try ManagedInstallerProductWheelWorkerRequest(
                action: .readPublished,
                componentIdentity: request.componentIdentity,
                version: staged.binding.version,
                artifactSHA256: staged.binding.artifactSHA256,
                pendingName: nil,
                publishedSlotName: slot.name,
                interpreterSHA256: interpreterSHA256
            )
        } catch { return .failure(.rejected) }
        return await execute(
            workerRequest, request: request, published: published,
            targetVenv: published
        )
    }

    private func admit(
        _ request: ManagedPythonProductVenvMutationRequest,
        published: URL
    ) async -> (root: URL, name: String)? {
        let binding = staged.binding
        let slot = MacOSManagedPythonProductVenvSlotLayout.slotName(for: request)
        let root = helperRoot.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
            isDirectory: true
        )
        guard Darwin.geteuid() == expectedOwner,
              helperRoot.isFileURL, helperRoot.baseURL == nil,
              helperRoot.path.hasPrefix("/"), helperRoot.path != "/",
              pendingFileNameIsExact(), staged.byteCount > 0,
              binding.deploymentID == request.deploymentID,
              binding.componentIdentity == request.componentIdentity,
              binding.venvSlotName == slot,
              published == root.appendingPathComponent(slot, isDirectory: true),
              await authorityCheck() == binding else { return nil }
        return (root, slot)
    }

    private func pendingFileNameIsExact() -> Bool {
        let artifact = staged.binding.artifactSHA256
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
        guard case .success(let interpreter) = runtime.verifiedInterpreter(for: request),
              case .success(let signedWorker) = await resource.locate(),
              await authorityCheck() == staged.binding else {
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
        guard case .success(let receipt) = result,
              receipt.action == workerRequest.action,
              receipt.requestSHA256 == "sha256:" + SHA256.hash(
                data: workerRequest.canonicalJSONData()
              ).map({ String(format: "%02x", $0) }).joined(),
              CompositionCatalogValidation.isTaggedSHA256(receipt.bindingEvidence),
              CompositionCatalogValidation.isTaggedSHA256(receipt.verificationEvidence),
              receipt.fileCount > 0,
              await authorityCheck() == staged.binding,
              published == helperRoot.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
                isDirectory: true
              ).appendingPathComponent(staged.binding.venvSlotName, isDirectory: true),
              case .success(let fresh) = runtime.verifiedInterpreter(for: request),
              fresh == interpreter,
              Self.digest(targetVenv.appendingPathComponent("bin/python3"),
                          owner: expectedOwner) == workerRequest.interpreterSHA256 else {
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
