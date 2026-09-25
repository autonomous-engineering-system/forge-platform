import Foundation

public enum ManagedInstallerPostToolXPCCallerIdentityError: Error, Equatable {
    case invalidIdentity
}

/// Exact signed installer identity admitted by the privileged observation
/// helper. The requirement is fixed to a Developer ID Application chain,
/// exact signing identifier and exact Team ID.
public struct ManagedInstallerPostToolXPCCallerIdentity: Equatable, Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let codeSigningRequirement: String

    public init(bundleIdentifier: String, teamIdentifier: String) throws {
        guard InstallerSelfUpdateValidation.isBundleIdentifier(bundleIdentifier),
              InstallerSelfUpdateValidation.isTeamIdentifier(teamIdentifier) else {
            throw ManagedInstallerPostToolXPCCallerIdentityError.invalidIdentity
        }
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        codeSigningRequirement = [
            "anchor apple generic",
            "identifier \"\(bundleIdentifier)\"",
            "certificate 1[field.1.2.840.113635.100.6.2.6] exists",
            "certificate leaf[field.1.2.840.113635.100.6.1.13] exists",
            "certificate leaf[subject.OU] = \"\(teamIdentifier)\"",
        ].joined(separator: " and ")
    }

    public init(releaseTrust: SealedInstallerReleaseTrustConfiguration) throws {
        try self.init(
            bundleIdentifier: releaseTrust.expectedBundleIdentifier,
            teamIdentifier: releaseTrust.expectedTeamIdentifier
        )
    }
}

/// Named privileged listener for the fixed post-tool observation service.
/// Foundation rejects peers that do not satisfy the exact code-signing
/// requirement before this delegate is consulted. Accepted peers receive only
/// the closed observation interface and its fail-closed handler.
public final class MacOSManagedInstallerPostToolObservationXPCListener:
    NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let serviceHandler: any ManagedInstallerPostToolObservationXPCService

    public convenience init(
        callerIdentity: ManagedInstallerPostToolXPCCallerIdentity,
        serviceHandler: any ManagedInstallerPostToolObservationXPCService
    ) {
        self.init(
            listener: NSXPCListener(
                machServiceName: MacOSManagedInstallerPostToolXPCTransport.machServiceName
            ),
            callerIdentity: callerIdentity,
            serviceHandler: serviceHandler,
            installCodeSigningRequirement: { listener, requirement in
                listener.setConnectionCodeSigningRequirement(requirement)
            }
        )
    }

    init(
        listener: NSXPCListener,
        callerIdentity: ManagedInstallerPostToolXPCCallerIdentity,
        serviceHandler: any ManagedInstallerPostToolObservationXPCService,
        installCodeSigningRequirement: (NSXPCListener, String) -> Void
    ) {
        self.listener = listener
        self.serviceHandler = serviceHandler
        super.init()
        installCodeSigningRequirement(listener, callerIdentity.codeSigningRequirement)
        listener.delegate = self
    }

    public func activate() {
        listener.activate()
    }

    public func invalidate() {
        listener.invalidate()
    }

    var endpoint: NSXPCListenerEndpoint {
        listener.endpoint
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        _ = listener
        newConnection.exportedInterface = NSXPCInterface(
            with: ManagedInstallerPostToolObservationXPCService.self
        )
        newConnection.exportedObject = serviceHandler
        newConnection.resume()
        return true
    }
}
