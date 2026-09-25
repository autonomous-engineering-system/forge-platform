import CryptoKit
import Foundation

public enum ManagedInstallerProductOperationBridgeFailure:
    Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

public struct ManagedInstallerProductComponentOperation: Equatable, Sendable {
    public let componentID: String
    public let change: ComponentChange
    public let installedVersion: String?
    public let candidateVersion: String
    public let artifactSHA256: String

    init(component: ComponentDiff) throws {
        try self.init(
            componentID: component.componentID,
            change: component.change,
            installedVersion: component.installedVersion,
            candidateVersion: component.candidateVersion,
            artifactSHA256: component.artifactDigest
        )
    }

    init(
        componentID: String,
        change: ComponentChange,
        installedVersion: String?,
        candidateVersion: String?,
        artifactSHA256: String?
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(componentID),
              change != .blocked,
              change != .remove,
              change == .install
                ? installedVersion == nil
                : installedVersion.map(Self.isBoundedVersion) == true,
              let candidateVersion,
              Self.isBoundedVersion(candidateVersion),
              let artifactSHA256,
              CompositionCatalogValidation.isTaggedSHA256(artifactSHA256) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        self.componentID = componentID
        self.change = change
        self.installedVersion = installedVersion
        self.candidateVersion = candidateVersion
        self.artifactSHA256 = artifactSHA256
    }

    private static func isBoundedVersion(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && !value.unicodeScalars.contains {
                $0.value < 32 || $0.value == 127
            }
    }
}

/// Canonical, non-secret bridge request for the product-owned Forge+EP saga.
/// The helper resolves every path, executable and command from its own sealed
/// configuration and durable journal. The caller can supply only identities,
/// reviewed actions and evidence references already bound by one reconstructed
/// terminal `MANAGED_TOOLS` receipt.
public struct ManagedInstallerProductOperationRequest: Equatable, Sendable {
    public static let schema = "forge-platform.native-product-operation-request/v2"
    static let maximumBytes = 128 * 1_024

    public let stablePlanFingerprint: String
    public let operationID: String
    public let sessionID: String
    public let deploymentID: String
    public let deploymentExists: Bool
    public let forgeInstanceID: String?
    public let engineeringPlatformInstanceID: String?
    public let installedCompositionIdentity: String?
    public let installedCompositionManifestSHA256: String?
    public let inventoryEvidenceReference: String
    public let compositionIdentity: String
    public let manifestSHA256: String
    public let installerRelease: VerifiedInstallerRelease
    public let components: [ManagedInstallerProductComponentOperation]
    public let providerTargetIDs: [String]
    public let runtimeEvidenceReferences: [String]
    public let requestFingerprint: String

    public init(
        stablePlan: ManagedInstallerStablePlan,
        runtimeTransactionReceipt: ManagedInstallerRuntimeTransactionReceipt
    ) throws {
        guard let reconstructed = try? ManagedInstallerRuntimeTransactionReceipt(
                  stablePlan: stablePlan,
                  preparationReceipt: runtimeTransactionReceipt.preparationReceipt,
                  managedToolReconciliationReceipt:
                    runtimeTransactionReceipt.managedToolReconciliationReceipt,
                  completionReceipt: runtimeTransactionReceipt.completionReceipt
              ), reconstructed == runtimeTransactionReceipt else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let operations = try stablePlan.reviewedOperation.components
            .map(ManagedInstallerProductComponentOperation.init)
            .sorted { $0.componentID < $1.componentID }
        let providerTargets = stablePlan.enabledProviderRequirements
            .map(\.id.rawValue).sorted()
        var references = [runtimeTransactionReceipt.completionReceipt
            .terminalReceipt.evidenceReference]
        references.append(contentsOf: runtimeTransactionReceipt
            .managedToolReconciliationReceipt.mutationReceipts
            .flatMap {
                [$0.mutationEvidenceReference, $0.finalReadbackEvidenceReference]
            })
        references.append(contentsOf: runtimeTransactionReceipt.preparationReceipt
            .providerRuntimeReceipt.providerReceipts
            .flatMap {
                [
                    $0.stagedArchiveEvidenceReference,
                    $0.inspectionEvidenceReference,
                    $0.mutationEvidenceReference,
                ]
            })
        try self.init(
            stablePlanFingerprint: stablePlan.fingerprint,
            operationID: stablePlan.activationPlan.operationID,
            sessionID: stablePlan.session.sessionID,
            deploymentID: stablePlan.deployment.id,
            deploymentExists: stablePlan.deployment.exists,
            forgeInstanceID: stablePlan.deployment.forgeInstanceID,
            engineeringPlatformInstanceID:
                stablePlan.deployment.engineeringPlatformInstanceID,
            installedCompositionIdentity:
                stablePlan.deployment.installedCompositionID,
            installedCompositionManifestSHA256:
                stablePlan.deployment.installedCompositionManifestSHA256,
            inventoryEvidenceReference:
                stablePlan.reviewedOperation.inventoryEvidenceReference,
            compositionIdentity: stablePlan.session.compositionIdentity,
            manifestSHA256: stablePlan.session.manifestSHA256,
            installerRelease: stablePlan.reviewedOperation.currentInstallerRelease,
            components: operations,
            providerTargetIDs: providerTargets,
            runtimeEvidenceReferences: references
        )
    }

