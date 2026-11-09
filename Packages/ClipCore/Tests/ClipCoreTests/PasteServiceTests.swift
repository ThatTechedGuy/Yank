import Foundation
import Testing

@testable import ClipCore

// Proves a paste does what the user relies on: the item's content goes back on the clipboard
// with our marker, ⌘V is pressed exactly when it should be, and the item is the first card
// afterwards. The clipboard, key presser and permission are fakes; the Store is real, on a
// SQLite file in a temporary folder, so the move-to-top is tested against real rows.
@MainActor struct PasteServiceTests {
    let folder = TemporaryFolder()
    let clipboard = FakeClipboard()
    let keys = FakeKeyPresser()
    let accessibility = FakeAccessibility()

    /// A store with two items saved a moment apart, and a paste service over it. Returns the
    /// older item, so a test can paste it and check it moved above the newer one.
    func makeService() async throws -> (PasteService, Store, older: ClipboardItem) {
        let store = try Store(folder: folder.url)
        // The first copy carries rich text next to its plain text, like a copy from Safari, so
        // the plain-text tests have something to strip.
        let older = try await store.save(
            CapturedCopy(
                data: [
                    ClipboardItemData(type: "public.rtf", data: Data("{\\rtf1 hi}".utf8)),
                    .text("hi"),
                ], sourceApp: nil, copiedAt: Date(timeIntervalSinceNow: -60)))
        try await store.save(CapturedCopy(data: [.text("newer")], sourceApp: nil, copiedAt: Date()))
        let service = PasteService(
            store: store, clipboard: clipboard, keyPresser: keys, accessibility: accessibility)
        return (service, store, older)
    }

