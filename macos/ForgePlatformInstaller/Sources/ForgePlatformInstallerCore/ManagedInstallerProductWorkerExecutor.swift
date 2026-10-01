import CryptoKit
import Darwin
import Dispatch
import Foundation

public enum ManagedInstallerProductWorkerFailure: Error, Equatable, Sendable {
    case unavailable
    case rejected
}

struct ManagedInstallerProductWorkerInvocation: Equatable, Sendable {
    let interpreterURL: URL
    let trustedStateRootURL: URL?
    let workerURL: URL
    let workerSHA256: String
    let expectedInterpreterOwner: uid_t
    let requireSingleInterpreterLink: Bool
    let timeoutNanoseconds: UInt64

    init(
        interpreterURL: URL,
        trustedStateRootURL: URL? = nil,
        workerURL: URL,
        workerSHA256: String,
        expectedInterpreterOwner: uid_t,
        requireSingleInterpreterLink: Bool,
        timeoutNanoseconds: UInt64
    ) {
        self.interpreterURL = interpreterURL
        self.trustedStateRootURL = trustedStateRootURL
        self.workerURL = workerURL
        self.workerSHA256 = workerSHA256
        self.expectedInterpreterOwner = expectedInterpreterOwner
        self.requireSingleInterpreterLink = requireSingleInterpreterLink
        self.timeoutNanoseconds = timeoutNanoseconds
    }
}

protocol ManagedInstallerProductWorkerInvocationResolving: Sendable {
    func resolveProductWorkerInvocation() async
        -> Result<ManagedInstallerProductWorkerInvocation, ManagedInstallerProductWorkerFailure>
}

