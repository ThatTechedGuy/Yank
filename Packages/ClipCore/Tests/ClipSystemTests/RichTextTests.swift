import AppKit
import ClipCore
import Testing

@testable import ClipSystem

// Proves formatting survives the trip through the editor: a bold word written as RTF comes
// back bold when the RTF is read again, and a copy with only plain text opens as plain text.
// The RTF is checked with AppKit's own reader, not the exporter's twin, so an exporter that
// wrote a font name the rest of the Mac does not understand would fail here.
struct RichTextTests {
    @Test func boldSurvivesTheRoundTripThroughRTF() async throws {
        var text = AttributedString("plain ")
        var bold = AttributedString("bold")
        bold.inlinePresentationIntent = .stronglyEmphasized
        text += bold

        let data = try await RichText.clipboardData(for: text)
        #expect(data.map(\.type) == [RichText.rtfType, ClipboardType.plainText])
        #expect(data[1].text == "plain bold")
        // AppKit reads the RTF: the second word's font carries the bold trait, the first's not.
        let read = try #require(NSAttributedString(rtf: data[0].data, documentAttributes: nil))
        let fontTraits = { (location: Int) in
            (read.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?
                .fontDescriptor.symbolicTraits
        }
        #expect(fontTraits(0)?.contains(.bold) == false)
        #expect(fontTraits(7)?.contains(.bold) == true)

        // And back into the editor: still two runs, the second one in a bold font.
        let reopened = try await RichText.attributedString(from: data)
        #expect(String(reopened.characters) == "plain bold")
        #expect(reopened.runs.count == 2)
    }

    @Test func aPlainTextCopyOpensAsPlainText() async throws {
        let text = try await RichText.attributedString(from: [
            ClipboardItemData(type: ClipboardType.plainText, data: Data("just words".utf8))
        ])
        #expect(String(text.characters) == "just words")
        #expect(text.runs.count == 1)
        #expect(try await RichText.attributedString(from: []).characters.isEmpty)
    }
}
