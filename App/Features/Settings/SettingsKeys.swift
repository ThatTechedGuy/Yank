// The names of the settings the app keeps in UserDefaults, written out once. UserDefaults is
// the Mac's key-value store for an app's preferences (≈ AsyncStorage or SharedPreferences):
// the Settings window writes each key with SwiftUI's `@AppStorage`, and the code that acts on
// a setting reads the same key. Keeping the strings here means a typo shows up in one place.
//
// Each setting can also be set for one run from the command line, because macOS lets any
// launch argument of the form `-key value` override a default for that process:
//     Yank.app/Contents/MacOS/Yank -pasteDestination clipboardOnly -alwaysPlainText YES
import Foundation

enum SettingsKey {
    /// "Paste items": `activeApp` (put on the clipboard and press ⌘V in the app you were
    /// using) or `clipboardOnly`. Missing means `activeApp`.
    static let pasteDestination = "pasteDestination"
    /// "Always paste as plain text": a Bool, off when missing.
    static let alwaysPlainText = "alwaysPlainText"
    /// The ignored apps, as an `IgnoredApps` value (a JSON list of bundle ids).
    static let ignoredApps = "ignoredApps"
    /// "Show the panel in screen recordings and sharing": a Bool, off when missing, so the
    /// panel is hidden from recordings unless the user says otherwise.
    static let showPanelInScreenSharing = "showPanelInScreenSharing"
    /// "Link previews": a Bool, on when missing, so a copied link gets its page's title and icon
    /// unless the user turns that off. Read with `linkPreviewsEnabled`, not `bool(forKey:)`,
    /// which would read a missing key as off.
    nonisolated static let linkPreviews = "linkPreviews"
    /// Whether the welcome window has been shown: a Bool, missing until the first launch opens
    /// the window, then true for good. `-hasShownWelcome NO` on the command line makes one
    /// launch behave like the first one again, which is how the UI test checks the window.
    static let hasShownWelcome = "hasShownWelcome"

    /// Whether link previews are on right now, for code outside a SwiftUI view. `nonisolated`
    /// because the Enricher asks from a background task; UserDefaults is safe to read from any
    /// thread.
    nonisolated static var linkPreviewsEnabled: Bool {
        // `bool(forKey:)` also understands "NO" typed on the command line, which arrives as a
        // string that `as? Bool` would miss; only a missing key needs the "on" default.
        let defaults = UserDefaults.standard
        return defaults.object(forKey: linkPreviews) == nil || defaults.bool(forKey: linkPreviews)
    }
}

/// The apps whose copies are never saved, by bundle id, in the order the user added them.
///
/// Stored as one JSON string under `SettingsKey.ignoredApps`. `@AppStorage` can hold a value
/// whose `rawValue` is a String (`RawRepresentable`), and JSON is the natural way to put a list
/// in a string; `defaults read com.thattechedguy.Yank ignoredApps` shows it as is. A list, not a
/// set, so the Settings window shows the apps in a stable order; the privacy rules turn it
/// into a set for their lookups.
struct IgnoredApps: RawRepresentable, Equatable {
    var bundleIds: [String]

    init(bundleIds: [String] = []) {
        self.bundleIds = bundleIds
    }

    /// Reads the JSON list back. A string that is not a JSON list of strings (never written by
    /// this app, but a hand-edited defaults file could hold one) counts as an empty list rather
    /// than a crash; the next change overwrites it.
    init?(rawValue: String) {
        bundleIds = (try? JSONDecoder().decode([String].self, from: Data(rawValue.utf8))) ?? []
    }

    var rawValue: String {
        // Encoding an array of strings cannot fail, so the `try?` fallback never runs.
        String(decoding: (try? JSONEncoder().encode(bundleIds)) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// The list as it stands in UserDefaults right now, for code outside a SwiftUI view.
    static var current: IgnoredApps {
        UserDefaults.standard.string(forKey: SettingsKey.ignoredApps).flatMap(IgnoredApps.init)
            ?? IgnoredApps()
    }
}
