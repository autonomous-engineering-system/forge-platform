import ForgePlatformInstallerCore

/// Registers the bundled helper only after the released CLI has passed trusted
/// startup, an explicit operator decision and a fresh installer-currency read.
enum InstallerCLIHelperRegistration {
    typealias Registrar = @Sendable (InstallerVersion) async -> ManagedInstallerPrivilegedHelperRegistrationResult

    enum Action: Sendable {
        case register, qualification, idle, mvp0314, mvp0316, mvp0318, mvp0319, mvp0320, mvp0322, mvp0323, mvp0324, mvp0325, mvp0326
    }

    static func makeRegistrar(
        for action: Action,
        coordinator: @escaping @Sendable () -> ManagedInstallerPrivilegedHelperRegistrationCoordinator?
    ) -> Registrar {
        { expectedVersion in
            guard let instance = coordinator() else { return .failed(.transitionBusy) }
            switch action {
            case .register:
                return await instance.ensureRegistered(expectedVersion: expectedVersion)
            case .qualification:
                return await instance.replaceLegacyQualification(expectedVersion: expectedVersion)
            case .idle:
                return await instance.replaceIdleOlderRegistration(expectedVersion: expectedVersion)
            case .mvp0314:
                return await instance.replaceMVP0314ForCleanInstall(expectedVersion: expectedVersion)
            case .mvp0316:
                return await instance.replaceMVP0316ForCleanInstall(expectedVersion: expectedVersion)
            case .mvp0318:
                return await instance.replaceMVP0318ForCleanInstall(expectedVersion: expectedVersion)
            case .mvp0319:
                return await instance.replaceMVP0319ForCleanInstall(expectedVersion: expectedVersion)
            case .mvp0320:
                return await instance.replaceMVP0320ForCleanInstall(expectedVersion: expectedVersion)
            case .mvp0322:
                return await instance.replaceMVP0322ForCleanInstall(expectedVersion: expectedVersion)
            case .mvp0323:
                return await instance.replaceMVP0323ForCleanInstall(expectedVersion: expectedVersion)
            case .mvp0324:
                return await instance.replaceMVP0324ForCleanInstall(expectedVersion: expectedVersion)
            case .mvp0325:
                return await instance.replaceMVP0325ForCleanInstall(expectedVersion: expectedVersion)
            case .mvp0326:
                return await instance.replaceMVP0326ForCleanInstall(expectedVersion: expectedVersion)
            }
        }
    }

    static let liveRegistrar = makeRegistrar(for: .register, coordinator: liveCoordinator)
    static let liveQualificationReplacer = makeRegistrar(for: .qualification, coordinator: liveCoordinator)
    static let liveIdleReplacer = makeRegistrar(for: .idle, coordinator: liveCoordinator)
    static let liveMVP0314Replacer = makeRegistrar(for: .mvp0314, coordinator: liveCoordinator)
    static let liveMVP0316Replacer = makeRegistrar(for: .mvp0316, coordinator: liveCoordinator)
    static let liveMVP0318Replacer = makeRegistrar(for: .mvp0318, coordinator: liveCoordinator)
    static let liveMVP0319Replacer = makeRegistrar(for: .mvp0319, coordinator: liveCoordinator)
    static let liveMVP0320Replacer = makeRegistrar(for: .mvp0320, coordinator: liveCoordinator)
    static let liveMVP0322Replacer = makeRegistrar(for: .mvp0322, coordinator: liveCoordinator)
    static let liveMVP0323Replacer = makeRegistrar(for: .mvp0323, coordinator: liveCoordinator)
    static let liveMVP0324Replacer = makeRegistrar(for: .mvp0324, coordinator: liveCoordinator)
    static let liveMVP0325Replacer = makeRegistrar(for: .mvp0325, coordinator: liveCoordinator)
    static let liveMVP0326Replacer = makeRegistrar(for: .mvp0326, coordinator: liveCoordinator)

    private static func liveCoordinator() -> ManagedInstallerPrivilegedHelperRegistrationCoordinator? {
        let service = MacOSManagedInstallerPrivilegedHelperServiceController()
        return ManagedInstallerPrivilegedHelperRegistrationCoordinator.production(service: service)
    }

    static func run(
        startup: any InstallerCLIStarting,
        currentVersion: InstallerVersion,
        currentRelease: VerifiedInstallerRelease,
        options: InstallerCLIOptions,
        confirm: ForgePlatformInstallerCLIApplication.Confirmation,
        register: Registrar,
        replacingQualification: Bool = false,
        replacingOlder: Bool = false,
        replacingMVP0314: Bool = false,
        replacingMVP0316: Bool = false,
        replacingMVP0318: Bool = false,
        replacingMVP0319: Bool = false,
        replacingMVP0320: Bool = false,
        replacingMVP0322: Bool = false,
        replacingMVP0323: Bool = false,
        replacingMVP0324: Bool = false,
        replacingMVP0325: Bool = false,
        replacingMVP0326: Bool = false
    ) async -> InstallerCLIResult {
        if !options.assumeYes {
            let accepted = options.nonInteractive ? false : await confirm(
                replacingQualification
                    ? "Vervang de exacte inactieve 0.2.4-kwalificatiehelper door de geverifieerde systeemhelper?"
                    : replacingMVP0314
                        ? "Beëindig de actieve 0.3.14-helper na schone-hostcontrole en registreer de geverifieerde 0.3.16-helper?"
                    : replacingMVP0316
                        ? "Beëindig de actieve 0.3.16-helper na schone-hostcontrole en registreer de geverifieerde 0.3.18-helper?"
                    : replacingMVP0319
                        ? "Beëindig de actieve 0.3.19-helper na bewezen effectvrije herstelstatus en registreer de geverifieerde 0.3.20-helper?"
                    : replacingMVP0320
                        ? "Beëindig de actieve 0.3.20-helper na bewezen veilige herstelstatus en registreer de geverifieerde 0.3.22-helper?"
                    : replacingMVP0322
                        ? "Beëindig de actieve 0.3.22-helper na bewezen veilige herstelstatus en registreer de geverifieerde 0.3.23-helper?"
                    : replacingMVP0323
                        ? "Beëindig de actieve 0.3.23-helper na bewezen veilige herstelstatus en registreer de geverifieerde 0.3.24-helper?"
                    : replacingMVP0324
                        ? "Beëindig de actieve 0.3.24-helper na bewezen veilige herstelstatus en registreer de geverifieerde 0.3.25-helper?"
                    : replacingMVP0325
                        ? "Beëindig de actieve 0.3.25-helper na bewezen veilige herstelstatus en registreer de geverifieerde 0.3.26-helper?"
                    : replacingMVP0326
                        ? "Beëindig de actieve 0.3.26-helper na bewezen veilige herstelstatus en registreer de geverifieerde 0.3.27-helper?"
                    : replacingMVP0318
                        ? "Beëindig de actieve 0.3.18-helper na gecontroleerde schone-herstelstatus en registreer de geverifieerde 0.3.19-helper?"
                    : replacingOlder
                        ? "Vervang de exacte inactieve oudere installer-helper door de geverifieerde actuele systeemhelper?"
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
