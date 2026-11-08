// The rows of the menu under Yank's menu bar icon: the saved count, why nothing is saved if
// so, Open Panel, Pause, Settings and Quit. YankApp puts this view inside the MenuBarExtra;
// keeping the rows here keeps the app's entry point short. SwiftUI re-renders the rows when
// anything they read from the model changes, as the model is `@Observable`.
//
// ClipCore is our package: `PauseState` comes from it. KeyboardShortcuts is the package that
// keeps the user's panel shortcut.
import ClipCore
import KeyboardShortcuts
import SwiftUI

struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        // First row: the saved count, or the error if the database did not open. They are
        // `Text`, a plain label, because a `Button` with no action would look clickable and
        // do nothing. "1 item saved", "2 items saved": `^[...](inflect: true)` asks Foundation
        // to pick the singular or plural for the number in the sentence.
        if let error = model.startupError {
            Text(error)
        } else {
            Text("^[\(model.itemCount) items](inflect: true) saved")
        }
        // Rows that explain why nothing is being saved, with a button to fix it. macOS (15.4+)
        // can ask the user before every clipboard read, or refuse it; the model re-reads that
        // state on every poll, so these rows appear and disappear as the user changes it.
        // `switch` over an enum must cover every case; `.allowed` needs no row, so it shows an
        // EmptyView.
        switch model.clipboardAccess {
        case .allowed:
            EmptyView()
        case .askEachTime:
            Text("macOS asks before every copy.")
            Button("Allow Yank in System Settings…") { model.openClipboardSettings() }
        case .denied:
            Text("Clipboard access is off, so nothing is saved.")
            Button("Allow Yank in System Settings…") { model.openClipboardSettings() }
        }
        Divider()
        // The same thing the global shortcut does, for people who reach for the mouse. The
        // shortcut shown next to it is the one the user chose in Settings, read from the
        // package; the key itself is handled globally, so this row only has to show it.
        Button("Open Panel") { model.openPanel() }
            .keyboardShortcut(KeyboardShortcuts.getShortcut(for: .togglePanel)?.toSwiftUI)
        pauseRows
        Divider()
        // Debug builds only: "Developer…" opens the Developer window and "Open Data Folder"
        // shows the database in Finder. The compiler leaves both out of a release build.
        #if DEBUG
            DeveloperMenuItems(model: model)
            Divider()
        #endif
        // `SettingsLink` is SwiftUI's button that opens the `Settings` scene; a plain Button
        // could not, because only SwiftUI knows that window. ⌘, is the Mac-wide key for it.
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        // The only way to quit Yank: with no Dock icon and no app menu, there is no other Quit.
        // NSApplication is AppKit's object for the running app; terminate(nil) quits it.
        Button("Quit Yank") { NSApplication.shared.terminate(nil) }
            // Lets ⌘Q quit while the menu is open, as users expect from any Mac app.
            .keyboardShortcut("q")
    }

    /// While running: a Pause submenu with the three lengths. While paused: a line saying
    /// until when, and Resume. (`@ViewBuilder` lets a property return several views or an
    /// if/else of views, the same way `body` does.)
    @ViewBuilder private var pauseRows: some View {
        if model.isPaused {
            switch model.pause {
            case .pausedUntil(let end):
                // `Date.FormatStyle` with only the time: "Paused until 3:45 PM" in the user's
                // own clock format.
                Text("Paused until \(end.formatted(date: .omitted, time: .shortened))")
            default:
                Text("Paused")
            }
            Button("Resume Saving") { model.resume() }
        } else {
            Menu("Pause Saving") {
                Button("For 15 Minutes") { model.pause(for: .seconds(15 * 60)) }
                Button("For 1 Hour") { model.pause(for: .seconds(60 * 60)) }
                Button("Until Resumed") { model.pauseUntilResumed() }
            }
        }
    }
}
