// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForgePlatformInstaller",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ForgePlatformInstallerCore", targets: ["ForgePlatformInstallerCore"]),
        .executable(name: "ForgePlatformInstaller", targets: ["ForgePlatformInstaller"]),
        .executable(name: "forge-platform-installer", targets: ["ForgePlatformInstallerCLI"]),
        .executable(
            name: "forge-platform-installer-helper",
            targets: ["ForgePlatformInstallerPrivilegedHelper"]
        ),
    ],
    targets: [
        .target(name: "ScopedKeychainAccess", publicHeadersPath: "include",
                cSettings: [.define("DEBUG", to: "1", .when(configuration: .debug))]),
        .target(name: "ForgePlatformInstallerCore", dependencies: ["ScopedKeychainAccess"]),
        .executableTarget(
            name: "ForgePlatformInstaller",
            dependencies: ["ForgePlatformInstallerCore"]
        ),
        .executableTarget(
            name: "ForgePlatformInstallerCLI",
            dependencies: ["ForgePlatformInstallerCore"]
        ),
        .executableTarget(
            name: "ForgePlatformInstallerPrivilegedHelper",
            dependencies: ["ForgePlatformInstallerCore"]
        ),
        .testTarget(
            name: "ForgePlatformInstallerCoreTests",
            dependencies: [
                "ForgePlatformInstallerCore",
                "ForgePlatformInstallerPrivilegedHelper",
            ]
        ),
        .testTarget(
            name: "ForgePlatformInstallerTests",
            dependencies: ["ForgePlatformInstaller", "ForgePlatformInstallerCore"]
        ),
        .testTarget(
            name: "ForgePlatformInstallerCLITests",
            dependencies: ["ForgePlatformInstallerCLI", "ForgePlatformInstallerCore"]
        ),
    ]
)
