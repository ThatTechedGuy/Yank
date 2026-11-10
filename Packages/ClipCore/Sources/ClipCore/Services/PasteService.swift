import Foundation

// The one function behind every paste from the panel. The panel never takes focus away from the
// app the user was working in (see PanelWindow), so nothing has to switch back before ⌘V.
/// Pastes a saved item into the app in front, or just onto the clipboard.
@MainActor public final class PasteService {
    private let store: Store
    private let clipboard: any Clipboard
    private let keyPresser: any KeyPressing
    private let accessibility: any AccessibilityStatus
    private let ownMarker: String

    /// Hides the panel and returns once it has given up the keyboard; pressed any sooner, ⌘V would
    /// land in the panel's own search box. The app sets this to the panel window's `hide()`.
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

    /// Pastes `item`. `plainText` keeps only its plain-text type; an item with no plain text at
    /// all, such as a bare image, is pasted whole. `destination` says whether to press ⌘V at all.
    public func paste(_ item: ClipboardItem, plainText: Bool, destination: PasteDestination)
        async throws
    {
        try await paste([item], plainText: plainText, destination: destination)
    }

    /// Pastes several cards in one clipboard write, in order: one pasteboard item per card (a file
    /// card with three files keeps its three), each with all of the card's types. Apps that take
    /// several items (TextEdit, Finder) paste them all; apps that take one paste the first. Every
    /// card moves to the top of the history, order kept. Nothing is written if a file card's file
    /// is gone.
    public func paste(_ items: [ClipboardItem], plainText: Bool, destination: PasteDestination)
        async throws
    {
        var data: [ClipboardItemData] = []
        for item in items {
            var itemData = try await store.data(for: item.id)
            if await itemData.hasMissingFile() { throw PasteError.fileNoLongerExists }
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
        // Every card was deleted after it was listed (a paste stack entry whose item has since
        // been erased, say), so the clipboard keeps what it holds.
        guard !data.isEmpty else {
            Log.paste.notice("paste skipped: the items no longer exist")
            return
        }
        // The marker rides on the first pasteboard item as an empty extra type, the same way
        // password managers mark a copy as concealed; the capture loop sees it and saves nothing.
        // It goes right after that item's last type, because a change of `pasteboardItemIndex`
        // starts a new pasteboard item: at the end of a multi-card paste it would become an
        // extra, empty item of its own.
        let firstItem = data[0].pasteboardItemIndex
        data.insert(
            ClipboardItemData(pasteboardItemIndex: firstItem, type: ownMarker, data: Data()),
            at: data.firstIndex { $0.pasteboardItemIndex != firstItem } ?? data.count)
        try await store.moveToTop(ids: items.map(\.id))
        await hidePanel()
        // The write comes after the last `await`, right before the press: a second paste
        // started while this one waited (⌃⌥⌘V twice on the stack) must not have its item on the
        // clipboard when this one's ⌘V lands.
        clipboard.write(data)
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
/// the app stores in UserDefaults, and what `-pasteDestination clipboardOnly` on the command line
/// sets.
public enum PasteDestination: String, Sendable {
    /// Put the item on the clipboard and press ⌘V in the app in front.
    case activeApp
    /// Only put the item on the clipboard; the user pastes it themselves.
    case clipboardOnly
}
