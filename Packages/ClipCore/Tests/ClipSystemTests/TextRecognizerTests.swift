import AppKit
import ClipCore
import Testing

@testable import ClipSystem

// Proves a screenshot becomes searchable by its words: a picture of a sentence is drawn in the
// test, saved to a real Store as an image copy, read by Vision through the Enricher, and then
// found by searching for one of its words. Real Vision, because the model call is what could
// be wrong; the picture is drawn here so the test needs no file. Vision takes tens of seconds
// the first time it loads its model, so the search test is a "slow" one that `test.sh --fast`
// skips.
struct TextRecognizerTests {
    /// Black text on a white picture, as a PNG. Drawn with Core Graphics so the size is in pixels.
    func picture(saying text: String) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 900, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 160))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black]
        ).draw(at: NSPoint(x: 30, y: 55))
        NSGraphicsContext.current = nil
        let image = try #require(context.makeImage())
        return try #require(Thumbnailer.pngData(image))
    }

    @Test func slowWordsInAnImageAreFoundBySearch() async throws {
        let folder = URL.temporaryDirectory.appending(path: "YankTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try Store(folder: folder)
        let copy = CapturedCopy(
            data: [
                ClipboardItemData(type: "public.png", data: try picture(saying: "Quarterly revenue grew"))
            ],
            sourceApp: nil, copiedAt: .now)
        let item = try await store.save(copy)
        #expect(item.kind == .image)
        let enricher = Enricher(
            store: store, makePreview: Thumbnailer.preview, recognizeText: TextRecognizer.text(in:))
        try await enricher.recognizeText(in: item)
        let found = try await store.search("revenue", limit: 10)
        #expect(found?.map(\.id) == [item.id])
        #expect(found?.first?.imageText?.contains("Quarterly") == true)
    }

    @Test func aPictureWithoutWordsHasNoText() async throws {
        let blank = try picture(saying: "")
        #expect(await TextRecognizer.text(in: blank) == nil)
        #expect(await TextRecognizer.text(in: Data("not an image".utf8)) == nil)
    }
}
