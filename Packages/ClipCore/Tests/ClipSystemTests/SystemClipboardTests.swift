import AppKit
import ClipCore
import Testing

@testable import ClipSystem

// Proves the real NSPasteboard adapter reads what the user copied, in full and in order, and
// drops data over the size limits. It talks to the real pasteboard system, because that is the
// part a fake cannot prove. Each test uses its own private pasteboard, so the user's actual
// clipboard is never read or changed. (`NSPasteboard(name:)` creates or joins a pasteboard by
// name; `NSPasteboard.general` is just the shared one every app uses.)
@MainActor struct SystemClipboardTests {
    @Test func readsEveryTypeOfEveryItemInOrder() {
        let pasteboard = NSPasteboard(name: .init("com.thattechedguy.Yank.test.\(UUID())"))
        // Named pasteboards live in the system's pasteboard server, outside this process, and
        // stay there until released. `releaseGlobally` removes this one when the test ends, so
        // repeated test runs don't leave hundreds behind. (`defer` runs at the end of the test.)
        defer { pasteboard.releaseGlobally() }
        let before = pasteboard.changeCount

        // Two items, each with two types, like Finder copying two files. The adapter must keep
        // every type of every item and remember which item each one belongs to, otherwise a
        // multi-file copy would come back as one file.
        let a = NSPasteboardItem()
        a.setString("one", forType: .string)
        a.setData(Data([1]), forType: .png)
        let b = NSPasteboardItem()
        b.setString("two", forType: .string)
        // A type name nobody else uses, so the test proves the adapter passes unknown types
        // through as raw bytes instead of only the ones it recognises. `setData(_:forType:)`
        // accepts any type name; nothing has to be registered first.
        b.setData(Data([2, 2]), forType: .init("com.example.custom"))
        pasteboard.clearContents()
        pasteboard.writeObjects([a, b])

        let clipboard = SystemClipboard(pasteboard: pasteboard)
        #expect(clipboard.changeCount > before)
        // The type names handed to the veto closure must list every type of every item, in
        // order, and the data read afterwards must line up with them.
        var seenTypes: [String] = []
        let read = clipboard.read { types in
            seenTypes = types
            return true
        }
        #expect(
            seenTypes == [
                "public.utf8-plain-text", "public.png", "public.utf8-plain-text", "com.example.custom",
            ])
        #expect(read?.map(\.type) == seenTypes)
        #expect(read?.map(\.pasteboardItemIndex) == [0, 0, 1, 1])
        #expect(read?[0].text == "one")
        #expect(read?[3].data == Data([2, 2]))
        // A veto means nothing is read: the caller gets nil, not an empty list, so it can tell
        // "skipped" from "the clipboard was empty".
        #expect(clipboard.read { _ in false } == nil)
        // macOS can make the user approve each read of the shared clipboard, and the menu shows
        // a notice when that is on. A private pasteboard has no such setting, so it reads back
        // as allowed; this checks the mapping to `ClipboardAccess` works at all.
        #expect(clipboard.access == .allowed)
    }

    @Test func dataOverTheLimitsIsDropped() {
        let pasteboard = NSPasteboard(name: .init("com.thattechedguy.Yank.test.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setData(Data(repeating: 0, count: 10), forType: .init("com.example.small"))
        item.setData(Data(repeating: 0, count: 100), forType: .init("com.example.big"))
        item.setData(Data(repeating: 0, count: 10), forType: .init("com.example.small2"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        // The limits stop one huge copy from filling the user's memory or disk. Per-type limit:
        // a single type over the cap is skipped on its own, and the smaller types around it are
        // still kept, so the copy is not lost entirely.
        let perType = SystemClipboard(pasteboard: pasteboard, maxBytesPerType: 50)
        #expect(perType.read { _ in true }?.map(\.type) == ["com.example.small", "com.example.small2"])
        // Per-item limit: types are added up in order, and once the total passes the cap the rest
        // of that item is dropped, so the earlier types are the ones that survive.
        let perItem = SystemClipboard(pasteboard: pasteboard, maxBytesPerItem: 15)
        #expect(perItem.read { _ in true }?.map(\.type) == ["com.example.small"])
    }
}
