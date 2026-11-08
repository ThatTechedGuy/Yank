// Tests for the pure rules that decide what happens to a copy: skip it, what kind it is, what
// the menu shows for it, and when two copies count as the same. These rules take plain values
// and return plain values, so the tests need no fakes and no disk. The framework is Swift
// Testing (≈ Jest / JUnit 5): `@Test` marks a test, `#expect` checks a condition and prints
// both sides when it fails. Run with `swift test` or scripts/test.sh --fast.
import Foundation
import Testing

@testable import ClipCore

// Proves the privacy rules keep secrets out of the history: a copy that an app marks as
// private, or that comes from an app the user chose to ignore, is skipped. The rules only see
// type names and the app's bundle id, never the content, so the decision costs no read. One
// suite per rule; test names describe the behaviour.
struct PrivacyRulesTests {
    let rules = PrivacyRules()

    // Every marker type the app knows about must cause a skip, so each one gets its own run.
    // (`arguments:` runs the test once per value, ≈ Jest's `test.each`; a failing marker shows
    // by name in the report.)
    @Test(arguments: PrivacyRules.markerTypes)
    func copiesWithAMarkerTypeAreSkipped(marker: String) {
        let types = [ClipboardType.plainText, marker]
        #expect(rules.decision(types: types, sourceApp: "com.apple.TextEdit") == .skip)
    }

    // The rules ship with no ignored apps at all: an unmarked copy is saved whoever sent it,
    // even a password manager, until the user adds that app. This pins that choice down so a
    // built-in list can't creep back in unnoticed.
    @Test func noAppIsIgnoredByDefault() {
        let types = [ClipboardType.plainText]
        #expect(rules.ignoredApps.isEmpty)
        #expect(rules.decision(types: types, sourceApp: "com.1password.1password") == .save)
        #expect(rules.decision(types: types, sourceApp: nil) == .save)
    }

    @Test func ownPastesAreRecognised() {
        let types = [ClipboardType.plainText, rules.ownMarker]
        #expect(rules.decision(types: types, sourceApp: nil) == .moveOwnPasteToTop)
    }

    // Only apps the user added are skipped, and only by exact bundle id.
    @Test func copiesFromAppsTheUserIgnoresAreSkipped() {
        let custom = PrivacyRules(ignoredApps: ["com.example.secret"])
        #expect(custom.decision(types: [], sourceApp: "com.example.secret") == .skip)
        #expect(custom.decision(types: [], sourceApp: "com.apple.TextEdit") == .save)
        #expect(custom.decision(types: [], sourceApp: nil) == .save)
    }
}

// Proves a pause ends when it should and not before: a timed pause is over the moment its end
// time passes, and "until resumed" never ends on its own. The state carries no clock, so each
// check passes a made-up time; nothing waits.
struct PauseStateTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func aTimedPauseEndsAfterItsDuration() {
        let state = PauseState.paused(for: .seconds(15 * 60), from: start)
        #expect(state == .pausedUntil(start + 15 * 60))
        #expect(state.isPaused(at: start))
        #expect(state.isPaused(at: start + 15 * 60 - 1))
        // At exactly 15 minutes the pause is over: the end time itself is not paused.
        #expect(!state.isPaused(at: start + 15 * 60))
        #expect(!state.isPaused(at: start + 24 * 60 * 60))
    }

    @Test func untilResumedNeverEndsOnItsOwnAndRunningIsNeverPaused() {
        #expect(PauseState.pausedUntilResumed.isPaused(at: start + 365 * 24 * 60 * 60))
        #expect(!PauseState.running.isPaused(at: start))
    }
}

struct KindDetectionTests {
    @Test func plainTextIsText() {
        #expect(ItemKind.detect([.text("hello")]) == .text)
    }

    @Test func aUrlTypeIsALink() {
        #expect(ItemKind.detect([.url("https://a.com"), .text("https://a.com")]) == .link)
    }

    @Test func textThatIsExactlyOneWebAddressIsALink() {
        #expect(ItemKind.detect([.text("https://example.com/path?q=1")]) == .link)
        #expect(ItemKind.detect([.text("  http://example.com\n")]) == .link)
        // A very long text is never a single address, and is answered without parsing it.
        #expect(ItemKind.detect([.text("https://a.com/" + String(repeating: "x", count: 5000))]) == .text)
    }

    @Test func aSentenceContainingAnAddressIsText() {
        #expect(ItemKind.detect([.text("see https://example.com for details")]) == .text)
        // Only a full http(s) address counts as a link. A mail address or a scheme with nothing
        // after it is not something the user can open in a browser, so both stay plain text.
        #expect(ItemKind.detect([.text("mailto:a@b.com")]) == .text)
        #expect(ItemKind.detect([.text("https://")]) == .text)
    }

