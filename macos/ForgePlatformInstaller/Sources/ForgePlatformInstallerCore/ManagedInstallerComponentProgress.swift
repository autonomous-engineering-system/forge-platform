import Darwin
import Foundation

/// Informational progress cannot authorize installation or replace terminal receipts.
public struct ManagedInstallerComponentProgress: Equatable, Sendable {
    public static let schema = "forge-platform.product-component-progress/v1"
    public let operationID: String
    public let stages: [ExecutionStage]

    private static let pairingFailureDetails: [String: String] = [
        "pairing-route-failed": "De installatiegegevens voor de koppeling zijn gewijzigd. Laat het installatieresultaat controleren voordat je hervat.",
        "pairing-ep-readiness-failed": "EP kon vóór het verbinden niet als gereed worden bevestigd. Laat EP controleren; start geen nieuwe installatie.",
        "pairing-forge-configure-failed": "Forge heeft de EP-koppeling niet opgeslagen. Laat de Forge-beheerrechten en het installatieresultaat controleren voordat je hervat.",
        "pairing-configuration-validation-failed": "Forge gaf andere koppelingsgegevens terug dan verwacht. Laat het installatieresultaat controleren voordat je hervat.",
        "pairing-configuration-readback-failed": "De opgeslagen EP-koppeling kon niet worden bevestigd. Hervat pas na gecontroleerd herstel.",
        "pairing-authenticated-preflight-failed": "De beveiligde verbinding van Forge naar EP kon niet worden bevestigd. Laat de verbinding en toegangsrechten controleren voordat je hervat.",
        "pairing-ep-final-readiness-failed": "EP kon na het verbinden niet als gereed worden bevestigd. Laat EP controleren voordat je hervat.",
    ]

