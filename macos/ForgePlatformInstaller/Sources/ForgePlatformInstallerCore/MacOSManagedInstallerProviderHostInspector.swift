import CryptoKit
import Darwin
import Foundation

enum MacOSManagedInstallerProviderProbe: Equatable, Sendable {
    case version
    case authenticationStatus
}

struct MacOSManagedInstallerProviderProbeCommand: Equatable, Sendable {
    let probe: MacOSManagedInstallerProviderProbe
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let provider: ProviderID?
    let account: ManagedInstallerProviderProbeAccount?

    init(probe: MacOSManagedInstallerProviderProbe, executableURL: URL,
         arguments: [String], environment: [String: String],
         provider: ProviderID? = nil,
         account: ManagedInstallerProviderProbeAccount? = nil) {
        self.probe = probe
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.provider = provider
        self.account = account
    }
}

struct ManagedInstallerProviderProbeAccount: Equatable, Sendable {
    let name: String
    let uid: uid_t
    let gid: gid_t
}

/// Ephemeral helper-only launch material, derived after an exact physical
/// AUTHENTICATION_REQUIRED observation. No caller supplies these paths or UID.
struct ManagedInstallerProviderAuthenticationTarget: Equatable, Sendable {
    let provider: ProviderID
    let account: ManagedInstallerProviderProbeAccount
    let executableURL: URL
    let providerHomeURL: URL
    let priorEvidenceReference: String
}

struct MacOSManagedInstallerProviderProbeResult: Equatable, Sendable {
    let exitStatus: Int32
    let standardOutput: Data?
}

protocol MacOSManagedInstallerProviderProbeRunning: Sendable {
    func runProviderProbe(
        _ command: MacOSManagedInstallerProviderProbeCommand
    ) async -> Result<
        MacOSManagedInstallerProviderProbeResult,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
}

/// Fixed command projection for the two provider CLIs admitted by the current
/// installer schema. Executable and credential-home locations come only from
/// the helper's derived component-instance layout; no request field becomes a
/// command, option, environment key or credential value.
enum MacOSManagedInstallerProviderProbeCommandFactory {
    static func command(
        provider: ProviderID,
        probe: MacOSManagedInstallerProviderProbe,
        executableURL: URL,
        providerHomeURL: URL,
        account: ManagedInstallerProviderProbeAccount? = nil
    ) -> MacOSManagedInstallerProviderProbeCommand {
        var environment = [
            "HOME": providerHomeURL.path,
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let arguments: [String]
        switch (provider, probe) {
        case (.codex, .version):
            environment["CODEX_HOME"] = providerHomeURL.path
            arguments = ["--version"]
        case (.codex, .authenticationStatus):
            environment["CODEX_HOME"] = providerHomeURL.path
            arguments = ["login", "status"]
        case (.githubCLI, .version):
            environment["GH_CONFIG_DIR"] = providerHomeURL.path
            arguments = ["--version"]
        case (.githubCLI, .authenticationStatus):
            environment["GH_CONFIG_DIR"] = providerHomeURL.path
            arguments = ["auth", "status", "--hostname", "github.com"]
        }
        return MacOSManagedInstallerProviderProbeCommand(
            probe: probe,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            provider: provider,
            account: account
        )
    }
}

/// Executes only a command produced by the fixed factory. Version output is
/// bounded and returned solely to the strict version parser; authentication
/// output is discarded so account names, keychain details or tokens cannot
/// become installer evidence or diagnostics.
struct MacOSSystemManagedInstallerProviderProbeRunner:
    MacOSManagedInstallerProviderProbeRunning {
    private static let timeout: DispatchTimeInterval = .seconds(20)
    private static let terminationGracePeriod: DispatchTimeInterval = .seconds(2)
    private static let outputDrainTimeout: DispatchTimeInterval = .seconds(2)
    private static let maximumVersionOutputBytes = 4 * 1_024

    func runProviderProbe(
        _ command: MacOSManagedInstallerProviderProbeCommand
    ) async -> Result<
        MacOSManagedInstallerProviderProbeResult,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        await Task.detached(priority: .userInitiated) {
            Self.runSynchronously(command)
        }.value
    }

