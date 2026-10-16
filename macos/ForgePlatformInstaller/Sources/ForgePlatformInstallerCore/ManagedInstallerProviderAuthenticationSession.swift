import Darwin
import Foundation

/// One in-memory human device ceremony. The helper owns the child, both output
/// pipes and its deadline. Its opaque child ID shares the durable effect
/// journal with product workers; no output, account material or credential is
/// journaled. An empty child journal does not establish Keychain quiescence.
final class ManagedInstallerProviderAuthenticationSession: @unchecked Sendable {
    enum Terminal: Equatable {
        case running
        case exited(Int32)
        case rejected
        case expired
    }

    private let provider: ProviderID
    private let process: Process
    private let exitRegistry: ManagedInstallerHelperChildExitRegistry
    private let effectJournal: any ManagedInstallerProductWorkerEffectJournaling
    private let lock = NSLock()
    private let challengeReady = DispatchSemaphore(value: 0)
    private var output = Data()
    private var errors = Data()
    private var challenge: ManagedInstallerProviderDeviceChallenge?
    private var terminal: Terminal = .running
    private var effectToken: UUID?
    private var started = false
    private var expirationRequested = false
    private var expirationExitObserved = false
    private var expiredProcessGroup: pid_t?
    private var observedPrivateGroup: pid_t?
    private var observedPrivateProcess: MacOSInstallerPackageHelperProcess?
    private let accountUID: uid_t
    private let expirationQuiescence: (@Sendable (pid_t) -> Bool)?
    private var stdout: Pipe?
    private var stderr: Pipe?

    init(provider: ProviderID, process: Process,
         exitRegistry: ManagedInstallerHelperChildExitRegistry = .processWide,
         effectJournal: any ManagedInstallerProductWorkerEffectJournaling,
         expirationQuiescence: (@Sendable (pid_t) -> Bool)? = nil,
         accountUID: uid_t = Darwin.geteuid()) {
        self.provider = provider
        self.process = process
        self.exitRegistry = exitRegistry
        self.effectJournal = effectJournal
        self.expirationQuiescence = expirationQuiescence
        self.accountUID = accountUID
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
        let quiescence: (@Sendable (pid_t) -> Bool)?
        if target.provider == .codex && target.account.name.hasPrefix("_fpi_") {
            quiescence = { group in
                Self.expiredAccountIsQuiet(group: group, uid: target.account.uid)
            }
        } else { quiescence = nil }
        return Self(
            provider: target.provider, process: process,
            effectJournal: FileManagedInstallerProductWorkerEffectJournal(
                helperRoot: FileManagedInstallerReleasedRouteXPCService.productionRoot
            ),
            // The renewed entrance is limited to Codex's fixed file-backed
            // login under a dedicated account. Named operator accounts and
            // GitHub/Keychain ceremonies retain the existing closed behavior.
            expirationQuiescence: quiescence, accountUID: target.account.uid
        )
    }

