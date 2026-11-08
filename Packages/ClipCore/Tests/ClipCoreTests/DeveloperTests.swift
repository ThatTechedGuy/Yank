import Foundation
import Testing

@testable import ClipCore

// Proves the numbers the Developer window shows are right: a CPU percentage computed from two
// samples, timing markers that remember their last durations, and a read-only snapshot of the
// database that only does work when something was written.
struct DeveloperTests {
    @Test func cpuPercentIsCpuTimeOverWallTime() {
        let start = ContinuousClock.now
        let earlier = ProcessSample(cpuTime: .seconds(5), footprint: 0, takenAt: start)
        // 200 ms of CPU time in 1 s of wall time is one fifth of one core.
        let later = ProcessSample(
            cpuTime: .seconds(5) + .milliseconds(200), footprint: 0, takenAt: start + .seconds(1))
        #expect(later.cpuPercent(since: earlier) == 20)
        // Two samples at the same instant cannot be divided; they read as idle, not infinite.
        #expect(earlier.cpuPercent(since: earlier) == 0)
    }

    @Test func currentSampleReadsRealNumbers() {
        let sample = ProcessSample.current()
        #expect(sample.footprint > 0)
        #expect(sample.cpuTime > .zero)
    }

    @Test func timingMarkersKeepTheLastDurationsPerName() {
        let timing = TimingSignposter(subsystem: "test", category: "timing")
        for _ in 0..<(TimingSignposter.keptPerName + 5) {
            timing.endInterval("Open panel", timing.beginInterval("Open panel"))
        }
        let state = timing.beginInterval("Search")
        timing.endInterval("Search", state)
        let intervals = timing.recentIntervals
        // The extra five "Open panel" intervals pushed out the oldest five; "Search" is untouched.
        #expect(intervals.count(where: { $0.name == "Open panel" }) == TimingSignposter.keptPerName)
        #expect(intervals.count(where: { $0.name == "Search" }) == 1)
        #expect(intervals.last?.name == "Search")
        #expect(intervals.allSatisfy { $0.duration >= .zero })
    }

    @Test func snapshotCountsItemsAndSkipsWorkWhenNothingChanged() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let app = SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")
        try await store.save(CapturedCopy(data: [.text("hello")], sourceApp: app, copiedAt: .now))
        try await store.save(
            CapturedCopy(data: [.text("https://example.com")], sourceApp: app, copiedAt: .now))

        let inspector = try StoreInspector(folder: folder.url)
        let first = try #require(try await inspector.snapshot(ifChangedSince: nil))
        #expect(first.itemCount == 2)
        #expect(first.countsByKind == [.text: 1, .link: 1])
        #expect(first.searchIndexRowCount == 2)
        #expect(first.databaseBytes > 0)

        // Nothing written since: no snapshot, no work.
        #expect(try await inspector.snapshot(ifChangedSince: first.dataVersion) == nil)

        try await store.save(CapturedCopy(data: [.text("again")], sourceApp: app, copiedAt: .now))
        let second = try #require(
            try await inspector.snapshot(ifChangedSince: first.dataVersion))
        #expect(second.itemCount == 3)
    }

    @Test func tablesAreDiscoveredAndPagedAsPlainCells() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let store = try Store(folder: folder.url)
        let app = SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")
        for word in ["one", "two", "three"] {
            try await store.save(CapturedCopy(data: [.text(word)], sourceApp: app, copiedAt: .now))
        }

        let inspector = try StoreInspector(folder: folder.url)
        let list = try #require(try await inspector.tables(ifChangedSince: nil))
        let byName = Dictionary(uniqueKeysWithValues: list.tables.map { ($0.name, $0) })
        // The app's tables, the search index, and the ones SQLite and GRDB keep for themselves.
        for name in [
            "clipboardItem", "clipboardItemData", "cardThumbnail", "pinboard",
            "clipboardItemSearchIndex", "grdb_migrations", "sqlite_sequence",
        ] {
            #expect(byName[name] != nil, "\(name) missing")
        }
        #expect(byName["clipboardItem"]?.rowCount == 3)
        #expect(byName["clipboardItem"]?.columns.first == .init(name: "id", type: "INTEGER"))
        #expect(byName["clipboardItemData"]?.columns.contains { $0.name == "data" } == true)
        #expect(try await inspector.tables(ifChangedSince: list.dataVersion) == nil)

        // Page 2 of size 2 holds the one remaining row; the text blob previews as its text.
        let items = try await inspector.page(of: "clipboardItem", offset: 2, limit: 2)
        #expect(items.rows.count == 1)
        let columns = try #require(byName["clipboardItem"]?.columns.map(\.name))
        #expect(items.rows[0][columns.firstIndex(of: "cardText")!] == .text("three"))
        #expect(items.rows[0][columns.firstIndex(of: "title")!] == .null)
        let data = try await inspector.page(of: "clipboardItemData", offset: 0, limit: 1)
        let dataColumns = try #require(byName["clipboardItemData"]?.columns.map(\.name))
        #expect(
            data.rows[0][dataColumns.firstIndex(of: "data")!]
                == .blob(byteCount: 3, preview: .text("one")))
    }
}
