// swift-tools-version: 6.0
// NEBULAKit — the shared code of the native NEBULA apps for iPhone and Mac (NEBULA 1.0).
//
// The Mac mini stays the NEBULA server; these modules are a thin, secure client of its existing API (through the
// owner's Mini App gateway). No business logic is duplicated here: agents, tasks, the Password Vault and Smart
// Authentication run on the server, which stays the single source of truth.
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "NEBULAKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NEBULACore", targets: ["NEBULACore"]),
        .library(name: "NEBULANetwork", targets: ["NEBULANetwork"]),
        .library(name: "NEBULAAuth", targets: ["NEBULAAuth"]),
        .library(name: "NEBULADesignSystem", targets: ["NEBULADesignSystem"]),
        .library(name: "NEBULAChat", targets: ["NEBULAChat"]),
        .library(name: "NEBULAAgents", targets: ["NEBULAAgents"]),
        .library(name: "NEBULAVault", targets: ["NEBULAVault"]),
        .library(name: "NEBULADesktop", targets: ["NEBULADesktop"]),
        .library(name: "NEBULASystem", targets: ["NEBULASystem"]),
        .library(name: "NEBULAAppUI", targets: ["NEBULAAppUI"]),
    ],
    targets: [
        // system zlib (Tight / ZRLE streams of the Live Desktop need a persistent inflate state)
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "NEBULACore", swiftSettings: strict),
        .target(name: "NEBULANetwork", dependencies: ["NEBULACore"], swiftSettings: strict),
        .target(name: "NEBULAAuth", dependencies: ["NEBULACore", "NEBULANetwork"], swiftSettings: strict),
        .target(name: "NEBULADesignSystem", dependencies: ["NEBULACore"], swiftSettings: strict),
        .target(name: "NEBULAChat", dependencies: ["NEBULACore", "NEBULANetwork", "NEBULADesignSystem"],
                swiftSettings: strict),
        .target(name: "NEBULAAgents", dependencies: ["NEBULACore", "NEBULANetwork", "NEBULADesignSystem"],
                swiftSettings: strict),
        .target(name: "NEBULAVault",
                dependencies: ["NEBULACore", "NEBULANetwork", "NEBULAAuth", "NEBULADesignSystem"],
                swiftSettings: strict),
        .target(name: "NEBULADesktop",
                dependencies: ["NEBULACore", "NEBULANetwork", "NEBULADesignSystem", "CZlib"],
                swiftSettings: strict),
        .target(name: "NEBULASystem", dependencies: ["NEBULACore", "NEBULANetwork", "NEBULADesignSystem"],
                swiftSettings: strict),
        .target(name: "NEBULAAppUI",
                dependencies: ["NEBULACore", "NEBULANetwork", "NEBULAAuth", "NEBULADesignSystem", "NEBULAChat",
                               "NEBULAAgents", "NEBULAVault", "NEBULADesktop", "NEBULASystem"],
                swiftSettings: strict),
        .testTarget(name: "NEBULACoreTests", dependencies: ["NEBULACore"]),
        .testTarget(name: "NEBULANetworkTests", dependencies: ["NEBULANetwork", "NEBULACore"]),
        .testTarget(name: "NEBULAAuthTests", dependencies: ["NEBULAAuth", "NEBULANetwork", "NEBULACore"]),
        .testTarget(name: "NEBULADesktopTests", dependencies: ["NEBULADesktop", "NEBULACore"]),
        .testTarget(name: "NEBULAChatTests", dependencies: ["NEBULAChat", "NEBULACore"]),
    ],
    swiftLanguageModes: [.v6]
)
