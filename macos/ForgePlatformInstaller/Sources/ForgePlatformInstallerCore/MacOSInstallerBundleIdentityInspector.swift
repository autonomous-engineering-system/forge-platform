import Foundation
import Security

/// Immutable evidence read from the code-signed current app bundle. It is
/// deliberately narrower than a general code-signing report: no certificate
/// chain, path, entitlement, command output or signing-time data can cross
/// into the self-update state machine.
public struct MacOSInstallerBundleCodeSigningEvidence: Equatable, Sendable {
    public let bundleIdentifier: String
    public let installerVersion: InstallerVersion
    public let teamIdentifier: String
    /// Full SHA-256 of the architecture-selected CodeDirectory, represented
    /// by the release descriptor's `code_directory_sha256` field.
    public let codeDirectorySHA256: String

    public init(
        bundleIdentifier: String,
        installerVersion: InstallerVersion,
        teamIdentifier: String,
        codeDirectorySHA256: String
    ) throws {
        guard InstallerSelfUpdateValidation.isBundleIdentifier(bundleIdentifier),
              InstallerSelfUpdateValidation.isTeamIdentifier(teamIdentifier),
              InstallerSelfUpdateValidation.isSHA256(codeDirectorySHA256) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.bundleIdentifier = bundleIdentifier
        self.installerVersion = installerVersion
        self.teamIdentifier = teamIdentifier
        self.codeDirectorySHA256 = codeDirectorySHA256
    }
}

/// Reads only code-signing evidence from a statically validated app bundle.
/// The concrete implementation invokes one fixed Apple tool only to obtain
/// the full CodeDirectory SHA-256 that Security.framework does not expose as
/// a public typed constant. It never passes a shell expression, UI input or a
/// caller-selected executable to that tool.
public protocol MacOSInstallerBundleCodeSigningInspecting: Sendable {
    func inspectSealedInstallerBundle(
        at bundleURL: URL
    ) async -> Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure>
}

/// Production code-signing evidence reader for an app bundle. It validates the
/// static code object before and after collecting metadata, takes identifier
/// and version from the code-signing information itself, and obtains the
/// 32-byte CodeDirectory hash from the fixed system `codesign` binary. Any
/// absent, duplicate or malformed evidence fails closed.
public struct MacOSInstallerBundleCodeSigningInspector: MacOSInstallerBundleCodeSigningInspecting {
    private static let codeSignToolURL = URL(fileURLWithPath: "/usr/bin/codesign", isDirectory: false)
    private static let codeSignTimeout: DispatchTimeInterval = .seconds(20)
    private static let terminationGracePeriod: DispatchTimeInterval = .seconds(2)
    private static let outputDrainTimeout: DispatchTimeInterval = .seconds(2)

    public init() {}

    public func inspectSealedInstallerBundle(
        at bundleURL: URL
    ) async -> Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure> {
        do {
            let staticCode = try createAndValidateStaticCode(at: bundleURL)
            try MacOSInstallerExecutableArchitecture.requireThinARM64Executable(in: bundleURL)
            let signingInformation = try copySigningInformation(from: staticCode)
            let codeDirectorySHA256 = try fullCodeDirectorySHA256(for: bundleURL)
            _ = try createAndValidateStaticCode(at: bundleURL)
            return .success(try MacOSInstallerBundleCodeSigningEvidence(
                bundleIdentifier: signingInformation.bundleIdentifier,
                installerVersion: signingInformation.installerVersion,
                teamIdentifier: signingInformation.teamIdentifier,
                codeDirectorySHA256: codeDirectorySHA256
            ))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        }
    }

