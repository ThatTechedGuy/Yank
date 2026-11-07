// The two settings that change what a paste does, read from UserDefaults: the Mac's key-value
// store for app preferences (≈ AsyncStorage or SharedPreferences). This file is the one place
// that knows their keys and defaults; the Settings window will later edit the same keys with
// SwiftUI's `@AppStorage`, which is a view wrapper over the same store.
//
// Until there is a Settings window, both can be set for one run from the command line, because
// macOS lets any launch argument of the form `-key value` override a default for that process:
//     Yank.app/Contents/MacOS/Yank -pasteDestination clipboardOnly -alwaysPlainText YES
import ClipCore
import Foundation

/// The user's paste preferences.
enum PasteSettings {
    static let destinationKey = "pasteDestination"
    static let alwaysPlainTextKey = "alwaysPlainText"

    /// "Paste items: to active app / to clipboard only". Active app unless set otherwise.
    static var destination: PasteDestination {
        UserDefaults.standard.string(forKey: destinationKey).flatMap(PasteDestination.init) ?? .activeApp
    }

    /// "Always paste as plain text". Off unless set; `bool(forKey:)` returns false for a missing key.
    static var alwaysPlainText: Bool { UserDefaults.standard.bool(forKey: alwaysPlainTextKey) }
}
