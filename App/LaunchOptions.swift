// Debug-only command-line flags, for trying the app and for the UI tests: a fake history of any
// size and the panel already open, without touching the real one. Release builds read none.
//     build/Build/Products/Debug/Yank.app/Contents/MacOS/Yank --seed 10000 --show-panel
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
            if let i = arguments.firstIndex(of: "--seed"), i + 1 < arguments.count {
                seedCount = Int(arguments[i + 1])
            }
            showPanel = arguments.contains("--show-panel")
        #endif
    }
}