    @Test func fileUrlsBeatTheFileNameText() {
        #expect(ItemKind.detect([.fileURL("/tmp/a.png"), .text("a.png")]) == .file)
    }

    @Test func imagesBeatTheirUrl() {
        #expect(ItemKind.detect([.png([1]), .url("https://a.com/a.png")]) == .image)
    }

    @Test func coloursAreColours() {
        #expect(ItemKind.detect([.marker(ClipboardType.color)]) == .color)
    }
}

struct CardTextTests {
    @Test func whitespaceIsCollapsedAndTextIsCut() {
        let text = "  line one\n\n\t  line two  " + String(repeating: "x", count: 300)
        let card = CardText.make(kind: .text, data: [.text(text)])
        #expect(card.hasPrefix("line one line two x"))
        #expect(card.count == CardText.maxLength)
    }

    @Test func filesShowTheirNamesOnePerLine() {
        let data: [ClipboardItemData] = [.fileURL("/tmp/a b.txt", item: 0), .fileURL("/tmp/c.png", item: 1)]
        #expect(CardText.make(kind: .file, data: data) == "a b.txt\nc.png")
    }

    @Test func imagesHaveNoCardTextUnlessTheyCarrySome() {
        #expect(CardText.make(kind: .image, data: [.png([1])]) == "")
        #expect(CardText.make(kind: .image, data: [.png([1]), .text("photo.png")]) == "photo.png")
    }

    @Test func aLinkWithOnlyAUrlTypeShowsTheAddress() {
        // Some apps copy a link as the URL type alone, with no plain text. The card must still
        // show the address, not come up blank.
        #expect(CardText.make(kind: .link, data: [.url("https://a.com/x")]) == "https://a.com/x")
    }

    @Test func aHugeTextStillGetsACardQuickly() {
        // A copied log file of many megabytes must not be split into words in full just to show
        // 200 characters. Only the start is looked at, and the card is still correct.
        let text = "start here " + String(repeating: "word ", count: 2_000_000)
        let card = CardText.make(kind: .text, data: [.text(text)])
        #expect(card.hasPrefix("start here word"))
        #expect(card.count == CardText.maxLength)
    }
}

struct DuplicateKeyTests {
    @Test func sameTextWithDifferentExtraTypesIsTheSameKey() {
        let a = DuplicateKey.make(kind: .text, data: [.text("hi"), .marker("public.rtf")])
        let b = DuplicateKey.make(kind: .text, data: [.text("hi")])
        #expect(a == b)
        #expect(a.count == 64)  // The key is a SHA-256 hash written as hex: 32 bytes, 64 characters.
    }

    @Test func differentContentIsADifferentKey() {
        #expect(
            DuplicateKey.make(kind: .text, data: [.text("hi")])
                != DuplicateKey.make(kind: .text, data: [.text("hi!")]))
        #expect(
            DuplicateKey.make(kind: .image, data: [.png([1, 2])])
                != DuplicateKey.make(kind: .image, data: [.png([1, 3])]))
    }

    @Test func aLinkIsTheSameKeyWithOrWithoutSurroundingWhitespace() {
        // The address bar copies "https://a.com"; a chat message copies "https://a.com\n". Both
        // are the same link to the user, so they must be one item.
        let bare = DuplicateKey.make(kind: .link, data: [.text("https://a.com")])
        let withNewline = DuplicateKey.make(kind: .link, data: [.text("https://a.com\n")])
        #expect(bare == withNewline)
    }

    @Test func theKindIsPartOfTheKey() {
        // Copying the text "file:///tmp/a" and copying the file /tmp/a produce the same bytes, but
        // they are different things to the user and must not collapse into one history item.
        // Mixing the kind into the hash keeps them apart.
        let text = DuplicateKey.make(kind: .text, data: [.text(URL(filePath: "/tmp/a").absoluteString)])
        let file = DuplicateKey.make(kind: .file, data: [.fileURL("/tmp/a")])
        #expect(text != file)
    }
}

// The footer line and the counts behind the large preview. Each case is one the card could
// get wrong: the singular, a file that is gone, a site with "www.", a kind that must wait.
struct CardDetailTests {
    @Test func textsCountTheirCharactersWithTheRightPlural() {
        #expect(CardDetail.make(kind: .text, data: [.text("x")]) == "1 character")
        #expect(CardDetail.make(kind: .text, data: [.text("héllo 👋🏽")]) == "7 characters")
    }