    private init(
        stablePlanFingerprint: String,
        operationID: String,
        sessionID: String,
        deploymentID: String,
        deploymentExists: Bool,
        forgeInstanceID: String?,
        engineeringPlatformInstanceID: String?,
        installedCompositionIdentity: String?,
        installedCompositionManifestSHA256: String?,
        inventoryEvidenceReference: String,
        compositionIdentity: String,
        manifestSHA256: String,
        installerRelease: VerifiedInstallerRelease,
        components: [ManagedInstallerProductComponentOperation],
        providerTargetIDs: [String],
        runtimeEvidenceReferences: [String],
        expectedRequestFingerprint: String? = nil
    ) throws {
        let orderedComponents = components.sorted { $0.componentID < $1.componentID }
        let orderedProviders = providerTargetIDs.sorted()
        let orderedEvidence = runtimeEvidenceReferences.sorted()
        let requiredComponents = [
            ProviderOwnerComponent.engineeringPlatformServer.rawValue,
            ProviderOwnerComponent.forgeRuntime.rawValue,
        ].sorted()
        guard ManagedPythonRuntimePostToolQualification.isFingerprint(
                  stablePlanFingerprint
              ),
              ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              ManagedPythonRuntimeStagingValidation.isOperationID(sessionID),
              ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
              forgeInstanceID.map(ManagedPythonRuntimeStagingValidation.isOperationID)
                ?? true,
              engineeringPlatformInstanceID.map(
                  ManagedPythonRuntimeStagingValidation.isOperationID
              ) ?? true,
              deploymentExists
                || forgeInstanceID == nil && engineeringPlatformInstanceID == nil,
              !deploymentExists
                || forgeInstanceID != nil || engineeringPlatformInstanceID != nil,
              (installedCompositionIdentity == nil)
                == (installedCompositionManifestSHA256 == nil),
              installedCompositionIdentity.map(
                  CompositionCatalogValidation.isCompositionIdentity
              ) ?? true,
              installedCompositionManifestSHA256.map(
                  CompositionCatalogValidation.isTaggedSHA256
              ) ?? true,
              deploymentExists || installedCompositionIdentity == nil,
              Self.isInventoryEvidenceReference(inventoryEvidenceReference),
              !compositionIdentity.isEmpty,
              compositionIdentity.utf8.count <= 256,
              CompositionCatalogValidation.isTaggedSHA256(manifestSHA256),
              GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(
                  installerRelease.releasePage
              ),
              InstallerSelfUpdateValidation.isInstallerArchiveName(
                  installerRelease.assetName
              ),
              InstallerSelfUpdateValidation.isSHA256(installerRelease.sha256),
              GitHubInstallerReleaseDescriptorValidation.isKeyID(
                  installerRelease.signingKeyID
              ),
              orderedComponents.map(\.componentID) == requiredComponents,
              Set(orderedComponents.map(\.componentID)).count == orderedComponents.count,
              Set(orderedProviders).count == orderedProviders.count,
              orderedProviders.allSatisfy({ ProviderTargetID(rawValue: $0) != nil }),
              !orderedEvidence.isEmpty,
              Set(orderedEvidence).count == orderedEvidence.count,
              orderedEvidence.allSatisfy(
                  ManagedPythonRuntimeInstalledReadback.isEvidenceReference
              ) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let fingerprint = Self.fingerprint(
            stablePlanFingerprint: stablePlanFingerprint,
            operationID: operationID,
            sessionID: sessionID,
            deploymentID: deploymentID,
            deploymentExists: deploymentExists,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedCompositionManifestSHA256: installedCompositionManifestSHA256,
            inventoryEvidenceReference: inventoryEvidenceReference,
            compositionIdentity: compositionIdentity,
            manifestSHA256: manifestSHA256,
            installerRelease: installerRelease,
            components: orderedComponents,
            providerTargetIDs: orderedProviders,
            runtimeEvidenceReferences: orderedEvidence
        )
        guard expectedRequestFingerprint == nil
                || expectedRequestFingerprint == fingerprint else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        self.stablePlanFingerprint = stablePlanFingerprint
        self.operationID = operationID
        self.sessionID = sessionID
        self.deploymentID = deploymentID
        self.deploymentExists = deploymentExists
        self.forgeInstanceID = forgeInstanceID
        self.engineeringPlatformInstanceID = engineeringPlatformInstanceID
        self.installedCompositionIdentity = installedCompositionIdentity
        self.installedCompositionManifestSHA256 = installedCompositionManifestSHA256
        self.inventoryEvidenceReference = inventoryEvidenceReference
        self.compositionIdentity = compositionIdentity
        self.manifestSHA256 = manifestSHA256
        self.installerRelease = installerRelease
        self.components = orderedComponents
        self.providerTargetIDs = orderedProviders
        self.runtimeEvidenceReferences = orderedEvidence
        requestFingerprint = fingerprint
    }

