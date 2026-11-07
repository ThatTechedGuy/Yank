import Foundation
import Synchronization
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

    /// The card texts `query` finds, in result order; nil when the text is not a search.
    func found(_ query: String, in store: Store) async throws -> [String]? {
        try await store.search(query, limit: 50)?.map(\.cardText)
    }

    @Test func theSearchIndexFollowsTheItemTable() async throws {
        try await withStore { store in
            try await store.save(copy([.text("quarterly report draft")]))
            // Search must find a copy the moment it is saved. The index is kept up to date by
            // SQLite triggers, not by the save code, so this checks the triggers fired on a plain
            // INSERT: a hit for a prefix of a word in the copy, none for a word that isn't there.
            #expect(try await found("quart", in: store) == ["quarterly report draft"])
            #expect(try await found("yearly", in: store) == [])
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
            #expect(try await found("beta", in: store) == ["beta"])
            #expect(try await found("alpha", in: store) == [])
        }
    }

    // Whatever the user types must give a sensible answer: SQLite's search language has its
    // own meaning for quotes, `*`, OR and NOT, and a typed one must never cause an error or a
    // wrongly empty list. Each argument is one run of the test (`arguments:` ≈ `test.each`).
    @Test(arguments: ["\"hello", "don't", "c++", "OR", "NOT", "hello NOT", "meeting?"])
    func typedPunctuationAndOperatorsAreOrdinaryWords(typed: String) async throws {
        try await withStore { store in
            try await store.save(copy([.text("hello don't c++ OR NOT meeting")]))
            #expect(try await found(typed, in: store) == ["hello don't c++ OR NOT meeting"])
        }
    }

    // Nothing typed, one letter, or nothing searchable means "not a search yet": the caller
    // shows the full list instead of a (slow) match on one letter or an empty result.
    @Test(arguments: ["", "s", " s ", "*", "\"", "  "])
    func tooLittleToSearchIsNotASearch(typed: String) async throws {
        try await withStore { store in
            try await store.save(copy([.text("something")]))
            #expect(try await found(typed, in: store) == nil)
        }
    }

    @Test func resultsComeBestMatchFirstThenNewest() async throws {
        try await withStore { store in
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            // Two items with one mention of "budget", saved a second apart, and an older one
            // that says it three times. The strong match must come first even though it is the
            // oldest; the two equal matches fall back to newest first. A fourth item without
            // the word must not appear at all.
            try await store.save(copy([.text("budget budget budget")], at: t0))
            try await store.save(copy([.text("the budget for March")], at: t0 + 1))
            try await store.save(copy([.text("budget review notes")], at: t0 + 2))
            try await store.save(copy([.text("lunch on Friday")], at: t0 + 3))
            #expect(
                try await found("bud", in: store) == [
                    "budget budget budget", "budget review notes", "the budget for March",
                ])
        }
    }

    @Test func searchMatchesTheSourceAppsName() async throws {
        try await withStore { store in
            let safari = SourceApp(bundleId: "com.apple.Safari", name: "Safari")
            try await store.save(CapturedCopy(data: [.text("a headline")], sourceApp: safari, copiedAt: .now))
            try await store.save(copy([.text("a note")]))
            #expect(try await found("safari", in: store) == ["a headline"])
            // Several words all have to match, across columns: the app's name and the text.
            #expect(try await found("saf head", in: store) == ["a headline"])
            #expect(try await found("saf note", in: store) == [])
        }
    }

    // The limit the panel has to meet: results within 33 ms at 100,000 items, p95. Two- and
    // three-letter searches are the slow case, because a short prefix matches a large share of
    // the history and SQLite then has to rank all of it. Tagged `.slow` so `test.sh --fast`
    // can leave it out: seeding 100,000 items takes a few seconds.
    @Test(.tags(.slow)) func slowSearchOverAHundredThousandItemsStaysWithinItsLimit() async throws {
        try await withStore { store in
            try await store.seed(count: 100_000)
            let clock = ContinuousClock()
            var durations: [Duration] = []
            // "sa" matches every text item (half of them say "Sample"), "me" and "mee" every
            // "meeting", "saf" every Safari copy by app name: each is a large share of the
            // history, too many to score, so they come newest first. "pages 1" matches about
            // 1,400 links, few enough to score. Twenty runs so the 95th percentile means
            // something.
            for query in ["sa", "me", "mee", "saf", "pages 1"] {
                for _ in 0..<4 {
                    let start = clock.now
                    let results = try await store.search(query, limit: 200)
                    durations.append(clock.now - start)
                    #expect(results?.count == 200)
                }
            }
            // p95 of 20 runs: the second slowest must be within the limit.
            let p95 = durations.sorted()[durations.count - 2]
            #expect(p95 < .milliseconds(33), "p95 was \(p95), all: \(durations.sorted())")
            // The broad search was not scored, so its results are simply newest first.
            let times = try await store.search("sa", limit: 200)?.map(\.copiedAt) ?? []
            #expect(times == times.sorted(by: >))
        }
    }

    @Test func pagesComeBackNewestFirstWithNoGaps() async throws {
        try await withStore { store in
            // Seven items with the same copy time: the hardest case for paging, because the time
            // alone cannot order them. Two pages of three plus one of one must still cover each
            // item exactly once, newest first (the last saved has the highest id, so it is first).
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            for i in 0..<7 { try await store.save(copy([.text("item \(i)")], at: t0)) }
            let pages = try await [
                store.items(limit: 3, offset: 0), store.items(limit: 3, offset: 3),
                store.items(limit: 3, offset: 6),
            ]
            #expect(pages.map(\.count) == [3, 3, 1])
            let texts = pages.flatMap { $0 }.map(\.cardText)
            #expect(texts == (0..<7).reversed().map { "item \($0)" })
        }
    }

    @Test func theLiveListDeliversANewCopyAndKeepsToItsLimit() async throws {
        try await withStore { store in
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            try await store.save(copy([.text("old")], at: t0))
            // `makeAsyncIterator` + `next()` is the hand-driven form of `for try await`: each
            // `next()` waits for the next delivery. The first comes at once with what is saved
            // now; the second only after the new copy is written.
            var deliveries = store.observeItems(limit: 2).makeAsyncIterator()
            #expect(try await deliveries.next()?.map(\.cardText) == ["old"])
            try await store.save(copy([.text("new")], at: t0 + 1))
            #expect(try await deliveries.next()?.map(\.cardText) == ["new", "old"])
            // A third item pushes the oldest out: the live list never grows past its limit.
            try await store.save(copy([.text("newest")], at: t0 + 2))
            #expect(try await deliveries.next()?.map(\.cardText) == ["newest", "new"])
        }
    }

    @Test func seedingReplacesTheHistoryWithFakeItemsOfEveryKind() async throws {
        try await withStore { store in
            try await store.save(copy([.text("real")]))
            try await store.seed(count: 20)
            #expect(try await store.count() == 20)
            let items = try await store.items(limit: 20)
            #expect(Set(items.map(\.kind)) == Set(ItemKind.allCases))
            #expect(!items.map(\.cardText).contains("real"))
            // Each fake item has data rows too, so a later paste of one has something to paste.
            #expect(try await store.data(for: items[0].id).count == 1)
        }
    }

    @Test func aSaveComputesTheFooterDetailItCan() async throws {
        try await withStore { store in
            let text = try await store.save(copy([.text("hello world")]))
            #expect(text.cardDetail == "11 characters")
            // An image's detail (its pixel size) needs decoding, which the save leaves to the
            // Enricher: the card shows no detail until then rather than a wrong one.
            let image = try await store.save(copy([.png([1, 2, 3])]))
            #expect(image.cardDetail == nil)
        }
    }

    @Test func aPreviewRoundTripsAndGoesWithItsItem() async throws {
        try await withStore { store in
            let item = try await store.save(copy([.png([1, 2, 3])]))
            #expect(try await store.thumbnail(for: item.id) == nil)
            let thumbnail = CardThumbnail(
                clipboardItemId: item.id, png: Data([9, 8, 7]), width: 3, height: 2)
            try await store.setPreview(CardPreview(thumbnail: thumbnail, detail: "3 × 2"), for: item.id)
            #expect(try await store.thumbnail(for: item.id) == thumbnail)
            #expect(try await store.items(limit: 1).first?.cardDetail == "3 × 2")
            // A second preview replaces the first (one thumbnail per item), and a nil detail
            // keeps the old one.
            let again = CardThumbnail(clipboardItemId: item.id, png: Data([1]), width: 1, height: 1)
            try await store.setPreview(CardPreview(thumbnail: again), for: item.id)
            #expect(try await store.thumbnail(for: item.id) == again)
            #expect(try await store.items(limit: 1).first?.cardDetail == "3 × 2")
            // Deleting the item takes its thumbnail with it, and a preview that arrives for a
            // deleted item (the Enricher finishing late) is dropped, not an error.
            try await store.delete(id: item.id)
            try await store.setPreview(CardPreview(thumbnail: again), for: item.id)
            #expect(try await store.thumbnail(for: item.id) == nil)
        }
    }

    @Test func quickLookGetsTheFileItselfOrTheBytesAsAFile() async throws {
        try await withStore { store in
            let file = try await store.save(copy([.fileURL("/tmp/some.pdf")]))
            #expect(try await store.quickLookFile(for: file)?.path == "/tmp/some.pdf")
            // An image is written out with the extension of its type, so Quick Look opens the
            // right viewer; a text with .txt.
            let image = try await store.save(copy([.png([1, 2, 3])]))
            let url = try #require(try await store.quickLookFile(for: image))
            #expect(url.pathExtension == "png")
            #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
            let text = try await store.save(copy([.text("hi")]))
            #expect(try await store.quickLookFile(for: text)?.pathExtension == "txt")
        }
    }
}