    private static func runSynchronously(
        _ command: MacOSManagedInstallerProviderProbeCommand
    ) -> Result<
        MacOSManagedInstallerProviderProbeResult,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        guard command.executableURL.isFileURL,
              command.executableURL.baseURL == nil,
              command.executableURL.path.hasPrefix("/"),
              command.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin",
              command.environment["LANG"] == "C",
              command.environment["LC_ALL"] == "C" else {
            return .failure(.rejected)
        }

        let process = Process()
        if let account = command.account {
            guard Darwin.geteuid() == 0, account.uid != 0, account.gid != 0,
                  ManagedInstallerProductWorkerRouteAuthority
                    .isServiceAccount(account.name),
                  let provider = command.provider,
                  let home = command.environment["HOME"],
                  command == MacOSManagedInstallerProviderProbeCommandFactory.command(
                    provider: provider, probe: command.probe,
                    executableURL: command.executableURL,
                    providerHomeURL: URL(fileURLWithPath: home, isDirectory: true),
                    account: account
                  ),
                  let current = CommandLine.arguments.first,
                  current.hasPrefix("/"),
                  URL(fileURLWithPath: current).lastPathComponent
                    == "forge-platform-installer-helper" else {
                return .failure(.rejected)
            }
            process.executableURL = URL(fileURLWithPath: current)
            process.arguments = [
                "--provider-account-probe", account.name,
                String(account.uid), String(account.gid), provider.rawValue,
                command.probe == .version ? "version" : "authentication-status",
                command.executableURL.path, home,
            ]
        } else {
            process.executableURL = command.executableURL
            process.arguments = command.arguments
        }
        process.environment = command.environment
        let output: Pipe?
        let collector: BoundedProcessOutputCollector?
        switch command.probe {
        case .version:
            let pipe = Pipe()
            output = pipe
            collector = BoundedProcessOutputCollector(
                maximumBytes: maximumVersionOutputBytes
            )
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
        case .authenticationStatus:
            output = nil
            collector = nil
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.readbackFailed)
        }

        let outputGroup = DispatchGroup()
        if let output, let collector {
            outputGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { outputGroup.leave() }
                collector.consume(output.fileHandleForReading)
            }
        }
        guard termination.wait(timeout: .now() + timeout) == .success else {
            if command.account != nil,
               Darwin.getpgid(process.processIdentifier) == process.processIdentifier {
                // The wrapper and provider share one private process group.
                // Kill both on timeout so no orphaned authenticated CLI runs.
                _ = Darwin.kill(-process.processIdentifier, SIGKILL)
            } else {
                process.terminate()
            }
            if termination.wait(timeout: .now() + terminationGracePeriod) != .success {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                guard termination.wait(timeout: .now() + terminationGracePeriod) == .success else {
                    return .failure(.readbackFailed)
                }
            }
            return .failure(.readbackFailed)
        }
        guard outputGroup.wait(timeout: .now() + outputDrainTimeout) == .success,
              process.terminationReason == .exit else {
            return .failure(.readbackFailed)
        }
        let captured: Data?
        if let collector {
            guard let data = collector.collectedData() else {
                return .failure(.readbackFailed)
            }
            captured = data
        } else {
            captured = nil
        }
        return .success(MacOSManagedInstallerProviderProbeResult(
            exitStatus: process.terminationStatus,
            standardOutput: captured
        ))
    }
}

