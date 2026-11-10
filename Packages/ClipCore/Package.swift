// swift-tools-version: 6.2

import PackageDescription

// Any warning fails the build, the same rule the app has in project.yml.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "ClipCore",
    // Must match the app's deployment target (26.4).
    platforms: [.macOS("26.4")],
    // Two libraries so the app links each one explicitly, and so the import rules
    // (scripts/check-imports.sh) can keep macOS code out of ClipCore.
    products: [
        .library(name: "ClipCore", targets: ["ClipCore"]),
        .library(name: "ClipSystem", targets: ["ClipSystem"]),
    ],
    // Pinned to exact tags. Package.resolved also pins KeyboardShortcuts, which only the app uses:
    // Xcode (16 and later) writes the whole app's pins into a local package's Package.resolved on
    // every build, so the committed file is the one Xcode writes. Don't run `swift package resolve`
    // or `update` here unless a version changes: they would drop that pin, and the next Xcode build
    // would put it back.
    // Sauce (MIT) finds which physical key types a letter on the user's keyboard layout, which
    // pressing ⌘V needs on Dvorak and similar layouts.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0"),
        .package(url: "https://github.com/Clipy/Sauce", exact: "2.5.2"),
    ],
    targets: [
        // The model, rules, storage and services. No UI, so its tests run in milliseconds without
        // launching the app. Only its Storage/ folder may use GRDB; scripts/check-imports.sh
        // enforces that.
        .target(
            name: "ClipCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),
        // Adapters that talk to macOS (clipboard, keyboard, thumbnails), implementing ClipCore's
        // ports.
        .target(
            name: "ClipSystem",
            dependencies: ["ClipCore", .product(name: "Sauce", package: "Sauce")],
            swiftSettings: strict
        ),
        // ClipCoreTests also sees GRDB, so a test can open the database file itself (to checkpoint
        // it, or to build an old schema to migrate); check-imports.sh covers Sources/ only.
        .testTarget(
            name: "ClipCoreTests",
            dependencies: ["ClipCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),
        .testTarget(name: "ClipSystemTests", dependencies: ["ClipSystem"], swiftSettings: strict),
    ]
)
