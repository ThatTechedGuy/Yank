// What the welcome window shows: a short hello, then the three things worth setting up before
// the first copy. The panel shortcut (changeable here), the Accessibility permission (with a
// button and a status line that turns to "Allowed" while the window is open) and the "Open at
// login" switch. Get Started closes the window. ≈ an onboarding screen in a mobile app, but
// one page and no carousel.
//
// The window around it is a SwiftUI `Window` scene in YankApp, which also decides that it
// opens by itself on the first launch only. This view marks it as shown the moment it
// appears, so quitting without pressing Get Started still counts as having seen it.
import KeyboardShortcuts
import SwiftUI

struct WelcomeView: View {
    /// The app's model, for the permission check and its dialog; YankApp puts it in the
    /// environment, the way a React context provider would.
    @Environment(AppModel.self) private var model
    /// SwiftUI's action that closes the window this view is in. ≈ `navigation.goBack()`.
    @Environment(\.dismiss) private var dismiss
    /// A copy of `model.isAccessibilityTrusted`, refreshed once a second, for the view to draw.
    @State private var isTrusted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                // The app's own icon, as Finder shows it. `applicationIconImage` is AppKit's
                // ready-made copy of it, so no image file is needed here.
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
            // The same grouped rows as the Settings window, so the controls look and behave
            // the same in both places.
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
                // Return presses it (`.defaultAction`), and it is drawn as the blue button.
                Button("Get Started") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("get-started")
            }
        }
        .padding(20)
        .frame(width: 460)
        // Esc closes the window too, as in any Mac dialog.
        .onExitCommand { dismiss() }
        .onAppear {
            // Shown once: from now on later launches leave the window closed.
            UserDefaults.standard.set(true, forKey: SettingsKey.hasShownWelcome)
            // A menu bar app is not always the active app when its window opens, which would
            // leave the window behind whatever the user was doing; this brings it forward.
            NSApplication.shared.activate()
        }
        // Re-checks the permission once a second for as long as the window is open, because
        // macOS sends no notice when the user switches Yank on in System Settings. `.task`
        // starts with the view and is cancelled when the window closes, like a `useEffect`
        // with a `setInterval` and its cleanup. Asking costs next to nothing.
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