    func createAndValidateStaticCode(at bundleURL: URL) throws -> SecStaticCode {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
              ) == errSecSuccess else {
            throw MacOSInstallerBundleCodeSigningInspectorError.invalidCode
        }
        return staticCode
    }

    func copySigningInformation(
        from staticCode: SecStaticCode
    ) throws -> MacOSInstallerBundleSigningInformation {
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let signingInformation else {
            throw MacOSInstallerBundleCodeSigningInspectorError.invalidCode
        }
        let information = signingInformation as NSDictionary
        guard let signingIdentifier = information[kSecCodeInfoIdentifier] as? String,
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
              let plist = information[kSecCodeInfoPList] as? [String: Any],
              let plistBundleIdentifier = plist["CFBundleIdentifier"] as? String,
              let version = plist["CFBundleShortVersionString"] as? String,
              signingIdentifier == plistBundleIdentifier else {
            throw MacOSInstallerBundleCodeSigningInspectorError.invalidCode
        }
        return try MacOSInstallerBundleSigningInformation(
            bundleIdentifier: signingIdentifier,
            installerVersion: InstallerVersion(version),
            teamIdentifier: teamIdentifier
        )
    }

    func fullCodeDirectorySHA256(for bundleURL: URL) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.codeSignToolURL.path) else {
            throw MacOSInstallerBundleCodeSigningInspectorError.invalidCode
        }
        let process = Process()
        process.executableURL = Self.codeSignToolURL
        process.arguments = ["-d", "--verbose=4", bundleURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let collector = BoundedProcessOutputCollector(maximumBytes: 128 * 1024)
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }
        try process.run()
        let outputGroup = DispatchGroup()
        outputGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { outputGroup.leave() }
            collector.consume(output.fileHandleForReading)
        }
        guard termination.wait(timeout: .now() + Self.codeSignTimeout) == .success else {
            // The executable and arguments above are fixed by this source;
            // termination is therefore confined to the exact inspection child
            // rather than an application, provider, or component process.
            process.terminate()
            if termination.wait(timeout: .now() + Self.terminationGracePeriod) != .success {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                guard termination.wait(timeout: .now() + Self.terminationGracePeriod) == .success else {
                    throw MacOSInstallerBundleCodeSigningInspectorError.invalidCode
                }
            }
            throw MacOSInstallerBundleCodeSigningInspectorError.invalidCode
        }
        guard outputGroup.wait(timeout: .now() + Self.outputDrainTimeout) == .success else {
            throw MacOSInstallerBundleCodeSigningInspectorError.invalidCode
        }
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw MacOSInstallerBundleCodeSigningInspectorError.invalidCode
        }
        guard let data = collector.collectedData(),
              let text = String(data: data, encoding: .utf8) else {
            throw MacOSInstallerBundleCodeSigningInspectorError.invalidCode
        }
        return try MacOSCodeSignEvidenceParser.fullCodeDirectorySHA256(from: text)
    }
}

/// Concrete current-bundle inspector used by the trusted runtime builder. It
/// binds the sealed V1/V2 resources to signing information observed from the
/// exact current app bundle; it never reads identity from PATH, environment,
/// displayed app name or an unsealed Info.plist.
public struct MacOSCurrentInstallerBundleInspector: CurrentInstallerBundleInspecting {
    private let bundleURL: URL
    private let signingInspector: any MacOSInstallerBundleCodeSigningInspecting
    private let trustConfigurationLoader: any SealedInstallerReleaseTrustConfigurationLoading
    private let provenanceLoader: any SealedInstallerReleaseProvenanceLoading

    public init(
        bundle: Bundle = .main,
        signingInspector: any MacOSInstallerBundleCodeSigningInspecting = MacOSInstallerBundleCodeSigningInspector(),
        trustConfigurationLoader: (any SealedInstallerReleaseTrustConfigurationLoading)? = nil,
        provenanceLoader: (any SealedInstallerReleaseProvenanceLoading)? = nil,
        bundleValidator: any SealedInstallerBundleValidating = MacOSSealedInstallerBundleValidator()
    ) {
        self.bundleURL = bundle.bundleURL
        self.signingInspector = signingInspector
        self.trustConfigurationLoader = trustConfigurationLoader ?? BundleSealedInstallerReleaseTrustConfigurationLoader(
            bundle: bundle,
            bundleValidator: bundleValidator
        )
        self.provenanceLoader = provenanceLoader ?? BundleSealedInstallerReleaseProvenanceLoader(
            bundle: bundle,
            bundleValidator: bundleValidator
        )
    }

    public init(
        bundleURL: URL,
        signingInspector: any MacOSInstallerBundleCodeSigningInspecting,
        trustConfigurationLoader: any SealedInstallerReleaseTrustConfigurationLoading,
        provenanceLoader: any SealedInstallerReleaseProvenanceLoading
    ) {
        self.bundleURL = bundleURL
        self.signingInspector = signingInspector
        self.trustConfigurationLoader = trustConfigurationLoader
        self.provenanceLoader = provenanceLoader
    }

