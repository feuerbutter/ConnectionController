// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CambridgeVPNAuto",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CambridgeVPNAutoCore", targets: ["CambridgeVPNAutoCore"]),
        .library(name: "ConnectionRouterObjC", targets: ["ConnectionRouterObjC"]),
        .executable(name: "CambridgeVPNAuto", targets: ["CambridgeVPNAuto"]),
        .executable(name: "CambridgeVPNAutoCoreChecks", targets: ["CambridgeVPNAutoCoreChecks"]),
        .executable(name: "ClaudeVPNGuard", targets: ["ClaudeVPNGuard"]),
        .executable(name: "ConnectionRouter", targets: ["ConnectionRouter"])
    ],
    targets: [
        .target(name: "CambridgeVPNAutoCore"),
        .executableTarget(name: "ClaudeVPNGuard", dependencies: ["CambridgeVPNAutoCore"]),
        .target(name: "ConnectionRouterObjC"),
        .executableTarget(name: "ConnectionRouter", dependencies: ["CambridgeVPNAutoCore", "ConnectionRouterObjC"]),
        .executableTarget(
            name: "CambridgeVPNAuto",
            dependencies: ["CambridgeVPNAutoCore"]
        ),
        .executableTarget(
            name: "CambridgeVPNAutoCoreChecks",
            dependencies: ["CambridgeVPNAutoCore"],
            path: "Tests/CambridgeVPNAutoCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
