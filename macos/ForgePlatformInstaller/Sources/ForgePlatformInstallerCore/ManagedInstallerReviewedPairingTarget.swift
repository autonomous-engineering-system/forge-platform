import Foundation

/// Public, non-secret project choice for one reviewed Forge+EP deployment.
/// The helper obtains product instances, consumer, host, operator, endpoint and
/// credential authority separately; none can be supplied through this value.
public struct ManagedInstallerReviewedPairingTarget: Equatable, Sendable {
    public let projectID: String
    public let repositoryID: String
    public let repositoryIdentity: String

    public init(
        projectID: String,
        repositoryID: String,
        repositoryIdentity: String
    ) throws {
        guard Self.isEPIdentifier(projectID),
              Self.isEPRepositoryID(repositoryID),
              Self.isForgeRepositoryIdentity(repositoryIdentity) else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        self.projectID = projectID
        self.repositoryID = repositoryID
        self.repositoryIdentity = repositoryIdentity
    }

    /// The EP consumer and project grammar is lowercase ASCII, 1...128.
    static func isEPIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              let first = value.utf8.first, (97...122).contains(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }

    /// EP's declared repository attachment uses a distinct identifier
    /// grammar: 3...128 lowercase ASCII characters, digits, dots, underscores
    /// and dashes, with a lowercase letter or digit first.
    static func isEPRepositoryID(_ value: String) -> Bool {
        guard (3...128).contains(value.utf8.count),
              let first = value.utf8.first,
              (97...122).contains(first) || (48...57).contains(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            (97...122).contains($0) || (48...57).contains($0)
                || [45, 46, 95].contains($0)
        }
    }

    private static func isForgeRepositoryIdentity(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256,
              let first = value.utf8.first,
              (48...57).contains(first) || (65...90).contains(first)
                || (97...122).contains(first) else { return false }
        return value.utf8.dropFirst().allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }

    func canonicalValue() -> StrictJSONResourceValue {
        .object([
            "project_id": .string(projectID),
            "repository_id": .string(repositoryID),
            "repository_identity": .string(repositoryIdentity),
        ])
    }

    static func decode(_ value: StrictJSONResourceValue) throws -> Self {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                "project_id", "repository_id", "repository_identity",
              ]),
              let project = fields["project_id"]?.stringValue,
              let repository = fields["repository_id"]?.stringValue,
              let identity = fields["repository_identity"]?.stringValue else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return try Self(projectID: project, repositoryID: repository,
                        repositoryIdentity: identity)
    }
}
