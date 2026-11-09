import Foundation
import GRDB
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

    @Test func pinboardsKeepTheirCreationOrderAndRename() async throws {
        try await withStore { store in
            let work = try await store.createPinboard(named: "Work")
            let snippets = try await store.createPinboard(named: "Snippets")
            #expect(try await store.pinboards().map(\.name) == ["Work", "Snippets"])
            #expect(snippets.position == work.position + 1)
            try await store.renamePinboard(id: work.id, to: "Office")
            #expect(try await store.pinboards().map(\.name) == ["Office", "Snippets"])
            // Deleting the first does not move the second: positions are not renumbered.
            try await store.deletePinboard(id: work.id)
            #expect(try await store.pinboards() == [snippets])
        }
    }

    // Pinning moves an item from the History tab to the pinboard's tab; unpinning or deleting
    // the pinboard moves it back. Every list here is read through the same filters the panel
    // uses, so the tabs show what this test shows.
    @Test func pinningMovesAnItemBetweenHistoryAndItsPinboard() async throws {
        try await withStore { store in
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            let a = try await store.save(copy([.text("a")], at: t0))
            let b = try await store.save(copy([.text("b")], at: t0 + 1))
            let board = try await store.createPinboard(named: "Snippets")
            let history = ItemFilter()
            let onBoard = ItemFilter(list: .pinboard(id: board.id))
            func texts(_ filter: ItemFilter) async throws -> [String] {
                var list = store.observeItems(matching: filter, limit: 10).makeAsyncIterator()
                return try await list.next()?.map(\.cardText) ?? []
            }

            try await store.pin(itemId: a.id, to: board.id)
            #expect(try await texts(history) == ["b"])
            #expect(try await texts(onBoard) == ["a"])
            // A repeat copy of a pinned item moves it up but keeps it pinned.
            try await store.save(copy([.text("a")], at: t0 + 2))
            #expect(try await texts(history) == ["b"])
            #expect(try await texts(onBoard) == ["a"])
            // Pinning to a pinboard that no longer exists is a quiet no-op.
            try await store.pin(itemId: b.id, to: board.id + 100)
            #expect(try await texts(history) == ["b"])

            try await store.unpin(itemId: a.id)
            #expect(try await texts(history) == ["a", "b"])
            #expect(try await texts(onBoard) == [])

            try await store.pin(itemId: b.id, to: board.id)
            try await store.deletePinboard(id: board.id)
            #expect(try await texts(history) == ["a", "b"])
            #expect(try await store.pinboards().isEmpty)
        }
    }

    // The kind and date filters narrow both the live list and the search, and the search only
    // sees the tab it is on. Dates are relative to the real clock here because the Store reads
    // it; the exact day maths is proven in DateRangeTests.
    @Test func kindAndDateFiltersNarrowTheListAndTheSearch() async throws {
        try await withStore { store in
            let now = Date()
            let old = Calendar.current.date(byAdding: .day, value: -40, to: now)!
            try await store.save(copy([.text("quarterly report")], at: now - 2))
            try await store.save(copy([.text("quarterly old")], at: old))
            try await store.save(copy([.url("https://quarterly.example")], at: now - 1))
            let board = try await store.createPinboard(named: "Keep")
            let pinned = try await store.save(copy([.text("quarterly pinned")], at: now))
            try await store.pin(itemId: pinned.id, to: board.id)
            func texts(_ filter: ItemFilter) async throws -> [String] {
                var list = store.observeItems(matching: filter, limit: 10).makeAsyncIterator()
                return try await list.next()?.map(\.cardText) ?? []
            }

            #expect(try await texts(ItemFilter(kind: .text)) == ["quarterly report", "quarterly old"])
            #expect(
                try await texts(ItemFilter(dateRange: .lastThirtyDays)) == [
                    "https://quarterly.example", "quarterly report",
                ])
            #expect(try await texts(ItemFilter(kind: .text, dateRange: .today)) == ["quarterly report"])
            #expect(try await texts(ItemFilter(list: .pinboard(id: board.id), kind: .link)) == [])

            let today = ItemFilter(kind: .text, dateRange: .today)
            #expect(
                try await store.search("quart", matching: today, limit: 10)?.map(\.cardText) == [
                    "quarterly report"
                ])
            #expect(try await store.search("quart", limit: 10)?.count == 3)
            let onBoard = ItemFilter(list: .pinboard(id: board.id))
            #expect(
                try await store.search("quart", matching: onBoard, limit: 10)?.map(\.cardText) == [
                    "quarterly pinned"
                ])
        }
    }

    // Erase removes the unpinned items with their files and shrinks the database file, and
    // leaves pinned items alone.
    @Test func eraseHistoryKeepsPinnedItemsAndShrinksTheFile() async throws {
        try await withStore { store in
            let big = Data((0..<2_000_000).map { UInt8($0 % 251) })
            let pinned = try await store.save(copy([.text("keep me")], at: .now - 2))
            try await store.save(copy([ClipboardItemData(type: "public.png", data: big)], at: .now - 1))
            // Enough small items that deleting them frees whole pages, so the file can shrink.
            for i in 0..<200 {
                try await store.save(copy([.text(String(repeating: "x", count: 5_000) + "\(i)")]))
            }
            let board = try await store.createPinboard(named: "Snippets")
            try await store.pin(itemId: pinned.id, to: board.id)
            let databaseFile = folder.url.appending(path: "yank.sqlite")
            let queue = try DatabaseQueue(path: databaseFile.path)
            // Move everything from the write-ahead log into the main file first, so "before" is
            // the file's full size and not whatever an automatic checkpoint had copied so far.
            _ = try await queue.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
            try queue.close()
            let sizeBefore =
                try FileManager.default.attributesOfItem(atPath: databaseFile.path)[.size] as? Int
            #expect(try largeFiles().count == 1)

            try await store.eraseHistory()

            #expect(try await store.items(limit: 10).map(\.cardText) == ["keep me"])
            #expect(try await store.data(for: pinned.id).map(\.text) == ["keep me"])
            #expect(try largeFiles().isEmpty)
            let sizeAfter = try FileManager.default.attributesOfItem(atPath: databaseFile.path)[.size] as? Int
            #expect(sizeAfter ?? 0 < sizeBefore ?? 0)
            // The search index was kept in step by its triggers: the erased text is gone from it.
            #expect(try await store.search("xxxx", limit: 10)?.isEmpty == true)
        }
    }

    @Test func renameShowsInSearchAndABlankNameClearsIt() async throws {
        try await withStore { store in
            let item = try await store.save(copy([.text("1 Infinite Loop, Cupertino")]))
            try await store.rename(id: item.id, to: "  Home address ")
            // The title is stored trimmed, and the index's UPDATE trigger picked it up.
            #expect(try await store.items(limit: 1).first?.title == "Home address")
            #expect(try await found("home", in: store) == ["1 Infinite Loop, Cupertino"])
            try await store.rename(id: item.id, to: "   ")
            #expect(try await store.items(limit: 1).first?.title == nil)
            #expect(try await found("home", in: store) == [])
        }
    }

    @Test func duplicateIsASeparateItemAndARepeatCopyMovesTheNewestOne() async throws {
        try await withStore { store in
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            let big = Data((0..<2_000_000).map { UInt8($0 % 251) })
            let original = try await store.save(
                copy([ClipboardItemData(type: "public.png", data: big), .text("same")], at: t0))
            try await store.rename(id: original.id, to: "Logo")
            try await store.save(copy([.text("other")], at: t0 + 1))

            let twin = try #require(try await store.duplicate(id: original.id))
            #expect(twin.id != original.id)
            #expect(twin.title == "Logo")
            #expect(try await store.items(limit: 3).map(\.id) == [twin.id, original.id + 1, original.id])
            // The copy has its own bytes and its own file: deleting it leaves the original's.
            #expect(try await store.data(for: twin.id) == (try await store.data(for: original.id)))
            #expect(try largeFiles().count == 2)

            // Copying the same content again moves the newest of the two, not the original.
            let again = try await store.save(
                copy([ClipboardItemData(type: "public.png", data: big), .text("same")]))
            #expect(again.id == twin.id)
            #expect(try await store.count() == 3)

            try await store.delete(id: twin.id)
            #expect(try largeFiles().count == 1)
            #expect(try await store.data(for: original.id).count == 2)
        }
    }

    @Test func replacingDataKeepsTheItemAndItsPlaceButChangesTheBytes() async throws {
        try await withStore { store in
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            let big = Data(repeating: 7, count: 1_500_000)
            let original = try await store.save(
                copy([ClipboardItemData(type: "public.png", data: big)], at: t0))
            try await store.rename(id: original.id, to: "Logo")
            try await store.save(copy([.text("newer")], at: t0 + 1))

            // The image becomes a text: same row, new bytes, kind, card text and fingerprint.
            let replaced = try #require(
                try await store.replaceData(for: original.id, with: [.text("edited")]))
            #expect(replaced.id == original.id)
            #expect(replaced.kind == .text)
            #expect(replaced.cardText == "edited")
            #expect(replaced.title == "Logo")
            #expect(replaced.contentFingerprint != original.contentFingerprint)
            #expect(try await store.data(for: original.id).map(\.text) == ["edited"])
            // It stays where it was in the list (second), and the old large file is gone.
            #expect(try await store.items(limit: 3).map(\.cardText) == ["newer", "edited"])
            #expect(try largeFiles().isEmpty)
            // The new fingerprint is live: copying the edited text again moves this item, and
            // copying the old bytes again makes a new item.
            #expect(try await store.save(copy([.text("edited")])).id == original.id)
            let repeatCopy = try await store.save(copy([ClipboardItemData(type: "public.png", data: big)]))
            #expect(repeatCopy.id != original.id)

            // A deleted item is left alone, and the file written for the attempt is removed.
            try await store.delete(id: original.id)
            let gone = try await store.replaceData(
                for: original.id, with: [ClipboardItemData(type: "public.png", data: big)])
            #expect(gone == nil)
            #expect(try largeFiles().count == 1)
        }
    }

    @Test func savingAnEditedCopyLeavesTheOriginalAlone() async throws {
        try await withStore { store in
            let original = try await store.save(copy([.text("draft"), .marker("public.rtf")]))
            let edited = try await store.save(copy([.text("draft, final")]))
            #expect(edited.id != original.id)
            let originalTypes = try await store.data(for: original.id).map(\.type)
            #expect(originalTypes == [ClipboardType.plainText, "public.rtf"])
            #expect(try await store.data(for: original.id)[0].text == "draft")
            #expect(try await store.items(limit: 2).map(\.id) == [edited.id, original.id])
        }
    }

    @Test func deletingSeveralRemovesThemAllAtOnce() async throws {
        try await withStore { store in
            let big = Data((0..<2_000_000).map { UInt8($0 % 251) })
            let a = try await store.save(
                copy([ClipboardItemData(type: "public.png", data: big)], at: .now - 3))
            let b = try await store.save(copy([.text("b")], at: .now - 2))
            let c = try await store.save(copy([.text("c")], at: .now - 1))
            // The live list delivers the result of the delete in one go: the delivery after
            // the delete is already down to the one remaining item, never a halfway state.
            var deliveries = store.observeItems(limit: 10).makeAsyncIterator()
            #expect(try await deliveries.next()?.map(\.id) == [c.id, b.id, a.id])
            try await store.delete(ids: [a.id, c.id])
            #expect(try await deliveries.next()?.map(\.id) == [b.id])
            #expect(try largeFiles().isEmpty)
            #expect(try await store.data(for: a.id).isEmpty)
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

    @Test func deletingAndErasingRemoveTheTemporaryCopies() async throws {
        try await withStore { store in
            let image = try await store.save(copy([.png([1, 2, 3])]))
            let imageFile = try #require(try await store.quickLookFile(for: image))
            try await store.delete(id: image.id)
            #expect(!FileManager.default.fileExists(atPath: imageFile.path))
            let text = try await store.save(copy([.text("private")]))
            let textFile = try #require(try await store.quickLookFile(for: text))
            try await store.eraseHistory()
            #expect(!FileManager.default.fileExists(atPath: textFile.path))
        }
    }

    // A word far beyond the 200 characters on the card is still found, and an edit that takes
    // the word away takes it out of the index too.
    @Test func searchSeesBeyondTheCardText() async throws {
        try await withStore { store in
            let text = "opening " + String(repeating: "word ", count: 100) + "deepword"
            let item = try await store.save(copy([.text(text)]))
            #expect(item.cardText.count <= CardText.maxLength)
            #expect(try await store.search("deepword", limit: 10)?.map(\.id) == [item.id])
            _ = try await store.replaceData(for: item.id, with: [.text("short now")])
            #expect(try await store.search("deepword", limit: 10)?.isEmpty == true)
        }
    }

    // A database made before v4 has only short card text in its index. After the migration a
    // word deep in an existing text item can be found.
    @Test func migrationFourIndexesTheFullTextOfExistingItems() async throws {
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: folder.url.appending(path: "yank.sqlite").path)
        try Migrations.migrator.migrate(queue, upTo: "v3")
        let text = "opening " + String(repeating: "word ", count: 100) + "deepword"
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO clipboardItem (kind, cardText, createdAt, copiedAt, contentFingerprint)
                    VALUES ('text', 'opening', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000', 'old')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO clipboardItemData (clipboardItemId, pasteboardItemIndex, position, type, data)
                    VALUES (1, 0, 0, ?, ?)
                    """, arguments: [ClipboardType.plainText, Data(text.utf8)])
        }
        try queue.close()
        let store = try Store(folder: folder.url)
        #expect(try await store.search("deepword", limit: 10)?.count == 1)
    }

    // Two different links that share a label ("click here") are two items, and each card shows
    // its own address.
    @Test func linksWithTheSameLabelStaySeparate() async throws {
        try await withStore { store in
            let first = try await store.save(copy([.url("https://a.example/one"), .text("click here")]))
            let second = try await store.save(copy([.url("https://b.example/two"), .text("click here")]))
            #expect(first.id != second.id)
            #expect(first.cardText == "https://a.example/one")
            #expect(try await store.count() == 2)
        }
    }

    // "Keep history": old unpinned items go, with their large files; recent and pinned ones stay.
    @Test func expiringRemovesOnlyOldUnpinnedItems() async throws {
        try await withStore { store in
            let now = Date()
            let old = now - 100 * 86_400
            let big = ClipboardItemData(type: "public.png", data: Data(repeating: 1, count: 1_000_001))
            try await store.save(copy([big], at: old))
            #expect(try largeFiles().count == 1)
            let pinned = try await store.save(copy([.text("pinned and old")], at: old))
            let recent = try await store.save(copy([.text("recent")], at: now))
            let board = try await store.createPinboard(named: "Keep")
            try await store.pin(itemId: pinned.id, to: board.id)
            try await store.deleteUnpinned(copiedBefore: now - 90 * 86_400)
            #expect(try await store.items(limit: 10).map(\.id) == [recent.id, pinned.id])
            #expect(try largeFiles().isEmpty)
        }
    }
}
