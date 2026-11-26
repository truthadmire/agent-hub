// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentHub", targets: ["AgentHub"]),
        .executable(name: "HubProcessGuard", targets: ["HubProcessGuard"]),
        .executable(name: "HubSmoke", targets: ["HubSmoke"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CProcessSupport", exclude: ["Guard"]),
        .executableTarget(name: "HubProcessGuard", path: "Sources/CProcessSupport/Guard"),
        .target(name: "HubProcess", dependencies: ["CProcessSupport", "HubProcessGuard"]),
        .target(name: "HubProviders", dependencies: ["HubProcess"]),
        .target(name: "HubGit"),
        .target(name: "HubKit", dependencies: ["CSQLite", "HubGit", "HubProcess", "HubProviders"]),
        .executableTarget(name: "AgentHub", dependencies: ["HubKit", "HubGit", "HubProviders"]),
        .executableTarget(name: "HubSmoke", dependencies: ["HubKit", "HubGit", "HubProcess", "HubProviders"]),
        .testTarget(name: "HubProcessTests", dependencies: ["HubProcess", "HubProcessGuard"]),
        .testTarget(name: "HubGitTests", dependencies: ["HubGit"]),
        .testTarget(name: "HubProvidersTests", dependencies: ["HubProviders", "HubProcess"]),
        .testTarget(name: "HubKitTests", dependencies: ["HubKit", "HubGit", "HubProcess", "HubProviders"])
    ]
)
