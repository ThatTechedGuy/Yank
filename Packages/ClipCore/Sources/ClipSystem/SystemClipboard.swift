import AppKit
import ClipCore

// Size limits: a copy of a 4K TIFF or a giant RTF can be hundreds of MB, and reading happens on
// the main thread, where a huge read would freeze the menu. A type larger than `maxBytesPerType`
// is dropped, and once an item has passed `maxBytesPerItem` the remaining types are dropped too.
/// `NSPasteboard` as a `Clipboard`.
@MainActor public final class SystemClipboard: Clipboard {
    private let pasteboard: NSPasteboard
    private let maxBytesPerType: Int
    private let maxBytesPerItem: Int

    // Tests pass a private, named pasteboard, so they never touch the real clipboard, and tiny
    // limits.
    public init(
        pasteboard: NSPasteboard = .general, maxBytesPerType: Int = 256_000_000,
        maxBytesPerItem: Int = 1_000_000_000
    ) {
        self.pasteboard = pasteboard
        self.maxBytesPerType = maxBytesPerType
        self.maxBytesPerItem = maxBytesPerItem
    }

    /// A number macOS bumps on every copy. The capture loop polls it to notice a new copy
    /// without reading any data.
    public var changeCount: Int { pasteboard.changeCount }

    public func read(if decide: ([String]) -> Bool) -> [ClipboardItemData]? {
        // `pasteboardItems` is a snapshot: the items it returns belong to this change of the
        // clipboard. If another copy lands while we hold them, their `data(forType:)` returns
        // nil instead of the new copy's bytes, so the names we check and the data we read can
        // never be from two different copies.
        let items = pasteboard.pasteboardItems ?? []
        // Names are free to read: they never trigger the macOS 15.4+ "Paste from Other Apps"
        // alert, only data does. That is what lets the privacy check run before any data enters
        // the process.
        guard decide(items.flatMap { $0.types.map(\.rawValue) }) else { return nil }
        var result: [ClipboardItemData] = []
        // Timed and logged, so the cost of a huge copy on the main thread can be checked from
        // the log.
        let started = ContinuousClock.now
        for (index, item) in items.enumerated() {
            var itemBytes = 0
            for type in item.types {
                // `data(forType:)` is the one call that may show the permission alert, and the
                // one that costs time for big data.
                guard let data = item.data(forType: type) else { continue }
                if data.count > maxBytesPerType {
                    Log.capture.notice(
                        "dropping \(type.rawValue, privacy: .public): \(data.count) bytes is over the per-type limit"
                    )
                    continue
                }
                itemBytes += data.count
                if itemBytes > maxBytesPerItem {
                    Log.capture.notice("item \(index) is over the per-item limit; dropping the rest")
                    break
                }
                result.append(
                    ClipboardItemData(pasteboardItemIndex: index, type: type.rawValue, data: data))
            }
        }
        let bytes = result.reduce(0) { $0 + $1.data.count }
        Log.capture.info(
            "read \(result.count) types, \(bytes) bytes in \(ContinuousClock.now - started, privacy: .public)"
        )
        return result
    }

    public func write(_ data: [ClipboardItemData]) {
        let items = Self.pasteboardItems(for: data)
        // `clearContents` takes ownership of the pasteboard (bumping `changeCount`) and must
        // come before `writeObjects`.
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        Log.paste.info("wrote \(data.count) types in \(items.count) pasteboard items")
    }

    /// Rebuilds the pasteboard items the source app had: `data` is in save order, so a change
    /// of `pasteboardItemIndex` starts a new item. A Finder copy of three files becomes three
    /// items again, which is what Finder expects back. Used by a paste and by a drag out of
    /// the panel.
    public static func pasteboardItems(for data: [ClipboardItemData]) -> [NSPasteboardItem] {
        var items: [NSPasteboardItem] = []
        var lastIndex: Int?
        for entry in data {
            if entry.pasteboardItemIndex != lastIndex {
                items.append(NSPasteboardItem())
                lastIndex = entry.pasteboardItemIndex
            }
            items[items.count - 1].setData(entry.data, forType: .init(entry.type))
        }
        return items
    }

    // The "Paste from Other Apps" setting in System Settings. `.default` means "never asked
    // yet", which from our side is the same as allowed: the first read will ask.
    public var access: ClipboardAccess {
        switch pasteboard.accessBehavior {
        case .default, .alwaysAllow: .allowed
        case .ask: .askEachTime
        case .alwaysDeny: .denied
        // A new, unknown state is treated as "will ask", the cautious middle.
        @unknown default: .askEachTime
        }
    }
}

/// `NSWorkspace.shared.frontmostApplication` as a `FrontmostApp`.
@MainActor public final class FrontmostAppReader: FrontmostApp {
    public init() {}

    public func current() -> SourceApp? {
        // No front app, or one without a bundle id (some helper processes), means the copy
        // simply has no source app.
        guard let app = NSWorkspace.shared.frontmostApplication,
            let bundleId = app.bundleIdentifier
        else { return nil }
        return SourceApp(bundleId: bundleId, name: app.localizedName ?? bundleId)
    }
}
