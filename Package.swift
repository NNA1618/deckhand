// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Deckhand",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Deckhand", targets: ["Deckhand"])
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "Deckhand",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
            path: "Sources/Deckhand",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("Combine"),
            ]
        )
    ]
)