    public func canonicalJSONData() -> Data {
        Self.canonicalData(
            stablePlanFingerprint: stablePlanFingerprint,
            operationID: operationID,
            sessionID: sessionID,
            deploymentID: deploymentID,
            deploymentExists: deploymentExists,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedCompositionManifestSHA256: installedCompositionManifestSHA256,
            inventoryEvidenceReference: inventoryEvidenceReference,
            compositionIdentity: compositionIdentity,
            manifestSHA256: manifestSHA256,
            installerRelease: installerRelease,
            components: components,
            providerTargetIDs: providerTargetIDs,
            runtimeEvidenceReferences: runtimeEvidenceReferences,
            requestFingerprint: requestFingerprint
        )
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "stable_plan_fingerprint", "operation_id", "session_id",
                  "deployment_id", "deployment_exists", "forge_instance_id",
                  "engineering_platform_instance_id", "installed_composition_identity",
                  "installed_composition_manifest_sha256", "inventory_evidence_reference",
                  "composition_identity", "manifest_sha256", "installer_release",
                  "components", "provider_target_ids", "runtime_evidence_references",
                  "request_fingerprint",
              ]),
              fields["schema"]?.stringValue == schema,
              let stablePlanFingerprint = fields["stable_plan_fingerprint"]?.stringValue,
              let operationID = fields["operation_id"]?.stringValue,
              let sessionID = fields["session_id"]?.stringValue,
              let deploymentID = fields["deployment_id"]?.stringValue,
              let deploymentExists = boolean(fields["deployment_exists"]),
              let forgeInstanceValue = fields["forge_instance_id"],
              let engineeringPlatformInstanceValue =
                fields["engineering_platform_instance_id"],
              let installedCompositionValue = fields["installed_composition_identity"],
              let installedCompositionManifestValue =
                fields["installed_composition_manifest_sha256"],
              let inventoryEvidenceReference = fields["inventory_evidence_reference"]?.stringValue,
              let compositionIdentity = fields["composition_identity"]?.stringValue,
              let manifestSHA256 = fields["manifest_sha256"]?.stringValue,
              let installerValue = fields["installer_release"],
              let componentValues = fields["components"]?.arrayValue,
              let providerValues = fields["provider_target_ids"]?.arrayValue,
              let evidenceValues = fields["runtime_evidence_references"]?.arrayValue,
              let requestFingerprint = fields["request_fingerprint"]?.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return try Self(
            stablePlanFingerprint: stablePlanFingerprint,
            operationID: operationID,
            sessionID: sessionID,
            deploymentID: deploymentID,
            deploymentExists: deploymentExists,
            forgeInstanceID: try optionalString(forgeInstanceValue),
            engineeringPlatformInstanceID:
                try optionalString(engineeringPlatformInstanceValue),
            installedCompositionIdentity:
                try optionalString(installedCompositionValue),
            installedCompositionManifestSHA256:
                try optionalString(installedCompositionManifestValue),
            inventoryEvidenceReference: inventoryEvidenceReference,
            compositionIdentity: compositionIdentity,
            manifestSHA256: manifestSHA256,
            installerRelease: decodeInstaller(installerValue),
            components: componentValues.map(decodeComponent),
            providerTargetIDs: providerValues.map(string),
            runtimeEvidenceReferences: evidenceValues.map(string),
            expectedRequestFingerprint: requestFingerprint
        )
    }

    private static func fingerprint(
        stablePlanFingerprint: String,
        operationID: String,
        sessionID: String,
        deploymentID: String,
        deploymentExists: Bool,
        forgeInstanceID: String?,
        engineeringPlatformInstanceID: String?,
        installedCompositionIdentity: String?,
        installedCompositionManifestSHA256: String?,
        inventoryEvidenceReference: String,
        compositionIdentity: String,
        manifestSHA256: String,
        installerRelease: VerifiedInstallerRelease,
        components: [ManagedInstallerProductComponentOperation],
        providerTargetIDs: [String],
        runtimeEvidenceReferences: [String]
    ) -> String {
        SHA256.hash(data: canonicalData(
            stablePlanFingerprint: stablePlanFingerprint,
            operationID: operationID,
            sessionID: sessionID,
            deploymentID: deploymentID,
            deploymentExists: deploymentExists,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedCompositionManifestSHA256: installedCompositionManifestSHA256,
            inventoryEvidenceReference: inventoryEvidenceReference,
            compositionIdentity: compositionIdentity,
            manifestSHA256: manifestSHA256,
            installerRelease: installerRelease,
            components: components,
            providerTargetIDs: providerTargetIDs,
            runtimeEvidenceReferences: runtimeEvidenceReferences,
            requestFingerprint: nil
        )).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalData(
        stablePlanFingerprint: String,
        operationID: String,
        sessionID: String,
        deploymentID: String,
        deploymentExists: Bool,
        forgeInstanceID: String?,
        engineeringPlatformInstanceID: String?,
        installedCompositionIdentity: String?,
        installedCompositionManifestSHA256: String?,
        inventoryEvidenceReference: String,
        compositionIdentity: String,
        manifestSHA256: String,
        installerRelease: VerifiedInstallerRelease,
        components: [ManagedInstallerProductComponentOperation],
        providerTargetIDs: [String],
        runtimeEvidenceReferences: [String],
        requestFingerprint: String?
    ) -> Data {
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string(schema),
            "stable_plan_fingerprint": .string(stablePlanFingerprint),
            "operation_id": .string(operationID),
            "session_id": .string(sessionID),
            "deployment_id": .string(deploymentID),
            "deployment_exists": .boolean(deploymentExists),
            "forge_instance_id": forgeInstanceID.map { .string($0) } ?? .null,
            "engineering_platform_instance_id": engineeringPlatformInstanceID.map {
                .string($0)
            } ?? .null,
            "installed_composition_identity": installedCompositionIdentity.map {
                .string($0)
            } ?? .null,
            "installed_composition_manifest_sha256":
                installedCompositionManifestSHA256.map { .string($0) } ?? .null,
            "inventory_evidence_reference": .string(inventoryEvidenceReference),
            "composition_identity": .string(compositionIdentity),
            "manifest_sha256": .string(manifestSHA256),
            "installer_release": installerValue(installerRelease),
            "components": .array(components.map(componentValue)),
            "provider_target_ids": .array(providerTargetIDs.map { .string($0) }),
            "runtime_evidence_references": .array(
                runtimeEvidenceReferences.map { .string($0) }
            ),
        ]
        if let requestFingerprint {
            fields["request_fingerprint"] = .string(requestFingerprint)
        }
        return StrictSignedJSON.canonicalPayload(from: .object(fields))
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

    private static func decodeInstaller(
        _ value: StrictJSONResourceValue
    ) throws -> VerifiedInstallerRelease {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                  "version", "release_page", "asset_name", "sha256", "signing_key_id",
              ]),
              let version = fields["version"]?.stringValue,
              let releasePage = fields["release_page"]?.stringValue,
              let assetName = fields["asset_name"]?.stringValue,
              let sha256 = fields["sha256"]?.stringValue,
              let signingKeyID = fields["signing_key_id"]?.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: releasePage,
            assetName: assetName,
            sha256: sha256,
            signingKeyID: signingKeyID
        )
    }

    private static func componentValue(
        _ component: ManagedInstallerProductComponentOperation
    ) -> StrictJSONResourceValue {
        .object([
            "identity": .string(component.componentID),
            "change": .string(component.change.rawValue),
            "installed_version": component.installedVersion.map {
                .string($0)
            } ?? .null,
            "candidate_version": .string(component.candidateVersion),
            "artifact_sha256": .string(component.artifactSHA256),
        ])
    }

    private static func decodeComponent(
        _ value: StrictJSONResourceValue
    ) throws -> ManagedInstallerProductComponentOperation {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                  "identity", "change", "installed_version", "candidate_version",
                  "artifact_sha256",
              ]),
              let identity = fields["identity"]?.stringValue,
              let changeValue = fields["change"]?.stringValue,
              let change = ComponentChange(rawValue: changeValue),
              let installedVersionValue = fields["installed_version"],
              let candidateVersion = fields["candidate_version"]?.stringValue,
              let artifactSHA256 = fields["artifact_sha256"]?.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return try ManagedInstallerProductComponentOperation(
            componentID: identity,
            change: change,
            installedVersion: try optionalString(installedVersionValue),
            candidateVersion: candidateVersion,
            artifactSHA256: artifactSHA256
        )
    }

    private static func boolean(_ value: StrictJSONResourceValue?) -> Bool? {
        guard case .boolean(let boolean)? = value else { return nil }
        return boolean
    }

    private static func optionalString(
        _ value: StrictJSONResourceValue
    ) throws -> String? {
        switch value {
        case .null: return nil
        case .string(let string): return string
        default: throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
    }

    private static func isInventoryEvidenceReference(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 256
            && !value.unicodeScalars.contains {
                $0.value < 32 || $0.value == 127
            }
    }

    fileprivate static func string(_ value: StrictJSONResourceValue) throws -> String {
        guard let string = value.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return string
    }
}

