import AppKit
import ClipCore
import Testing

@testable import ClipSystem

// Proves the real decoders give a card what it shows: a small PNG and the true pixel size for
// an image, an icon for a file Quick Look cannot preview, a hex value for a colour, and the
// colour a source app's icon is mostly made of. They use real ImageIO, AppKit and Quick Look,
// because the framework calls are what could be wrong; the inputs are drawn in the test.
struct ThumbnailerTests {
    func item(id: Int64, kind: ItemKind) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: kind, cardText: "", createdAt: .now, copiedAt: .now, contentFingerprint: "f")
    }

    /// A flat `color` picture of the given size in pixels. Drawn with Core Graphics directly so
    /// the size is in pixels, not points (NSImage would draw it at the screen's Retina scale
    /// and double it).
    func image(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// The same picture, encoded as PNG.
    func png(width: Int, height: Int, color: CGColor) throws -> Data {
        try #require(Thumbnailer.pngData(try image(width: width, height: height, color: color)))
    }

    // A photo taken sideways is stored unrotated with an orientation tag (EXIF 6: turn a
    // quarter right to view). The card must show it upright and report the size the user sees.
    // JPEG, because PNG has no orientation tag.
    @Test func aSidewaysPhotoIsTurnedUprightAndReportsTheSizeTheUserSees() throws {
        let jpeg = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination,
            try image(width: 200, height: 300, color: CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let thumbnail = try #require(Thumbnailer.imageThumbnail(jpeg as Data))
        #expect((thumbnail.originalWidth, thumbnail.originalHeight) == (300, 200))
        #expect(thumbnail.width > thumbnail.height)
    }

    @Test func imagesAreShrunkToTheCardSizeAndReportTheirRealSize() throws {
        let data = try png(width: 2000, height: 1000, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let thumbnail = try #require(Thumbnailer.imageThumbnail(data))
        #expect(thumbnail.width == Thumbnailer.maxPixelSize)
        #expect(thumbnail.height == Thumbnailer.maxPixelSize / 2)
        #expect((thumbnail.originalWidth, thumbnail.originalHeight) == (2000, 1000))
        // A small image is never scaled up: it would only blur.
        let small = try #require(
            Thumbnailer.imageThumbnail(
                try png(width: 40, height: 30, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))))
        #expect((small.width, small.height) == (40, 30))
        #expect(Thumbnailer.imageThumbnail(Data("not an image".utf8)) == nil)
    }

    @Test func anImageItemGetsAThumbnailAndItsPixelSize() async throws {
        let item = item(id: 7, kind: .image)
        let data = [
            ClipboardItemData(
                type: "public.png",
                data: try png(width: 300, height: 200, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1)))
        ]
        let preview = try #require(await Thumbnailer.preview(for: item, data: data))
        #expect(preview.detail == "300 × 200")
        #expect(preview.thumbnail?.clipboardItemId == 7)
        #expect((preview.thumbnail?.width, preview.thumbnail?.height) == (300, 200))
    }

    @Test func aFileWithNoQuickLookPreviewGetsItsIcon() async throws {
        // A made-up extension has no Quick Look generator, so the Finder icon stands in. The
        // file does not even have to exist for that.
        let url = URL(filePath: "/tmp/yank-test-\(UUID()).zzqq")
        let item = item(id: 1, kind: .file)
        let data = [ClipboardItemData(type: ClipboardType.fileURL, data: Data(url.absoluteString.utf8))]
        let preview = try #require(await Thumbnailer.preview(for: item, data: data))
        #expect(preview.thumbnail != nil)
        #expect(preview.detail == nil)
    }

    @Test func coloursBecomeTheirHexValue() throws {
        let color = NSColor(srgbRed: 43 / 255, green: 89 / 255, blue: 214 / 255, alpha: 1)
        let archived = try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
        #expect(Thumbnailer.colorHex(archived) == "#2B59D6")
        #expect(Thumbnailer.colorHex(Data([1, 2, 3])) == nil)
    }

    @MainActor @Test func theDominantColourIgnoresWhiteAndTransparentPixels() {
        // Mostly white with transparent corners, like a document icon, and a blue stripe: the
        // answer must be the blue, not white or a blend with the corners.
        let image = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            NSColor.white.setFill()
            NSRect(x: 10, y: 10, width: 80, height: 80).fill()
            NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill()
            NSRect(x: 10, y: 10, width: 80, height: 20).fill()
            return true
        }
        let tint = SourceAppIcons.dominantColor(of: image).usingColorSpace(.sRGB)!
        #expect(tint.blueComponent > 0.9)
        #expect(tint.redComponent < 0.1 && tint.greenComponent < 0.1)
    }
}
