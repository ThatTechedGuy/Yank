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

    /// Opens System Settings at Accessibility, where the user grants the permission.
    public func requestAccessibility() { accessibility.requestAccess() }

    /// Pastes `item`. `plainText` keeps only its plain-text type (for ⇧Return and the "always
    /// plain text" setting); an item with no plain text at all, such as a bare image, is pasted
    /// whole rather than as nothing. `destination` says whether to press ⌘V at all.
    public func paste(_ item: ClipboardItem, plainText: Bool, destination: PasteDestination)
        async throws
    {
        try await paste([item], plainText: plainText, destination: destination)
    }

    /// Pastes several cards at once, left to right: the clipboard gets one pasteboard item per
    /// card (a file card with three files keeps its three), each with all of the card's types,
    /// in one write. Apps that take several items (TextEdit, Finder) paste them all; apps that
    /// take one paste the first. Every card is moved to the top of the history, in a way that
    /// keeps their order. Nothing is written if a file card's file is gone.
    public func paste(_ items: [ClipboardItem], plainText: Bool, destination: PasteDestination)
        async throws
    {
        var data: [ClipboardItemData] = []
        for item in items {
            var itemData = try await store.data(for: item.id)
            if itemData.contains(where: \.isMissingFile) { throw PasteError.fileNoLongerExists }
            if plainText {
                let textOnly = itemData.filter { $0.type == ClipboardType.plainText }
                if !textOnly.isEmpty { itemData = textOnly }
            }
            // Each card's pasteboard items are numbered from 0 when saved; shift them past the
            // cards before it, so the clipboard gets them as separate items in card order.
            let offset = data.last.map { $0.pasteboardItemIndex + 1 } ?? 0
            data += itemData.map { entry in
                var entry = entry
                entry.pasteboardItemIndex += offset
                return entry
            }
        }
        // The marker rides on the first pasteboard item as an empty extra type, the same way
        // password managers mark a copy as concealed. The capture loop sees it on the next poll
        // and knows there is nothing to save: the item is already at the top (see below).
        data.append(
            ClipboardItemData(
                pasteboardItemIndex: data.first?.pasteboardItemIndex ?? 0, type: ownMarker,
                data: Data()))
        clipboard.write(data)
        try await store.moveToTop(ids: items.map(\.id))
        await hidePanel()
        let ids = items.map(\.id)
        guard destination == .activeApp else {
            Log.paste.info("items \(ids, privacy: .public) put on the clipboard")
            return
        }
        guard accessibility.isTrusted else {
            Log.paste.notice("Accessibility is off: items \(ids, privacy: .public) left on the clipboard")
            return
        }
        try keyPresser.pressPaste()
        Log.paste.info(
            "pasted items \(ids, privacy: .public)\(plainText ? " as plain text" : "", privacy: .public)")
    }
}

/// Why a paste could not happen.
public enum PasteError: Error, Equatable {
    /// A file card's file has been moved or deleted since it was copied.
    case fileNoLongerExists
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