    public static func decode(_ data: Data, intent: ManagedInstallerReviewedExecutionIntent) throws -> Self {
        guard !data.isEmpty, data.count <= 8192 else { throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest }
        var reader = try StrictJSONResourceReader(data: data)
        let value = try reader.parseDocument()
        guard let fields = value.objectValue,
              Set(fields.keys) == ["schema", "operation_id", "deployment_id", "session_id",
                "stable_plan_fingerprint", "request_fingerprint", "installer_version",
                "installer_release_sha256", "rows"],
              fields["schema"]?.stringValue == schema,
              fields["operation_id"]?.stringValue == intent.operationID,
              fields["deployment_id"]?.stringValue == intent.deploymentID,
              fields["session_id"]?.stringValue == intent.sessionID,
              fields["stable_plan_fingerprint"]?.stringValue == intent.stablePlanFingerprint,
              fields["installer_version"]?.stringValue == intent.installerVersion.description,
              fields["installer_release_sha256"]?.stringValue == intent.installerReleaseSHA256,
              let fingerprint = fields["request_fingerprint"]?.stringValue,
              InstallerSelfUpdateValidation.isSHA256(fingerprint),
              let rows = fields["rows"]?.arrayValue, (2...4).contains(rows.count),
              StrictSignedJSON.canonicalPayload(from: value) == data else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        var stages: [ExecutionStage] = []
        for row in rows {
            guard let item = row.objectValue, Set(item.keys) == ["component_id", "state", "code"],
                  let id = item["component_id"]?.stringValue,
                  ["engineering-platform-server", "forge-runtime", "pairing", "readiness"].contains(id),
                  !stages.contains(where: { $0.id == id }),
                  let code = item["code"]?.stringValue,
                  let detail = detail(for: code),
                  let rawState = item["state"]?.stringValue else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            let state: ExecutionStageState
            let allowedCodes: Set<String>
            switch rawState {
            case "pending": state = .pending; allowedCodes = ["none"]
            case "running": state = .running; allowedCodes = ["preflight", "installing", "preparing-service", "creating-component", "registering-service", "starting-service", "checking-service"]
            case "installed": state = .awaitingPeer; allowedCodes = ["awaiting-pairing"]
            case "passed": state = .passed; allowedCodes = ["ready"]
            case "failed": state = .failed(detail); allowedCodes = Set(["ep-service-start-failed", "forge-service-start-failed", "component-failed", "pairing-failed", "readiness-failed"]).union(pairingFailureDetails.keys)
            default: throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            guard allowedCodes.contains(code),
                  code != "awaiting-pairing" || id == "forge-runtime",
                  code != "ep-service-start-failed" || id == "engineering-platform-server",
                  code != "forge-service-start-failed" || id == "forge-runtime",
                  code != "pairing-failed" || id == "pairing",
                  !pairingFailureDetails.keys.contains(code) || id == "pairing",
                  code != "readiness-failed" || id == "readiness" else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            stages.append(ExecutionStage(id: id, title: title(for: id), detail: detail, state: state))
        }
        guard stages.contains(where: { $0.id == "readiness" }),
              stages.contains(where: { $0.id == "engineering-platform-server" || $0.id == "forge-runtime" }) else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return Self(operationID: intent.operationID, stages: stages)
    }

    private static func title(for id: String) -> String {
        switch id {
        case "engineering-platform-server": return "Engineering Platform"
        case "forge-runtime": return "Forge"
        case "pairing": return "EP en Forge verbinden"
        default: return "Werking controleren"
        }
    }

    private static func detail(for code: String) -> String? {
        if let reason = pairingFailureDetails[code] { return reason }
        switch code {
        case "none": return "Nog niet gestart"
        case "preflight": return "Installatie controleren"
        case "installing": return "Installeren en service controleren"
        case "preparing-service": return "Servicemappen en accounttoegang voorbereiden"
        case "creating-component": return "Component aanmaken via de officiële installatieroute"
        case "registering-service": return "Achtergrondservice registreren"
        case "starting-service": return "Achtergrondservice starten"
        case "checking-service": return "Service en providerverbinding controleren"
        case "awaiting-pairing": return "Geïnstalleerd; wacht op verbinding met EP"
        case "ready": return "Werking bevestigd"
        case "ep-service-start-failed": return "De EP-service is niet bereikbaar. Laat installatieherstel de servicemappen, toegangsrechten en service controleren voordat je hervat."
        case "forge-service-start-failed": return "De Forge-servicecontrole is niet geslaagd. De installatie is nog niet gereed. Laat de service, Codex-verbinding en pairing controleren voordat je hervat; start niet opnieuw met installeren."
        case "component-failed": return "Deze component kon niet worden afgerond. Controleer het installatieresultaat voordat je hervat."
        case "pairing-failed": return "EP en Forge konden niet worden verbonden. De componentresultaten blijven behouden."
        case "readiness-failed": return "De eindcontrole is niet geslaagd. De installatie is nog niet gereed."
        default: return nil
        }
    }
}

public protocol ManagedInstallerComponentProgressIntentReading: Sendable {
    func readComponentProgress(_ intent: ManagedInstallerReviewedExecutionIntent) async throws
        -> ManagedInstallerComponentProgress
}

struct FileManagedInstallerComponentProgressReader {
    let root: URL
    let expectedOwner: uid_t
    init(root: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot, expectedOwner: uid_t = 0) {
        self.root = root; self.expectedOwner = expectedOwner
    }
    func read(_ intent: ManagedInstallerReviewedExecutionIntent) -> Data? {
        let folder = root.appendingPathComponent("state/product-progress", isDirectory: true)
        let parent = folder.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard parent >= 0 else { return nil }
        defer { Darwin.close(parent) }
        var directory = stat()
        guard Darwin.fstat(parent, &directory) == 0, directory.st_uid == expectedOwner,
              directory.st_mode & mode_t(0o7777) == mode_t(0o700), Self.noACL(parent) else { return nil }
        let name = intent.operationID + ".json"
        let file = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard file >= 0 else { return nil }
        defer { Darwin.close(file) }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0, before.st_uid == expectedOwner,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1,
              before.st_mode & mode_t(0o7777) == mode_t(0o600), before.st_flags == 0,
              before.st_size > 0, before.st_size <= 8192, Self.noACL(file),
              let bytes = try? FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: 8193),
              bytes.count == before.st_size,
              (try? ManagedInstallerComponentProgress.decode(bytes, intent: intent)) != nil else { return nil }
        var after = stat(), named = stat(), parentAfter = stat(), parentNamed = stat()
        guard Darwin.fstat(file, &after) == 0,
              name.withCString({ Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              Darwin.fstat(parent, &parentAfter) == 0,
              folder.path.withCString({ Darwin.lstat($0, &parentNamed) }) == 0,
              Self.same(before, after), Self.same(before, named),
              Self.same(directory, parentAfter), Self.same(directory, parentNamed),
              Self.noACL(file), Self.noACL(parent) else { return nil }
        return bytes
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_gid == b.st_gid
        && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_flags == b.st_flags
        && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
        && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
        && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func noACL(_ fd: Int32) -> Bool {
        errno = 0
        guard let acl = Darwin.acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        guard Darwin.acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?; errno = 0
        return Darwin.acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == -1 && errno == EINVAL
    }
}
