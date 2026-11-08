// AppKit is the classic macOS UI and system framework (NSPasteboard, NSWorkspace, NSApplication).
// SwiftUI sits on top of it; for the clipboard there is no SwiftUI API, so we use AppKit here.
import AppKit
import ClipCore

// The real clipboard, behind ClipCore's `Clipboard` port (the interface ClipCore defines so it
// can be tested with a fake). Reads every pasteboard item and every type on it, and writes
// them back the same way, so a paste offers the same content the source app did.
//
// Size limits: a copy of a 4K TIFF or a giant RTF can be hundreds of MB. Reading happens on the
// main thread (this class is `@MainActor`, which means every call runs there), so a huge read
// would freeze the menu. We cap what we read: a type larger than `maxBytesPerType` is dropped,
// and once an item has passed `maxBytesPerItem` the remaining types are dropped too. Both are
// parameters so tests can use tiny numbers.
/// `NSPasteboard` as a `Clipboard`.
@MainActor public final class SystemClipboard: Clipboard {
    private let pasteboard: NSPasteboard
    private let maxBytesPerType: Int
    private let maxBytesPerItem: Int

    // `NSPasteboard.general` is the clipboard every app shares. Tests pass a private, named
    // pasteboard so they never touch your real clipboard.
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
        // The type names, such as "public.utf8-plain-text", in order. Names are free to read:
        // they never trigger the macOS 15.4+ "Paste from Other Apps" alert, only data does. That
        // is what lets the privacy check run before any data enters the process. (`flatMap`
        // here concatenates: [[a, b], [c]] → [a, b, c]. `.rawValue` unwraps AppKit's
        // `NSPasteboard.PasteboardType` wrapper to the plain UTI string ClipCore uses.)
        guard decide(items.flatMap { $0.types.map(\.rawValue) }) else { return nil }
        var result: [ClipboardItemData] = []
        // Time the whole read and log it, so the cost of a huge copy on the main thread can be
        // checked from the log (see the README). `ContinuousClock` is a stopwatch clock,
        // ≈ `performance.now()`.
        let started = ContinuousClock.now
        for (index, item) in items.enumerated() {
            var itemBytes = 0
            for type in item.types {
                // `data(forType:)` is the one call that may show the permission alert, and the
                // one that costs time for big data. A type with no data is skipped.
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
        // come before `writeObjects`; writing without it is refused.
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        Log.paste.info("wrote \(data.count) types in \(items.count) pasteboard items")
    }

    /// Rebuilds the pasteboard items the source app had: `data` is in save order, so a change
    /// of `pasteboardItemIndex` starts a new item. A Finder copy of three files becomes three
    /// items again, each with its own file URL, which is what Finder expects back. A paste
    /// writes these to the clipboard; a drag out of the panel hands them to the drag session.
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

    // Whether the user has let Yank read other apps' copies (the "Paste from Other Apps" setting
    // in System Settings). The menu shows this and points to the setting when it is not Allow.
    // Maps AppKit's four states onto the three the app cares about. `.default` means "never
    // asked yet", which from our side is the same as allowed: the first read will ask.
    public var access: ClipboardAccess {
        switch pasteboard.accessBehavior {
        case .default, .alwaysAllow: .allowed
        case .ask: .askEachTime
        case .alwaysDeny: .denied
        // AppKit enums can gain cases in later SDKs; `@unknown default` keeps the switch
        // complete without pretending we know them. A new, unknown state is treated as "will
        // ask", the cautious middle.
        @unknown default: .askEachTime
        }
    }
}

// Which app is in front, so each saved copy can show where it came from. Read via NSWorkspace,
// AppKit's view of the whole system: running apps, opening files and URLs, the Dock.
// ≈ Android's ActivityManager / UsageStats, minus the permission: on macOS this is free to ask.
/// `NSWorkspace.shared.frontmostApplication` as a `FrontmostApp`.
@MainActor public final class FrontmostAppReader: FrontmostApp {
    public init() {}

    public func current() -> SourceApp? {
        // No front app, or one without a bundle id (some helper processes), means the copy
        // simply has no source app; that is allowed. (`guard let a = x, let b = a.y` unwraps
        // two optionals in a row; either nil exits.)
        guard let app = NSWorkspace.shared.frontmostApplication,
            let bundleId = app.bundleIdentifier
        else { return nil }
        return SourceApp(bundleId: bundleId, name: app.localizedName ?? bundleId)
    }
}
