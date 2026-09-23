import Foundation

public enum InstallerComponentID: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case forgeRuntime = "forge-runtime"
    case engineeringPlatformServer = "engineering-platform-server"
    case workspaceServer = "workspace-server"
    case workspaceClient = "workspace-client"
    case engineeringPlatformProjectAgent = "engineering-platform-project-agent"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .forgeRuntime: return "Forge Server"
        case .engineeringPlatformServer: return "Engineering Platform Server"
        case .workspaceServer: return "Workspace Server"
        case .workspaceClient: return "Workspace Client"
        case .engineeringPlatformProjectAgent: return "EP Client (Project Agent)"
        }
    }
}

public enum InstallerComponentAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

public struct InstallerComponentOption: Equatable, Sendable, Identifiable {
    public let component: InstallerComponentID
    public let availability: InstallerComponentAvailability
    public var id: InstallerComponentID { component }

    public init(component: InstallerComponentID, availability: InstallerComponentAvailability) {
        self.component = component
        self.availability = availability
    }
}

public enum InstallerPresetID: String, CaseIterable, Equatable, Sendable, Identifiable {
    case forgeAndEPServers = "forge-ep-servers"
    case epServerOnly = "ep-server-only"
    case forgeServerOnly = "forge-server-only"
    case serverInstall = "server-install"
    case clientInstall = "client-install"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .forgeAndEPServers: return "Forge + EP Servers"
        case .epServerOnly: return "Alleen EP Server"
        case .forgeServerOnly: return "Alleen Forge Server"
        case .serverInstall: return "Volledige Server-installatie"
        case .clientInstall: return "Client-installatie"
        }
    }
}

public struct InstallerPreset: Equatable, Sendable, Identifiable {
    public let id: InstallerPresetID
    public let components: Set<InstallerComponentID>
    public let availability: InstallerComponentAvailability

    public init(
        id: InstallerPresetID,
        components: Set<InstallerComponentID>,
        availability: InstallerComponentAvailability
    ) {
        self.id = id
        self.components = components
        self.availability = availability
    }
}

public struct InstallerComponentSelection: Equatable, Sendable {
    public private(set) var selected: Set<InstallerComponentID>

    public init(selected: Set<InstallerComponentID> = []) {
        self.selected = selected
    }

    public static let options: [InstallerComponentOption] = [
        InstallerComponentOption(component: .forgeRuntime, availability: .available),
        InstallerComponentOption(component: .engineeringPlatformServer, availability: .available),
        InstallerComponentOption(
            component: .workspaceServer,
            availability: .unavailable(
                "Workspace Server heeft nog geen door deze installer gekwalificeerd productie-artifact/provisionercontract."
            )
        ),
        InstallerComponentOption(
            component: .workspaceClient,
            availability: .unavailable(
                "Workspace Client wordt pas beschikbaar zodra de Workspace-releasecompositie is gekwalificeerd."
            )
        ),
        InstallerComponentOption(
            component: .engineeringPlatformProjectAgent,
            availability: .unavailable(
                "EP Project Agent blijft user-owned en is nog niet opgenomen in deze server-installerkwalificatie."
            )
        ),
    ]

    public static let presets: [InstallerPreset] = [
        InstallerPreset(
            id: .forgeAndEPServers,
            components: [.forgeRuntime, .engineeringPlatformServer],
            availability: .available
        ),
        InstallerPreset(
            id: .epServerOnly,
            components: [.engineeringPlatformServer],
            availability: .available
        ),
        InstallerPreset(
            id: .forgeServerOnly,
            components: [.forgeRuntime],
            availability: .available
        ),
        InstallerPreset(
            id: .serverInstall,
            components: [.forgeRuntime, .engineeringPlatformServer, .workspaceServer],
            availability: .unavailable(
                "Volledige Server-installatie vereist Workspace Server; dat artifact is nog niet gekwalificeerd."
            )
        ),
        InstallerPreset(
            id: .clientInstall,
            components: [.workspaceClient, .engineeringPlatformProjectAgent],
            availability: .unavailable(
                "Client-installatie vereist Workspace Client en EP Project Agent; deze zijn nog niet gekwalificeerd."
            )
        ),
    ]

    public var isValid: Bool {
        !selected.isEmpty && selected.allSatisfy { component in
            Self.options.first(where: { $0.component == component })?.availability.isAvailable == true
        }
    }

    @discardableResult
    public mutating func setSelected(_ component: InstallerComponentID, selected isSelected: Bool) -> Bool {
        guard let option = Self.options.first(where: { $0.component == component }),
              option.availability.isAvailable else {
            return false
        }
        if isSelected {
            selected.insert(component)
        } else {
            selected.remove(component)
        }
        return true
    }

    @discardableResult
    public mutating func applyPreset(_ presetID: InstallerPresetID) -> Bool {
        guard let preset = Self.presets.first(where: { $0.id == presetID }),
              preset.availability.isAvailable else {
            return false
        }
        selected = preset.components
        return true
    }
}

public struct InstallerCompositionRequest: Equatable, Sendable {
    public let componentIdentities: Set<String>
    public let installedComposition: ManagedDeploymentCompositionIdentity?

    public var installedCompositionID: String? {
        installedComposition?.compositionID
    }

    public init(
        componentIdentities: Set<String>,
        installedComposition: ManagedDeploymentCompositionIdentity?
    ) throws {
        guard !componentIdentities.isEmpty,
              componentIdentities.allSatisfy(CompositionCatalogValidation.isCapability) else {
            throw InstallerCompositionRequestError.invalid
        }
        self.componentIdentities = componentIdentities
        self.installedComposition = installedComposition
    }
}

public enum InstallerCompositionRequestError: Error, Equatable, Sendable {
    case invalid
}
