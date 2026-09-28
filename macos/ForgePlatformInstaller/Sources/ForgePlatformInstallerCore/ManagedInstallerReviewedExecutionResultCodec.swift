import Foundation

/// Bounded domain reply for the reviewed-execution XPC route. The reply has
/// no generic product output, command, environment or credential field.
public enum ManagedInstallerReviewedExecutionResultCodec {
    public static let schema = "forge-platform.reviewed-execution-result/v1"
    public static let maximumBytes = 64 * 1_024
    private static let maximumItems = 32

    public static func encode(_ result: ManagedDeploymentExecutionResult) -> Data? {
        let value: StrictJSONResourceValue
        switch result {
        case .completed(let stages, let items):
            guard let stageValues = encodeStages(stages),
                  !stageValues.isEmpty,
                  stages.allSatisfy({ $0.state == .passed }),
                  !items.isEmpty, items.count <= maximumItems,
                  Set(items.map(\.componentID)).count == items.count,
                  let summaries = encodeSummaries(items) else { return nil }
            value = .object([
                "schema": .string(schema), "kind": .string("completed"),
                "stages": .array(stageValues), "summaries": .array(summaries),
            ])
        case .failed(let failure, let stages):
            guard let stageValues = encodeStages(stages) else { return nil }
            value = .object([
                "schema": .string(schema), "kind": .string("failed"),
                "failure": .string(failure.rawValue), "stages": .array(stageValues),
            ])
        case .updateRequired(let release):
            guard valid(release.releasePage), valid(release.assetName),
                  valid(release.signingKeyID),
                  InstallerSelfUpdateValidation.isSHA256(release.sha256) else { return nil }
            value = .object([
                "schema": .string(schema), "kind": .string("update-required"),
                "release": .object([
                    "version": .string(release.version.description),
                    "release_page": .string(release.releasePage),
                    "asset_name": .string(release.assetName),
                    "sha256": .string(release.sha256),
                    "signing_key_id": .string(release.signingKeyID),
                ]),
            ])
        }
        let data = StrictSignedJSON.canonicalPayload(from: value)
        return data.count <= maximumBytes ? data : nil
    }

    public static func decode(_ data: Data) throws -> ManagedDeploymentExecutionResult {
        guard !data.isEmpty, data.count <= maximumBytes else { throw invalid() }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              fields["schema"]?.stringValue == schema,
              let kind = fields["kind"]?.stringValue else { throw invalid() }
        let result: ManagedDeploymentExecutionResult
        switch kind {
        case "completed":
            guard Set(fields.keys) == Set(["schema", "kind", "stages", "summaries"]),
                  let stages = try decodeStages(fields["stages"]), !stages.isEmpty,
                  stages.allSatisfy({ $0.state == .passed }),
                  let summaries = try decodeSummaries(fields["summaries"]),
                  !summaries.isEmpty else { throw invalid() }
            result = .completed(stages: stages, summaryItems: summaries)
        case "failed":
            guard Set(fields.keys) == Set(["schema", "kind", "failure", "stages"]),
                  let raw = fields["failure"]?.stringValue,
                  let failure = InstallerOperationFailureCode(rawValue: raw),
                  let stages = try decodeStages(fields["stages"]) else { throw invalid() }
            result = .failed(failure, stages: stages)
        case "update-required":
            guard Set(fields.keys) == Set(["schema", "kind", "release"]),
                  let release = fields["release"]?.objectValue,
                  Set(release.keys) == Set([
                    "version", "release_page", "asset_name", "sha256", "signing_key_id",
                  ]),
                  let versionText = release["version"]?.stringValue,
                  let version = try? InstallerVersion(versionText),
                  let page = release["release_page"]?.stringValue,
                  let asset = release["asset_name"]?.stringValue,
                  let sha256 = release["sha256"]?.stringValue,
                  let key = release["signing_key_id"]?.stringValue else { throw invalid() }
            result = .updateRequired(VerifiedInstallerRelease(
                version: version, releasePage: page, assetName: asset,
                sha256: sha256, signingKeyID: key
            ))
        default:
            throw invalid()
        }
        guard encode(result) == data else { throw invalid() }
        return result
    }