/// Concrete helper-side inspector for component-owned provider contexts. The
/// configured root is selected when the helper is assembled. Every remaining
/// path segment is derived from already validated immutable identities in the
/// canonical request; user-scoped legacy requirements remain ineligible until
/// an exact OS-user authority is added to that request schema.
public struct MacOSManagedInstallerProviderHostInspector:
    ManagedInstallerProviderHostInspecting, Sendable {
    private static let maximumExecutableBytes = 512 * 1_024 * 1_024

    private enum LayoutKind: Equatable, Sendable {
        case installerVersioned
        case engineeringPlatformProduct
    }

    private let rootDirectory: URL
    private let layoutKind: LayoutKind
    private let freshEPDeploymentID: String?
    private let freshClaim: ManagedInstallerProductServiceAccountClaim?
    private let freshAccountReader: (any ManagedInstallerFreshProductAccountReading)?
    private let runner: any MacOSManagedInstallerProviderProbeRunning

    public init(rootDirectory: URL) {
        self.init(
            rootDirectory: rootDirectory,
            layoutKind: .installerVersioned,
            freshEPDeploymentID: nil,
            runner: MacOSSystemManagedInstallerProviderProbeRunner()
        )
    }

    /// The privileged helper selects this frozen EP product root. Its
    /// instance/provider path comes only from the reviewed requirement.
    public init(epProductRoot: URL) {
        self.init(
            rootDirectory: epProductRoot,
            layoutKind: .engineeringPlatformProduct,
            freshEPDeploymentID: nil,
            runner: MacOSSystemManagedInstallerProviderProbeRunner()
        )
    }

    /// Fresh EP preparation is keyed by the reviewed deployment, but its
    /// product-owned provider context belongs to the distinct EP instance.
    init(epProductRoot: URL, freshDeploymentID: String,
         runner: any MacOSManagedInstallerProviderProbeRunning =
            MacOSSystemManagedInstallerProviderProbeRunner()) {
        self.init(rootDirectory: epProductRoot,
                  layoutKind: .engineeringPlatformProduct,
                  freshEPDeploymentID: freshDeploymentID, runner: runner)
    }

    init(rootDirectory: URL, freshClaim: ManagedInstallerProductServiceAccountClaim,
         accountReader: any ManagedInstallerFreshProductAccountReading,
         runner: any MacOSManagedInstallerProviderProbeRunning =
            MacOSSystemManagedInstallerProviderProbeRunner()) {
        self.init(rootDirectory: rootDirectory, layoutKind: .installerVersioned,
                  freshEPDeploymentID: nil, freshClaim: freshClaim,
                  freshAccountReader: accountReader, runner: runner)
    }

    init(epProductRoot: URL, freshClaim: ManagedInstallerProductServiceAccountClaim,
         accountReader: any ManagedInstallerFreshProductAccountReading,
         runner: any MacOSManagedInstallerProviderProbeRunning =
            MacOSSystemManagedInstallerProviderProbeRunner()) {
        self.init(rootDirectory: epProductRoot,
                  layoutKind: .engineeringPlatformProduct,
                  freshEPDeploymentID: freshClaim.deploymentID,
                  freshClaim: freshClaim, freshAccountReader: accountReader,
                  runner: runner)
    }

    init(
        rootDirectory: URL,
        runner: any MacOSManagedInstallerProviderProbeRunning
    ) {
        self.init(rootDirectory: rootDirectory, layoutKind: .installerVersioned,
                  freshEPDeploymentID: nil, runner: runner)
    }

    init(
        epProductRoot: URL,
        runner: any MacOSManagedInstallerProviderProbeRunning
    ) {
        self.init(rootDirectory: epProductRoot, layoutKind: .engineeringPlatformProduct,
                  freshEPDeploymentID: nil, runner: runner)
    }

    private init(
        rootDirectory: URL,
        layoutKind: LayoutKind,
        freshEPDeploymentID: String?,
        freshClaim: ManagedInstallerProductServiceAccountClaim? = nil,
        freshAccountReader: (any ManagedInstallerFreshProductAccountReading)? = nil,
        runner: any MacOSManagedInstallerProviderProbeRunning
    ) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
        self.layoutKind = layoutKind
        self.freshEPDeploymentID = freshEPDeploymentID
        self.freshClaim = freshClaim
        self.freshAccountReader = freshAccountReader
        self.runner = runner
    }

    public func inspectProvider(
        _ requirement: ProviderRequirement,
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerProviderHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        await inspectProvider(requirement, context: .init(
            operationID: request.operationID,
            deploymentID: request.deploymentID,
            stablePlanFingerprint: request.stablePlanFingerprint,
            enabledProviderRequirements: request.enabledProviderRequirements
        ))
    }

    /// Pre-product provider verification shares the same physical inspector
    /// and exact account/home checks as the terminal post-tool gate.
    func inspectFreshProvider(
        _ requirement: ProviderRequirement,
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerProviderHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        guard !stablePlan.deployment.exists,
              !stablePlan.enabledProviderRequirements.isEmpty else {
            return .failure(.rejected)
        }
        return await inspectProvider(requirement, context: .init(
            operationID: stablePlan.activationPlan.operationID,
            deploymentID: stablePlan.deployment.id,
            stablePlanFingerprint: stablePlan.fingerprint,
            enabledProviderRequirements: stablePlan.enabledProviderRequirements
        ))
    }

    func prepareFreshAuthentication(
        _ requirement: ProviderRequirement,
        stablePlan: ManagedInstallerStablePlan
    ) async -> ManagedInstallerProviderAuthenticationTarget? {
        guard let claim = freshClaim, let freshAccountReader,
              requirement.credentialScope == .component,
              requirement.targetIdentity == stablePlan.deployment.id,
              requirement.ownerComponent == .forgeRuntime
                || requirement.ownerComponent == .engineeringPlatformServer,
              let runtime = requirement.runtime,
              case .success(let observed) = await inspectFreshProvider(
                  requirement, stablePlan: stablePlan
              ), observed.state == .authenticationRequired,
              observed.executableSHA256 == runtime.executableSHA256,
              case .success(let account?) = freshAccountReader
                .readAccountSynchronously(claim),
              account.matches(claim), account.uid != 0, account.gid != 0,
              let owner = requirement.ownerComponent else { return nil }
        let resolvedTarget = freshEPDeploymentID.map {
            ManagedInstallerProductServiceAccountPlanner.instanceID(
                deploymentID: $0,
                componentIdentity: ProviderOwnerComponent.engineeringPlatformServer.rawValue
            )
        } ?? stablePlan.deployment.id
        let layout = Layout(
            rootDirectory: rootDirectory,
            deploymentID: stablePlan.deployment.id,
            owner: owner,
            targetIdentity: resolvedTarget,
            provider: requirement.provider,
            runtime: runtime,
            layoutKind: layoutKind
        )
        guard let executable = try? executableEvidence(for: layout),
              executable.sha256 == runtime.executableSHA256,
              executable.identity == observed.executableIdentity,
              (try? validateProviderHome(
                  for: layout,
                  account: ManagedInstallerProviderProbeAccount(
                      name: claim.accountName, uid: account.uid, gid: account.gid
                  )
              )) != nil,
              case .success(let after?) = freshAccountReader
                .readAccountSynchronously(claim), after == account else { return nil }
        return ManagedInstallerProviderAuthenticationTarget(
            provider: requirement.provider,
            account: ManagedInstallerProviderProbeAccount(
                name: claim.accountName, uid: account.uid, gid: account.gid
            ),
            executableURL: layout.executableURL,
            providerHomeURL: layout.providerHomeURL,
            priorEvidenceReference: observed.evidenceReference
        )
    }

    static func prepareProductionAuthenticationTarget(
        stablePlan: ManagedInstallerStablePlan,
        requirement: ProviderRequirement
    ) async -> ManagedInstallerProviderAuthenticationTarget? {
        guard let inspectors = ManagedInstallerPostToolComponentProviderInspector
            .productionInspectors(stablePlan: stablePlan) else { return nil }
        switch requirement.ownerComponent {
        case .forgeRuntime:
            return await inspectors.forge.prepareFreshAuthentication(
                requirement, stablePlan: stablePlan
            )
        case .engineeringPlatformServer:
            return await inspectors.engineeringPlatform.prepareFreshAuthentication(
                requirement, stablePlan: stablePlan
            )
        case .engineeringPlatformProjectAgent, .none: return nil
        }
    }

    private struct InspectionContext {
        let operationID: String
        let deploymentID: String
        let stablePlanFingerprint: String
        let enabledProviderRequirements: [ProviderRequirement]
    }

    private func inspectProvider(
        _ requirement: ProviderRequirement,
        context request: InspectionContext
    ) async -> Result<
        ManagedInstallerProviderHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        guard request.enabledProviderRequirements.contains(requirement),
              requirement.credentialScope == .component,
              let owner = requirement.ownerComponent,
              let targetIdentity = requirement.targetIdentity,
              let runtime = requirement.runtime,
              (freshEPDeploymentID == nil || (
                  layoutKind == .engineeringPlatformProduct
                      && request.deploymentID == freshEPDeploymentID
                      && targetIdentity == freshEPDeploymentID
              )),
              (layoutKind != .engineeringPlatformProduct || (
                  owner == .engineeringPlatformServer
                      && runtime.executableRelativePath == "bin/" + (
                          requirement.provider == .codex ? "codex" : "gh"
                      )
              )) else {
            return .failure(.rejected)
        }
        let originalAccount: ManagedInstallerProductServiceAccountReadback?
        let probeAccount: ManagedInstallerProviderProbeAccount?
        if let freshClaim {
            guard let freshAccountReader,
                  freshClaim.stablePlanFingerprint == request.stablePlanFingerprint,
                  freshClaim.operationID == request.operationID,
                  freshClaim.deploymentID == request.deploymentID,
                  freshClaim.componentIdentity == owner.rawValue,
                  freshClaim.instanceID
                    == ManagedInstallerProductServiceAccountPlanner.instanceID(
                        deploymentID: request.deploymentID,
                        componentIdentity: owner.rawValue
                    ),
                  freshClaim.accountName
                    == ManagedInstallerProductServiceAccountPlanner.name(
                        deploymentID: request.deploymentID,
                        componentIdentity: owner.rawValue,
                        instanceID: freshClaim.instanceID
                    ),
                  targetIdentity == request.deploymentID,
                  case .success(let readback?) = freshAccountReader
                    .readAccountSynchronously(freshClaim),
                  readback.matches(freshClaim),
                  readback.uid != 0, readback.gid != 0 else {
                return .failure(.rejected)
            }
            originalAccount = readback
            probeAccount = ManagedInstallerProviderProbeAccount(
                name: freshClaim.accountName,
                uid: readback.uid, gid: readback.gid
            )
        } else {
            originalAccount = nil
            probeAccount = nil
        }
        let resolvedTargetIdentity = freshEPDeploymentID.map {
            ManagedInstallerProductServiceAccountPlanner.instanceID(
                deploymentID: $0,
                componentIdentity: ProviderOwnerComponent.engineeringPlatformServer.rawValue
            )
        } ?? targetIdentity
        let layout = Layout(
            rootDirectory: rootDirectory,
            deploymentID: request.deploymentID,
            owner: owner,
            targetIdentity: resolvedTargetIdentity,
            provider: requirement.provider,
            runtime: runtime,
            layoutKind: layoutKind
        )

        let before: ExecutableEvidence
        do {
            guard let evidence = try executableEvidence(for: layout) else {
                return readback(
                    requirement: requirement,
                    request: request,
                    state: .absent,
                    version: nil,
                    evidence: nil
                )
            }
            before = evidence
        } catch {
            return .failure(.readbackFailed)
        }

        guard before.sha256 == runtime.executableSHA256 else {
            return readback(
                requirement: requirement,
                request: request,
                state: .installed,
                version: nil,
                evidence: before
            )
        }
        do {
            try validateProviderHome(for: layout, account: probeAccount)
        } catch {
            return .failure(.readbackFailed)
        }

        let versionCommand = MacOSManagedInstallerProviderProbeCommandFactory.command(
            provider: requirement.provider,
            probe: .version,
            executableURL: layout.executableURL,
            providerHomeURL: layout.providerHomeURL,
            account: probeAccount
        )
        let versionResult: MacOSManagedInstallerProviderProbeResult
        switch await runner.runProviderProbe(versionCommand) {
        case .success(let result): versionResult = result
        case .failure(let failure): return .failure(failure)
        }
        guard versionResult.exitStatus == 0,
              let output = versionResult.standardOutput,
              let version = Self.version(from: output, provider: requirement.provider) else {
            return readback(
                requirement: requirement,
                request: request,
                state: .failed,
                version: nil,
                evidence: before
            )
        }

        let afterVersion: ExecutableEvidence
        do {
            guard let observed = try executableEvidence(for: layout),
                  observed == before else {
                return .failure(.readbackFailed)
            }
            afterVersion = observed
        } catch {
            return .failure(.readbackFailed)
        }
        guard version == runtime.version else {
            return readback(
                requirement: requirement,
                request: request,
                state: .installed,
                version: version,
                evidence: afterVersion
            )
        }

        let authCommand = MacOSManagedInstallerProviderProbeCommandFactory.command(
            provider: requirement.provider,
            probe: .authenticationStatus,
            executableURL: layout.executableURL,
            providerHomeURL: layout.providerHomeURL,
            account: probeAccount
        )
        let authResult: MacOSManagedInstallerProviderProbeResult
        switch await runner.runProviderProbe(authCommand) {
        case .success(let result): authResult = result
        case .failure(let failure): return .failure(failure)
        }
        let afterAuthentication: ExecutableEvidence
        do {
            guard let observed = try executableEvidence(for: layout),
                  observed == before else {
                return .failure(.readbackFailed)
            }
            afterAuthentication = observed
        } catch {
            return .failure(.readbackFailed)
        }
        if let freshClaim, let originalAccount {
            guard case .success(let confirmed?) = freshAccountReader?
                .readAccountSynchronously(freshClaim),
                  confirmed == originalAccount else {
                return .failure(.readbackFailed)
            }
        }
        let state: ManagedInstallerProviderHostReadback.State
        switch authResult.exitStatus {
        case 0: state = .verified
        case 1: state = .authenticationRequired
        default: state = .failed
        }
        return readback(
            requirement: requirement,
            request: request,
            state: state,
            version: version,
            evidence: afterAuthentication
        )
    }

    private func readback(
        requirement: ProviderRequirement,
        request: InspectionContext,
        state: ManagedInstallerProviderHostReadback.State,
        version: InstallerVersion?,
        evidence: ExecutableEvidence?
    ) -> Result<
        ManagedInstallerProviderHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        do {
            return .success(try ManagedInstallerProviderHostReadback(
                providerTargetID: requirement.id,
                state: state,
                version: version,
                executableIdentity: evidence?.identity,
                executableSHA256: evidence?.sha256,
                evidenceReference: Self.evidenceReference(
                    requirement: requirement,
                    request: request,
                    state: state,
                    version: version,
                    evidence: evidence
                )
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    static func version(from data: Data, provider: ProviderID) -> InstallerVersion? {
        guard !data.isEmpty,
              data.count <= 4 * 1_024,
              let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 }),
              let firstLine = text.split(whereSeparator: \Character.isNewline).first else {
            return nil
        }
        let fields = firstLine.split(whereSeparator: \Character.isWhitespace)
        let rawVersion: Substring
        switch provider {
        case .githubCLI:
            guard fields.count >= 3, fields[0] == "gh", fields[1] == "version" else {
                return nil
            }
            rawVersion = fields[2]
        case .codex:
            guard fields.count >= 2,
                  fields[0] == "codex" || fields[0] == "codex-cli" else {
                return nil
            }
            rawVersion = fields[1]
        }
        return try? InstallerVersion(String(rawVersion))
    }

    private func executableEvidence(for layout: Layout) throws -> ExecutableEvidence? {
        let root: Int32
        do {
            root = try openRoot()
        } catch InspectionError.absent {
            return nil
        }
        defer { _ = Darwin.close(root) }

        var current = root
        var ownedDescriptors: [Int32] = []
        defer { ownedDescriptors.forEach { _ = Darwin.close($0) } }
        do {
            let segments = layout.executableDirectorySegments
            for (index, segment) in segments.enumerated() {
                let next = try openDirectory(
                    segment, at: current,
                    allowPublishedBin: index == segments.count - 1 && segment == "bin"
                )
                ownedDescriptors.append(next)
                current = next
            }
            let descriptor = try openExecutable(layout.executableFileName, at: current)
            defer { _ = Darwin.close(descriptor) }
            return try hashExecutable(descriptor, identityMaterial: layout.identityMaterial)
        } catch InspectionError.absent {
            return nil
        }
    }

    private func validateProviderHome(
        for layout: Layout, account: ManagedInstallerProviderProbeAccount?
    ) throws {
        let root = try openRoot()
        defer { _ = Darwin.close(root) }
        var current = root
        var ownedDescriptors: [Int32] = []
        defer { ownedDescriptors.forEach { _ = Darwin.close($0) } }
        let segments = layout.providerTargetDirectorySegments
            + [layout.providerHomeDirectoryName]
        for (index, segment) in segments.enumerated() {
            let home = index == segments.count - 1
            let next = try openDirectory(
                segment, at: current,
                expectedOwner: home ? account?.uid : nil,
                expectedGroup: home ? account?.gid : nil
            )
            ownedDescriptors.append(next)
            current = next
        }
    }

    private func openRoot() throws -> Int32 {
        guard rootDirectory.isFileURL,
              rootDirectory.baseURL == nil,
              rootDirectory.path.hasPrefix("/"),
              rootDirectory.path != "/" else {
            throw InspectionError.insecure
        }
        let descriptor = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw InspectionError.absent }
            throw InspectionError.insecure
        }
        guard Self.isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw InspectionError.insecure
        }
        return descriptor
    }

    private func openDirectory(
        _ name: String, at parent: Int32,
        expectedOwner: uid_t? = nil, expectedGroup: gid_t? = nil,
        allowPublishedBin: Bool = false
    ) throws -> Int32 {
        guard Self.isSafePathSegment(name) else { throw InspectionError.insecure }
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw InspectionError.absent }
            throw InspectionError.insecure
        }
        guard Self.isSecureDirectory(descriptor, owner: expectedOwner,
                                     group: expectedGroup,
                                     allowPublishedBin: allowPublishedBin) else {
            _ = Darwin.close(descriptor)
            throw InspectionError.insecure
        }
        return descriptor
    }

    private func openExecutable(_ name: String, at parent: Int32) throws -> Int32 {
        guard Self.isSafePathSegment(name) else { throw InspectionError.insecure }
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw InspectionError.absent }
            throw InspectionError.insecure
        }
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              Self.isSecureExecutable(details) else {
            _ = Darwin.close(descriptor)
            throw InspectionError.insecure
        }
        return descriptor
    }

    private func hashExecutable(
        _ descriptor: Int32,
        identityMaterial: Data
    ) throws -> ExecutableEvidence {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Self.isSecureExecutable(before),
              before.st_size > 0,
              before.st_size <= off_t(Self.maximumExecutableBytes) else {
            throw InspectionError.insecure
        }
        var hasher = SHA256()
        var count = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
        while true {
            let readCount = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw InspectionError.insecure
            }
            count += readCount
            guard count <= Self.maximumExecutableBytes else {
                throw InspectionError.insecure
            }
            hasher.update(data: Data(buffer.prefix(readCount)))
        }
        var after = stat()
        guard count == before.st_size,
              Darwin.fstat(descriptor, &after) == 0,
              Self.sameFile(before, after),
              Self.isSecureExecutable(after) else {
            throw InspectionError.insecure
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let identityDigest = SHA256.hash(data: identityMaterial).map {
            String(format: "%02x", $0)
        }.joined()
        return ExecutableEvidence(
            identity: "provider-executable-\(identityDigest)",
            sha256: "sha256:\(digest)"
        )
    }

    private static func evidenceReference(
        requirement: ProviderRequirement,
        request: InspectionContext,
        state: ManagedInstallerProviderHostReadback.State,
        version: InstallerVersion?,
        evidence: ExecutableEvidence?
    ) -> String {
        let material = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.macos-provider-observation/v1"),
            "operation_id": .string(request.operationID),
            "deployment_id": .string(request.deploymentID),
            "stable_plan_fingerprint": .string(request.stablePlanFingerprint),
            "provider_target": .string(requirement.id.rawValue),
            "state": .string(state.rawValue),
            "version": version.map { .string($0.description) } ?? .null,
            "executable_identity": evidence.map { .string($0.identity) } ?? .null,
            "executable_sha256": evidence.map { .string($0.sha256) } ?? .null,
        ]))
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return "receipt:provider-observation-\(digest)"
    }

    private static func isSecureDirectory(
        _ descriptor: Int32, owner: uid_t? = nil, group: gid_t? = nil,
        allowPublishedBin: Bool = false
    ) -> Bool {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == (owner ?? Darwin.geteuid())
            && (group == nil || details.st_gid == group) else { return false }
        let mode = details.st_mode & mode_t(0o7777)
        if mode == mode_t(0o700) { return true }
        guard allowPublishedBin, mode == mode_t(0o755) || mode == mode_t(0o555)
        else { return false }
        let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
        if let acl { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        return acl == nil && errno == ENOENT
    }

    private static func isSecureExecutable(_ details: stat) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == Darwin.geteuid()
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o500)
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func isSafePathSegment(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 384 && value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 45, 46, 95, 48...57, 65...90, 97...122: return true
            default: return false
            }
        }
    }

    private static func canonicalRootDirectory(_ input: URL) -> URL {
        guard input.isFileURL,
              input.baseURL == nil,
              input.path.hasPrefix("/"),
              let resolved = input.path.withCString({ Darwin.realpath($0, nil) }) else {
            return input.standardizedFileURL
        }
        defer { Darwin.free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private struct Layout: Sendable {
        let rootDirectory: URL
        let deploymentID: String
        let owner: ProviderOwnerComponent
        let targetIdentity: String
        let provider: ProviderID
        let runtime: ProviderRuntimeRequirement
        let layoutKind: LayoutKind

        var providerTargetDirectorySegments: [String] {
            if layoutKind == .engineeringPlatformProduct {
                return [
                    "instances", targetIdentity, "providers",
                    provider == .codex ? "codex" : "github",
                ]
            }
            return [
                "deployments", deploymentID, "providers", owner.rawValue,
                targetIdentity, provider.rawValue,
            ]
        }

        var executableDirectorySegments: [String] {
            providerTargetDirectorySegments
                + runtimeDirectorySegments
                + runtime.executableRelativePath.split(separator: "/").dropLast().map(String.init)
        }

        var runtimeDirectorySegments: [String] {
            layoutKind == .engineeringPlatformProduct
                ? ["runtime"] : ["runtime", runtime.version.description]
        }

        var executableFileName: String {
            String(runtime.executableRelativePath.split(separator: "/").last!)
        }

        var providerHomeURL: URL {
            providerTargetDirectorySegments.reduce(rootDirectory) {
                $0.appendingPathComponent($1, isDirectory: true)
            }.appendingPathComponent(
                providerHomeDirectoryName,
                isDirectory: true
            )
        }

        var providerHomeDirectoryName: String {
            layoutKind == .engineeringPlatformProduct && provider == .githubCLI
                ? "config" : "home"
        }

        var executableURL: URL {
            let runtimeRoot = (providerTargetDirectorySegments
                + runtimeDirectorySegments).reduce(rootDirectory) {
                    $0.appendingPathComponent($1, isDirectory: true)
                }
            return runtime.executableRelativePath.split(separator: "/").reduce(runtimeRoot) {
                $0.appendingPathComponent(String($1), isDirectory: false)
            }
        }

        var identityMaterial: Data {
            let existingFields = [
                deploymentID, owner.rawValue, targetIdentity, provider.rawValue,
                runtime.version.description, runtime.executableRelativePath,
                runtime.executableSHA256,
            ]
            let fields = layoutKind == .engineeringPlatformProduct
                ? ["ep-product"] + existingFields : existingFields
            return Data(fields.joined(separator: "\u{0}").utf8)
        }
    }

    private struct ExecutableEvidence: Equatable, Sendable {
        let identity: String
        let sha256: String
    }

    private enum InspectionError: Error {
        case absent
        case insecure
    }
}
