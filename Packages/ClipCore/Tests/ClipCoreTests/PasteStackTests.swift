import Foundation
import Testing

@testable import ClipCore

@MainActor struct PasteStackTests {
    func item(_ id: Int64) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: .text, cardText: "item \(id)", createdAt: .now, copiedAt: .now,
            contentFingerprint: "f\(id)")
    }

    @Test func turningOnStartsEmptyAndCopiesQueueInOrder() {
        var stack = PasteStack.off
        #expect(!stack.isOn)
        stack.turnOn()
        #expect(stack == .on(queue: []))
        stack.add(item(1))
        stack.add(item(2))
        #expect(stack.queue.map(\.id) == [1, 2])
        // Turning on again does not clear what is waiting.
        stack.turnOn()
        #expect(stack.queue.map(\.id) == [1, 2])
    }

    @Test func pasteNextTakesTheOldestAndTheLastOneLeavesTheStackOnAndEmpty() {
        var stack = PasteStack.on(queue: [item(1), item(2)])
        #expect(stack.popNext()?.id == 1)
        #expect(stack.popNext()?.id == 2)
        #expect(stack == .on(queue: []))
        #expect(stack.popNext() == nil)
        #expect(stack == .on(queue: []))
    }

    @Test func turningOffClearsTheQueueAndOffIgnoresEverything() {
        var stack = PasteStack.on(queue: [item(1)])
        stack.turnOff()
        #expect(stack == .off)
        stack.add(item(2))
        #expect(stack.popNext() == nil)
        #expect(stack == .off)
    }

    /// `onCapture` fires for a new copy and for a repeat copy, so both join. The app's own
    /// paste carries the marker, is never saved, and so never joins.
    @Test func copiesJoinTheQueueOnlyWhileTheStackIsOnAndOwnPastesNever() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let clipboard = FakeClipboard()
        let capture = CaptureService(
            clipboard: clipboard, frontmostApp: FakeFrontmostApp(), store: store,
            settle: .milliseconds(1))
        var stack = PasteStack.off
        capture.onCapture = { stack.add($0) }

        clipboard.put([.text("before")])
        try await capture.tick()
        #expect(stack.queue.isEmpty)

        stack.turnOn()
        clipboard.put([.text("a")])
        try await capture.tick()
        clipboard.put([.text("a")])  // the same text again: a repeat copy still joins
        try await capture.tick()
        clipboard.put([.text("b"), .marker(PrivacyRules().ownMarker)])  // our own paste
        try await capture.tick()
        #expect(stack.queue.map(\.cardText) == ["a", "a"])
        #expect(try await store.count() == 2)
    }

    /// "Paste next" is a pop followed by an ordinary paste, so the queue is one shorter even
    /// when the paste cannot press ⌘V, and the next press moves on to the next item.
    @Test func pasteNextWithoutAccessibilityStillShortensTheQueue() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let a = try await store.save(CapturedCopy(data: [.text("a")], sourceApp: nil, copiedAt: .now))
        let b = try await store.save(CapturedCopy(data: [.text("b")], sourceApp: nil, copiedAt: .now))
        let clipboard = FakeClipboard()
        let keys = FakeKeyPresser()
        let accessibility = FakeAccessibility()
        accessibility.isTrusted = false
        let service = PasteService(
            store: store, clipboard: clipboard, keyPresser: keys, accessibility: accessibility)
        var stack = PasteStack.on(queue: [a, b])

        let popped = stack.popNext()
        let next = try #require(popped)
        try await service.paste(next, plainText: false, destination: .activeApp)
        #expect(clipboard.contents.first?.text == "a")
        #expect(keys.presses == 0)
        #expect(stack.queue.map(\.id) == [b.id])
    }
}