public struct ManagedInstallerProductCompletion: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ready = "READY"
        case removed = "REMOVED"
    }

    public let componentID: String
    public let state: State
    public let dashboardURL: VerifiedDashboardURL?
    public let serviceScope: ServiceScope?

    public init(
        componentID: String,
        state: State,
        dashboardURL: VerifiedDashboardURL? = nil,
        serviceScope: ServiceScope? = nil
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(componentID) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        self.componentID = componentID
        self.state = state
        self.dashboardURL = dashboardURL
        self.serviceScope = serviceScope
    }
}

public struct ManagedInstallerProductOperationReceipt: Equatable, Sendable {
    public static let schema = "forge-platform.native-product-operation-receipt/v1"
    static let maximumBytes = 128 * 1_024

    public let requestFingerprint: String
    public let stablePlanFingerprint: String
    public let operationID: String
    public let productReceiptReferences: [String]
    public let pairingReceiptReference: String?
    public let readinessReceiptReferences: [String]
    public let completions: [ManagedInstallerProductCompletion]

    public init(
        request: ManagedInstallerProductOperationRequest,
        productReceiptReferences: [String],
        pairingReceiptReference: String?,
        readinessReceiptReferences: [String],
        completions: [ManagedInstallerProductCompletion]
    ) throws {
        let products = productReceiptReferences.sorted()
        let readiness = readinessReceiptReferences.sorted()
        let orderedCompletions = completions.sorted { $0.componentID < $1.componentID }
        let expected = request.components.sorted { $0.componentID < $1.componentID }
        guard !products.isEmpty,
              Set(products).count == products.count,
              products.allSatisfy(ManagedPythonRuntimeInstalledReadback.isEvidenceReference),
              readiness.count == 2,
              Set(readiness).count == readiness.count,
              readiness.allSatisfy(ManagedPythonRuntimeInstalledReadback.isEvidenceReference),
              pairingReceiptReference.map(
                  ManagedPythonRuntimeInstalledReadback.isEvidenceReference
              ) == true,
              expected.map(\.componentID) == orderedCompletions.map(\.componentID),
              zip(expected, orderedCompletions).allSatisfy({ operation, completion in
                  operation.change == .remove
                    ? completion.state == .removed
                    : completion.state == .ready
              }) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        requestFingerprint = request.requestFingerprint
        stablePlanFingerprint = request.stablePlanFingerprint
        operationID = request.operationID
        self.productReceiptReferences = products
        self.pairingReceiptReference = pairingReceiptReference
        self.readinessReceiptReferences = readiness
        self.completions = orderedCompletions
    }