    @Test func filesShowTheirSizeOrTheirCount() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let file = folder.url.appending(path: "a.bin")
        try Data(repeating: 0, count: 2048).write(to: file)
        // "2 KB" or "2 kB", whichever the Mac's locale writes.
        #expect(CardDetail.make(kind: .file, data: [.fileURL(file.path)])?.lowercased() == "2 kb")
        #expect(
            CardDetail.make(kind: .file, data: [.fileURL("/tmp/a"), .fileURL("/tmp/b", item: 1)]) == "2 files"
        )
        // A file deleted since the copy has no size; the card shows nothing rather than "0 B".
        #expect(CardDetail.make(kind: .file, data: [.fileURL("/tmp/does-not-exist-\(UUID())")]) == nil)
    }

    @Test func linksShowTheirSiteWithoutWWW() {
        #expect(CardDetail.make(kind: .link, data: [.text(" https://www.apple.com/mac \n")]) == "apple.com")
        #expect(CardDetail.make(kind: .link, data: [.url("https://ampcode.com/x")]) == "ampcode.com")
    }

    @Test func imagesAndColoursWaitForTheEnricher() {
        #expect(CardDetail.make(kind: .image, data: [.png([1])]) == nil)
        #expect(CardDetail.make(kind: .color, data: [.marker(ClipboardType.color)]) == nil)
    }

    @Test func wordsAreRunsOfNonWhitespace() {
        let counts = TextCounts("don't  stop\nat 3 pm —")
        #expect(counts.words == 6)
        #expect(counts.characters == 21)
        #expect(TextCounts("a").description == "1 character · 1 word")
    }
}

// Proves the date ranges start at local midnight and count calendar days, with the clock and
// the calendar fixed so the answers never depend on when or where the test runs. Each test
// builds moments in UTC (`utc`) and asks where a range starts for a calendar in some time zone.
struct DateRangeTests {
    func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func calendar(in zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    // 23:30 UTC on 8 November is already 09:30 on the 9th in Brisbane (UTC+10, no summer
    // time), so "today" is the 9th there and starts ten hours before its UTC midnight.
    @Test func todayIsTheLocalDayNotTheUTCOne() {
        let now = utc(2026, 11, 8, 23, 30)
        let brisbane = calendar(in: "Australia/Brisbane")
        #expect(DateRange.today.start(now: now, calendar: brisbane) == utc(2026, 11, 8, 14))
        #expect(DateRange.lastSevenDays.start(now: now, calendar: brisbane) == utc(2026, 11, 2, 14))
        #expect(DateRange.lastThirtyDays.start(now: now, calendar: brisbane) == utc(2026, 10, 10, 14))
        #expect(DateRange.anyTime.start(now: now, calendar: brisbane) == nil)
    }

    // New York's clocks went back on 1 November 2026, so that day was 25 hours long. At noon
    // (now EST, UTC−5) the day began 13 hours earlier at midnight EDT (UTC−4), not 12.
    @Test func theDayTheClocksChangeStartsAtItsOwnMidnight() throws {
        let noon = utc(2026, 11, 1, 17)
        let newYork = calendar(in: "America/New_York")
        let start = try #require(DateRange.today.start(now: noon, calendar: newYork))
        #expect(start == utc(2026, 11, 1, 4))
        #expect(noon.timeIntervalSince(start) == 13 * 3600)
    }

    // Counting back across the change: seven days back from 2 November reaches 27 October,
    // whose midnight was still on summer time. Six blocks of 24 hours would land an hour late.
    @Test func sevenDaysBackAcrossTheChangeIsSevenCalendarDays() {
        let now = utc(2026, 11, 2, 17)
        let newYork = calendar(in: "America/New_York")
        #expect(DateRange.today.start(now: now, calendar: newYork) == utc(2026, 11, 2, 5))
        #expect(DateRange.lastSevenDays.start(now: now, calendar: newYork) == utc(2026, 10, 27, 4))
        #expect(DateRange.lastThirtyDays.start(now: now, calendar: newYork) == utc(2026, 10, 4, 4))
    }
}

struct PanelHeightTests {
    @Test func heightsOutsideTheLimitsArePulledBack() {
        #expect(PanelHeight.clamped(10) == PanelHeight.minimum)
        #expect(PanelHeight.clamped(9999) == PanelHeight.maximum)
        #expect(PanelHeight.clamped(300) == 300)
        #expect(PanelHeight.clamped(PanelHeight.initial) == PanelHeight.initial)
    }
}
