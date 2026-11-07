// swift-tools-version: 6.2
// ↑ Not a normal comment: SwiftPM reads this first line to pick the manifest format version.
//   It must stay the very first line.

// Package.swift is the manifest of a Swift package: a library with its own source and tests.
// It plays the role of package.json (name, dependencies, exports) and is itself Swift code,
// the way build.gradle.kts is Kotlin code. `swift build` / `swift test` in this folder use it
// directly; the Xcode app pulls it in through project.yml.

// PackageDescription is the API for writing this manifest. (`import` makes another module's public
// names available, ≈ `import ... from '...'` in TS, but for a whole module at once.)
import PackageDescription

// Compiler settings shared by every target below: any warning fails the build, the same rule the
// app has in project.yml, so warnings never pile up unread. (`let` is a constant, ≈ `const`;
// `[SwiftSetting]` is "an array of SwiftSetting"; the leading dot in `.treatAllWarnings` means
// "a static member of the expected type", so this is SwiftSetting.treatAllWarnings(as: .error).
// `as:` is an argument label: Swift calls name their arguments, like an inline options object.)
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

// The package itself. SwiftPM runs this file and reads this one value to learn what to build.
// (`Package(...)` calls Package's initializer, ≈ `new Package({...})`.)
let package = Package(
    name: "ClipCore",
    // Oldest macOS this package supports. Must match the app's deployment target (26) so both
    // sides agree on which Apple APIs may be used without `if #available` checks.
    platforms: [.macOS(.v26)],
    // Products are what other code can depend on. ≈ the `exports` map in package.json.
    // We export two separate libraries so the app links each one explicitly, and so the
    // import rules (scripts/check-imports.sh) can keep macOS code out of ClipCore.
    products: [
        .library(name: "ClipCore", targets: ["ClipCore"]),
        .library(name: "ClipSystem", targets: ["ClipSystem"]),
    ],
    // Third-party packages, fetched from Git and pinned to an exact tag.
    // GRDB is a typed SQLite toolkit with migrations, full-text search and live queries.
    // ≈ Drizzle (TS) or Room (Android). Package.resolved records the exact commit, like a lockfile.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0")
    ],
    // Targets are the modules (folders of source) inside this package. By convention, target
    // "X" compiles every .swift file under Sources/X, and test target "XTests" under Tests/XTests.
    targets: [
        // ClipCore: the app's model, rules, storage and services. Plain Swift, no UI, so its tests
        // run in milliseconds without launching the app. Only its Storage/ folder may use GRDB;
        // scripts/check-imports.sh enforces that.
        .target(
            name: "ClipCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),
        // ClipSystem: adapters that talk to macOS (clipboard, keyboard, thumbnails). It depends
        // on ClipCore because it implements ClipCore's "ports" (interfaces), like an Android
        // module providing implementations of interfaces declared in a domain module.
        .target(name: "ClipSystem", dependencies: ["ClipCore"], swiftSettings: strict),
        // Test targets: run with `swift test`. Each can only see the module it depends on.
        .testTarget(name: "ClipCoreTests", dependencies: ["ClipCore"], swiftSettings: strict),
        .testTarget(name: "ClipSystemTests", dependencies: ["ClipSystem"], swiftSettings: strict),
    ]
)
