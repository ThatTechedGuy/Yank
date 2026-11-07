import Foundation

// The one function behind every paste from the panel: Return, ⇧Return, a double-click and
// ⌘1–⌘9 all end up here. It puts the item back on the clipboard and, when allowed, presses ⌘V
// in the app the user was working in. The panel never took focus away from that app (see
// PanelWindow), so nothing has to switch back first.
//
// In order: load the item's clipboard types from the Store; keep only the plain text if asked;
// add our own marker type so the capture loop knows this copy is ours and saves nothing; write
// it all to the clipboard; move the item to the top of the history; hide the panel and wait
// until it has really given up the keyboard; then press ⌘V, but only when the destination is
// the active app and macOS lets us (the Accessibility permission). Without the permission the
// item is simply left on the clipboard and the user presses ⌘V themselves.
//
// `@MainActor` because the clipboard, the key presser and the panel all live on the main
// thread; the Store calls are `async` and do their work elsewhere, so nothing here blocks.
/// Pastes a saved item into the app in front, or just onto the clipboard.
@MainActor public final class PasteService {
    private let store: Store
    private let clipboard: any Clipboard
    private let keyPresser: any KeyPressing
    private let accessibility: any AccessibilityStatus
    private let ownMarker: String

    /// Hides the panel and returns once it has given up the keyboard. The app sets this to the
    /// panel window's `hide()`; a paste without it (tests) leaves the panel alone. The wait
    /// matters: if ⌘V were pressed while the panel still had the keyboard, the keystroke would
    /// land in our own search box instead of the other app.
    public var hidePanel: @MainActor () async -> Void = {}

    // The marker defaults to the one PrivacyRules looks for, so the two can't drift apart.
    public init(
        store: Store, clipboard: any Clipboard, keyPresser: any KeyPressing,
        accessibility: any AccessibilityStatus, ownMarker: String = PrivacyRules().ownMarker
    ) {
        self.store = store
        self.clipboard = clipboard
        self.keyPresser = keyPresser
        self.accessibility = accessibility
        self.ownMarker = ownMarker
    }

    /// Whether macOS lets Yank press ⌘V. The panel shows a hint when it doesn't.
    public var isAccessibilityTrusted: Bool { accessibility.isTrusted }

    /// Shows macOS's own dialog for granting the Accessibility permission.
    public func requestAccessibility() { accessibility.requestAccess() }

    /// Pastes `item`. `plainText` keeps only its plain-text type (for ⇧Return and the "always
    /// plain text" setting); an item with no plain text at all, such as a bare image, is pasted
    /// whole rather than as nothing. `destination` says whether to press ⌘V at all.
    public func paste(_ item: ClipboardItem, plainText: Bool, destination: PasteDestination)
        async throws
    {
        var data = try await store.data(for: item.id)
        if plainText {
            let textOnly = data.filter { $0.type == ClipboardType.plainText }
            if !textOnly.isEmpty { data = textOnly }
        }
        // The marker rides on the first pasteboard item as an empty extra type, the same way
        // password managers mark a copy as concealed. The capture loop sees it on the next poll
        // and knows there is nothing to save: the item is already at the top (see below).
        data.append(
            ClipboardItemData(
                pasteboardItemIndex: data.first?.pasteboardItemIndex ?? 0, type: ownMarker,
                data: Data()))
        clipboard.write(data)
        try await store.moveToTop(id: item.id)
        await hidePanel()
        guard destination == .activeApp else {
            Log.paste.info("item \(item.id, privacy: .public) put on the clipboard")
            return
        }
        guard accessibility.isTrusted else {
            Log.paste.notice("Accessibility is off: item \(item.id, privacy: .public) left on the clipboard")
            return
        }
        try keyPresser.pressPaste()
        Log.paste.info(
            "pasted item \(item.id, privacy: .public)\(plainText ? " as plain text" : "", privacy: .public)")
    }
}

/// Where a paste from the panel goes: the user's "Paste items" setting. Its raw values are what
/// the app stores in UserDefaults, so the setting can be read, written and even set from the
/// command line (`-pasteDestination clipboardOnly`) by these names.
public enum PasteDestination: String, Sendable {
    /// Put the item on the clipboard and press ⌘V in the app in front.
    case activeApp
    /// Only put the item on the clipboard; the user pastes it themselves.
    case clipboardOnly
}
