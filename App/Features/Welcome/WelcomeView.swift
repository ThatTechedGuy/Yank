// What the welcome window shows: the three things worth setting up before the first copy (the panel
// shortcut, the Accessibility permission and "Open at login"). The `Window` scene in YankApp
// decides that it opens by itself on the first launch only.
import KeyboardShortcuts
import SwiftUI

struct WelcomeView: View {
    /// For the permission check and its dialog.
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// A copy of `model.isAccessibilityTrusted`, refreshed once a second, for the view to draw.
    @State private var isTrusted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Yank")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "Yank keeps everything you copy. Press your shortcut in any app, pick a card, "
                            + "and press Return to paste it."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The same grouped rows as the Settings window, so the controls look the same.
            Form {
                Section {
                    KeyboardShortcuts.Recorder("Show panel", name: .togglePanel)
                    accessibilityRow
                    OpenAtLoginToggle()
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Get Started") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("get-started")
            }
        }
        .padding(20)
        .frame(width: 460)
        .onExitCommand { dismiss() }
        .onAppear {
            // Marked on appear, not on Get Started, so quitting without pressing it still counts as
            // having seen the window.
            UserDefaults.standard.set(true, forKey: SettingsKey.hasShownWelcome)
            // A menu bar app is not always active when its window opens, which would leave the
            // window behind whatever the user was doing.
            NSApplication.shared.activate()
        }
        // Polled once a second while the window is open, because macOS sends no notice when the
        // user switches Yank on in System Settings. Asking costs next to nothing.
        .task {
            while !Task.isCancelled {
                isTrusted = model.isAccessibilityTrusted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// "Paste for you": what the permission is for, whether it is on, and a button that shows
    /// macOS's dialog while it is not.
    private var accessibilityRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                // A coloured dot is never the only sign: the words next to it say the same.
                Label {
                    Text(isTrusted ? "Allowed" : "Not allowed yet")
                } icon: {
                    Image(systemName: isTrusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(isTrusted ? .green : .orange)
                }
                .accessibilityIdentifier("accessibility-status")
                if !isTrusted {
                    Button("Allow…") { model.requestAccessibility() }
                        .accessibilityIdentifier("allow-accessibility")
                }
            }
        } label: {
            Text("Paste for you")
            Text(
                "Lets Yank press ⌘V in the app you were using. Without it, Yank puts the item on the "
                    + "clipboard and you press ⌘V yourself.")
        }
    }
}
