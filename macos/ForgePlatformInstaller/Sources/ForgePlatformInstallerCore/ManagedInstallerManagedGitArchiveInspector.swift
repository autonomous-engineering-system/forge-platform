import CryptoKit
import Foundation

public enum ManagedInstallerManagedGitArchiveInspectionFailure:
    Error, Equatable, Sendable {
    case invalidRequest
    case rejected
}

public struct ManagedInstallerManagedGitArchiveInspection: Equatable, Sendable {
    public static let manifestPath = "forge-platform-managed-git.json"
    public static let binaryPath = "bin/git"
    public static let execPath = "libexec/git-core"
    public static let layout = "forge-platform-managed-git-archive-layout/v1"
    public static let schema = "forge-platform.managed-git-archive-manifest/v1"

    public let version: InstallerVersion
    public let archiveSHA256: String
    public let binarySHA256: String
    public let sourceArchive: ManagedPythonDownloadIdentity
    public let buildProvenanceSHA256: String
    public let minimumMacOSVersion: InstallerVersion
    public let evidenceReference: String
}

struct ManagedInstallerManagedGitArchiveInventory: Equatable, Sendable {
    let inspection: ManagedInstallerManagedGitArchiveInspection
    let members: [ManagedPythonRuntimeArchiveMember]
}

/// Admits one exact archive with a thin-arm64 Git entrypoint, constrained tree
/// shape and declared source/build identities. A later producer qualification
/// must verify every supporting executable and the runtime-prefix behaviour.
/// Its caller supplies bytes for the signed composition's exact URL and digest;
/// neither a filesystem path nor an executable command is accepted here.
public enum MacOSManagedInstallerManagedGitArchiveInspector {
    public static func inspect(
        _ archive: Data,
        requirement: ManagedToolRequirement
    ) -> Result<
        ManagedInstallerManagedGitArchiveInspection,
        ManagedInstallerManagedGitArchiveInspectionFailure
    > {
        do {
            return .success(try inspectForExtraction(
                archive, requirement: requirement
            ).inspection)
        } catch let failure as ManagedInstallerManagedGitArchiveInspectionFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    static func inspectForExtraction(
        _ archive: Data,
        requirement: ManagedToolRequirement
    ) throws -> ManagedInstallerManagedGitArchiveInventory {
        guard requirement.identity == .git else {
            throw ManagedInstallerManagedGitArchiveInspectionFailure.invalidRequest
        }
        guard !archive.isEmpty,
              "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: archive)
                == requirement.artifact.sha256 else {
            throw ManagedInstallerManagedGitArchiveInspectionFailure.rejected
        }
        var tar = try ManagedPythonTarInspector(
            maximumExpandedBytes: MacOSManagedPythonRuntimeArchiveInspector
                .maximumExpandedArchiveBytes,
            maximumEntries: MacOSManagedPythonRuntimeArchiveInspector.maximumArchiveEntries,
            maximumPathBytes: MacOSManagedPythonRuntimeArchiveInspector.maximumPathBytes,
            maximumManifestBytes: 64 * 1024,
            maximumInterpreterBytes: 128 * 1024 * 1024,
            manifestPath: ManagedInstallerManagedGitArchiveInspection.manifestPath,
            executablePath: ManagedInstallerManagedGitArchiveInspection.binaryPath
        )
        try ManagedPythonGZIP.inspect(archive, feeding: &tar)
        let contents = try tar.finish()
        let fields = try manifestFields(contents.manifest)
        let binarySHA256 = "sha256:"
            + GitHubInstallerReleaseDescriptor.sha256(of: contents.interpreter)
        let minimumMacOSVersion = try ManagedPythonMachOInspector.inspect(
            contents.interpreter
        )
        guard fields["schema"]?.stringValue
                == ManagedInstallerManagedGitArchiveInspection.schema,
              fields["layout"]?.stringValue
                == ManagedInstallerManagedGitArchiveInspection.layout,
              fields["version"]?.stringValue == requirement.version.description,
              fields["artifact_url"]?.stringValue == requirement.artifact.url,
              fields["architecture"]?.stringValue == "arm64",
              fields["managed_root_identity"]?.stringValue
                == ManagedToolRequirement.managedRootIdentity,
              fields["binary_relative_path"]?.stringValue
                == ManagedInstallerManagedGitArchiveInspection.binaryPath,
              fields["git_exec_path_relative"]?.stringValue
                == ManagedInstallerManagedGitArchiveInspection.execPath,
              fields["binary_sha256"]?.stringValue == binarySHA256,
              fields["minimum_macos_version"]?.stringValue
                == minimumMacOSVersion.description,
              minimumMacOSVersion.major >= 26,
              case .some(.boolean(true)) = fields["runtime_prefix"],
              let sourceURL = fields["source_archive_url"]?.stringValue,
              let sourceSHA256 = fields["source_archive_sha256"]?.stringValue,
              let buildProvenanceSHA256 = fields["build_provenance_sha256"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(buildProvenanceSHA256),
              contents.members.contains(where: {
                  $0.path == ManagedInstallerManagedGitArchiveInspection.execPath + "/"
                    && $0.kind == .directory
              }),
              contents.members.contains(where: {
                  $0.path.hasPrefix(
                      ManagedInstallerManagedGitArchiveInspection.execPath + "/"
                  ) && $0.kind == .file && $0.mode & 0o100 != 0
              }) else {
            throw ManagedInstallerManagedGitArchiveInspectionFailure.rejected
        }
        let source = try ManagedPythonDownloadIdentity(
            url: sourceURL, sha256: sourceSHA256
        )
        let evidenceReference = "managed-git-archive-"
            + SHA256.hash(data: Data((
                requirement.artifact.sha256 + binarySHA256
                    + source.sha256 + buildProvenanceSHA256
            ).utf8)).map { String(format: "%02x", $0) }.joined()
        return ManagedInstallerManagedGitArchiveInventory(
            inspection: ManagedInstallerManagedGitArchiveInspection(
                version: requirement.version,
                archiveSHA256: requirement.artifact.sha256,
                binarySHA256: binarySHA256,
                sourceArchive: source,
                buildProvenanceSHA256: buildProvenanceSHA256,
                minimumMacOSVersion: minimumMacOSVersion,
                evidenceReference: evidenceReference
            ),
            members: contents.members
        )
    }

    private static func manifestFields(
        _ data: Data
    ) throws -> [String: StrictJSONResourceValue] {
        var reader = try StrictJSONResourceReader(data: data)
        let value = try reader.parseDocument()
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                  "schema", "layout", "version", "artifact_url", "architecture",
                  "managed_root_identity", "binary_relative_path",
                  "git_exec_path_relative", "binary_sha256",
                  "minimum_macos_version", "runtime_prefix",
                  "source_archive_url", "source_archive_sha256",
                  "build_provenance_sha256",
              ]),
              StrictSignedJSON.canonicalPayload(from: value) == data else {
            throw ManagedInstallerManagedGitArchiveInspectionFailure.rejected
        }
        return fields
    }
}
