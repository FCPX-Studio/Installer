// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StudioKit",
    platforms: [.macOS(.v14)],
    products: [
        // Shared by the installers AND the FxPlug extensions: keep it free of UI and networking.
        .library(name: "StudioLicense", targets: ["StudioLicense"]),
        // Installer-only modules.
        .library(name: "StudioActivation", targets: ["StudioActivation"]),
        .library(name: "StudioInstallKit", targets: ["StudioInstallKit"]),
        .library(name: "StudioInstallerUI", targets: ["StudioInstallerUI"]),
        // Development helper: key generation and local token signing (never ship it).
        .executable(name: "studio-license-tool", targets: ["StudioLicenseTool"]),
    ],
    targets: [
        .target(name: "StudioLicense"),
        .target(name: "StudioActivation", dependencies: ["StudioLicense"]),
        .target(name: "StudioInstallKit"),
        .target(
            name: "StudioInstallerUI",
            dependencies: ["StudioLicense", "StudioActivation", "StudioInstallKit"]
        ),
        .executableTarget(name: "StudioLicenseTool", dependencies: ["StudioLicense"]),
        .testTarget(name: "StudioLicenseTests", dependencies: ["StudioLicense"]),
        .testTarget(name: "StudioInstallKitTests", dependencies: ["StudioInstallKit"]),
    ]
)