    @Test func pastingWritesEveryTypePlusTheMarkerPressesPasteOnceAndMovesTheItemUp() async throws {
        defer { folder.remove() }
        let (service, store, older) = try await makeService()
        // The panel must have given up the keyboard before ⌘V is pressed, otherwise the
        // keystroke lands in our own search box. The fake "hide" notes whether ⌘V had already
        // been pressed when it ran.
        var hiddenBeforePress = false
        service.hidePanel = { hiddenBeforePress = keys.presses == 0 }
        try await service.paste(older, plainText: false, destination: .activeApp)
        #expect(
            clipboard.contents.map(\.type) == [
                "public.rtf", ClipboardType.plainText, PrivacyRules().ownMarker,
            ])
        #expect(keys.presses == 1)
        #expect(hiddenBeforePress)
        // The pasted item is now the newest, above the item copied after it.
        #expect(try await store.items(limit: 2).map(\.id) == [older.id, older.id + 1])
        // The capture loop's next poll sees our marker and saves nothing: still two items.
        let capture = CaptureService(
            clipboard: clipboard, frontmostApp: FakeFrontmostApp(), store: store,
            settle: .milliseconds(1))
        clipboard.changeCount += 1  // as if the loop had seen the count before our write
        try await capture.tick()
        #expect(try await store.count() == 2)
    }

    @Test func plainTextKeepsOnlyThePlainTextType() async throws {
        defer { folder.remove() }
        let (service, _, older) = try await makeService()
        try await service.paste(older, plainText: true, destination: .activeApp)
        #expect(clipboard.contents.map(\.type) == [ClipboardType.plainText, PrivacyRules().ownMarker])
        #expect(clipboard.contents[0].text == "hi")
    }

    @Test func plainTextFallsBackToEverythingWhenTheItemHasNoText() async throws {
        defer { folder.remove() }
        let (service, store, _) = try await makeService()
        let image = try await store.save(
            CapturedCopy(data: [.png([1, 2, 3])], sourceApp: nil, copiedAt: Date()))
        // A bare image has no plain text to keep, so asking for plain text must not paste
        // nothing: the image goes as it is.
        try await service.paste(image, plainText: true, destination: .activeApp)
        #expect(clipboard.contents.map(\.type) == ["public.png", PrivacyRules().ownMarker])
    }

    /// Three cards, one of them a Finder copy of two files, pasted together: the clipboard
    /// gets one pasteboard item per card (two for the two files), left to right, each with
    /// every type the card has, the marker on the first, all in one write. Afterwards the
    /// three sit at the top in the same order.
    @Test func pastingSeveralWritesOneClipboardItemPerCardInOrder() async throws {
        defer { folder.remove() }
        let (service, store, older) = try await makeService()
        let files = try await store.save(
            CapturedCopy(
                data: [
                    .fileURL("/tmp/one.txt", item: 0), .fileURL("/tmp/two.txt", item: 1),
                ], sourceApp: nil, copiedAt: Date()))
        let image = try await store.save(
            CapturedCopy(data: [.png([1, 2, 3])], sourceApp: nil, copiedAt: Date()))
        // Both files exist, so the paste is allowed.
        for path in ["/tmp/one.txt", "/tmp/two.txt"] {
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        defer {
            for path in ["/tmp/one.txt", "/tmp/two.txt"] { try? FileManager.default.removeItem(atPath: path) }
        }
        let before = clipboard.changeCount

        try await service.paste([older, files, image], plainText: false, destination: .activeApp)

        #expect(clipboard.changeCount == before + 1)
        #expect(
            clipboard.contents.map { ($0.pasteboardItemIndex, $0.type) }.map { "\($0.0):\($0.1)" } == [
                "0:public.rtf", "0:\(ClipboardType.plainText)", "0:\(PrivacyRules().ownMarker)",
                "1:\(ClipboardType.fileURL)", "2:\(ClipboardType.fileURL)", "3:public.png",
            ])
        #expect(keys.presses == 1)
        #expect(try await store.items(limit: 4).map(\.id) == [older.id, files.id, image.id, older.id + 1])
    }

    // A card deleted after it was listed (a paste stack entry, say) has no data. Pasting it must
    // leave what the user has on the clipboard alone, and press nothing.
    @Test func pastingADeletedCardLeavesTheClipboardAlone() async throws {
        defer { folder.remove() }
        let (service, store, older) = try await makeService()
        clipboard.put([.text("what the user copied")])
        let before = clipboard.changeCount
        try await store.delete(id: older.id)
        try await service.paste(older, plainText: false, destination: .activeApp)
        #expect(clipboard.changeCount == before)
        #expect(clipboard.contents.map(\.text) == ["what the user copied"])
        #expect(keys.presses == 0)
    }

    @Test func aFileThatIsGoneRefusesThePasteBeforeAnythingIsWritten() async throws {
        defer { folder.remove() }
        let (service, store, older) = try await makeService()
        let gone = try await store.save(
            CapturedCopy(
                data: [.fileURL("/tmp/yank-tests-\(UUID().uuidString).txt")], sourceApp: nil,
                copiedAt: Date()))
        let before = clipboard.changeCount
        await #expect(throws: PasteError.fileNoLongerExists) {
            try await service.paste([older, gone], plainText: false, destination: .activeApp)
        }
        #expect(clipboard.changeCount == before)
        #expect(keys.presses == 0)
    }

    @Test func pasteIsNeverPressedWithoutPermissionOrInClipboardOnlyMode() async throws {
        defer { folder.remove() }
        let (service, _, older) = try await makeService()
        // Without the Accessibility permission the item still goes on the clipboard, marker and
        // all, and the user presses ⌘V themselves.
        accessibility.isTrusted = false
        try await service.paste(older, plainText: false, destination: .activeApp)
        #expect(keys.presses == 0)
        #expect(clipboard.contents.last?.type == PrivacyRules().ownMarker)
        // "Paste items: to clipboard only" never presses, even with the permission.
        accessibility.isTrusted = true
        try await service.paste(older, plainText: false, destination: .clipboardOnly)
        #expect(keys.presses == 0)
        #expect(clipboard.changeCount == 2)
        // Nothing in a paste shows the macOS permission prompt; only the hint's button does.
        #expect(accessibility.requests == 0)
    }
}
