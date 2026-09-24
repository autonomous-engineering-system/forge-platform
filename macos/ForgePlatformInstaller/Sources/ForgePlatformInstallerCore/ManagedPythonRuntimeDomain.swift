import Foundation

public enum ManagedPythonRuntimeIdentityError: Error, Equatable, Sendable {
    case invalid
}

public struct ManagedPythonDownloadIdentity: Equatable, Sendable {
    public let url: String
    public let sha256: String

    public init(url: String, sha256: String) throws {
        guard CompositionCatalogValidation.isCanonicalHTTPSURL(url),
              CompositionCatalogValidation.isTaggedSHA256(sha256) else {
            throw ManagedPythonRuntimeIdentityError.invalid
        }
        self.url = url
        self.sha256 = sha256
    }
}

/// Exact catalog-approved CPython identity retained by the native session.
/// No executable path, environment variable, credential or ambient runtime is
/// inferred from this value.
public struct ManagedPythonRuntimeIdentity: Equatable, Sendable {
    public static let schema = "forge-platform.managed-python-runtime/v1"
    public static let implementation = "cpython"
    public static let operatingSystem = "macos"
    public static let architecture = "arm64"
    public static let buildVariant = "standard-gil"
    public static let platformTag = "macosx_26_0_arm64"
    public static let artifactKind = "forge-platform-managed-python-runtime-archive-v1"
    public static let managedRootIdentity = "forge-platform-managed-python-v1"

    public let version: InstallerVersion
    public let minimumMacOSVersion: InstallerVersion
    public let pythonTag: String
    public let abiTag: String
    public let artifact: ManagedPythonDownloadIdentity
    public let source: ManagedPythonDownloadIdentity
    public let sourceProvenance: ManagedPythonDownloadIdentity
    public let buildProvenance: ManagedPythonDownloadIdentity
    public let policyRevision: String
    public let identitySHA256: String

    public init(
        version: InstallerVersion,
        minimumMacOSVersion: InstallerVersion,
        pythonTag: String,
        abiTag: String,
        artifact: ManagedPythonDownloadIdentity,
        source: ManagedPythonDownloadIdentity,
        sourceProvenance: ManagedPythonDownloadIdentity,
        buildProvenance: ManagedPythonDownloadIdentity,
        policyRevision: String,
        identitySHA256: String
    ) throws {
        let expectedTag = "cp\(version.major)\(version.minor)"
        guard minimumMacOSVersion.major >= 26,
              pythonTag == expectedTag,
              abiTag == pythonTag,
              Self.isPythonTag(pythonTag),
              Self.isPolicyRevision(policyRevision),
              CompositionCatalogValidation.isTaggedSHA256(identitySHA256) else {
            throw ManagedPythonRuntimeIdentityError.invalid
        }
        self.version = version
        self.minimumMacOSVersion = minimumMacOSVersion
        self.pythonTag = pythonTag
        self.abiTag = abiTag
        self.artifact = artifact
        self.source = source
        self.sourceProvenance = sourceProvenance
        self.buildProvenance = buildProvenance
        self.policyRevision = policyRevision
        self.identitySHA256 = identitySHA256
        guard identitySHA256 == computedIdentitySHA256 else {
            throw ManagedPythonRuntimeIdentityError.invalid
        }
    }

    var computedIdentitySHA256: String {
        "sha256:" + GitHubInstallerReleaseDescriptor.sha256(
            of: StrictSignedJSON.canonicalPayload(from: identityMaterial)
        )
    }

    private var identityMaterial: StrictJSONResourceValue {
        .object([
            "schema": .string(Self.schema),
            "implementation": .string(Self.implementation),
            "version": .string(version.description),
            "operating_system": .string(Self.operatingSystem),
            "architecture": .string(Self.architecture),
            "minimum_macos_version": .string(minimumMacOSVersion.description),
            "build_variant": .string(Self.buildVariant),
            "python_tag": .string(pythonTag),
            "abi_tag": .string(abiTag),
            "platform_tag": .string(Self.platformTag),
            "artifact_kind": .string(Self.artifactKind),
            "managed_root_identity": .string(Self.managedRootIdentity),
            "artifact": Self.locatorValue(artifact),
            "source": Self.locatorValue(source),
            "source_provenance": Self.locatorValue(sourceProvenance),
            "build_provenance": Self.locatorValue(buildProvenance),
            "policy_revision": .string(policyRevision),
        ])
    }

    private static func locatorValue(_ locator: ManagedPythonDownloadIdentity) -> StrictJSONResourceValue {
        .object([
            "url": .string(locator.url),
            "digest": .string(locator.sha256),
        ])
    }

    private static func isPythonTag(_ value: String) -> Bool {
        guard value.hasPrefix("cp"), (4...5).contains(value.utf8.count) else { return false }
        return value.dropFirst(2).unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    private static func isPolicyRevision(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count),
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else { return false }
        return value.unicodeScalars.allSatisfy {
            isLowercaseLetterOrDigit($0) || [45, 46, 47, 95].contains($0.value)
        }
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

public struct ManagedProductVirtualEnvironmentIdentity: Equatable, Sendable {
    private static let supportedComponentIdentities: Set<String> = [
        "forge-runtime",
        "workspace-server",
        "workspace-client",
        "engineering-platform-server",
        "engineering-platform-project-agent",
    ]

    public let componentIdentity: String
    public let venvIdentity: String
    public let pythonRuntimeIdentitySHA256: String

    public init(
        componentIdentity: String,
        venvIdentity: String,
        pythonRuntimeIdentitySHA256: String
    ) throws {
        guard Self.supportedComponentIdentities.contains(componentIdentity),
              Self.isSafeVenvIdentity(venvIdentity),
              CompositionCatalogValidation.isTaggedSHA256(pythonRuntimeIdentitySHA256) else {
            throw ManagedPythonRuntimeIdentityError.invalid
        }
        self.componentIdentity = componentIdentity
        self.venvIdentity = venvIdentity
        self.pythonRuntimeIdentitySHA256 = pythonRuntimeIdentitySHA256
    }

    private static func isSafeVenvIdentity(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count),
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else { return false }
        return value.unicodeScalars.allSatisfy {
            isLowercaseLetterOrDigit($0) || [45, 46, 95].contains($0.value)
        }
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}
