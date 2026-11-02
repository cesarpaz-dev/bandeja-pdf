// swift-tools-version: 5.9
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

let package = Package(
    name: "BandejaPDF",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "BandejaPDF", targets: ["BandejaUI"]),
        .executable(name: "BandejaAgent", targets: ["BandejaAgent"]),
        .executable(name: "BandejaCLI", targets: ["BandejaCLI"])
    ],
    targets: [
        .target(name: "BandejaShared"),
        .target(name: "BandejaCore", dependencies: ["BandejaShared"]),
        .executableTarget(name: "BandejaAgent", dependencies: ["BandejaShared", "BandejaCore"]),
        .executableTarget(name: "BandejaUI", dependencies: ["BandejaShared"]),
        .executableTarget(name: "BandejaCLI", dependencies: ["BandejaShared"]),
        .testTarget(name: "BandejaCoreTests", dependencies: ["BandejaCore", "BandejaShared"], exclude: ["run-standalone.sh"])
    ]
)
