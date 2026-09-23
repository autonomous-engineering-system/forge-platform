// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForgePlatformInstaller",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ForgePlatformInstallerCore", targets: ["ForgePlatformInstallerCore"]),
        .executable(name: "ForgePlatformInstaller", targets: ["ForgePlatformInstaller"]),
        .executable(
            name: "ForgePlatformInstallerReleaseCrypto",
            targets: ["ForgePlatformInstallerReleaseCrypto"]
        ),
    ],
    targets: [
        .target(name: "ForgePlatformInstallerCore"),
        .executableTarget(
            name: "ForgePlatformInstaller",
            dependencies: ["ForgePlatformInstallerCore"]
        ),
        .executableTarget(
            name: "ForgePlatformInstallerReleaseCrypto",
            dependencies: ["ForgePlatformInstallerCore"]
        ),
        .testTarget(
            name: "ForgePlatformInstallerCoreTests",
            dependencies: ["ForgePlatformInstallerCore"]
        ),
        .testTarget(
            name: "ForgePlatformInstallerTests",
            dependencies: ["ForgePlatformInstaller", "ForgePlatformInstallerCore"]
        ),
    ]
)
