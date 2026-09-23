import Foundation

enum ManagedCompositionSessionPlanFailure: Error, Equatable, Sendable {
    case rejected
}

/// Pure native projection from already verified catalog/index identities plus
/// exact digest-bound manifest bytes into one immutable wizard session plan.
/// It performs no network request, product readback, provider login or mutation.
struct ManagedCompositionSessionPlanBuilder {
    private static let schemaV1 = "forge-platform.composition/v1"
    private static let schemaV2 = "forge-platform.composition/v2"
    private static let schemaV3 = "forge-platform.composition/v3"
    private static let rootFields: Set<String> = [
        "schema", "composition_id", "channel", "requires_installer",
        "host_requirements", "managed_tools", "python_runtime", "product_venvs",
        "providers", "components", "upgrade_from",
    ]

    func build(
        sessionID: String,
        manifestBytes: Data,
        selectedEntry: VerifiedComponentCombinationCatalogEntry,
        compositionCatalogIdentity: VerifiedCompositionCatalogIdentity,
        componentCombinationCatalogIdentity: VerifiedCompositionCatalogIdentity,
        currentInstaller: CurrentVerifiedInstallerCompositionContext
    ) -> Result<VerifiedCompositionSessionPlan, ManagedCompositionSessionPlanFailure> {
        do {
            guard !manifestBytes.isEmpty,
                  manifestBytes.count <= CompositionCatalogFeedReadback.maximumCatalogBytes,
                  selectedEntry.manifest.sha256
                    == "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: manifestBytes) else {
                throw ManagedCompositionSessionPlanFailure.rejected
            }
            var reader = try StrictJSONResourceReader(data: manifestBytes)
            let root = try reader.parseDocument()
            guard let fields = root.objectValue,
                  Set(fields.keys) == Self.rootFields,
                  let schema = fields["schema"]?.stringValue,
                  schema == Self.schemaV1 || schema == Self.schemaV2 || schema == Self.schemaV3,
                  let compositionID = fields["composition_id"]?.stringValue,
                  compositionID == selectedEntry.compositionID,
                  let channel = fields["channel"]?.stringValue,
                  channel == selectedEntry.channel.rawValue,
                  try Self.matchesInstallerRequirement(
                    fields["requires_installer"],
                    selectedEntry.installerRequirement
                  ),
                  let providerValues = fields["providers"]?.arrayValue,
                  let componentValues = fields["components"]?.arrayValue else {
                throw ManagedCompositionSessionPlanFailure.rejected
            }

            let componentIdentities = try Set(componentValues.map(Self.componentIdentity))
            guard componentIdentities == selectedEntry.componentIdentities else {
                throw ManagedCompositionSessionPlanFailure.rejected
            }
            let requirements = try providerValues.map {
                try Self.providerRequirement($0, schema: schema)
            }
            guard Set(requirements.map(\.id)).count == requirements.count else {
                throw ManagedCompositionSessionPlanFailure.rejected
            }

            let plan = try VerifiedCompositionSessionPlan(
                sessionID: sessionID,
                compositionIdentity: compositionID,
                manifestSHA256: selectedEntry.manifest.sha256,
                installerReleaseSequence: currentInstaller.installerReleaseSequence,
                installerProvenanceSHA256: currentInstaller.installerProvenanceSHA256,
                installerReleaseTrustConfigurationSHA256:
                    currentInstaller.installerReleaseTrustConfigurationSHA256,
                compositionCatalogFeed: currentInstaller.compositionCatalogFeed,
                compositionCatalog: compositionCatalogIdentity,
                componentCombinationCatalog: componentCombinationCatalogIdentity,
                componentSelectionSequence: selectedEntry.selectionSequence,
                providerRequirements: requirements
            )
            guard currentInstaller.accepts(plan) else {
                throw ManagedCompositionSessionPlanFailure.rejected
            }
            return .success(plan)
        } catch {
            return .failure(.rejected)
        }
    }

    private static func matchesInstallerRequirement(
        _ value: StrictJSONResourceValue?,
        _ expected: VerifiedCompositionCatalogInstallerRequirement
    ) throws -> Bool {
        guard let fields = value?.objectValue,
              Set(fields.keys) == Set(["minimum_version", "capabilities"]),
              let version = fields["minimum_version"]?.stringValue,
              let parsedVersion = try? InstallerVersion(version),
              parsedVersion == expected.minimumVersion,
              let capabilityValues = fields["capabilities"]?.arrayValue else {
            throw ManagedCompositionSessionPlanFailure.rejected
        }
        let capabilities = try capabilityValues.map { item -> String in
            guard let value = item.stringValue,
                  CompositionCatalogValidation.isCapability(value) else {
                throw ManagedCompositionSessionPlanFailure.rejected
            }
            return value
        }
        return capabilities == expected.capabilities
    }

    private static func componentIdentity(_ value: StrictJSONResourceValue) throws -> String {
        guard let fields = value.objectValue,
              let identity = fields["identity"]?.stringValue,
              CompositionCatalogValidation.isCapability(identity) else {
            throw ManagedCompositionSessionPlanFailure.rejected
        }
        return identity
    }

    private static func providerRequirement(
        _ value: StrictJSONResourceValue,
        schema: String
    ) throws -> ProviderRequirement {
        guard let fields = value.objectValue else {
            throw ManagedCompositionSessionPlanFailure.rejected
        }
        let expectedFields: Set<String>
        switch schema {
        case schemaV1:
            expectedFields = ["identity", "required", "minimum_version", "credential_scope"]
        case schemaV2:
            expectedFields = ["identity", "required", "minimum_version", "credential_scope", "owner_component", "target_identity"]
        case schemaV3:
            expectedFields = [
                "identity", "required", "minimum_version", "credential_scope",
                "owner_component", "target_identity", "runtime",
            ]
        default:
            throw ManagedCompositionSessionPlanFailure.rejected
        }
        guard Set(fields.keys) == expectedFields,
              let providerRaw = fields["identity"]?.stringValue,
              let provider = ProviderID(rawValue: providerRaw),
              case .boolean(let required)? = fields["required"],
              let scopeRaw = fields["credential_scope"]?.stringValue,
              let scope = ProviderCredentialScope(rawValue: scopeRaw) else {
            throw ManagedCompositionSessionPlanFailure.rejected
        }

        let minimumVersion: InstallerVersion?
        switch fields["minimum_version"] {
        case .string(let raw)?:
            guard let parsed = try? InstallerVersion(raw) else {
                throw ManagedCompositionSessionPlanFailure.rejected
            }
            minimumVersion = parsed
        case .null?:
            minimumVersion = nil
        default:
            throw ManagedCompositionSessionPlanFailure.rejected
        }

        if schema == schemaV1 {
            guard scope == .user else {
                throw ManagedCompositionSessionPlanFailure.rejected
            }
            return ProviderRequirement(
                provider: provider,
                isRequired: required,
                minimumVersion: minimumVersion,
                credentialScope: .user
            )
        }

        guard let ownerRaw = fields["owner_component"]?.stringValue,
              let owner = ProviderOwnerComponent(rawValue: ownerRaw),
              let target = fields["target_identity"]?.stringValue,
              Self.isSafeTargetIdentity(target),
              scope == owner.requiredCredentialScope else {
            throw ManagedCompositionSessionPlanFailure.rejected
        }
        let runtime: ProviderRuntimeRequirement?
        if schema == schemaV3 {
            guard let runtimeFields = fields["runtime"]?.objectValue,
                  Set(runtimeFields.keys) == Set([
                    "version", "archive_kind", "artifact",
                    "executable_relative_path", "executable_digest",
                  ]),
                  let versionRaw = runtimeFields["version"]?.stringValue,
                  let runtimeVersion = try? InstallerVersion(versionRaw),
                  let archiveRaw = runtimeFields["archive_kind"]?.stringValue,
                  let archiveKind = ProviderRuntimeArchiveKind(rawValue: archiveRaw),
                  let artifact = runtimeFields["artifact"]?.objectValue,
                  Set(artifact.keys) == Set(["url", "digest"]),
                  let artifactURL = artifact["url"]?.stringValue,
                  let artifactDigest = artifact["digest"]?.stringValue,
                  let executableRelativePath = runtimeFields["executable_relative_path"]?.stringValue,
                  let executableDigest = runtimeFields["executable_digest"]?.stringValue,
                  let parsedRuntime = try? ProviderRuntimeRequirement(
                    version: runtimeVersion,
                    archiveKind: archiveKind,
                    artifactURL: artifactURL,
                    artifactSHA256: artifactDigest,
                    executableRelativePath: executableRelativePath,
                    executableSHA256: executableDigest
                  ) else {
                throw ManagedCompositionSessionPlanFailure.rejected
            }
            runtime = parsedRuntime
        } else {
            runtime = nil
        }
        return ProviderRequirement(
            provider: provider,
            isRequired: required,
            minimumVersion: minimumVersion,
            credentialScope: scope,
            ownerComponent: owner,
            targetIdentity: target,
            runtime: runtime
        )
    }

    private static func isSafeTargetIdentity(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isLowercaseLetterOrDigit(scalar)
                || scalar.value == 45
                || scalar.value == 46
                || scalar.value == 95
        }
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}
