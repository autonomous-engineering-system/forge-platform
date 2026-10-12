import Darwin
import Foundation

struct MacOSInstallerHelperBootstrapMetadata: Sendable {
    let trust: SealedInstallerReleaseTrustConfiguration
    let provenance: SealedInstallerReleaseProvenance
    private init(trust: SealedInstallerReleaseTrustConfiguration, provenance: SealedInstallerReleaseProvenance) {
        self.trust = trust; self.provenance = provenance
    }
    static func decodeSignedInfo(_ fields: [String: Any]) -> Self? {
        guard Set(fields.keys) == Set(["CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString",
            "SMAuthorizedClients", "FPIBootstrapSchema", "FPIReleaseTrustResource", "FPIReleaseProvenanceResource"]),
              fields["CFBundleIdentifier"] as? String == MacOSInstallerHelperBootstrapContract.label,
              fields["FPIBootstrapSchema"] as? String == "forge-platform.installer-bootstrap/v1",
              fields["SMAuthorizedClients"] as? [String] == [MacOSInstallerHelperBootstrapContract.requirement(
                identifier: MacOSInstallerHelperBootstrapContract.appIdentifier)],
              let trustBytes = resource(fields["FPIReleaseTrustResource"]),
              let provenanceBytes = resource(fields["FPIReleaseProvenanceResource"]),
              let trust = try? SealedInstallerReleaseTrustConfiguration.decodeJSONResource(trustBytes),
              let provenance = try? SealedInstallerReleaseProvenance.decodeJSONResource(provenanceBytes),
              trust.expectedBundleIdentifier == MacOSInstallerHelperBootstrapContract.appIdentifier,
              trust.expectedTeamIdentifier == MacOSInstallerHelperBootstrapContract.team,
              trust.repository == "autonomous-engineering-system/forge-platform",
              provenance.releaseTrustConfigurationSHA256 == trust.configurationSHA256,
              fields["CFBundleVersion"] as? String == provenance.installerVersion.description,
              fields["CFBundleShortVersionString"] as? String == provenance.installerVersion.description else { return nil }
        return .init(trust: trust, provenance: provenance)
    }
    private static func resource(_ field: Any?) -> Data? {
        guard let encoded = field as? String, encoded.utf8.count <= 44 * 1024,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 32 * 1024,
              bytes.base64EncodedString() == encoded else { return nil }
        return bytes
    }
    func matches(_ record: VerifiedInstallerReleaseRecord) -> Bool {
        record.helperPackage != nil && record.sequence == provenance.releaseSequence &&
        record.release.version == provenance.installerVersion && record.channel == provenance.channel &&
        record.sourceRevision == provenance.sourceRevision && record.provenanceExpectation.policyRevision == provenance.policyRevision &&
        record.provenanceExpectation.capabilities == provenance.capabilities && record.provenanceSHA256 == provenance.provenanceSHA256 &&
        record.expectedReleaseTrustConfigurationSHA256 == trust.configurationSHA256 &&
        record.expectedBundleIdentifier == trust.expectedBundleIdentifier && record.expectedTeamIdentifier == trust.expectedTeamIdentifier
    }
}

/// Only the protected standalone executable's own signed metadata is accepted.
/// The current process must match the static code at the fixed installed path.
struct MacOSInstallerHelperBootstrapMetadataReader: Sendable {
    typealias ProcessRead = @Sendable (URL) -> MacOSInstallerPackageHelperProcess?
    typealias InfoRead = @Sendable (URL) -> [String: Any]?
    private let executable: URL
    private let owner: uid_t
    private let process: ProcessRead
    private let info: InfoRead
    init() {
        executable = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/" + MacOSInstallerHelperBootstrapContract.label)
        owner = 0
        process = { url in MacOSInstallerPackageHelperInstalledReader.inspectProcess(getpid(), executable: url,
            team: MacOSInstallerHelperBootstrapContract.team, expectedOwner: 0,
            expectedIdentifier: MacOSInstallerHelperBootstrapContract.label) }
        info = { MacOSInstallerHelperBootstrapAuthorization.signedInfo($0, identifier: MacOSInstallerHelperBootstrapContract.label) }
    }
    // Internal source-only filesystem/inspection seam, never a runtime option.
    init(executable: URL, owner: uid_t, process: @escaping ProcessRead, info: @escaping InfoRead) {
        self.executable = executable; self.owner = owner; self.process = process; self.info = info
    }
    func load() -> MacOSInstallerHelperBootstrapMetadata? {
        guard geteuid() == owner, executable.lastPathComponent == MacOSInstallerHelperBootstrapContract.label,
              let parentBefore = secure(executable.deletingLastPathComponent(), directory: true),
              let before = secure(executable, directory: false), before.st_size >= 32, before.st_size <= 128 * 1024 * 1024,
              (try? MacOSInstallerExecutableArchitecture.requireThinARM64Executable(at: executable)) != nil,
              let processBefore = process(executable), processBefore.processID == getpid(), processBefore.startSeconds > 0,
              let fields = info(executable), let metadata = MacOSInstallerHelperBootstrapMetadata.decodeSignedInfo(fields),
              let after = secure(executable, directory: false), MacOSInstallerHelperPackageVerifier.same(before, after),
              let parentAfter = secure(executable.deletingLastPathComponent(), directory: true),
              MacOSInstallerHelperPackageVerifier.same(parentBefore, parentAfter), process(executable) == processBefore else { return nil }
        return metadata
    }
    private func secure(_ url: URL, directory: Bool) -> stat? {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY | (directory ? O_DIRECTORY : 0)) }
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_uid == owner,
              value.st_mode & mode_t(S_IFMT) == (directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)),
              value.st_mode & 0o7022 == 0, // SMJobBless installs its protected root-only executable as 0544.
              // Retain the exact staged 0755 profile; no writable or arbitrary modes.
              directory || (value.st_nlink == 1 && [mode_t(0o544), mode_t(0o755)].contains(value.st_mode & 0o7777)),
              MacOSInstallerHelperPackageVerifier.noACL(descriptor) else { return nil }
        return value
    }
}
