// The editor's window. AppKit rather than a SwiftUI scene, like the panel's: the panel's Edit is
// fired outside any SwiftUI scene, and `openWindow` can only be called from inside a view. Each
// Edit opens a fresh window; AppKit keeps it alive while on screen, so nothing holds it.
import AppKit
import SwiftUI

final class EditorWindow: NSWindow {
    init(editor: ItemEditor) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        title = editor.original == nil ? "New Text Item" : "Edit"
        // Under ARC the window is freed when nothing refers to it; AppKit releasing it again on
        // close would be one release too many.
        isReleasedWhenClosed = false
        contentView = NSHostingView(
            rootView: EditorView(editor: editor, close: { [weak self] in self?.close() }))
        setAccessibilityIdentifier("editor")
        center()
    }

    /// Puts the window in front with the keyboard and makes Yank the active app: an inactive app's
    /// window would open behind whatever the user was working in.
    func open() {
        makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}
