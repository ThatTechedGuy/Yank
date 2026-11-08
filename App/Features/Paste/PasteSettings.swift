// The two settings that change what a paste does, read from UserDefaults (see SettingsKey for
// the keys and what UserDefaults is). The Settings window's General tab writes the same keys
// with `@AppStorage`; this is the read side the paste code uses.
import ClipCore
import Foundation

/// The user's paste preferences.
enum PasteSettings {
    /// "Paste items: to active app / to clipboard only". Active app unless set otherwise.
    static var destination: PasteDestination {
        UserDefaults.standard.string(forKey: SettingsKey.pasteDestination).flatMap(PasteDestination.init)
            ?? .activeApp
    }

    /// "Always paste as plain text". Off unless set; `bool(forKey:)` returns false for a missing key.
    static var alwaysPlainText: Bool { UserDefaults.standard.bool(forKey: SettingsKey.alwaysPlainText) }
}
