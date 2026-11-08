// The Settings window: three tabs, General, Privacy and Data, like Paste's. SwiftUI's
// `Settings` scene (in YankApp) gives us the window itself, the ⌘, shortcut and the standard
// toolbar-tab look; this file only says what goes in it. Every control writes straight to
// UserDefaults through `@AppStorage`, so there is no save button and nothing to sync by hand:
// the value is on disk the moment the control changes, and the code that acts on it reads it
// from there. ≈ a settings screen whose every input is bound to AsyncStorage.
//
// `@AppStorage("key") var x = default` is a property wrapper, like `@State`, that reads the
// key from UserDefaults, uses the default when it is missing, and writes back on every change.
// ServiceManagement is the framework behind "open at login"; KeyboardShortcuts (a package)
// draws the box that records the panel shortcut.
import ClipCore
import KeyboardShortcuts
import ServiceManagement
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
    // "Open at login" is not a setting we keep: macOS keeps it, in System Settings › General
    // › Login Items, and the user can change it there too. So the truth is
    // `SMAppService.mainApp.status`, read when the tab appears and after each toggle, and
    // this `@State` is only a copy for the Toggle to bind to.
    @State private var opensAtLogin = false
    @State private var loginItemError: String?

    var body: some View {
        // `Form` with the `.grouped` style is the standard look of a Mac settings tab: rows
        // with a label on the left and the control on the right, in rounded groups.
        Form {
            Section {
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, wanted in setOpensAtLogin(wanted) }
                if let loginItemError {
                    Text(loginItemError).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                // A Picker shows as a pop-up menu in a Form. Each option's `.tag` is the value
                // written to the setting when it is chosen.
                Picker("Paste items", selection: $pasteDestination) {
                    Text("Into the app you were using").tag(PasteDestination.activeApp.rawValue)
                    Text("Onto the clipboard only").tag(PasteDestination.clipboardOnly.rawValue)
                }
                Toggle("Always paste as plain text", isOn: $alwaysPlainText)
            }
            Section {
                // The package's recorder box: click it, press a key combination, and the new
                // shortcut is saved and registered at once; the panel reacts to the new key
                // without a restart because it listens by name, not by key.
                KeyboardShortcuts.Recorder("Show panel", name: .togglePanel)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: readLoginItemStatus)
    }

    /// Copies macOS's answer into the Toggle. `.enabled` is on; `.requiresApproval` means the
    /// user has to allow it in System Settings, so the Toggle shows off with an explanation.
    private func readLoginItemStatus() {
        let status = SMAppService.mainApp.status
        opensAtLogin = status == .enabled
        loginItemError =
            status == .requiresApproval ? "Allow Yank in System Settings › General › Login Items." : nil
    }

    /// Registers or unregisters the app as a login item, then re-reads what macOS says so the
    /// Toggle never shows a state that was refused.
    private func setOpensAtLogin(_ wanted: Bool) {
        guard wanted != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.ui.error("login item change failed: \(error, privacy: .public)")
            loginItemError = error.localizedDescription
        }
        readLoginItemStatus()
    }
}

/// Which apps are never saved from, and whether the panel shows up in screen recordings.
private struct PrivacySettings: View {
    @AppStorage(SettingsKey.showPanelInScreenSharing) private var showPanelInScreenSharing = false

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

    var body: some View {
        Form {
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