    public func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "request_fingerprint": .string(requestFingerprint),
            "stable_plan_fingerprint": .string(stablePlanFingerprint),
            "operation_id": .string(operationID),
            "product_receipt_references": .array(
                productReceiptReferences.map { .string($0) }
            ),
            "pairing_receipt_reference": pairingReceiptReference.map {
                .string($0)
            } ?? .null,
            "readiness_receipt_references": .array(
                readinessReceiptReferences.map { .string($0) }
            ),
            "completions": .array(completions.map(Self.completionValue)),
        ]))
    }

    public static func decodeJSON(
        _ data: Data,
        request: ManagedInstallerProductOperationRequest
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "request_fingerprint", "stable_plan_fingerprint",
                  "operation_id", "product_receipt_references",
                  "pairing_receipt_reference", "readiness_receipt_references",
                  "completions",
              ]),
              fields["schema"]?.stringValue == schema,
              fields["request_fingerprint"]?.stringValue == request.requestFingerprint,
              fields["stable_plan_fingerprint"]?.stringValue
                == request.stablePlanFingerprint,
              fields["operation_id"]?.stringValue == request.operationID,
              let productValues = fields["product_receipt_references"]?.arrayValue,
              let pairingValue = fields["pairing_receipt_reference"],
              let readinessValues = fields["readiness_receipt_references"]?.arrayValue,
              let completionValues = fields["completions"]?.arrayValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return try Self(
            request: request,
            productReceiptReferences: productValues.map(ManagedInstallerProductOperationRequest.string),
            pairingReceiptReference: optionalString(pairingValue),
            readinessReceiptReferences: readinessValues.map(ManagedInstallerProductOperationRequest.string),
            completions: completionValues.map(decodeCompletion)
        )
    }

    private static func completionValue(
        _ completion: ManagedInstallerProductCompletion
    ) -> StrictJSONResourceValue {
        .object([
            "component_identity": .string(completion.componentID),
            "state": .string(completion.state.rawValue),
            "dashboard_url": completion.dashboardURL.map {
                .string($0.absoluteString)
            } ?? .null,
            "service_scope": completion.serviceScope.map {
                .string($0.rawValue)
            } ?? .null,
        ])
    }

    private static func decodeCompletion(
        _ value: StrictJSONResourceValue
    ) throws -> ManagedInstallerProductCompletion {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                  "component_identity", "state", "dashboard_url", "service_scope",
              ]),
              let componentID = fields["component_identity"]?.stringValue,
              let stateValue = fields["state"]?.stringValue,
              let state = ManagedInstallerProductCompletion.State(rawValue: stateValue) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let dashboard = try optionalString(fields["dashboard_url"] ?? .null)
            .map(VerifiedDashboardURL.init)
        let scopeValue = try optionalString(fields["service_scope"] ?? .null)
        let scope: ServiceScope?
        if let scopeValue {
            guard let parsed = ServiceScope(rawValue: scopeValue) else {
                throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
            }
            scope = parsed
        } else {
            scope = nil
        }
        return try ManagedInstallerProductCompletion(
            componentID: componentID,
            state: state,
            dashboardURL: dashboard,
            serviceScope: scope
        )
    }

    private static func optionalString(
        _ value: StrictJSONResourceValue
    ) throws -> String? {
        switch value {
        case .null: return nil
        case .string(let string): return string
        default: throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
    }
}

