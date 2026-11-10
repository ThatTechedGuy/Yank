import Foundation
import Testing

@testable import ClipCore

/// Says the front app is TextEdit the first time it is asked and, at that very moment, has the
/// user switch to Safari and copy again. The service asks just before its settle wait, so the
/// second copy always lands during the wait, with no timers racing each other in the test.
@MainActor private final class SwitchesAppAndCopies: FrontmostApp {
    let clipboard: FakeClipboard
    private var hasSwitched = false

    init(clipboard: FakeClipboard) { self.clipboard = clipboard }

    func current() -> SourceApp? {
        if hasSwitched { return SourceApp(bundleId: "com.apple.Safari", name: "Safari") }
        hasSwitched = true
        clipboard.put([.text("second")])
        return SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")
    }
}

@MainActor struct CaptureServiceTests {
    let folder = TemporaryFolder()
    let clipboard = FakeClipboard()
    let frontmost = FakeFrontmostApp()

    func makeService(rules: PrivacyRules = PrivacyRules()) throws -> (CaptureService, Store) {
        let store = try Store(folder: folder.url)
        // A 1 ms settle keeps the tests fast; the real app waits 300 ms.
        let service = CaptureService(
            clipboard: clipboard, frontmostApp: frontmost, store: store, rules: rules,
            settle: .milliseconds(1))
        return (service, store)
    }

    @Test func nothingIsSavedUntilTheClipboardChanges() async throws {
        defer { folder.remove() }
        // Whatever is on the clipboard when the app launches is not a new copy, so it must not be
        // saved or even read.
        clipboard.put([.text("already there")])
        let (service, store) = try makeService()
        try await service.tick()
        #expect(try await store.count() == 0)
        #expect(clipboard.reads == 0)

        clipboard.put([.text("fresh copy")])
        var captured: ClipboardItem?
        service.onCapture = { captured = $0 }
        try await service.tick()
        #expect(captured?.cardText == "fresh copy")
        #expect(captured?.sourceAppBundleId == "com.apple.TextEdit")
        #expect(try await store.count() == 1)
        // The app ticks over and over while it runs, so a tick with no new copy must cost
        // nothing: no read, no save.
        try await service.tick()
        #expect(clipboard.reads == 1)
    }

    @Test func aCopyReplacedDuringTheSettleWaitIsSavedUnderTheNewerApp() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let service = CaptureService(
            clipboard: clipboard, frontmostApp: SwitchesAppAndCopies(clipboard: clipboard), store: store,
            settle: .milliseconds(1))
        clipboard.put([.text("first")])
        try await service.tick()
        // The first copy is stale by the time the wait ends: saving now would file "second"
        // under TextEdit.
        #expect(try await store.count() == 0)
        #expect(clipboard.reads == 0)
        try await service.tick()
        let items = try await store.items(limit: 10)
        #expect(items.map(\.cardText) == ["second"])
        #expect(items.first?.sourceAppBundleId == "com.apple.Safari")
    }

    @Test func markedCopiesAreNeverRead() async throws {
        defer { folder.remove() }
        let (service, store) = try makeService()
        clipboard.put([.text("hunter2"), .marker("org.nspasteboard.ConcealedType")])
        try await service.tick()
        #expect(clipboard.reads == 0)
        #expect(try await store.count() == 0)
    }

    // An ignored app is skipped by its bundle id alone, so nothing secret ever enters the process.
    @Test func copiesFromIgnoredAppsAreNeverRead() async throws {
        defer { folder.remove() }
        let (service, store) = try makeService(rules: PrivacyRules(ignoredApps: ["com.example.vault"]))
        frontmost.app = SourceApp(bundleId: "com.example.vault", name: "Vault")
        clipboard.put([.text("hunter2")])
        try await service.tick()
        #expect(clipboard.reads == 0)
        #expect(try await store.count() == 0)
    }

    // A copy made while paused stays unsaved after the pause ends.
    @Test func nothingIsSavedWhilePaused() async throws {
        defer { folder.remove() }
        let (service, store) = try makeService()
        service.pause = .pausedUntilResumed
        clipboard.put([.text("while paused")])
        try await service.tick()
        #expect(clipboard.reads == 0)
        #expect(try await store.count() == 0)

        service.pause = .running
        try await service.tick()
        #expect(try await store.count() == 0)
        clipboard.put([.text("after resuming")])
        try await service.tick()
        #expect(try await store.items(limit: 10).map(\.cardText) == ["after resuming"])
    }
}
