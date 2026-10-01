import ForgePlatformInstallerCore

/// Registers the bundled helper only after the released CLI has passed trusted
/// startup, an explicit operator decision and a fresh installer-currency read.
enum InstallerCLIHelperRegistration {
    typealias Registrar = @Sendable (InstallerVersion) async -> ManagedInstallerPrivilegedHelperRegistrationResult

    static let liveRegistrar: Registrar = { expectedVersion in
        let service = MacOSManagedInstallerPrivilegedHelperServiceController()
        guard let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator.production(
            service: service
        ) else { return .failed(.transitionBusy) }
        return await coordinator.ensureRegistered(expectedVersion: expectedVersion)
    }

    static let liveQualificationReplacer: Registrar = { expectedVersion in
        let service = MacOSManagedInstallerPrivilegedHelperServiceController()
        guard let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator.production(
            service: service
        ) else { return .failed(.transitionBusy) }
        return await coordinator.replaceLegacyQualification(expectedVersion: expectedVersion)
    }

    static func run(
        startup: any InstallerCLIStarting,
        currentVersion: InstallerVersion,
        currentRelease: VerifiedInstallerRelease,
        options: InstallerCLIOptions,
        confirm: ForgePlatformInstallerCLIApplication.Confirmation,
        register: Registrar,
        replacingQualification: Bool = false
    ) async -> InstallerCLIResult {
        if !options.assumeYes {
            let accepted = options.nonInteractive ? false : await confirm(
                replacingQualification
                    ? "Vervang de exacte inactieve 0.2.4-kwalificatiehelper door de geverifieerde systeemhelper?"
                    : "Registreer de geverifieerde installer-helper als systeemdaemon?"
            )
            if !accepted {
                return InstallerCLIResult(
                    exitCode: .confirmationRequired,
                    status: "confirmation-required",
                    message: "Helperregistratie vereist een expliciete bevestiging."
                )
            }
        }

        switch await startup.start(currentVersion: currentVersion) {
        case .ready(let freshRelease, _):
            guard freshRelease == currentRelease,
                  freshRelease.version == currentVersion else {
                return blocked("De geverifieerde installerrelease veranderde vóór helperregistratie.")
            }
        case .updateRequired(let release), .relaunching(let release):
            return InstallerCLIResult(
                exitCode: .installerUpdateRequired,
                status: "installer-update-required",
                message: "Een nieuwere verified installer is vereist vóór helperregistratie.",
                details: ["required_version": release.version.description]
            )
        case .blocked(let reason):
            return blocked(reason)
        }

        switch await register(currentVersion) {
        case .ready(let receipt):
            return InstallerCLIResult(
                exitCode: .success,
                status: "helper-enabled",
                message: "De systeemhelper is geregistreerd en staat op ENABLED.",
                details: details(for: receipt)
            )
        case .requiresApproval(let receipt):
            return InstallerCLIResult(
                exitCode: .interactionRequired,
                status: "helper-requires-approval",
                message: "macOS-goedkeuring voor de systeemhelper is nog vereist.",
                details: details(for: receipt)
            )
        case .failed(let failure):
            let reason: String
            switch failure {
            case .registrationFailed: reason = "registration-failed"
            case .serviceUnavailable: reason = "service-unavailable"
            case .statusDrift: reason = "status-drift"
            case .registeredParentMismatch: reason = "registered-parent-mismatch"
            case .unregistrationFailed: reason = "unregistration-failed"
            case .transitionBusy: reason = "transition-busy"
            }
            return InstallerCLIResult(
                exitCode: .executionFailed,
                status: "helper-registration-failed",
                message: "Helperregistratie of onafhankelijke status-readback is mislukt.",
                details: ["reason": reason]
            )
        }
    }

    private static func blocked(_ reason: String) -> InstallerCLIResult {
        InstallerCLIResult(exitCode: .blocked, status: "blocked", message: reason)
    }

    private static func details(
        for receipt: ManagedInstallerPrivilegedHelperRegistrationReceipt
    ) -> [String: String] {
        [
            "label": receipt.label,
            "plist_name": receipt.plistName,
            "bundle_program": receipt.bundleProgram,
            "mach_services": receipt.machServices.joined(separator: ","),
            "service_status": receipt.status.rawValue,
        ]
    }
}
