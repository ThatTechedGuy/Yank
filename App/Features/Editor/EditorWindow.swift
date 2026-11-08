// The editor's window: an ordinary macOS document-style window (title bar, close button,
// resizable) with the SwiftUI editor inside it. It is AppKit rather than a SwiftUI
// `WindowGroup` because the Edit action comes from the panel and the menu bar, which live
// outside any SwiftUI scene, and SwiftUI's `openWindow` can only be called from inside a
// view. The panel's window is built the same way, so the pattern is already in the app.
//
// Each Edit opens a fresh window; closing it is Cancel. AppKit keeps a window alive while it
// is on screen, so nothing here has to hold on to it.
import AppKit
import SwiftUI

final class EditorWindow: NSWindow {
    init(editor: ItemEditor) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        title = editor.original == nil ? "New Text Item" : "Edit"
        // Swift already frees the window when nothing refers to it; AppKit freeing it again on
        // close would be one time too many. `false` here is the rule for every window made in
        // code under Swift.
        isReleasedWhenClosed = false
        contentView = NSHostingView(
            rootView: EditorView(editor: editor, close: { [weak self] in self?.close() }))
        setAccessibilityIdentifier("editor")
        center()
    }

    /// Puts the window on screen, in front, with the keyboard, and makes Yank the active app:
    /// as a menu bar app it never is otherwise, and an inactive app's window would open
    /// behind whatever the user was working in.
    func open() {
        makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}