public protocol ManagedInstallerProductOperationTransporting: Sendable {
    func executeProductOperation(
        _ canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductOperationBridgeFailure>
}

/// Converts the exact stable plan and reconstructed runtime transaction into a
/// canonical helper request, then accepts only one canonical terminal receipt
/// for that request. The transport remains unavailable until a separately
/// qualified helper is installed and wired by the released runtime.
public struct ManagedInstallerCanonicalProductOperationsExecutor:
    ManagedInstallerProductOperationsExecuting, Sendable {
    private let transport: any ManagedInstallerProductOperationTransporting

    public init(transport: any ManagedInstallerProductOperationTransporting) {
        self.transport = transport
    }

    public func executeProductOperations(
        stablePlan: ManagedInstallerStablePlan,
        runtimeTransactionReceipt: ManagedInstallerRuntimeTransactionReceipt
    ) async -> ManagedDeploymentExecutionResult {
        let request: ManagedInstallerProductOperationRequest
        do {
            request = try ManagedInstallerProductOperationRequest(
                stablePlan: stablePlan,
                runtimeTransactionReceipt: runtimeTransactionReceipt
            )
        } catch {
            return .failed(.executionFailed, stages: [])
        }
        let requestData = request.canonicalJSONData()
        guard requestData.count <= ManagedInstallerProductOperationRequest.maximumBytes,
              (try? ManagedInstallerProductOperationRequest.decodeJSON(requestData))
                == request else {
            return .failed(.executionFailed, stages: [])
        }

        let responseData: Data
        switch await transport.executeProductOperation(requestData) {
        case .success(let returned): responseData = returned
        case .failure: return .failed(.executionFailed, stages: [])
        }
        guard let receipt = try? ManagedInstallerProductOperationReceipt.decodeJSON(
                  responseData,
                  request: request
              ), receipt.canonicalJSONData() == responseData else {
            return .failed(.executionFailed, stages: [])
        }

        var stages = [
            ExecutionStage(
                id: "product-operations",
                title: "Productoperaties",
                detail: "Forge en Engineering Platform",
                state: .passed
            ),
        ]
        stages.append(ExecutionStage(
            id: "pairing",
            title: "Forge↔EP-pairing",
            detail: "Exacte productinstanties gekoppeld",
            state: .passed
        ))
        stages.append(ExecutionStage(
            id: "readiness",
            title: "Readiness",
            detail: "Terminale productreadback",
            state: .passed
        ))
        let summaries = receipt.completions.map { completion in
            InstallationSummaryItem(
                componentID: completion.componentID,
                title: Self.title(for: completion.componentID),
                status: completion.state == .ready ? "Gereed" : "Verwijderd",
                dashboardURL: completion.dashboardURL,
                serviceScope: completion.serviceScope
            )
        }
        return .completed(stages: stages, summaryItems: summaries)
    }

    private static func title(for componentID: String) -> String {
        switch componentID {
        case ProviderOwnerComponent.forgeRuntime.rawValue: return "Forge"
        case ProviderOwnerComponent.engineeringPlatformServer.rawValue:
            return "Engineering Platform"
        default: return componentID
        }
    }
}