    func begin(challengeTimeout: TimeInterval = 30,
               sessionTimeout: TimeInterval = 15 * 60)
        -> ManagedInstallerProviderDeviceChallenge? {
        guard challengeTimeout > 0, sessionTimeout > challengeTimeout else { return nil }
        lock.lock()
        guard !started else { lock.unlock(); return nil }
        guard !exitRegistry.hasUncertainChildEffects() else {
            terminal = .rejected
            lock.unlock()
            return nil
        }
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
        process.terminationHandler = {
            [weak self, lock, exitRegistry, effectJournal, token] process in
            lock.lock()
            // A planned expiration retains its durable reservation until a
            // separate fresh physical readback. It is not a successful login.
            let unsuccessfulCodexExit = self.map {
                $0.expirationQuiescence != nil && $0.provider == .codex
                    && $0.challenge != nil
                    && $0.observedPrivateGroup == process.processIdentifier
                    && process.terminationReason == .exit && process.terminationStatus != 0
                    && !exitRegistry.hasUncertainChildEffects()
            } ?? false
            if let self, self.expirationRequested || unsuccessfulCodexExit {
                self.expirationRequested = true
                self.expiredProcessGroup = process.processIdentifier
                self.terminal = .expired
                self.challenge = nil
                self.output.removeAll(); self.errors.removeAll()
                self.expirationExitObserved = true
                _ = exitRegistry.finish(token)
                lock.unlock()
                self.stdout?.fileHandleForReading.readabilityHandler = nil
                self.stderr?.fileHandleForReading.readabilityHandler = nil
                self.challengeReady.signal()
                return
            }
            let normalExit = process.terminationReason == .exit
                && process.terminationStatus == 0
                && !exitRegistry.hasUncertainChildEffects()
            if !normalExit { exitRegistry.markChildEffectsUncertain() }
            var durableExit = true
            if !normalExit {
                if case .failure = effectJournal.finish(token, normalExit: false) {
                    exitRegistry.markChildEffectsUncertain()
                    durableExit = false
                }
                self?.effectToken = nil
            }
            // A successful child exit ends the process, but not the credential
            // ceremony. Keep its durable ID until physical readback is verified.
            _ = exitRegistry.finish(token)
            if let self, self.terminal == .running {
                self.terminal = durableExit && process.terminationReason == .exit
                    ? .exited(process.terminationStatus) : .rejected
            }
            lock.unlock()
            self?.stdout?.fileHandleForReading.readabilityHandler = nil
            self?.stderr?.fileHandleForReading.readabilityHandler = nil
            self?.challengeReady.signal()
        }
        // Serialize launch with cancellation. A cancelled ceremony must not
        // start a child after stopProcess observed that no PID existed.
        lock.lock()
        guard terminal == .running else {
            lock.unlock()
            _ = exitRegistry.finish(token)
            return nil
        }
        guard case .success = effectJournal.beginAuthentication(token) else {
            lock.unlock()
            _ = exitRegistry.finish(token)
            reject()
            return nil
        }
        effectToken = token
        do {
            try process.run()
            lock.unlock()
        }
        catch {
            lock.unlock()
            if case .failure = effectJournal.cancelBeforeLaunch(token) {
                exitRegistry.markChildEffectsUncertain()
            }
            lock.lock()
            effectToken = nil
            lock.unlock()
            _ = exitRegistry.finish(token)
            reject()
            return nil
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + sessionTimeout
        ) { [weak self] in self?.expireOrCancel() }
        guard challengeReady.wait(
            timeout: .now() + challengeTimeout
        ) == .success else { cancel(); return nil }
        lock.lock()
        let result = terminal == .rejected ? nil : challenge
        lock.unlock()
        return result
    }

    /// Expiration is a retained pending state, never an instruction to clear
    /// negative evidence. Only this exact session can later retire its token.
    func expireOrCancel() {
        lock.lock()
        let pid = process.processIdentifier
        guard expirationQuiescence != nil, provider == .codex,
              terminal == .running, challenge != nil, pid > 0,
              Darwin.getpgid(pid) == pid,
              !exitRegistry.hasUncertainChildEffects() else {
            lock.unlock()
            cancel()
            return
        }
        guard let original = observedPrivateProcess,
              MacOSInstallerPackageHelperInstalledReader.inspectKernelProcess(
                  pid, expectedOwner: accountUID
              ) == original else {
            // Never signal an unproven or recycled PID. Keep durable negative
            // evidence and await the actual registered child's callback.
            terminal = .rejected
            exitRegistry.markChildEffectsUncertain()
            _ = effectJournal.markUncertain()
            lock.unlock()
            challengeReady.signal()
            return
        }
        expirationRequested = true
        expiredProcessGroup = pid
        terminal = .expired
        // Do not retain even the expired code while awaiting human renewal.
        challenge = nil
        output.removeAll(); errors.removeAll()
        // Signal while holding the session lock so completion cannot race a
        // stale PID/group signal after the termination callback has retired it.
        _ = Darwin.kill(-pid, SIGKILL)
        lock.unlock()
        challengeReady.signal()
    }

