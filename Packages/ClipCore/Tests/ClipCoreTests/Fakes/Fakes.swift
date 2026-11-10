// Hand-written stand-ins for the clipboard, the frontmost app and the other ports, so ClipCore's
// tests never touch the user's real clipboard.
import Foundation
import Testing

@testable import ClipCore

/// A clipboard the test fills by hand. `put` replaces the contents and bumps `changeCount`, as
/// a real copy does on NSPasteboard.
@MainActor final class FakeClipboard: Clipboard {
    var changeCount = 0
    var contents: [ClipboardItemData] = []
    var access: ClipboardAccess = .allowed
    /// How many times the data was actually read (`decide` said yes). The privacy rules must
    /// decide from the type names alone, so tests check this stays 0 for a skipped copy.
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

    func write(_ data: [ClipboardItemData]) { put(data) }
}

@MainActor final class FakeFrontmostApp: FrontmostApp {
    var app: SourceApp? = SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")
    func current() -> SourceApp? { app }
}

/// Counts ⌘V presses instead of sending them, so a test never pastes into a real app.
@MainActor final class FakeKeyPresser: KeyPressing {
    var presses = 0
    /// Runs at each press, so a test can look at the clipboard the moment ⌘V lands.
    var onPress: () -> Void = {}
    func pressPaste() throws {
        presses += 1
        onPress()
    }
}

/// `requests` counts how often the macOS Accessibility prompt would have been shown.
@MainActor final class FakeAccessibility: AccessibilityStatus {
    var isTrusted = true
    var requests = 0
    func requestAccess() { requests += 1 }
}

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
/// means tests running at the same time never share a database.
struct TemporaryFolder {
    let url = URL.temporaryDirectory.appending(path: "YankTests-\(UUID().uuidString)")
    func remove() { try? FileManager.default.removeItem(at: url) }
}

// `.slow` marks tests that take seconds (seeding 100,000 items) instead of milliseconds.
// `scripts/test.sh --fast` skips them by the "slow" prefix of their names, not by this tag.
extension Tag {
    @Tag static var slow: Self
}

/// A web that answers every address with the same title and icon, and remembers which addresses
/// were asked for. `@MainActor` makes the class `Sendable`, which `LinkFetching` requires,
/// without a lock of its own.
@MainActor final class FakeLinkFetcher: LinkFetching {
    var fetched: [URL] = []
    var preview = LinkPreview(
        title: "Example Domain",
        icon: LinkPreview.Icon(png: Data([0x89, 0x50, 0x4E, 0x47]), width: 32, height: 32))

    func fetch(_ url: URL) async throws -> LinkPreview {
        fetched.append(url)
        return preview
    }
}
