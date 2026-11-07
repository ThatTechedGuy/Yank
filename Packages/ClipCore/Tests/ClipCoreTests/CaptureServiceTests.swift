import Foundation
import Testing

@testable import ClipCore

// Proves the whole capture path works together: a change on the clipboard ends up as a saved
// item, and private copies are never even read. This is what the user relies on every time they
// copy. The clipboard and the frontmost app are fakes the test controls; the Store is real, on a
// SQLite file in a temporary folder, so saving is tested for real too. (`@MainActor` on the suite
// runs every test on the main thread, which CaptureService and the fakes require.)
@MainActor struct CaptureServiceTests {
    let folder = TemporaryFolder()
    let clipboard = FakeClipboard()
    let frontmost = FakeFrontmostApp()

    func makeService(rules: PrivacyRules = PrivacyRules()) throws -> (CaptureService, Store) {
        let store = try Store(folder: folder.url)
        // `settle` is how long the service waits after a change before reading, so an app that
        // writes the clipboard in several steps is read once, complete. 1 ms keeps the tests fast;
        // the real app waits 300 ms.
        let service = CaptureService(
            clipboard: clipboard, frontmostApp: frontmost, store: store, rules: rules,
            settle: .milliseconds(1))
        return (service, store)
    }

    @Test func nothingIsSavedUntilTheClipboardChanges() async throws {
        defer { folder.remove() }
        // Whatever is on the clipboard when the app launches is not a new copy, so it must not be
        // saved or even read. The service remembers the change count it started with and only
        // acts when that number moves.
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
        // nothing: no read, no save. `reads` stays at 1, the one real copy above.
        try await service.tick()
        #expect(clipboard.reads == 1)
    }

    @Test func aCopyReplacedDuringTheSettleWaitIsSavedUnderTheNewerApp() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        // A longer settle wait than usual, so the test can put a second copy on the clipboard
        // while the service is still waiting for the first one.
        let service = CaptureService(
            clipboard: clipboard, frontmostApp: frontmost, store: store, settle: .milliseconds(100))
        frontmost.app = SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")
        clipboard.put([.text("first")])
        // Mid-wait, the user switches to Safari and copies again. (`Task` starts this alongside
        // the tick below, like a `setTimeout` that fires during an await.)
        let secondCopy = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(20))
            frontmost.app = SourceApp(bundleId: "com.apple.Safari", name: "Safari")
            clipboard.put([.text("second")])
        }
        try await service.tick()
        try await secondCopy.value
        // The first copy is stale by the time the wait ends: saving now would file "second"
        // under TextEdit. So nothing is saved on this tick, and nothing was read.
        #expect(try await store.count() == 0)
        #expect(clipboard.reads == 0)
        // The next tick sees the newer change and saves it under the app that made it.
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

    // An app the user put on the ignored list is skipped by its bundle id alone: the service
    // never reads the data, so nothing secret ever enters the process.
    @Test func copiesFromIgnoredAppsAreNeverRead() async throws {
        defer { folder.remove() }
        let (service, store) = try makeService(rules: PrivacyRules(ignoredApps: ["com.example.vault"]))
        frontmost.app = SourceApp(bundleId: "com.example.vault", name: "Vault")
        clipboard.put([.text("hunter2")])
        try await service.tick()
        #expect(clipboard.reads == 0)
        #expect(try await store.count() == 0)
    }
}
