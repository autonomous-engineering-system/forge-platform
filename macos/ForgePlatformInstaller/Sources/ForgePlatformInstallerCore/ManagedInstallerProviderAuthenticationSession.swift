import Darwin
import Foundation

/// One in-memory human device ceremony. The helper owns the child, both output
/// pipes and its deadline. Only the bounded device challenge leaves this type;
/// process output, account material and credentials are never journaled.
final class ManagedInstallerProviderAuthenticationSession: @unchecked Sendable {
    enum Terminal: Equatable {
        case running
        case exited(Int32)
        case rejected
    }

    private let provider: ProviderID
    private let process: Process
    private let exitRegistry: ManagedInstallerHelperChildExitRegistry
    private let lock = NSLock()
    private let challengeReady = DispatchSemaphore(value: 0)
    private var output = Data()
    private var errors = Data()
    private var challenge: ManagedInstallerProviderDeviceChallenge?
    private var terminal: Terminal = .running
    private var started = false
    private var stdout: Pipe?
    private var stderr: Pipe?

    init(provider: ProviderID, process: Process,
         exitRegistry: ManagedInstallerHelperChildExitRegistry = .processWide) {
        self.provider = provider
        self.process = process
        self.exitRegistry = exitRegistry
    }

    static func production(
        target: ManagedInstallerProviderAuthenticationTarget,
        helperExecutable: URL
    ) -> Self? {
        let root = FileManagedInstallerReleasedRouteXPCService.productionRoot.path
        guard Darwin.geteuid() == 0,
              helperExecutable.isFileURL, helperExecutable.baseURL == nil,
              helperExecutable.lastPathComponent == "forge-platform-installer-helper",
              helperExecutable.path.hasPrefix("/"),
              ManagedInstallerProductWorkerRouteAuthority
                .isServiceAccount(target.account.name),
              target.account.uid != 0, target.account.gid != 0,
              target.executableURL.isFileURL, target.providerHomeURL.isFileURL,
              target.executableURL.path.hasPrefix(root + "/"),
              target.providerHomeURL.path.hasPrefix(root + "/") else { return nil }
        let process = Process()
        process.executableURL = helperExecutable
        process.arguments = [
            "--provider-account-auth", target.account.name,
            String(target.account.uid), String(target.account.gid),
            target.provider.rawValue, "authentication-login",
            target.executableURL.path, target.providerHomeURL.path,
        ]
        process.environment = [
            "HOME": "/var/empty", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C", "LC_ALL": "C",
        ]
        process.standardInput = FileHandle.nullDevice
        return Self(provider: target.provider, process: process)
    }

    func begin(challengeTimeout: TimeInterval = 30,
               sessionTimeout: TimeInterval = 15 * 60)
        -> ManagedInstallerProviderDeviceChallenge? {
        guard challengeTimeout > 0, sessionTimeout > challengeTimeout else { return nil }
        lock.lock()
        guard !started else { lock.unlock(); return nil }
        started = true
        let out = Pipe()
        let err = Pipe()
        stdout = out
        stderr = err
        process.standardOutput = out
        process.standardError = err
        lock.unlock()

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData, errorStream: false)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData, errorStream: true)
        }
        let token = exitRegistry.reserve(process)
        process.terminationHandler = { [weak self, exitRegistry, token] process in
            _ = exitRegistry.finish(token)
            self?.didTerminate(process)
        }
        // Serialize launch with cancellation. A cancelled ceremony must not
        // start a child after stopProcess observed that no PID existed.
        lock.lock()
        guard terminal == .running else {
            lock.unlock()
            _ = exitRegistry.finish(token)
            return nil
        }
        do {
            try process.run()
            lock.unlock()
        }
        catch {
            lock.unlock()
            _ = exitRegistry.finish(token)
            reject()
            return nil
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + sessionTimeout
        ) { [weak self] in self?.cancel() }
        guard challengeReady.wait(
            timeout: .now() + challengeTimeout
        ) == .success else { cancel(); return nil }
        lock.lock()
        let result = terminal == .rejected ? nil : challenge
        lock.unlock()
        return result
    }

    func status() -> Terminal {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }

    func cancel() {
        lock.lock()
        let shouldStop = started && terminal == .running
        if shouldStop { terminal = .rejected }
        lock.unlock()
        guard shouldStop else { return }
        stopProcess()
        challengeReady.signal()
    }

    private func receive(_ bytes: Data, errorStream: Bool) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        guard terminal == .running else { lock.unlock(); return }
        if errorStream {
            errors.append(bytes)
        } else {
            output.append(bytes)
        }
        guard output.count <= 4 * 1_024, errors.count <= 4 * 1_024 else {
            terminal = .rejected
            lock.unlock()
            stopProcess()
            challengeReady.signal()
            return
        }
        if challenge == nil {
            challenge = ManagedInstallerProviderDeviceChallenge.parse(
                provider: provider, output: output
            ) ?? ManagedInstallerProviderDeviceChallenge.parse(
                provider: provider, output: errors
            )
            if challenge != nil { challengeReady.signal() }
        }
        lock.unlock()
    }

    private func didTerminate(_ child: Process) {
        lock.lock()
        if terminal == .running {
            terminal = child.terminationReason == .exit
                ? .exited(child.terminationStatus) : .rejected
        }
        lock.unlock()
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        challengeReady.signal()
    }

    private func reject() {
        lock.lock()
        terminal = .rejected
        lock.unlock()
        challengeReady.signal()
    }

    private func stopProcess() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if Darwin.getpgid(pid) == pid {
            _ = Darwin.kill(-pid, SIGKILL)
        } else {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
}