protocol ManagedInstallerProductWorkerRunning: Sendable {
    func runProductWorker(
        _ invocation: ManagedInstallerProductWorkerInvocation,
        canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductWorkerFailure>
}

protocol ManagedInstallerProductWheelWorkerRunning: Sendable {
    func runWheelWorker(
        _ invocation: ManagedInstallerProductWorkerInvocation,
        request: ManagedInstallerProductWheelWorkerRequest
    ) async -> Result<ManagedInstallerProductWheelWorkerReceipt,
                      ManagedInstallerProductWorkerFailure>
}

protocol ManagedInstallerForgeUpdateResourcesChecking: Sendable {
    func check() async -> Bool
}

struct SignedManagedInstallerForgeUpdateResourcesChecker:
    ManagedInstallerForgeUpdateResourcesChecking {
    func check() async -> Bool {
        guard let resolver = ManagedInstallerForgeUpdateControllerResourceResolver
            .forCurrentProcess(),
              case .success = await resolver.resolveReleaseReceipt(),
              case .success = await resolver.resolveForge239ReleaseReceipt() else {
            return false
        }
        return true
    }
}

/// Resolves one active helper-owned CPython slot and the exact code-sealed
/// worker resource. Neither path, digest nor process option crosses XPC.
struct FileManagedInstallerProductWorkerInvocationResolver:
    ManagedInstallerProductWorkerInvocationResolving, Sendable {
    static let workerResourceName = "forge-platform-product-worker"
    static let workerResourceExtension = "pyz"
    static let workerDigestInfoKey = "ForgePlatformProductWorkerSHA256"
    static let runtimeSlotsDirectoryName = "managed-python-runtime-slots"
    static let interpreterRelativePath = "bin/python3"

    private let hostStateReader: FileManagedInstallerManagedPythonHostReader
    private let stateRoot: URL
    private let runtimeSlotsRoot: URL
    private let workerURL: URL?
    private let workerSHA256: String?
    private let authorityReader: (any ManagedInstallerProductWorkerAuthorityReading)?
    private let expectedInterpreterOwner: uid_t
    private let timeoutNanoseconds: UInt64

    init(
        stateRoot: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot,
        runtimeSlotsRoot: URL? = nil,
        workerURL: URL? = Bundle.main.url(
            forResource: Self.workerResourceName,
            withExtension: Self.workerResourceExtension
        ),
        workerSHA256: String? = Bundle.main.object(
            forInfoDictionaryKey: Self.workerDigestInfoKey
        ) as? String,
        authorityReader: (any ManagedInstallerProductWorkerAuthorityReading)? = nil,
        expectedInterpreterOwner: uid_t = 0,
        timeoutNanoseconds: UInt64 = 120_000_000_000
    ) {
        self.stateRoot = stateRoot
        hostStateReader = FileManagedInstallerManagedPythonHostReader(
            rootDirectory: stateRoot
        )
        self.runtimeSlotsRoot = runtimeSlotsRoot ?? stateRoot.appendingPathComponent(
            Self.runtimeSlotsDirectoryName,
            isDirectory: true
        )
        self.workerURL = workerURL
        self.workerSHA256 = workerSHA256
        self.authorityReader = authorityReader
        self.expectedInterpreterOwner = expectedInterpreterOwner
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func resolveProductWorkerInvocation()
        -> Result<ManagedInstallerProductWorkerInvocation, ManagedInstallerProductWorkerFailure> {
        guard timeoutNanoseconds > 0,
              let workerURL,
              workerURL.isFileURL,
              workerURL.baseURL == nil,
              let workerSHA256,
              CompositionCatalogValidation.isTaggedSHA256(workerSHA256),
              case .success(let hostState) = hostStateReader.readManagedPythonHostState(),
              let identity = hostState.activeRuntimeIdentitySHA256,
              let slot = hostState.activeRuntimeSlotIdentity else {
            return .failure(.unavailable)
        }
        if let authorityReader {
            guard case .success(let digest) = authorityReader.readAuthorityDigest(),
                  CompositionCatalogValidation.isTaggedSHA256(digest) else {
                return .failure(.unavailable)
            }
        }
        let expectedPrefix = "sha256-"
        guard slot == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                  for: identity
              ),
              slot.hasPrefix(expectedPrefix),
              slot.count == expectedPrefix.count + 64,
              slot.dropFirst(expectedPrefix.count).allSatisfy({ $0.isHexDigit }),
              slot == slot.lowercased() else {
            return .failure(.rejected)
        }
        let interpreter = runtimeSlotsRoot
            .appendingPathComponent(slot, isDirectory: true)
            .appendingPathComponent(Self.interpreterRelativePath, isDirectory: false)
        return .success(ManagedInstallerProductWorkerInvocation(
            interpreterURL: interpreter,
            trustedStateRootURL: stateRoot,
            workerURL: workerURL,
            workerSHA256: workerSHA256,
            expectedInterpreterOwner: expectedInterpreterOwner,
            requireSingleInterpreterLink: true,
            timeoutNanoseconds: timeoutNanoseconds
        ))
    }
}

/// Runs the fixed worker under isolated managed CPython. Input and output are
/// bounded canonical JSON pipes. PATH, HOME, caller environment, shell and
/// network-selected modules never participate in process construction.
struct MacOSManagedInstallerProductWorkerRunner:
    ManagedInstallerProductWorkerRunning,
    ManagedInstallerProductWheelWorkerRunning, Sendable {
    private static let maximumErrorBytes = 8 * 1_024
    private static let maximumWorkerBytes = 16 * 1_024 * 1_024
    private let forgeUpdateResources: any ManagedInstallerForgeUpdateResourcesChecking

    init(forgeUpdateResources: any ManagedInstallerForgeUpdateResourcesChecking =
        SignedManagedInstallerForgeUpdateResourcesChecker()) {
        self.forgeUpdateResources = forgeUpdateResources
    }

    func runProductWorker(
        _ invocation: ManagedInstallerProductWorkerInvocation,
        canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductWorkerFailure> {
        let productRequest = try? ManagedInstallerProductOperationRequest.decodeJSON(
            canonicalRequest
        )
        let removalRequest = try? ManagedInstallerProductRemovalRequest.decodeJSON(
            canonicalRequest
        )
        let reviewIntent = try? ManagedInstallerProductRemovalReviewIntent.decodeJSON(
            canonicalRequest
        )
        let lifecycleIntent = try? ManagedInstallerPreservedLifecycleReviewIntent.decodeJSON(
            canonicalRequest
        )
        let lifecycleRequest = try? ManagedInstallerPreservedLifecycleRequest.decodeJSON(
            canonicalRequest
        )
        let preserveRecovery = try? ManagedInstallerPreserveRecoveryRequest.decodeJSON(
            canonicalRequest
        )
        let purgeRecovery = try? ManagedInstallerPurgeRecoveryRequest.decodeJSON(
            canonicalRequest
        )
        guard !canonicalRequest.isEmpty,
              canonicalRequest.count <= ManagedInstallerProductOperationRequest.maximumBytes,
              productRequest?.canonicalJSONData() == canonicalRequest
                || removalRequest?.canonicalJSONData() == canonicalRequest
                || reviewIntent?.canonicalJSONData() == canonicalRequest
                || lifecycleIntent?.canonicalJSONData() == canonicalRequest
                || lifecycleRequest?.canonicalJSONData() == canonicalRequest
                || preserveRecovery?.canonicalJSONData() == canonicalRequest
                || purgeRecovery?.canonicalJSONData() == canonicalRequest else {
            return .failure(.rejected)
        }
        let forgeUpdateRequested = productRequest?.components.contains {
            $0.componentID == "forge-runtime" && $0.change == .update
        } == true || lifecycleIntent?.component == "forge-runtime"
            || lifecycleRequest?.intent.component == "forge-runtime"
            || preserveRecovery?.intent.component == "forge-runtime"
            || purgeRecovery?.execution.intent.component == "forge-runtime"
        if forgeUpdateRequested {
            guard await forgeUpdateResources.check() else {
                return .failure(.unavailable)
            }
        }
        return await runVerifiedWorker(
            invocation, canonicalRequest: canonicalRequest,
            maximumReceiptBytes: max(
                ManagedInstallerProductOperationReceipt.maximumBytes,
                ManagedInstallerProductRemovalReceipt.maximumBytes,
                ManagedInstallerPreservedLifecycleReviewProposal.maximumBytes,
                ManagedInstallerPreservedLifecycleReceipt.maximumBytes,
                ManagedInstallerPreserveRecoveryReceipt.maximumBytes,
                ManagedInstallerPurgeRecoveryReceipt.maximumBytes
            )
        )
    }

    func runWheelWorker(
        _ invocation: ManagedInstallerProductWorkerInvocation,
        request: ManagedInstallerProductWheelWorkerRequest
    ) async -> Result<ManagedInstallerProductWheelWorkerReceipt,
                      ManagedInstallerProductWorkerFailure> {
        let raw = request.canonicalJSONData()
        let output: Data
        switch await runVerifiedWorker(
            invocation, canonicalRequest: raw, maximumReceiptBytes: 8192
        ) {
        case .success(let value): output = value
        case .failure(let failure): return .failure(failure)
        }
        guard let receipt = try? ManagedInstallerProductWheelWorkerReceipt.decode(
            output, for: request
        ) else { return .failure(.rejected) }
        return .success(receipt)
    }

    private func runVerifiedWorker(
        _ invocation: ManagedInstallerProductWorkerInvocation,
        canonicalRequest: Data, maximumReceiptBytes: Int
    ) async -> Result<Data, ManagedInstallerProductWorkerFailure> {
        guard !canonicalRequest.isEmpty,
              canonicalRequest.count <= ManagedInstallerProductOperationRequest.maximumBytes,
              maximumReceiptBytes > 0,
              secureInterpreter(invocation), secureWorker(invocation) else {
            return .failure(.rejected)
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = invocation.interpreterURL
        process.arguments = ["-I", "-S", invocation.workerURL.path]
        process.environment = [
            "HOME": "/var/empty",
            "LANG": "C",
            "LC_ALL": "C",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONHASHSEED": "0",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty", isDirectory: true)
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        let holder = ManagedInstallerProductWorkerProcess(process)

        do {
            try process.run()
        } catch {
            return .failure(.unavailable)
        }

        async let output = Self.readBounded(
            standardOutput.fileHandleForReading,
            maximumBytes: maximumReceiptBytes,
            timeoutNanoseconds: invocation.timeoutNanoseconds
        )
        async let error = Self.readBounded(
            standardError.fileHandleForReading,
            maximumBytes: Self.maximumErrorBytes,
            timeoutNanoseconds: invocation.timeoutNanoseconds
        )
        let written = await Self.writeBounded(
            canonicalRequest,
            to: standardInput.fileHandleForWriting,
            timeoutNanoseconds: invocation.timeoutNanoseconds
        )
        if !written && process.isRunning { process.terminate() }
        let completed = await holder.wait(timeoutNanoseconds: invocation.timeoutNanoseconds)
        let capturedOutput = await output
        let capturedError = await error
        guard written, completed,
              process.terminationReason == .exit,
              process.terminationStatus == 0,
              capturedError != nil,
              let capturedOutput else {
            return .failure(.unavailable)
        }
        return .success(capturedOutput)
    }

    static func writeBounded(
        _ data: Data,
        to handle: FileHandle,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        await Task.detached {
            let descriptor = handle.fileDescriptor
            defer { try? handle.close() }
            guard !data.isEmpty, timeoutNanoseconds > 0 else { return false }
            let started = DispatchTime.now().uptimeNanoseconds
            let (sum, overflow) = started.addingReportingOverflow(timeoutNanoseconds)
            let deadline = overflow ? UInt64.max : sum
            let previousFlags = Darwin.fcntl(descriptor, F_GETFL)
            guard previousFlags >= 0,
                  Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0,
                  Darwin.fcntl(descriptor, F_SETFL, previousFlags | O_NONBLOCK) == 0 else {
                return false
            }
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { bytes in
                    Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                }
                if count > 0 {
                    offset += count
                    continue
                }
                if count == 0 { return false }
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                let milliseconds = max(1, min(50, (deadline - now) / 1_000_000))
                var descriptorToPoll = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = Darwin.poll(&descriptorToPoll, 1, Int32(milliseconds))
                if ready < 0 && errno != EINTR { return false }
                if ready > 0 && descriptorToPoll.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    return false
                }
            }
            return true
        }.value
    }

    func secureInterpreter(
        _ invocation: ManagedInstallerProductWorkerInvocation
    ) -> Bool {
        if invocation.requireSingleInterpreterLink {
            guard secureManagedInterpreterDirectories(invocation) else { return false }
        }
        return secureRegularFile(
            invocation.interpreterURL,
            expectedOwner: invocation.expectedInterpreterOwner,
            requireExecutable: true,
            requireSingleLink: invocation.requireSingleInterpreterLink
        ) != nil
    }

    private func secureManagedInterpreterDirectories(
        _ invocation: ManagedInstallerProductWorkerInvocation
    ) -> Bool {
        guard let rootURL = invocation.trustedStateRootURL,
              rootURL.isFileURL, rootURL.baseURL == nil,
              rootURL.path.hasPrefix("/"), rootURL.path != "/",
              invocation.interpreterURL.isFileURL,
              invocation.interpreterURL.baseURL == nil else { return false }
        let slot = invocation.interpreterURL.deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent
        guard
              slot.hasPrefix("sha256-"), slot.count == 71,
              slot.dropFirst(7).allSatisfy({ $0.isHexDigit }),
              slot == slot.lowercased(),
              invocation.interpreterURL == rootURL
                .appendingPathComponent(
                    FileManagedInstallerProductWorkerInvocationResolver
                        .runtimeSlotsDirectoryName,
                    isDirectory: true
                )
                .appendingPathComponent(slot, isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("python3", isDirectory: false) else {
            return false
        }

        let root = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { return false }
        defer { _ = Darwin.close(root) }
        guard secureDirectory(root, owner: invocation.expectedInterpreterOwner,
                              requirePrivate: true) else { return false }
        var parent = root
        for name in [
            FileManagedInstallerProductWorkerInvocationResolver.runtimeSlotsDirectoryName,
            slot,
            "bin",
        ] {
            let child = name.withCString {
                Darwin.openat(
                    parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
                )
            }
            guard child >= 0 else {
                if parent != root { _ = Darwin.close(parent) }
                return false
            }
            if parent != root { _ = Darwin.close(parent) }
            parent = child
            guard secureDirectory(child, owner: invocation.expectedInterpreterOwner,
                                  requirePrivate: name == FileManagedInstallerProductWorkerInvocationResolver.runtimeSlotsDirectoryName) else {
                _ = Darwin.close(child)
                return false
            }
        }
        _ = Darwin.close(parent)
        return true
    }

    private func secureDirectory(
        _ descriptor: Int32,
        owner: uid_t,
        requirePrivate: Bool
    ) -> Bool {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == owner else { return false }
        let permissions = details.st_mode & mode_t(0o7777)
        return requirePrivate ? permissions == mode_t(0o700)
            : (permissions & mode_t(0o022)) == 0
    }

    func secureWorker(_ invocation: ManagedInstallerProductWorkerInvocation) -> Bool {
        guard let data = secureRegularFile(
            invocation.workerURL,
            expectedOwner: nil,
            requireExecutable: false,
            requireSingleLink: true
        ) else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return invocation.workerSHA256 == "sha256:" + digest
    }

    private func secureRegularFile(
        _ url: URL,
        expectedOwner: uid_t?,
        requireExecutable: Bool,
        requireSingleLink: Bool
    ) -> Data? {
        guard url.isFileURL, url.baseURL == nil, url.path.hasPrefix("/") else { return nil }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              !requireSingleLink || before.st_nlink == 1,
              expectedOwner == nil || before.st_uid == expectedOwner,
              (before.st_mode & mode_t(0o022)) == 0,
              !requireExecutable || (before.st_mode & mode_t(0o111)) != 0,
              before.st_size >= 0,
              before.st_size <= off_t(Self.maximumWorkerBytes)
                || requireExecutable else {
            return nil
        }
        let maximum = requireExecutable
            ? min(Int(before.st_size), 64)
            : Int(before.st_size)
        var data = Data(count: maximum)
        let readCount = data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return -1 }
            return Darwin.read(descriptor, base, bytes.count)
        }
        var after = stat()
        guard readCount == maximum,
              Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            return nil
        }
        return data
    }

    static func readBounded(
        _ handle: FileHandle,
        maximumBytes: Int,
        timeoutNanoseconds: UInt64
    ) async -> Data? {
        await Task.detached {
            let descriptor = handle.fileDescriptor
            defer { try? handle.close() }
            guard maximumBytes > 0, maximumBytes < Int.max,
                  timeoutNanoseconds > 0 else { return nil }
            let started = DispatchTime.now().uptimeNanoseconds
            let (sum, overflow) = started.addingReportingOverflow(timeoutNanoseconds)
            let deadline = overflow ? UInt64.max : sum
            let previousFlags = Darwin.fcntl(descriptor, F_GETFL)
            guard previousFlags >= 0,
                  Darwin.fcntl(descriptor, F_SETFL, previousFlags | O_NONBLOCK) == 0 else {
                return nil
            }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, min($0.count, maximumBytes + 1 - result.count))
                }
                if count > 0 {
                    result.append(contentsOf: buffer.prefix(Int(count)))
                    if result.count > maximumBytes { return nil }
                    continue
                }
                if count == 0 { return result }
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else { return nil }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return nil }
                let milliseconds = max(1, min(50, (deadline - now) / 1_000_000))
                var descriptorToPoll = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = Darwin.poll(&descriptorToPoll, 1, Int32(milliseconds))
                if ready < 0 && errno != EINTR { return nil }
                if ready > 0 && descriptorToPoll.revents & Int16(POLLERR | POLLNVAL) != 0 {
                    return nil
                }
            }
        }.value
    }
}