    public func inspectCurrentInstallerBundle() async -> Result<CurrentInstallerBundleIdentity, InstallerSelfUpdateFailure> {
        let signingEvidence: MacOSInstallerBundleCodeSigningEvidence
        switch await signingInspector.inspectSealedInstallerBundle(at: bundleURL) {
        case .success(let evidence):
            signingEvidence = evidence
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        }
        let trustConfiguration: SealedInstallerReleaseTrustConfiguration
        switch await trustConfigurationLoader.loadSealedReleaseTrustConfiguration() {
        case .success(let configuration):
            trustConfiguration = configuration
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        }
        let provenance: SealedInstallerReleaseProvenance
        switch await provenanceLoader.loadSealedReleaseProvenance() {
        case .success(let loadedProvenance):
            provenance = loadedProvenance
        case .failure:
            return .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        }
        guard signingEvidence.bundleIdentifier == trustConfiguration.expectedBundleIdentifier,
              signingEvidence.teamIdentifier == trustConfiguration.expectedTeamIdentifier,
              signingEvidence.installerVersion == provenance.installerVersion,
              provenance.releaseTrustConfigurationSHA256 == trustConfiguration.configurationSHA256 else {
            return .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        }
        do {
            return .success(try CurrentInstallerBundleIdentity(
                version: signingEvidence.installerVersion,
                acceptedReleaseSequence: provenance.releaseSequence,
                channel: provenance.channel,
                sourceRevision: provenance.sourceRevision,
                bundleIdentifier: signingEvidence.bundleIdentifier,
                teamIdentifier: signingEvidence.teamIdentifier,
                codeDirectorySHA256: signingEvidence.codeDirectorySHA256,
                provenanceSHA256: provenance.provenanceSHA256,
                releaseTrustConfigurationSHA256: trustConfiguration.configurationSHA256
            ))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        }
    }
}

struct MacOSInstallerBundleSigningInformation {
    let bundleIdentifier: String
    let installerVersion: InstallerVersion
    let teamIdentifier: String

    init(
        bundleIdentifier: String,
        installerVersion: InstallerVersion,
        teamIdentifier: String
    ) throws {
        guard InstallerSelfUpdateValidation.isBundleIdentifier(bundleIdentifier),
              InstallerSelfUpdateValidation.isTeamIdentifier(teamIdentifier) else {
            throw MacOSInstallerBundleCodeSigningInspectorError.invalidCode
        }
        self.bundleIdentifier = bundleIdentifier
        self.installerVersion = installerVersion
        self.teamIdentifier = teamIdentifier
    }
}

enum MacOSInstallerBundleCodeSigningInspectorError: Error {
    case invalidCode
}

/// Exact parser for the one full SHA-256 field needed from the fixed system
/// `codesign` diagnostic. A partial 20-byte CDHash, a duplicate architecture
/// value or any unrelated output is not release identity evidence.
enum MacOSCodeSignEvidenceParser {
    static func fullCodeDirectorySHA256(from output: String) throws -> String {
        let prefix = "CandidateCDHashFull sha256="
        let matches = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                guard line.hasPrefix(prefix) else {
                    return nil
                }
                return String(line.dropFirst(prefix.count))
            }
        guard matches.count == 1,
              InstallerSelfUpdateValidation.isSHA256(matches[0]) else {
            throw MacOSInstallerBundleCodeSigningInspectorError.invalidCode
        }
        return matches[0]
    }
}

/// Drains a fixed-tool diagnostic pipe while retaining a small bounded copy.
/// An unexpected large diagnostic stream is discarded and reported as invalid
/// evidence, but it never blocks the child process or becomes unbounded memory.
final class BoundedProcessOutputCollector: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var overflowed = false
    private var readFailed = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func consume(_ fileHandle: FileHandle) {
        do {
            while let chunk = try fileHandle.read(upToCount: 8192), !chunk.isEmpty {
                lock.lock()
                if !overflowed {
                    if data.count <= maximumBytes - chunk.count {
                        data.append(chunk)
                    } else {
                        overflowed = true
                        data.removeAll(keepingCapacity: false)
                    }
                }
                lock.unlock()
            }
        } catch {
            lock.lock()
            readFailed = true
            data.removeAll(keepingCapacity: false)
            lock.unlock()
        }
    }

    func collectedData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed, !readFailed else {
            return nil
        }
        return data
    }
}
