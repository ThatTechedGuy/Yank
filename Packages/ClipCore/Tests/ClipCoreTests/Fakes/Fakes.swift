// Hand-written stand-ins for the clipboard and the frontmost app, so ClipCore's tests never
// touch the user's real clipboard and can decide exactly what "the clipboard" holds. They are
// plain classes that adopt the same protocols the real adapters do (≈ a `jest.fn()` mock or a
// fake repository in Android tests). Swift ships no mocking library, and a protocol this small
// does not need one.
import Foundation
import Testing

@testable import ClipCore

/// A clipboard the test fills by hand. `put` replaces the contents and bumps `changeCount`,
/// which is exactly what a real copy does on NSPasteboard, so CaptureService cannot tell the
/// difference.
@MainActor final class FakeClipboard: Clipboard {
    var changeCount = 0
    var contents: [ClipboardItemData] = []
    var access: ClipboardAccess = .allowed
    /// How many times the data was actually read (`decide` said yes). The privacy rules must
    /// decide from the type names alone, before any content is read, so a password never passes
    /// through the app. Tests check this stays 0 for a skipped copy.
    var reads = 0

    func put(_ data: [ClipboardItemData]) {
        contents = data
        changeCount += 1
    }

    func read(if decide: ([String]) -> Bool) -> [ClipboardItemData]? {
        guard decide(contents.map(\.type)) else { return nil }
        reads += 1
        return contents
    }

    /// A paste writes the clipboard the same way a copy does, so it just reuses `put`.
    func write(_ data: [ClipboardItemData]) { put(data) }
}

@MainActor final class FakeFrontmostApp: FrontmostApp {
    var app: SourceApp? = SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")
    func current() -> SourceApp? { app }
}

/// Counts ⌘V presses instead of sending them, so a test never pastes into a real app.
@MainActor final class FakeKeyPresser: KeyPressing {
    var presses = 0
    func pressPaste() throws { presses += 1 }
}

/// The Accessibility permission as the test wants it. `requests` counts how often the macOS
/// prompt would have been shown.
@MainActor final class FakeAccessibility: AccessibilityStatus {
    var isTrusted = true
    var requests = 0
    func requestAccess() { requests += 1 }
}

// Small builders so a test reads as "a text copy of X" instead of repeating type strings and
// byte conversions on every line. Each one makes the same `ClipboardItemData` the real adapter
// would produce for that kind of copy.
extension ClipboardItemData {
    static func text(_ string: String) -> ClipboardItemData {
        ClipboardItemData(type: ClipboardType.plainText, data: Data(string.utf8))
    }
    static func url(_ string: String) -> ClipboardItemData {
        ClipboardItemData(type: ClipboardType.url, data: Data(string.utf8))
    }
    static func fileURL(_ path: String, item: Int = 0) -> ClipboardItemData {
        ClipboardItemData(
            pasteboardItemIndex: item, type: ClipboardType.fileURL,
            data: Data(URL(filePath: path).absoluteString.utf8))
    }
    static func png(_ bytes: [UInt8]) -> ClipboardItemData {
        ClipboardItemData(type: "public.png", data: Data(bytes))
    }
    static func marker(_ type: String) -> ClipboardItemData {
        ClipboardItemData(type: type, data: Data())
    }
}

/// A fresh folder per test for the Store's SQLite file and large-data files. The random name
/// means tests running at the same time never share a database; `remove()` deletes it at the
/// end so test runs don't fill the temp folder.
struct TemporaryFolder {
    let url = URL.temporaryDirectory.appending(path: "YankTests-\(UUID().uuidString)")
    func remove() { try? FileManager.default.removeItem(at: url) }
}

// Tags label tests so a run can pick or skip them. `.slow` marks tests that take seconds
// (seeding 100,000 items) instead of milliseconds; `scripts/test.sh --fast` skips them, the full
// run includes them. (`@Tag` ≈ a Jest `describe` name you can filter on, or a JUnit category.)
extension Tag {
    @Tag static var slow: Self
}