private final class ManagedInstallerProductWorkerProcess: @unchecked Sendable {
    private let process: Process
    private let exit = ManagedInstallerProductWorkerExitGate()

    init(_ process: Process) {
        self.process = process
        // Register before run(): a short-lived worker must not exit between
        // launch and installation of the completion observer.
        process.terminationHandler = { [exit] _ in
            _ = exit.complete(true)
        }
    }

    func wait(timeoutNanoseconds: UInt64) async -> Bool {
        let timeout = Task.detached { [exit, process] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
            catch { return }
            guard exit.complete(false) else { return }
            // A worker that ignores SIGTERM must not hold the privileged
            // helper's operation lease or its pipe readers indefinitely.
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        let completed = await exit.wait()
        timeout.cancel()
        return completed
    }
}

final class ManagedInstallerProductWorkerExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func complete(_ result: Bool) -> Bool {
        lock.lock()
        guard completed == nil else {
            lock.unlock()
            return false
        }
        completed = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
        return true
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let completed {
                lock.unlock()
                continuation.resume(returning: completed)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// Serial product-operation executor used by the privileged XPC listener.
/// Actor isolation also prevents two product sagas from racing in one helper.
public actor ManagedInstallerPythonProductOperationExecutor:
    ManagedInstallerProductOperationHelperExecuting {
    private let resolver: any ManagedInstallerProductWorkerInvocationResolving
    private let runner: any ManagedInstallerProductWorkerRunning
    private var inFlight = false

    public init() {
        resolver = ManagedInstallerHelperSignedWorkerInvocationResolver()
        runner = MacOSManagedInstallerProductWorkerRunner()
    }

    init(
        resolver: any ManagedInstallerProductWorkerInvocationResolving,
        runner: any ManagedInstallerProductWorkerRunning
    ) {
        self.resolver = resolver
        self.runner = runner
    }

    public func executeProductOperation(
        _ request: ManagedInstallerProductOperationRequest
    ) async -> Result<
        ManagedInstallerProductOperationReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard !inFlight else { return .failure(.rejected) }
        inFlight = true
        defer { inFlight = false }
        let invocation: ManagedInstallerProductWorkerInvocation
        switch await resolver.resolveProductWorkerInvocation() {
        case .success(let resolved): invocation = resolved
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        let response: Data
        switch await runner.runProductWorker(
            invocation,
            canonicalRequest: request.canonicalJSONData()
        ) {
        case .success(let completed): response = completed
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        guard response.count <= ManagedInstallerProductOperationReceipt.maximumBytes,
              let receipt = try? ManagedInstallerProductOperationReceipt.decodeJSON(
                  response,
                  request: request
              ),
              receipt.canonicalJSONData() == response else {
            return .failure(.rejected)
        }
        return .success(receipt)
    }

    public func executeProductRemoval(
        _ request: ManagedInstallerProductRemovalRequest
    ) async -> Result<
        ManagedInstallerProductRemovalReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard !inFlight else { return .failure(.rejected) }
        inFlight = true
        defer { inFlight = false }
        let invocation: ManagedInstallerProductWorkerInvocation
        switch await resolver.resolveProductWorkerInvocation() {
        case .success(let resolved): invocation = resolved
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        let response: Data
        switch await runner.runProductWorker(
            invocation,
            canonicalRequest: request.canonicalJSONData()
        ) {
        case .success(let completed): response = completed
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        guard response.count <= ManagedInstallerProductRemovalReceipt.maximumBytes,
              let receipt = try? ManagedInstallerProductRemovalReceipt.decodeJSON(
                  response, request: request
              ), receipt.canonicalJSONData() == response else {
            return .failure(.rejected)
        }
        return .success(receipt)
    }

    public func prepareProductRemovalReview(
        _ intent: ManagedInstallerProductRemovalReviewIntent
    ) async -> Result<
        ManagedInstallerProductRemovalReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard !inFlight else { return .failure(.rejected) }
        inFlight = true
        defer { inFlight = false }
        let invocation: ManagedInstallerProductWorkerInvocation
        switch await resolver.resolveProductWorkerInvocation() {
        case .success(let resolved): invocation = resolved
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        let response: Data
        switch await runner.runProductWorker(
            invocation,
            canonicalRequest: intent.canonicalJSONData()
        ) {
        case .success(let completed): response = completed
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        guard response.count <= ManagedInstallerProductRemovalReviewProposal.maximumBytes,
              let proposal = try? ManagedInstallerProductRemovalReviewProposal.decodeJSON(
                  response, intent: intent
              ), proposal.canonicalJSONData() == response else {
            return .failure(.rejected)
        }
        return .success(proposal)
    }

    public func preparePreservedLifecycleReview(
        _ intent: ManagedInstallerPreservedLifecycleReviewIntent
    ) async -> Result<
        ManagedInstallerPreservedLifecycleReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard !inFlight else { return .failure(.rejected) }
        inFlight = true
        defer { inFlight = false }
        let invocation: ManagedInstallerProductWorkerInvocation
        switch await resolver.resolveProductWorkerInvocation() {
        case .success(let resolved): invocation = resolved
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        let response: Data
        switch await runner.runProductWorker(
            invocation, canonicalRequest: intent.canonicalJSONData()
        ) {
        case .success(let completed): response = completed
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        guard response.count <= ManagedInstallerPreservedLifecycleReviewProposal.maximumBytes,
              let proposal = try? ManagedInstallerPreservedLifecycleReviewProposal.decodeJSON(
                  response, intent: intent
              ), proposal.canonicalJSONData() == response else {
            return .failure(.rejected)
        }
        return .success(proposal)
    }

    public func preparePairingRepairReview(
        _ intent: ManagedInstallerPairingRepairReviewIntent
    ) async -> Result<
        ManagedInstallerPairingRepairReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard !inFlight else { return .failure(.rejected) }
        inFlight = true
        defer { inFlight = false }
        let invocation: ManagedInstallerProductWorkerInvocation
        switch await resolver.resolveProductWorkerInvocation() {
        case .success(let resolved): invocation = resolved
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        let response: Data
        switch await runner.runProductWorker(
            invocation, canonicalRequest: intent.canonicalJSONData()
        ) {
        case .success(let completed): response = completed
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        guard response.count <= ManagedInstallerPairingRepairReviewProposal.maximumBytes,
              let proposal = try? ManagedInstallerPairingRepairReviewProposal.decodeJSON(
                  response, intent: intent
              ), proposal.canonicalJSONData() == response else {
            return .failure(.rejected)
        }
        return .success(proposal)
    }

    public func executePreservedLifecycle(
        _ request: ManagedInstallerPreservedLifecycleRequest
    ) async -> Result<
        ManagedInstallerPreservedLifecycleReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard !inFlight else { return .failure(.rejected) }
        inFlight = true
        defer { inFlight = false }
        let invocation: ManagedInstallerProductWorkerInvocation
        switch await resolver.resolveProductWorkerInvocation() {
        case .success(let resolved): invocation = resolved
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        let response: Data
        switch await runner.runProductWorker(
            invocation, canonicalRequest: request.canonicalJSONData()
        ) {
        case .success(let completed): response = completed
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        guard response.count <= ManagedInstallerPreservedLifecycleReceipt.maximumBytes,
              let receipt = try? ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
                  response, request: request
              ), receipt.canonicalJSONData() == response else {
            return .failure(.rejected)
        }
        return .success(receipt)
    }

    public func readTerminalPreserveRecovery(
        _ request: ManagedInstallerPreserveRecoveryRequest
    ) async -> Result<
        ManagedInstallerPreserveRecoveryReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard !inFlight else { return .failure(.rejected) }
        inFlight = true
        defer { inFlight = false }
        let invocation: ManagedInstallerProductWorkerInvocation
        switch await resolver.resolveProductWorkerInvocation() {
        case .success(let resolved): invocation = resolved
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        let response: Data
        switch await runner.runProductWorker(
            invocation, canonicalRequest: request.canonicalJSONData()
        ) {
        case .success(let completed): response = completed
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        guard response.count <= ManagedInstallerPreserveRecoveryReceipt.maximumBytes,
              let receipt = try? ManagedInstallerPreserveRecoveryReceipt.decodeJSON(
                response, request: request
              ), receipt.canonicalJSONData() == response else {
            return .failure(.rejected)
        }
        return .success(receipt)
    }

    public func readTerminalPurgeRecovery(
        _ request: ManagedInstallerPurgeRecoveryRequest
    ) async -> Result<
        ManagedInstallerPurgeRecoveryReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard !inFlight else { return .failure(.rejected) }
        inFlight = true
        defer { inFlight = false }
        let invocation: ManagedInstallerProductWorkerInvocation
        switch await resolver.resolveProductWorkerInvocation() {
        case .success(let resolved): invocation = resolved
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        let response: Data
        switch await runner.runProductWorker(
            invocation, canonicalRequest: request.canonicalJSONData()
        ) {
        case .success(let completed): response = completed
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
        guard response.count <= ManagedInstallerPurgeRecoveryReceipt.maximumBytes,
              let receipt = try? ManagedInstallerPurgeRecoveryReceipt.decodeJSON(
                response, request: request
              ), receipt.canonicalJSONData() == response else {
            return .failure(.rejected)
        }
        return .success(receipt)
    }
}
