// The Settings window's tabs: General, Labels, Privacy and Data. Every control writes straight to
// UserDefaults through `@AppStorage`, so there is no save button; the code that acts on a setting
// reads it from there.
import ClipCore
import ClipSystem
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            LabelSettings()
                .tabItem { Label("Labels", systemImage: "tag") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            DataSettings()
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        // A fixed width, so the tabs do not jump when switching; the height follows each tab.
        .frame(width: 460)
    }
}

/// Open at login, how pasting works, and the shortcuts.
private struct GeneralSettings: View {
    // The destination is stored as the enum's raw string, so the picker's tags are the same values
    // the paste code decodes.
    @AppStorage(SettingsKey.pasteDestination) private var pasteDestination = PasteDestination.activeApp
        .rawValue
    @AppStorage(SettingsKey.alwaysPlainText) private var alwaysPlainText = false

    var body: some View {
        Form {
            Section {
                OpenAtLoginToggle()
            }
            Section {
                Picker("Paste items", selection: $pasteDestination) {
                    Text("Into the app you were using").tag(PasteDestination.activeApp.rawValue)
                    Text("Onto the clipboard only").tag(PasteDestination.clipboardOnly.rawValue)
                }
                Toggle("Always paste as plain text", isOn: $alwaysPlainText)
                    .accessibilityIdentifier("always-plain-text")
            }
            Section {
                // A newly recorded key works without a restart: the app listens by name, not key.
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

/// The labelling switch and the category list the model picks from.
private struct LabelSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.labels) private var labels = true

    var body: some View {
        Form {
            Section {
                Toggle("Label copies", isOn: $labels)
                    .accessibilityIdentifier("labels")
            } footer: {
                // Read when the tab draws; turning Apple Intelligence on shows here on the next visit.
                if let reason = Labeller.unavailableReason {
                    Text("Labelling is not running. \(reason)")
                } else {
                    Text(
                        "On, Apple's on-device model gives each copy a category, a language and a short "
                            + "title. Nothing leaves your Mac. Off, nothing is sent to the model; labels "
                            + "already given stay.")
                }
            }
            Section {
                // Arrow buttons, not `.onMove`, which does nothing in a grouped Form.
                ForEach(model.categories) { category in
                    CategoryRow(category: category, move: { move(category, by: $0) })
                }
                Button("Add Category") {
                    let name = Self.freeName(among: model.categories)
                    model.changeCategories { _ = try await $0.createCategory(named: name, about: "") }
                }
                .accessibilityIdentifier("add-category")
            } header: {
                Text("Categories")
            } footer: {
                Text(
                    "The model picks one of these for each copy, by its description; a new category is "
                        + "used once it has one. Removing a category moves its items to Other. After a "
                        + "change, items whose category you did not set by hand are labelled again.")
            }
        }
        .formStyle(.grouped)
        // Tall enough for the starting list, which the window would otherwise cut in half.
        .frame(minHeight: 760)
    }

    /// Swaps a category with the one above (-1) or below (1) it.
    private func move(_ category: ItemCategory, by step: Int) {
        var ids = model.categories.map(\.id)
        guard let index = ids.firstIndex(of: category.id), ids.indices.contains(index + step) else { return }
        ids.swapAt(index, index + step)
        let order = ids
        model.changeCategories { try await $0.reorderCategories(ids: order) }
    }

    /// "New Category", or "New Category 2" and so on when that is taken.
    private static func freeName(among categories: [ItemCategory]) -> String {
        let names = Set(categories.map(\.name))
        return (1...).lazy.map { $0 == 1 ? "New Category" : "New Category \($0)" }.first {
            !names.contains($0)
        }!
    }
}

/// One category: its name and description, saved when the field is left or Return is pressed,
/// so typing a name does not label the history again on every key.
private struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: ItemCategory
    /// Moves the row up (-1) or down (1).
    let move: (Int) -> Void

    @State private var name: String
    @State private var about: String
    @FocusState private var focused: Bool

    init(category: ItemCategory, move: @escaping (Int) -> Void) {
        self.category = category
        self.move = move
        _name = State(initialValue: category.name)
        _about = State(initialValue: category.about)
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("category-name-\(category.id)")
                TextField("What belongs here, in one line", text: $about)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("category-about-\(category.id)")
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            let isFirst = model.categories.first?.id == category.id
            let isLast = model.categories.last?.id == category.id
            Group {
                Button("Move Up", systemImage: "chevron.up") { move(-1) }.disabled(isFirst)
                Button("Move Down", systemImage: "chevron.down") { move(1) }.disabled(isLast)
                Button("Remove", systemImage: "minus.circle") {
                    let id = category.id
                    model.changeCategories { try await $0.deleteCategory(id: id) }
                }
                .disabled(category.isBuiltIn)
                .help(category.isBuiltIn ? "\(category.name) is built in and cannot be removed" : "Remove")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .onChange(of: category) { _, saved in
            name = saved.name
            about = saved.about
        }
    }

    private func save() {
        guard name != category.name || about != category.about else { return }
        let (id, name, about) = (category.id, name, about)
        // The Store refuses a blank name or another category's, and saves nothing that would
        // tell this row, so the field puts the saved name back itself.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = model.categories.contains {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
        if trimmed.isEmpty || taken { self.name = category.name }
        model.changeCategories { try await $0.updateCategory(id: id, name: name, about: about) }
    }
}

/// Which apps are never saved from, whether the panel shows up in screen recordings, and Yank's
/// two uses of the network: link previews and update checks.
private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.showPanelInScreenSharing) private var showPanelInScreenSharing = false
    @AppStorage(SettingsKey.linkPreviews) private var linkPreviews = true
    /// A copy of Sparkle's setting, which SwiftUI cannot observe. Sparkle keeps the truth.
    @State private var checksForUpdates = false

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
                // Fetching a one-time link (a sign-in link, an unsubscribe link) uses it up, so the
                // user is told what the switch does.
                Text(
                    "On, a copied link's page is fetched for its title and icon. Turn off if you copy "
                        + "sign-in or one-time links, which fetching can use up. Links to this Mac and "
                        + "your local network are never fetched.")
            }
            Section {
                Toggle("Check for updates automatically", isOn: $checksForUpdates)
                    .accessibilityIdentifier("check-for-updates")
                    .onAppear { checksForUpdates = model.updater.updater.automaticallyChecksForUpdates }
                    .onChange(of: checksForUpdates) { _, on in
                        // Skips the write from `onAppear`: an explicit "off" before the user ever
                        // chose would stop Sparkle from asking on the second launch.
                        guard on != model.updater.updater.automaticallyChecksForUpdates else { return }
                        model.updater.updater.automaticallyChecksForUpdates = on
                    }
            } footer: {
                Text(
                    "On, Yank asks GitHub once a day whether there is a new version, and offers to "
                        + "install it. It sends Yank's version number, never anything you copied.")
            }
        }
        .formStyle(.grouped)
    }
}

/// How long history is kept, and the "Erase History…" button behind a confirmation.
private struct DataSettings: View {
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
        .confirmationDialog(
            "Erase all unpinned items?", isPresented: $confirmsErase, titleVisibility: .visible
        ) {
            Button("Erase History", role: .destructive) { model.eraseHistory() }
        } message: {
            Text("Pinned items stay. This cannot be undone.")
        }
    }
}
