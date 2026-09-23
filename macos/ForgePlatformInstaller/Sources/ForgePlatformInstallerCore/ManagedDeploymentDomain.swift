import Foundation

/// Read-only Forge Platform management identity shown before composition
/// selection. Product instance identities remain product-owned; this target
/// contains only bounded non-secret inventory evidence.
public struct ManagedDeploymentTarget: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String?
    public let exists: Bool
    public let forgeInstanceID: String?
    public let engineeringPlatformInstanceID: String?

    public init(
        id: String,
        label: String? = nil,
        exists: Bool,
        forgeInstanceID: String? = nil,
        engineeringPlatformInstanceID: String? = nil
    ) throws {
        guard Self.isSafeIdentifier(id) else {
            throw ManagedDeploymentTargetError.invalidIdentity
        }
        if let label {
            guard !label.isEmpty,
                  label.utf8.count <= 128,
                  label.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
                throw ManagedDeploymentTargetError.invalidLabel
            }
        }
        if let forgeInstanceID, !Self.isSafeIdentifier(forgeInstanceID) {
            throw ManagedDeploymentTargetError.invalidProductInstance
        }
        if let engineeringPlatformInstanceID,
           !Self.isSafeIdentifier(engineeringPlatformInstanceID) {
            throw ManagedDeploymentTargetError.invalidProductInstance
        }
        if exists && forgeInstanceID == nil && engineeringPlatformInstanceID == nil {
            throw ManagedDeploymentTargetError.emptyExistingDeployment
        }
        if !exists && (forgeInstanceID != nil || engineeringPlatformInstanceID != nil) {
            throw ManagedDeploymentTargetError.precreateTargetContainsProductIdentity
        }
        self.id = id
        self.label = label
        self.exists = exists
        self.forgeInstanceID = forgeInstanceID
        self.engineeringPlatformInstanceID = engineeringPlatformInstanceID
    }

    public var displayName: String {
        label ?? id
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard value.utf8.count >= 1,
              value.utf8.count <= 128,
              let first = value.unicodeScalars.first,
              isASCIIAlphaNumeric(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy { scalar in
            if isASCIIAlphaNumeric(scalar) {
                return true
            }
            switch scalar.value {
            case 45, 46, 95:
                return true
            default:
                return false
            }
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122: return true
        default: return false
        }
    }
}

public enum ManagedDeploymentTargetError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidLabel
    case invalidProductInstance
    case emptyExistingDeployment
    case precreateTargetContainsProductIdentity
}

/// Exact read-only inventory supplied by the trusted Forge Platform
/// coordinator. The create candidate carries a coordinator-generated opaque
/// deployment identity but has no product instance identity and mutates
/// nothing until the reviewed execution phase.
public struct ManagedDeploymentInventory: Equatable, Sendable {
    public let existing: [ManagedDeploymentTarget]
    public let createCandidate: ManagedDeploymentTarget
    public let evidenceReference: String

    public init(
        existing: [ManagedDeploymentTarget],
        createCandidate: ManagedDeploymentTarget,
        evidenceReference: String
    ) throws {
        guard !createCandidate.exists else {
            throw ManagedDeploymentInventoryError.createCandidateAlreadyExists
        }
        guard !evidenceReference.isEmpty,
              evidenceReference.utf8.count <= 256,
              !evidenceReference.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ManagedDeploymentInventoryError.invalidEvidenceReference
        }
        let identities = existing.map(\.id) + [createCandidate.id]
        guard Set(identities).count == identities.count else {
            throw ManagedDeploymentInventoryError.duplicateDeploymentIdentity
        }
        guard existing.allSatisfy(\.exists) else {
            throw ManagedDeploymentInventoryError.invalidExistingDeployment
        }
        self.existing = existing.sorted { $0.id < $1.id }
        self.createCandidate = createCandidate
        self.evidenceReference = evidenceReference
    }

    public var targets: [ManagedDeploymentTarget] {
        existing + [createCandidate]
    }
}

public enum ManagedDeploymentInventoryError: Error, Equatable, Sendable {
    case createCandidateAlreadyExists
    case invalidEvidenceReference
    case duplicateDeploymentIdentity
    case invalidExistingDeployment
}

public enum ManagedDeploymentSelectionFailure: String, Equatable, Sendable {
    case coordinatorUnavailable = "coordinator-unavailable"
    case inventoryUnavailable = "inventory-unavailable"
    case ambiguousInventory = "ambiguous-inventory"

    public var userFacingMessage: String {
        switch self {
        case .coordinatorUnavailable:
            return "Managed-deploymentinventarisatie is niet beschikbaar."
        case .inventoryUnavailable:
            return "De deploymentinventaris kon niet veilig worden gelezen."
        case .ambiguousInventory:
            return "De deploymentinventaris bevat conflicterende of dubbelzinnige productbindingen."
        }
    }
}

public enum ManagedDeploymentInventoryResult: Equatable, Sendable {
    case available(ManagedDeploymentInventory)
    case unavailable(ManagedDeploymentSelectionFailure)
}

public enum ManagedDeploymentSelectionGate: Equatable, Sendable {
    case pending
    case loading
    case available(ManagedDeploymentInventory)
    case selected(ManagedDeploymentTarget, evidenceReference: String)
    case unavailable(ManagedDeploymentSelectionFailure)

    public var selectedTarget: ManagedDeploymentTarget? {
        guard case .selected(let target, _) = self else { return nil }
        return target
    }

    public var isSelected: Bool {
        selectedTarget != nil
    }
}
