import Foundation
import Testing

@testable import ClipCore

// Proves the Store keeps the user's history correctly: a copy is saved with its details, a repeat
// copy moves up instead of duplicating, big data survives a round trip through a file, and the
// search index stays in step. These run against a real Store on a real SQLite file, because the
// SQL, the triggers and the file handling are exactly what could go wrong. Each test gets its own
// temporary folder, so tests can run at the same time without sharing a database (Swift Testing
// runs tests in parallel by default).
struct StoreTests {
    let folder = TemporaryFolder()

    // Opens a fresh Store, runs the test body against it, then deletes the folder even if the
    // body failed. Keeps each test to the lines that matter. (`async throws` works like an async
    // function in TS that may reject: callers `try await` it, and a thrown error fails the test.)
    func withStore(_ body: (Store) async throws -> Void) async throws {
        // `defer` runs when the function exits, however it exits. ≈ `finally`.
        defer { folder.remove() }
        try await body(try Store(folder: folder.url))
    }

    func copy(_ data: [ClipboardItemData], app: String = "com.apple.TextEdit", at: Date = .now)
        -> CapturedCopy
    {
        CapturedCopy(data: data, sourceApp: SourceApp(bundleId: app, name: "App"), copiedAt: at)
    }

    /// The names of the large-data files on disk right now. Large data lives in one flat folder
    /// of `<UUID>.bin` files, so counting them shows whether a save wrote one and a delete or a
    /// sweep removed it.
    func largeFiles() throws -> [String] {
        let url = folder.url.appending(path: "LargeData")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasSuffix(".bin") }
    }

    @Test func savesATextCopyWithItsDetailsAndData() async throws {
        try await withStore { store in
            let item = try await store.save(copy([.text("hello world"), .marker("public.rtf")]))
            #expect(item.kind == .text)
            #expect(item.cardText == "hello world")
            #expect(item.sourceAppBundleId == "com.apple.TextEdit")
            #expect(item.sourceAppName == "App")
            #expect(try await store.count() == 1)
            let data = try await store.data(for: item.id)
            #expect(data.map(\.type) == [ClipboardType.plainText, "public.rtf"])
            #expect(data[0].text == "hello world")
        }
    }

    @Test func aRepeatCopyMovesTheItemToTheTopInsteadOfDuplicating() async throws {
        try await withStore { store in
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            let first = try await store.save(copy([.text("same")], at: t0))
            try await store.save(copy([.text("other")], at: t0 + 1))
            // The same text copied again, from another app, two seconds later. The user should
            // see one "same" item at the top, with the new time and app, not a second copy of it.
            let again = try await store.save(copy([.text("same")], app: "com.apple.Safari", at: t0 + 2))

            #expect(again.id == first.id)
            #expect(again.createdAt == t0)
            #expect(again.copiedAt == t0 + 2)
            #expect(again.sourceAppBundleId == "com.apple.Safari")
            #expect(try await store.count() == 2)
            #expect(try await store.items(limit: 10).map(\.cardText) == ["same", "other"])
        }
    }

    @Test func largeDataGoesToAFileAndComesBackIdentical() async throws {
        try await withStore { store in
            let big = Data((0..<2_000_000).map { UInt8($0 % 251) })
            let item = try await store.save(
                copy([ClipboardItemData(type: "public.png", data: big), .text("x")]))
            // Only the big type goes to a file; the small "x" stays in the database row.
            #expect(try largeFiles().count == 1)
            #expect(try await store.data(for: item.id)[0].data == big)

            try await store.delete(id: item.id)
            #expect(try await store.count() == 0)
            #expect(try largeFiles().isEmpty)
            #expect(try await store.data(for: item.id).isEmpty)
        }
    }

    @Test func aRepeatCopyReplacesOldData() async throws {
        try await withStore { store in
            let big = Data(repeating: 7, count: 1_500_000)
            let first = try await store.save(
                copy([.png([1, 2, 3]), ClipboardItemData(type: "public.tiff", data: big)]))
            let again = try await store.save(copy([.png([1, 2, 3])]))
            #expect(again.id == first.id)
            // The repeat had no TIFF, so the old TIFF file must be gone, not left behind as a
            // leak the user can never see.
            #expect(try await store.data(for: first.id).count == 1)
            #expect(try largeFiles().isEmpty)
        }
    }

    @Test func orphanDataFilesAreSweptAtLaunch() async throws {
        defer { folder.remove() }
        // A file no row points at, as a crash between writing the file and saving the row would
        // leave behind. Opening the Store must delete it, and must keep files that rows do use.
        let largeData = folder.url.appending(path: "LargeData")
        try FileManager.default.createDirectory(at: largeData, withIntermediateDirectories: true)
        let stray = largeData.appending(path: "\(UUID().uuidString).bin")
        try Data([9]).write(to: stray)
        let store = try Store(folder: folder.url)
        try await store.save(
            copy([ClipboardItemData(type: "public.png", data: Data(repeating: 1, count: 1_100_000))]))
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(try largeFiles().count == 1)
        // A second open keeps the file the saved item uses.
        _ = try Store(folder: folder.url)
        #expect(try largeFiles().count == 1)
    }

    @Test func dataKeepsItsPasteboardItemIndex() async throws {
        try await withStore { store in
            // Two files copied together are two pasteboard items. The index must survive the
            // round trip, or a paste of the copy would hand the other app one item with two
            // file URLs instead of two files.
            let item = try await store.save(copy([.fileURL("/a", item: 0), .fileURL("/b", item: 1)]))
            #expect(item.kind == .file)
            #expect(try await store.data(for: item.id).map(\.pasteboardItemIndex) == [0, 1])
        }
    }

    @Test func theSearchIndexFollowsTheItemTable() async throws {
        try await withStore { store in
            try await store.save(copy([.text("quarterly report draft")]))
            // Search must find a copy the moment it is saved. The index is kept up to date by
            // SQLite triggers, not by the save code, so this checks the triggers fired on a plain
            // INSERT: a hit for a prefix of a word in the copy, none for a word that isn't there.
            #expect(try await store.searchHitCount("quart") == 1)
            #expect(try await store.searchHitCount("yearly") == 0)
        }
    }

    @Test func theSearchIndexFollowsARepeatCopysNewCardText() async throws {
        try await withStore { store in
            // The same picture copied twice, the second time with different text next to it.
            // The repeat updates the existing row, so this checks the UPDATE trigger: the index
            // must know the new words and forget the old ones.
            try await store.save(copy([.png([1]), .text("alpha")]))
            try await store.save(copy([.png([1]), .text("beta")]))
            #expect(try await store.count() == 1)
            #expect(try await store.searchHitCount("beta") == 1)
            #expect(try await store.searchHitCount("alpha") == 0)
        }
    }
}
