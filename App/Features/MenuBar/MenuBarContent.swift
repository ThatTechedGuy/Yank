// The rows of the menu under Yank's menu bar icon.
import ClipCore
import KeyboardShortcuts
import SwiftUI

struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        // `Text`, not a `Button`: a button with no action would look clickable and do nothing.
        if let error = model.startupError {
            Text(error)
        } else {
            Text("^[\(model.itemCount) items](inflect: true) saved")
        }
        // macOS (15.4+) can ask before every clipboard read, or refuse it. The model re-reads that
        // state on every poll, so these rows follow System Settings.
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
        // The key itself is handled globally; this only shows the user's recorded shortcut.
        Button("Open Panel") { model.togglePanel() }
            .keyboardShortcut(KeyboardShortcuts.getShortcut(for: .togglePanel)?.toSwiftUI)
        Button("New Text Item") { model.edit(nil) }
            .keyboardShortcut("n")
        pauseRows
        Divider()
        stackRows
        Divider()
        #if DEBUG
            DeveloperMenuItems(model: model)
            Divider()
        #endif
        // Not `SettingsLink`: it opens the window without activating Yank, so the window sits
        // behind the current app and draws inactive (grey switches and tabs instead of blue).
        Button("Settings…") { model.openSettings() }
            .keyboardShortcut(",")
        #if !DEBUG
            Button("Check for Updates…") { model.updater.checkForUpdates(nil) }
        #endif
        // The only Quit: Yank has no Dock icon and no app menu.
        Button("Quit Yank") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// The paste stack's on/off switch and, while it is on, what is waiting, oldest first. The rows
    /// are labels: an item only leaves by being pasted (⌃⌥⌘V) or by turning the stack off.
    @ViewBuilder private var stackRows: some View {
        Button(model.stack.isOn ? "Turn Paste Stack Off" : "Turn Paste Stack On") { model.toggleStack() }
            .keyboardShortcut(KeyboardShortcuts.getShortcut(for: .toggleStack)?.toSwiftUI)
        if model.stack.isOn {
            let queue = model.stack.queue
            if queue.isEmpty {
                Text("Nothing waiting. Copy something to add it.")
            } else {
                let key = KeyboardShortcuts.getShortcut(for: .pasteNext)?.description ?? "the paste-next key"
                Text("^[\(queue.count) items](inflect: true) waiting; \(key) pastes the next")
                // Keyed by position, not item id: copying the same thing twice queues the same
                // item twice, and SwiftUI needs each row's key to be unique.
                ForEach(Array(queue.enumerated()), id: \.offset) { _, item in
                    Text(item.title ?? item.cardText)
                }
            }
        }
    }

    /// While running: a Pause submenu with the three lengths. While paused: a line saying until
    /// when, and Resume.
    @ViewBuilder private var pauseRows: some View {
        if model.isPaused {
            switch model.pause {
            case .pausedUntil(let end):
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
