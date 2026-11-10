import ClipCore
import Foundation

/// The user's paste preferences, read from the keys Settings writes with `@AppStorage`.
enum PasteSettings {
    /// "Paste items". The active app unless set otherwise.
    static var destination: PasteDestination {
        UserDefaults.standard.string(forKey: SettingsKey.pasteDestination).flatMap(PasteDestination.init)
            ?? .activeApp
    }

    /// "Always paste as plain text". Off unless set.
    static var alwaysPlainText: Bool { UserDefaults.standard.bool(forKey: SettingsKey.alwaysPlainText) }
}
