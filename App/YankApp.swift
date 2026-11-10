// The app's entry point: it creates the one AppModel and declares the menu bar item and the
// windows. project.yml sets SWIFT_DEFAULT_ACTOR_ISOLATION to MainActor for this target, so
// everything in App/ runs on the main actor unless it says otherwise.
import ClipCore
import SwiftUI

@main
struct YankApp: App {
    @State private var model = AppModel()

    init() {
        Log.ui.info("Yank launched")
    }

    var body: some Scene {
        // The only UI that is always on screen: Yank has no Dock icon (LSUIElement in project.yml).
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            let waiting = model.stack.queue.count
            Label {
                Text(waiting > 0 ? "\(waiting)" : "")
            } icon: {
                Image(systemName: model.isPaused ? "pause.circle" : "list.clipboard")
            }
            .labelStyle(.titleAndIcon)
            // VoiceOver gets the app's name and the two states the icon shows only by its look.
            .accessibilityLabel(
                "Yank" + (model.isPaused ? ", paused" : "")
                    + (waiting > 0 ? ", \(waiting) waiting in the paste stack" : ""))
        }
        Settings {
            SettingsView()
                .environment(model)
        }
        // The Format menu's Bold, Italic and Underline (⌘B ⌘I ⌘U) for the editor's rich text box.
        // Yank shows no menu bar of its own, but the keys still reach a hidden menu's commands
        // while one of Yank's windows has the keyboard.
        .commands { TextFormattingCommands() }
        // Opens by itself on the first launch and never again: `defaultLaunchBehavior` is read
        // once, at launch, from the key the window writes when it appears. Restoration is disabled
        // because macOS would otherwise reopen the window after a quit that left it open.
        Window("Welcome to Yank", id: "welcome") {
            WelcomeView()
                .environment(model)
        }
        .defaultLaunchBehavior(
            UserDefaults.standard.bool(forKey: SettingsKey.hasShownWelcome) ? .suppressed : .presented
        )
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
        #if DEBUG
            DeveloperWindow(model: model)
        #endif
    }
}