    private static func encodeStages(_ stages: [ExecutionStage]) -> [StrictJSONResourceValue]? {
        guard stages.count <= maximumItems,
              Set(stages.map(\.id)).count == stages.count else { return nil }
        var values: [StrictJSONResourceValue] = []
        for stage in stages {
            guard valid(stage.id), valid(stage.title), valid(stage.detail) else { return nil }
            let state: StrictJSONResourceValue
            switch stage.state {
            case .pending: state = .object(["kind": .string("pending")])
            case .running: state = .object(["kind": .string("running")])
            case .passed: state = .object(["kind": .string("passed")])
            case .failed(let detail):
                guard valid(detail) else { return nil }
                state = .object(["kind": .string("failed"), "detail": .string(detail)])
            }
            values.append(.object([
                "id": .string(stage.id), "title": .string(stage.title),
                "detail": .string(stage.detail), "state": state,
            ]))
        }
        return values
    }

    private static func decodeStages(_ value: StrictJSONResourceValue?) throws -> [ExecutionStage]? {
        guard let values = value?.arrayValue, values.count <= maximumItems else { return nil }
        return try values.map { value in
            guard let fields = value.objectValue,
                  Set(fields.keys) == Set(["id", "title", "detail", "state"]),
                  let id = fields["id"]?.stringValue,
                  let title = fields["title"]?.stringValue,
                  let detail = fields["detail"]?.stringValue,
                  let stateFields = fields["state"]?.objectValue,
                  let kind = stateFields["kind"]?.stringValue else { throw invalid() }
            let state: ExecutionStageState
            switch kind {
            case "pending" where Set(stateFields.keys) == Set(["kind"]): state = .pending
            case "running" where Set(stateFields.keys) == Set(["kind"]): state = .running
            case "passed" where Set(stateFields.keys) == Set(["kind"]): state = .passed
            case "failed" where Set(stateFields.keys) == Set(["kind", "detail"]):
                guard let failure = stateFields["detail"]?.stringValue else { throw invalid() }
                state = .failed(failure)
            default: throw invalid()
            }
            return ExecutionStage(id: id, title: title, detail: detail, state: state)
        }
    }

    private static func encodeSummaries(
        _ items: [InstallationSummaryItem]
    ) -> [StrictJSONResourceValue]? {
        var values: [StrictJSONResourceValue] = []
        for item in items {
            guard valid(item.componentID), valid(item.title), valid(item.status),
                  item.dashboardURL.map({ valid($0.absoluteString) }) ?? true else { return nil }
            values.append(.object([
                "component_id": .string(item.componentID),
                "title": .string(item.title), "status": .string(item.status),
                "dashboard_url": item.dashboardURL.map {
                    .string($0.absoluteString)
                } ?? .null,
                "service_scope": item.serviceScope.map {
                    .string($0.rawValue)
                } ?? .null,
            ]))
        }
        return values
    }

    private static func decodeSummaries(
        _ value: StrictJSONResourceValue?
    ) throws -> [InstallationSummaryItem]? {
        guard let values = value?.arrayValue, values.count <= maximumItems else { return nil }
        return try values.map { value in
            guard let fields = value.objectValue,
                  Set(fields.keys) == Set([
                    "component_id", "title", "status", "dashboard_url", "service_scope",
                  ]),
                  let id = fields["component_id"]?.stringValue,
                  let title = fields["title"]?.stringValue,
                  let status = fields["status"]?.stringValue,
                  let dashboardValue = fields["dashboard_url"],
                  let scopeValue = fields["service_scope"] else { throw invalid() }
            let dashboard: VerifiedDashboardURL?
            switch dashboardValue {
            case .null: dashboard = nil
            case .string(let raw): dashboard = try VerifiedDashboardURL(raw)
            default: throw invalid()
            }
            let scope: ServiceScope?
            switch scopeValue {
            case .null: scope = nil
            case .string(let raw):
                guard let parsed = ServiceScope(rawValue: raw) else { throw invalid() }
                scope = parsed
            default: throw invalid()
            }
            return InstallationSummaryItem(
                componentID: id, title: title, status: status,
                dashboardURL: dashboard, serviceScope: scope
            )
        }
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024
            && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    private static func invalid() -> ManagedInstallerReleasedRouteXPCFailure { .invalidRequest }
}
