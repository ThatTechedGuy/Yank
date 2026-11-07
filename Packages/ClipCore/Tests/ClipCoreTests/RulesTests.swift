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
