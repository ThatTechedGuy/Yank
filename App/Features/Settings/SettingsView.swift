// The Settings window: three tabs, General, Privacy and Data, like Paste's. SwiftUI's
// `Settings` scene (in YankApp) gives us the window itself, the ⌘, shortcut and the standard
// toolbar-tab look; this file only says what goes in it. Every control writes straight to
// UserDefaults through `@AppStorage`, so there is no save button and nothing to sync by hand:
// the value is on disk the moment the control changes, and the code that acts on it reads it
// from there. ≈ a settings screen whose every input is bound to AsyncStorage.
//
// `@AppStorage("key") var x = default` is a property wrapper, like `@State`, that reads the
// key from UserDefaults, uses the default when it is missing, and writes back on every change.
// KeyboardShortcuts (a package) draws the box that records the panel shortcut.
import ClipCore
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        // A TabView inside the Settings scene draws the tabs as toolbar buttons with icons, the
        // way System Settings and every Mac app do it. The `.tabItem` label is each tab's name
        // and SF Symbol.
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            DataSettings()
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        // `.frame` fixes the width so the tabs do not jump when switching; the height follows
        // the content of each tab.
        .frame(width: 460)
    }
}

/// Open at login, how pasting works, and the panel shortcut.
private struct GeneralSettings: View {
    // The two paste settings, by the keys `PasteSettings` reads. The destination is stored as
    // the enum's raw string, so the picker's tags are the same values the paste code decodes.
    @AppStorage(SettingsKey.pasteDestination) private var pasteDestination = PasteDestination.activeApp
        .rawValue
    @AppStorage(SettingsKey.alwaysPlainText) private var alwaysPlainText = false

    var body: some View {
        // `Form` with the `.grouped` style is the standard look of a Mac settings tab: rows
        // with a label on the left and the control on the right, in rounded groups.
        Form {
            Section {
                // Shared with the welcome window; macOS, not Yank, keeps the setting.
                OpenAtLoginToggle()
            }
            Section {
                // A Picker shows as a pop-up menu in a Form. Each option's `.tag` is the value
                // written to the setting when it is chosen.
                Picker("Paste items", selection: $pasteDestination) {
                    Text("Into the app you were using").tag(PasteDestination.activeApp.rawValue)
                    Text("Onto the clipboard only").tag(PasteDestination.clipboardOnly.rawValue)
                }
                Toggle("Always paste as plain text", isOn: $alwaysPlainText)
                    .accessibilityIdentifier("always-plain-text")
            }
            Section {
                // The package's recorder box: click it, press a key combination, and the new
                // shortcut is saved and registered at once; the panel reacts to the new key
                // without a restart because it listens by name, not by key.
                KeyboardShortcuts.Recorder("Show panel", name: .togglePanel)
                KeyboardShortcuts.Recorder("Paste next from the stack", name: .pasteNext)
                KeyboardShortcuts.Recorder("Turn the paste stack on or off", name: .toggleStack)
            } footer: {
                Text(
                    "The paste stack queues everything you copy while it is on, and pastes it back one "
                        + "item per press, in order. Turn it on from the menu bar.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Which apps are never saved from, whether the panel shows up in screen recordings, and
/// whether copied links are fetched for their title and icon.
private struct PrivacySettings: View {
    @AppStorage(SettingsKey.showPanelInScreenSharing) private var showPanelInScreenSharing = false
    @AppStorage(SettingsKey.linkPreviews) private var linkPreviews = true

    var body: some View {
        Form {
            Section {
                IgnoredAppsList()
            } header: {
                Text("Ignored apps")
            } footer: {
                Text(
                    "Nothing copied in these apps is saved. Password managers and apps that mark "
                        + "their copies as private are already skipped.")
            }
            Section {
                Toggle("Show the panel in screen recordings and sharing", isOn: $showPanelInScreenSharing)
            } footer: {
                Text("Off hides the panel from recordings and shared screens, so your history stays private.")
            }
            Section {
                Toggle("Link previews", isOn: $linkPreviews)
                    .accessibilityIdentifier("link-previews")
            } footer: {
                // Fetching a page is the one time Yank goes on the network, and opening a
                // one-time link (a sign-in link, an unsubscribe link) uses it up, so the user
                // is told what the switch does.
                Text(
                    "On, a copied link's page is fetched for its title and icon. Turn off if you copy "
                        + "sign-in or one-time links, which fetching can use up. Links to this Mac and "
                        + "your local network are never fetched.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The "Erase History…" button, behind a confirmation.
private struct DataSettings: View {
    // The model does the erasing, because it owns the store and the count the menu shows.
    // `@Environment(AppModel.self)` reads the object YankApp put in the environment, the way
    // a React component reads a context.
    @Environment(AppModel.self) private var model
    @State private var confirmsErase = false
    @AppStorage(SettingsKey.keepHistoryDays) private var keepHistoryDays = 0

    var body: some View {
        Form {
            Section {
                Picker("Keep history", selection: $keepHistoryDays) {
                    Text("Forever").tag(0)
                    Text("1 year").tag(365)
                    Text("90 days").tag(90)
                    Text("30 days").tag(30)
                }
                .accessibilityIdentifier("keep-history")
            } footer: {
                Text(
                    "Items older than this are deleted for good, unless they are on a pinboard. "
                        + "Yank checks when it starts and once an hour.")
            }
            Section {
                LabeledContent("History") {
                    Text("^[\(model.itemCount) items](inflect: true) saved")
                }
                Button("Erase History…", role: .destructive) { confirmsErase = true }
                    .accessibilityIdentifier("erase-history")
            } footer: {
                Text("Removes every item that is not on a pinboard, and the files that went with them.")
            }
        }
        .formStyle(.grouped)
        // The standard "are you sure?" sheet. The destructive button is red; Cancel is added
        // for us and does nothing, so cancelling keeps everything.
        .confirmationDialog(
            "Erase all unpinned items?", isPresented: $confirmsErase, titleVisibility: .visible
        ) {
            Button("Erase History", role: .destructive) { model.eraseHistory() }
        } message: {
            Text("Pinned items stay. This cannot be undone.")
        }
    }
}
