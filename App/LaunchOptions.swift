// Flags on the command line Yank was started with. They exist for trying the app and for the
// UI tests: a test can start Yank with a fake history of any size and the panel already open,
// without touching the real history. Nothing is read from the command line in a release build,
// so the app you use every day always opens its real database.
//
// Try it from Terminal (after a debug build):
//     build/Build/Products/Debug/Yank.app/Contents/MacOS/Yank --seed 10000 --show-panel
//
// ≈ `process.argv` flags, or Android `adb shell am start` extras.
import ClipCore
import Foundation

struct LaunchOptions {
    /// `--seed N`: wipe the fake-history database and fill it with N items. Debug builds only.
    private(set) var seedCount: Int?
    /// `--show-panel`: open the panel as soon as the app is ready. Debug builds only.
    private(set) var showPanel = false

    /// The database to open: the fake one when seeding, the real one otherwise.
    var storeFolder: URL {
        #if DEBUG
            if seedCount != nil { return Store.seedFolder }
        #endif
        return Store.defaultFolder
    }

    init(arguments: [String] = CommandLine.arguments) {
        #if DEBUG
            // `firstIndex` finds the flag; the number is the next word on the line.
            if let i = arguments.firstIndex(of: "--seed"), i + 1 < arguments.count {
                seedCount = Int(arguments[i + 1])
            }
            showPanel = arguments.contains("--show-panel")
        #endif
    }
}
