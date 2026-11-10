// The list of ignored apps in Settings › Privacy. It is kept as bundle ids (`IgnoredApps`), because
// that is what the capture code compares against; the name and icon are looked up on each draw, so
// a renamed or moved app still shows correctly and a deleted one shows its id.
import SwiftUI
import UniformTypeIdentifiers

struct IgnoredAppsList: View {
    @AppStorage(SettingsKey.ignoredApps) private var ignored = IgnoredApps()
    /// The bundle id of the selected row, which the − button removes.
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            List(ignored.bundleIds, id: \.self, selection: $selection) { bundleId in
                IgnoredAppRow(bundleId: bundleId)
            }
            .frame(minHeight: 120)
            // The section header above says "Ignored apps", but VoiceOver does not tie the
            // list to it, so the list gets the same name itself.
            .accessibilityLabel("Ignored apps")
            .accessibilityIdentifier("ignored-apps")
            .overlay {
                if ignored.bundleIds.isEmpty {
                    Text("No ignored apps").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 0) {
                Button(action: addApp) { Image(systemName: "plus") }
                    .help("Add an app to ignore")
                    .accessibilityLabel("Add app")
                Divider().frame(height: 16)
                Button(action: removeSelected) { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Stop ignoring the selected app")
                    .accessibilityLabel("Remove app")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
    }

    /// Asks the user to pick an app, then adds its bundle id. An app without one, or one already in
    /// the list, is quietly skipped.
    ///
    /// The dialog is a sheet on the Settings window, with a completion callback, not `runModal()`:
    /// Yank is usually not the active app, and a modal Open dialog shown from an inactive app
    /// closes itself after a few seconds, taking the Settings window with it.
    private func addApp() {
        let dialog = NSOpenPanel()
        dialog.message = "Choose an app whose copies Yank should never save."
        dialog.allowedContentTypes = [.application]
        dialog.directoryURL = URL(filePath: "/Applications")
        dialog.canChooseDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = dialog.url,
                let bundleId = Bundle(url: url)?.bundleIdentifier,
                !ignored.bundleIds.contains(bundleId)
            else { return }
            ignored.bundleIds.append(bundleId)
            selection = bundleId
        }
        if let window = NSApp.keyWindow {
            dialog.beginSheetModal(for: window, completionHandler: finish)
        } else {
            dialog.begin(completionHandler: finish)
        }
    }

    private func removeSelected() {
        guard let selection else { return }
        ignored.bundleIds.removeAll { $0 == selection }
        self.selection = nil
    }
}

/// One row: the app's icon and name if it is installed, else its bundle id.
private struct IgnoredAppRow: View {
    let bundleId: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Label {
                Text(FileManager.default.displayName(atPath: url.path))
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
            }
        } else {
            Text(bundleId)
        }
    }
}