// Proves the Enricher saves what the decoder returns, asks it once per item however many
// cards ask at the same time, and never reads the bytes of a text. The decoder is a closure
// here (the real one needs AppKit); it counts its calls and returns a fixed preview.
struct EnricherTests {
    let folder = TemporaryFolder()

    @Test func savesThePreviewAndDecodesEachItemOnce() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let calls = Mutex(0)
        let enricher = Enricher(store: store) { item, data in
            calls.withLock { $0 += 1 }
            // Hold on, so the second caller arrives while the first is still decoding.
            try? await Task.sleep(for: .milliseconds(50))
            return CardPreview(
                thumbnail: CardThumbnail(clipboardItemId: item.id, png: data[0].data, width: 1, height: 1),
                detail: "decoded")
        }
        let item = try await store.save(
            CapturedCopy(data: [.png([4, 2])], sourceApp: nil, copiedAt: .now))
        async let first = enricher.enrich(item)
        async let second = enricher.enrich(item)
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(calls.withLock { $0 } == 1)
        #expect(try await store.thumbnail(for: item.id)?.png == Data([4, 2]))
        #expect(try await store.items(limit: 1).first?.cardDetail == "decoded")
        // Done: the next ask decodes again (a thumbnail lost to a corrupt row, say).
        try await enricher.enrich(item)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func textsAndLinksAreNotDecoded() async throws {
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let enricher = Enricher(store: store) { _, _ in
            Issue.record("a text must not be decoded")
            return nil
        }
        let item = try await store.save(
            CapturedCopy(data: [.text("plain")], sourceApp: nil, copiedAt: .now))
        #expect(try await enricher.enrich(item) == nil)
    }
}
