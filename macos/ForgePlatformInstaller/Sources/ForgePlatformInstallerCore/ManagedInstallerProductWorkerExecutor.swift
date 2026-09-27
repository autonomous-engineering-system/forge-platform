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
    let workerURL: URL
    let workerSHA256: String
    let expectedInterpreterOwner: uid_t
    let requireSingleInterpreterLink: Bool
    let timeoutNanoseconds: UInt64
}

protocol ManagedInstallerProductWorkerInvocationResolving: Sendable {
    func resolveProductWorkerInvocation()
        -> Result<ManagedInstallerProductWorkerInvocation, ManagedInstallerProductWorkerFailure>
}

protocol ManagedInstallerProductWorkerRunning: Sendable {
    func runProductWorker(
        _ invocation: ManagedInstallerProductWorkerInvocation,
        canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductWorkerFailure>
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
    private let runtimeSlotsRoot: URL
    private let workerURL: URL?
    private let workerSHA256: String?
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
        expectedInterpreterOwner: uid_t = 0,
        timeoutNanoseconds: UInt64 = 120_000_000_000
    ) {
        hostStateReader = FileManagedInstallerManagedPythonHostReader(
            rootDirectory: stateRoot
        )
        self.runtimeSlotsRoot = runtimeSlotsRoot ?? stateRoot.appendingPathComponent(
            Self.runtimeSlotsDirectoryName,
            isDirectory: true
        )
        self.workerURL = workerURL
        self.workerSHA256 = workerSHA256
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
              let slot = hostState.activeRuntimeSlotIdentity else {
            return .failure(.unavailable)
        }
        let expectedPrefix = "sha256-"
        guard slot.hasPrefix(expectedPrefix),
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
    ManagedInstallerProductWorkerRunning, Sendable {
    private static let maximumErrorBytes = 8 * 1_024
    private static let maximumWorkerBytes = 16 * 1_024 * 1_024

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
        guard !canonicalRequest.isEmpty,
              canonicalRequest.count <= ManagedInstallerProductOperationRequest.maximumBytes,
              productRequest?.canonicalJSONData() == canonicalRequest
                || removalRequest?.canonicalJSONData() == canonicalRequest,
              secureInterpreter(invocation),
              secureWorker(invocation) else {
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

        do {
            try process.run()
            try standardInput.fileHandleForWriting.write(contentsOf: canonicalRequest)
            try standardInput.fileHandleForWriting.close()
        } catch {
            process.terminate()
            return .failure(.unavailable)
        }

        let holder = ManagedInstallerProductWorkerProcess(process)
        async let output = Self.readBounded(
            standardOutput.fileHandleForReading,
            maximumBytes: max(
                ManagedInstallerProductOperationReceipt.maximumBytes,
                ManagedInstallerProductRemovalReceipt.maximumBytes
            )
        )
        async let error = Self.readBounded(
            standardError.fileHandleForReading,
            maximumBytes: Self.maximumErrorBytes
        )
        let completed = await holder.wait(timeoutNanoseconds: invocation.timeoutNanoseconds)
        let capturedOutput = await output
        let capturedError = await error
        guard completed,
              process.terminationReason == .exit,
              process.terminationStatus == 0,
              capturedError != nil,
              let capturedOutput else {
            return .failure(.unavailable)
        }
        return .success(capturedOutput)
    }

    func secureInterpreter(
        _ invocation: ManagedInstallerProductWorkerInvocation
    ) -> Bool {
        secureRegularFile(
            invocation.interpreterURL,
            expectedOwner: invocation.expectedInterpreterOwner,
            requireExecutable: true,
            requireSingleLink: invocation.requireSingleInterpreterLink
        ) != nil
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

    private static func readBounded(_ handle: FileHandle, maximumBytes: Int) async -> Data? {
        await Task.detached {
            var result = Data()
            do {
                while result.count <= maximumBytes {
                    guard let chunk = try handle.read(upToCount: maximumBytes + 1 - result.count),
                          !chunk.isEmpty else {
                        try? handle.close()
                        return result
                    }
                    result.append(chunk)
                }
            } catch {}
            try? handle.close()
            return nil
        }.value
    }
}

private final class ManagedInstallerProductWorkerProcess: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func wait(timeoutNanoseconds: UInt64) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [self] in
                await waitForExit()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }
            let completed = await group.next() ?? false
            if !completed && process.isRunning { process.terminate() }
            group.cancelAll()
            return completed
        }
    }

    private func waitForExit() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [process] in
                process.waitUntilExit()
                continuation.resume()
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
        resolver = FileManagedInstallerProductWorkerInvocationResolver()
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
        switch resolver.resolveProductWorkerInvocation() {
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
        switch resolver.resolveProductWorkerInvocation() {
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
}
