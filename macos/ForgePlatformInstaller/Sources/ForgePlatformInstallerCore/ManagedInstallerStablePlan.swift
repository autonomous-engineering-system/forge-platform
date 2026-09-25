import CryptoKit
import Foundation

/// Exact pre-mutation authority shared by native journal seeding and the
/// post-tool replanner. The fingerprint is derived here from the reviewed
/// operation and immutable session; callers cannot inject an unrelated hash.
public struct ManagedInstallerStablePlan: Equatable, Sendable {
    public let session: VerifiedCompositionSessionPlan
    public let deployment: ManagedDeploymentTarget
    public let activationPlan: ManagedPythonRuntimeActivationPlan
    public let reviewedOperation: ReviewedManagedDeploymentOperation
    public let enabledProviderRequirements: [ProviderRequirement]
    public let originalManagedToolActions: [ManagedToolOriginalPlanAction]
    public let fingerprint: String

    public init(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget,
        activationPlan: ManagedPythonRuntimeActivationPlan,
        reviewedOperation: ReviewedManagedDeploymentOperation,
        originalManagedToolActions: [ManagedToolOriginalPlanAction]
    ) throws {
        let actions = originalManagedToolActions.sorted {
            $0.requirement.identity.rawValue < $1.requirement.identity.rawValue
        }
        let requirements = Dictionary(uniqueKeysWithValues: session.managedTools.map {
            ($0.identity, $0)
        })
        let availableProviders = Dictionary(uniqueKeysWithValues: session.providerRequirements.map {
            ($0.id, $0)
        })
        let enabledProviders = reviewedOperation.enabledProviderRequirements.sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        let requiredProviderIdentities = Set(session.providerRequirements.compactMap {
            $0.isRequired ? $0.id : nil
        })
        guard Set(actions.map(\.requirement.identity)).count == actions.count,
              Set(actions.map(\.requirement.identity)) == Set(requirements.keys),
              actions.allSatisfy({ requirements[$0.requirement.identity] == $0.requirement }),
              Set(enabledProviders.map(\.id)).count == enabledProviders.count,
              enabledProviders.allSatisfy({ availableProviders[$0.id] == $0 }),
              requiredProviderIdentities.isSubset(of: Set(enabledProviders.map(\.id))),
              activationPlan.sessionID == session.sessionID,
              activationPlan.deploymentID == deployment.id,
              activationPlan.compositionIdentity == session.compositionIdentity,
              activationPlan.manifestSHA256 == session.manifestSHA256,
              activationPlan.runtimeIdentitySHA256 == session.managedPythonRuntime.identitySHA256,
              activationPlan.runtimeArchiveSHA256 == session.managedPythonRuntime.artifact.sha256,
              activationPlan.productVirtualEnvironments == session.productVirtualEnvironments,
              reviewedOperation.sessionID == session.sessionID,
              reviewedOperation.compositionIdentity == session.compositionIdentity,
              reviewedOperation.manifestSHA256 == session.manifestSHA256,
              reviewedOperation.deploymentID == deployment.id,
              reviewedOperation.deploymentExists == deployment.exists,
              Set(reviewedOperation.components.map(\.componentID)).count
                == reviewedOperation.components.count else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }

        self.session = session
        self.deployment = deployment
        self.activationPlan = activationPlan
        self.reviewedOperation = reviewedOperation
        enabledProviderRequirements = enabledProviders
        self.originalManagedToolActions = actions
        fingerprint = Self.fingerprint(
            session: session,
            deployment: deployment,
            activationPlan: activationPlan,
            reviewedOperation: reviewedOperation,
            enabledProviders: enabledProviders,
            actions: actions
        )
    }

    private static func fingerprint(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget,
        activationPlan: ManagedPythonRuntimeActivationPlan,
        reviewedOperation: ReviewedManagedDeploymentOperation,
        enabledProviders: [ProviderRequirement],
        actions: [ManagedToolOriginalPlanAction]
    ) -> String {
        let material: StrictJSONResourceValue = .object([
            "schema": .string("forge-platform.native-stable-plan/v1"),
            "session": sessionValue(session),
            "deployment": deploymentValue(
                deployment,
                inventoryEvidenceReference: reviewedOperation.inventoryEvidenceReference
            ),
            "installer_release": installerValue(reviewedOperation.currentInstallerRelease),
            "enabled_providers": .array(enabledProviders.map(providerValue)),
            "managed_tools": .array(actions.map(toolValue)),
            "python": pythonValue(activationPlan),
            "components": .array(
                reviewedOperation.components.sorted { $0.componentID < $1.componentID }
                    .map(componentValue)
            ),
        ])
        return SHA256.hash(data: StrictSignedJSON.canonicalPayload(from: material))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func sessionValue(
        _ session: VerifiedCompositionSessionPlan
    ) -> StrictJSONResourceValue {
        let venvs: [StrictJSONResourceValue] = session.productVirtualEnvironments.map {
            .object([
                "component_identity": .string($0.componentIdentity),
                "venv_identity": .string($0.venvIdentity),
                "python_runtime_identity": .string($0.pythonRuntimeIdentitySHA256),
            ])
        }
        let providers = session.providerRequirements.sorted {
            $0.id.rawValue < $1.id.rawValue
        }.map(providerValue)
        let fields: [String: StrictJSONResourceValue] = [
            "session_id": .string(session.sessionID),
            "composition_identity": .string(session.compositionIdentity),
            "manifest_sha256": .string(session.manifestSHA256),
            "installer_release_sequence": .integer(String(session.installerReleaseSequence)),
            "installer_provenance_sha256": .string(session.installerProvenanceSHA256),
            "installer_release_trust_configuration_sha256":
                .string(session.installerReleaseTrustConfigurationSHA256),
            "composition_catalog_feed": .string(session.compositionCatalogFeed.url),
            "composition_catalog": catalogValue(session.compositionCatalog),
            "component_combination_catalog": catalogValue(session.componentCombinationCatalog),
            "component_selection_sequence": .integer(String(session.componentSelectionSequence)),
            "managed_python_runtime_identity": .string(
                session.managedPythonRuntime.identitySHA256
            ),
            "product_venvs": .array(venvs),
            "providers": .array(providers),
        ]
        return .object(fields)
    }

    private static func catalogValue(
        _ catalog: VerifiedCompositionCatalogIdentity
    ) -> StrictJSONResourceValue {
        .object([
            "sequence": .integer(String(catalog.sequence)),
            "sha256": .string(catalog.sha256),
        ])
    }

    private static func deploymentValue(
        _ deployment: ManagedDeploymentTarget,
        inventoryEvidenceReference: String
    ) -> StrictJSONResourceValue {
        .object([
            "id": .string(deployment.id),
            "label": deployment.label.map { .string($0) } ?? .null,
            "exists": .boolean(deployment.exists),
            "forge_instance_id": deployment.forgeInstanceID.map { .string($0) } ?? .null,
            "engineering_platform_instance_id": deployment.engineeringPlatformInstanceID.map {
                .string($0)
            } ?? .null,
            "installed_composition_id": deployment.installedCompositionID.map {
                .string($0)
            } ?? .null,
            "installed_composition_manifest_sha256":
                deployment.installedCompositionManifestSHA256.map { .string($0) } ?? .null,
            "inventory_evidence_reference": .string(inventoryEvidenceReference),
        ])
    }

    private static func installerValue(
        _ release: VerifiedInstallerRelease
    ) -> StrictJSONResourceValue {
        .object([
            "version": .string(release.version.description),
            "release_page": .string(release.releasePage),
            "asset_name": .string(release.assetName),
            "sha256": .string(release.sha256),
            "signing_key_id": .string(release.signingKeyID),
        ])
    }

    private static func toolValue(
        _ planned: ManagedToolOriginalPlanAction
    ) -> StrictJSONResourceValue {
        .object([
            "identity": .string(planned.requirement.identity.rawValue),
            "version": .string(planned.requirement.version.description),
            "artifact_url": .string(planned.requirement.artifact.url),
            "artifact_sha256": .string(planned.requirement.artifact.sha256),
            "action": .string(planned.action.rawValue),
        ])
    }

    private static func pythonValue(
        _ plan: ManagedPythonRuntimeActivationPlan
    ) -> StrictJSONResourceValue {
        .object([
            "operation_id": .string(plan.operationID),
            "execution_request_fingerprint": .string(plan.executionRequestFingerprint),
            "action": .string(plan.action.rawValue),
            "runtime_identity": .string(plan.runtimeIdentitySHA256),
            "runtime_archive_sha256": .string(plan.runtimeArchiveSHA256),
            "runtime_slot_identity": .string(plan.runtimeSlotIdentity),
            "rollback_runtime_identity": plan.rollbackRuntimeIdentitySHA256.map {
                .string($0)
            } ?? .null,
            "required_retained_runtime_identities": .array(
                plan.requiredRetainedRuntimeIdentitySHA256s.map { .string($0) }
            ),
            "initial_readback": .object([
                "active_runtime_identity": plan.initialReadback.activeRuntimeIdentitySHA256.map {
                    .string($0)
                } ?? .null,
                "active_runtime_slot": plan.initialReadback.activeRuntimeSlotIdentity.map {
                    .string($0)
                } ?? .null,
                "retained_runtime_identities": .array(
                    plan.initialReadback.retainedRuntimeIdentitySHA256s.map { .string($0) }
                ),
                "evidence_reference": .string(plan.initialReadback.evidenceReference),
            ]),
        ])
    }

    private static func providerValue(
        _ requirement: ProviderRequirement
    ) -> StrictJSONResourceValue {
        .object([
            "identity": .string(requirement.id.rawValue),
            "provider": .string(requirement.provider.rawValue),
            "required": .boolean(requirement.isRequired),
            "minimum_version": requirement.minimumVersion.map {
                .string($0.description)
            } ?? .null,
            "credential_scope": .string(requirement.credentialScope.rawValue),
            "owner_component": requirement.ownerComponent.map {
                .string($0.rawValue)
            } ?? .null,
            "target_identity": requirement.targetIdentity.map { .string($0) } ?? .null,
            "runtime": requirement.runtime.map(providerRuntimeValue) ?? .null,
        ])
    }

    private static func providerRuntimeValue(
        _ runtime: ProviderRuntimeRequirement
    ) -> StrictJSONResourceValue {
        .object([
            "version": .string(runtime.version.description),
            "archive_kind": .string(runtime.archiveKind.rawValue),
            "artifact_url": .string(runtime.artifactURL),
            "artifact_sha256": .string(runtime.artifactSHA256),
            "executable_relative_path": .string(runtime.executableRelativePath),
            "executable_sha256": .string(runtime.executableSHA256),
        ])
    }

    private static func componentValue(_ component: ComponentDiff) -> StrictJSONResourceValue {
        .object([
            "identity": .string(component.componentID),
            "title": .string(component.title),
            "change": .string(component.change.rawValue),
            "installed_version": component.installedVersion.map { .string($0) } ?? .null,
            "candidate_version": component.candidateVersion.map { .string($0) } ?? .null,
            "artifact_digest": component.artifactDigest.map { .string($0) } ?? .null,
            "detail": .string(component.detail),
        ])
    }
}