    /// Called only after the actor independently admits the SAME immutable
    /// target and reads AUTHENTICATION_REQUIRED again. Group/account absence
    /// is checked both before and immediately before the durable transition.
    func completeExpiredReadback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard terminal == .expired, expirationRequested, expirationExitObserved,
              let group = expiredProcessGroup, let quiet = expirationQuiescence,
              let token = effectToken, !exitRegistry.hasUncertainChildEffects(),
              quiet(group), quiet(group) else { return false }
        guard case .success = effectJournal.finishExpiredAuthentication(token) else {
            return false
        }
        effectToken = nil
        return true
    }

    static func expiredAccountIsQuiet(group: pid_t, uid: uid_t) -> Bool {
        guard group > 1, uid != 0,
              Darwin.kill(-group, 0) == -1, errno == ESRCH else { return false }
        // Kernel account-process read; no argv, environment, cache or keychain
        // content is inspected. Any process, including an escaped descendant,
        // under this dedicated account prevents renewal.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        var size = 0
        let result = mib.withUnsafeMutableBufferPointer {
            Darwin.sysctl($0.baseAddress, u_int($0.count), nil, &size, nil, 0)
        }
        guard result == 0, size <= 64 * 1024 * 1024 else { return false }
        var buffer = [UInt8](repeating: 0, count: max(size, MemoryLayout<kinfo_proc>.size))
        size = buffer.count
        let read = buffer.withUnsafeMutableBytes { bytes in
            mib.withUnsafeMutableBufferPointer {
                Darwin.sysctl($0.baseAddress, u_int($0.count), bytes.baseAddress, &size, nil, 0)
            }
        }
        return read == 0 && size == 0
    }

    /// Explicit user renewal is limited to the already supported file-backed
    /// Codex session. GitHub/Keychain and named-operator sessions stay closed.
    func hasObservedRenewalExit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return terminal == .expired && expirationExitObserved
    }

    func requestCodeRenewal() -> Bool {
        lock.lock()
        let allowed = provider == .codex && expirationQuiescence != nil
            && (terminal == .expired || (terminal == .running && challenge != nil))
        let running = terminal == .running
        lock.unlock()
        guard allowed else { return false }
        if running { expireOrCancel() }
        return status() == .expired
    }

    func status() -> Terminal {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }

    /// Only the reviewed fresh physical credential readback may close the
    /// durable ceremony. A helper crash before this call leaves it unresolved.
    func completeVerifiedReadback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard terminal == .exited(0), let token = effectToken,
              !exitRegistry.hasUncertainChildEffects() else { return false }
        guard case .success = effectJournal.finish(token, normalExit: true) else {
            exitRegistry.markChildEffectsUncertain()
            terminal = .rejected
            return false
        }
        effectToken = nil
        return true
    }

    /// A failed bootstrap after possible publication is sticky negative
    /// evidence. The historical journal and reservation remain unresolved.
    func rejectUncertainBootstrap() {
        lock.lock()
        defer { lock.unlock() }
        terminal = .rejected
        exitRegistry.markChildEffectsUncertain()
        _ = effectJournal.markUncertain()
    }

    func cancel() {
        lock.lock()
        let shouldStop = started && terminal == .running
        if shouldStop {
            terminal = .rejected
            if process.processIdentifier > 0 {
                exitRegistry.markChildEffectsUncertain()
                _ = effectJournal.markUncertain()
            }
        }
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
            exitRegistry.markChildEffectsUncertain()
            _ = effectJournal.markUncertain()
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
            if challenge != nil {
                let pid = process.processIdentifier
                if pid > 0, Darwin.getpgid(pid) == pid {
                    observedPrivateGroup = pid
                    observedPrivateProcess = MacOSInstallerPackageHelperInstalledReader
                        .inspectKernelProcess(pid, expectedOwner: accountUID)
                }
                challengeReady.signal()
            }
        }
        lock.unlock()
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
