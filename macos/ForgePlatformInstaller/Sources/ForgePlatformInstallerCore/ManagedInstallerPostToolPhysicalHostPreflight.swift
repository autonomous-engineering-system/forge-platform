import Darwin
import Foundation

/// Facts read by the privileged helper from its own host. Network and trusted
/// time are established by the fresh signed-material admission, not by these
/// local hardware observations.
struct ManagedInstallerPostToolPhysicalHostFacts: Equatable, Sendable {
    let macOSVersion: InstallerVersion
    let hardwareArchitecture: String
    let nativeArm64Process: Bool
    let rosettaTranslated: Bool
    let availableDiskBytes: UInt64
    let memoryBytes: UInt64
    let administratorAuthorized: Bool
}

protocol ManagedInstallerPostToolPhysicalHostFactReading: Sendable {
    func readFacts() -> ManagedInstallerPostToolPhysicalHostFacts?
}

struct MacOSManagedInstallerPostToolPhysicalHostFactReader:
    ManagedInstallerPostToolPhysicalHostFactReading, Sendable {
    private let rootDirectory: URL

    init(rootDirectory: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot) {
        self.rootDirectory = rootDirectory
    }

    func readFacts() -> ManagedInstallerPostToolPhysicalHostFacts? {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard let version = try? InstallerVersion(
            "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        ) else { return nil }

        var machine = [CChar](repeating: 0, count: 64)
        var machineSize = size_t(machine.count)
        guard Darwin.sysctlbyname("hw.machine", &machine, &machineSize, nil, 0) == 0,
              machineSize > 1, machineSize <= machine.count else { return nil }
        let architecture = machine.withUnsafeBytes { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }

        var translated: Int32 = -1
        var translatedSize = size_t(MemoryLayout<Int32>.size)
        guard Darwin.sysctlbyname(
            "sysctl.proc_translated", &translated, &translatedSize, nil, 0
        ) == 0, translatedSize == MemoryLayout<Int32>.size,
            translated == 0 || translated == 1 else { return nil }

        var memory: UInt64 = 0
        var memorySize = size_t(MemoryLayout<UInt64>.size)
        guard Darwin.sysctlbyname("hw.memsize", &memory, &memorySize, nil, 0) == 0,
              memorySize == MemoryLayout<UInt64>.size, memory > 0 else { return nil }

        var volume = statvfs()
        let descriptor = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fstatvfs(descriptor, &volume) == 0,
              volume.f_bsize > 0 else { return nil }
        let (available, overflow) = UInt64(volume.f_bavail)
            .multipliedReportingOverflow(by: UInt64(volume.f_bsize))
        guard !overflow else { return nil }

        #if arch(arm64)
        let nativeArm64 = true
        #else
        let nativeArm64 = false
        #endif
        return ManagedInstallerPostToolPhysicalHostFacts(
            macOSVersion: version, hardwareArchitecture: architecture,
            nativeArm64Process: nativeArm64, rosettaTranslated: translated == 1,
            availableDiskBytes: available, memoryBytes: memory,
            administratorAuthorized: Darwin.geteuid() == 0
        )
    }
}

/// Parses only the signed composition's exact host-requirements contract.
/// Unknown or malformed requirements cannot silently become a passing check.
struct ManagedInstallerPostToolSignedHostRequirement: Equatable, Sendable {
    let minimumMacOSVersion: InstallerVersion
    let minimumAvailableDiskBytes: UInt64
    let backupReserveBytes: UInt64
    let minimumMemoryBytes: UInt64
    let requiresAdministrator: Bool
    let requiresNetwork: Bool
    let requiresTrustedClock: Bool

    static func parse(_ manifest: Data) -> Self? {
        guard var reader = try? StrictJSONResourceReader(data: manifest),
              let fields = try? reader.parseDocument().objectValue,
              let host = fields["host_requirements"]?.objectValue,
              Set(host.keys) == Set([
                "minimum_macos_version", "supported_architectures",
                "minimum_available_disk_bytes", "backup_reserve_bytes",
                "minimum_memory_bytes", "requires_administrator", "requires_network",
                "requires_trusted_clock",
              ]),
              let minimumRaw = host["minimum_macos_version"]?.stringValue,
              let minimum = try? InstallerVersion(minimumRaw), minimum.major >= 26,
              let architectures = host["supported_architectures"]?.arrayValue,
              architectures.count == 1,
              architectures[0].stringValue == "arm64",
              let disk = host["minimum_available_disk_bytes"]?.integerValue,
              let reserve = host["backup_reserve_bytes"]?.integerValue,
              let memory = host["minimum_memory_bytes"]?.integerValue,
              disk >= 0, reserve >= 0, memory >= 0,
              case .boolean(let admin) = host["requires_administrator"],
              case .boolean(let network) = host["requires_network"],
              case .boolean(let clock) = host["requires_trusted_clock"] else {
            return nil
        }
        return Self(
            minimumMacOSVersion: minimum,
            minimumAvailableDiskBytes: UInt64(disk),
            backupReserveBytes: UInt64(reserve),
            minimumMemoryBytes: UInt64(memory),
            requiresAdministrator: admin, requiresNetwork: network,
            requiresTrustedClock: clock
        )
    }

    func permits(_ facts: ManagedInstallerPostToolPhysicalHostFacts,
                 freshSignedMaterialAndClock: Bool) -> Bool {
        let (requiredDisk, overflow) = minimumAvailableDiskBytes
            .addingReportingOverflow(backupReserveBytes)
        return !overflow
            && facts.macOSVersion.major >= 26
            && facts.macOSVersion >= minimumMacOSVersion
            && facts.hardwareArchitecture == "arm64"
            && facts.nativeArm64Process && !facts.rosettaTranslated
            && facts.availableDiskBytes >= requiredDisk
            && facts.memoryBytes >= minimumMemoryBytes
            && (!requiresAdministrator || facts.administratorAuthorized)
            && (!requiresNetwork || freshSignedMaterialAndClock)
            && (!requiresTrustedClock || freshSignedMaterialAndClock)
    }
}
