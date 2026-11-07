// Hand-written stand-ins for the clipboard and the frontmost app, so ClipCore's tests never
// touch the user's real clipboard and can decide exactly what "the clipboard" holds. They are
// plain classes that adopt the same protocols the real adapters do (≈ a `jest.fn()` mock or a
// fake repository in Android tests). Swift ships no mocking library, and a protocol this small
// does not need one.
import Foundation

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
}

@MainActor final class FakeFrontmostApp: FrontmostApp {
    var app: SourceApp? = SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")
    func current() -> SourceApp? { app }
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
