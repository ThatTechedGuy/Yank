// Makes the card-sized preview of an item from its bytes, with Apple's own decoders: ImageIO
// for images (the framework behind every image on the Mac, which can make a small version of a
// 50 MB photo without decoding all of it), Quick Look for files (the same previews Finder shows
// in Gallery view and on Space), and the file's Finder icon when Quick Look has none. Colours
// are unarchived with AppKit and turned into their hex value. The Enricher in ClipCore calls
// `preview` after each save, from a background task; nothing here needs the main thread.
import AppKit
import ClipCore
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Previews for the cards: thumbnails of images and files, hex values of colours.
public enum Thumbnailer {
    /// The long side of a thumbnail, in pixels. Cards are about 220 points wide, 440 pixels on
    /// a Retina screen, so 512 is sharp on a card and small on disk (tens of KB per photo).
    public static let maxPixelSize = 512

    /// The preview for an item, or nil when there is nothing to make or decoding failed.
    public static func preview(for item: ClipboardItem, data: [ClipboardItemData]) async -> CardPreview? {
        switch item.kind {
        case .image:
            guard let image = data.firstImage, let thumbnail = imageThumbnail(image.data) else { return nil }
            return CardPreview(
                thumbnail: CardThumbnail(
                    clipboardItemId: item.id, png: thumbnail.png, width: thumbnail.width,
                    height: thumbnail.height),
                detail: "\(thumbnail.originalWidth) × \(thumbnail.originalHeight)")
        case .file:
            // One card per copy, so a multi-file copy is previewed by its first file.
            guard
                let url = data.first(where: { $0.type == ClipboardType.fileURL }).flatMap({
                    URL(string: $0.text)
                }),
                let image = await fileThumbnail(url) ?? iconThumbnail(url),
                let png = pngData(image)
            else { return nil }
            return CardPreview(
                thumbnail: CardThumbnail(
                    clipboardItemId: item.id, png: png, width: image.width, height: image.height))
        case .color:
            guard let color = data.first(where: { $0.type == ClipboardType.color }),
                let hex = colorHex(color.data)
            else { return nil }
            return CardPreview(detail: hex)
        case .text, .link:
            return nil
        }
    }

    /// A PNG of at most `maxPixelSize` on its long side, plus the image's real pixel size.
    /// ImageIO reads only as much of the image as the small version needs, and never scales
    /// up: a tiny image stays tiny. Nil when the bytes are not an image it can read.
    static func imageThumbnail(_ data: Data) -> (
        png: Data, width: Int, height: Int, originalWidth: Int, originalHeight: Int
    )? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            var originalWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            var originalHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // A photo taken sideways stores its pixels unrotated plus an orientation tag.
        // `CreateThumbnailWithTransform` rotates the thumbnail to match; the reported size is
        // swapped for the sideways orientations (5 to 8) so it describes what the user sees.
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
            swap(&originalWidth, &originalHeight)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let png = pngData(image)
        else { return nil }
        return (png, image.width, image.height, originalWidth, originalHeight)
    }

    /// Quick Look's thumbnail of a file, or nil when it has none for that kind of file (or the
    /// file is gone). Quick Look runs its generators in a separate process, so a broken file
    /// cannot crash Yank. `scale: 1` asks for pixels, not points: 512 means 512 pixels.
    static func fileThumbnail(_ url: URL) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: maxPixelSize, height: maxPixelSize), scale: 1,
            representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    /// The icon Finder shows for the file, 128 pixels, as the fallback preview. Works for a
    /// file that no longer exists too: the icon then comes from the name's extension.
    static func iconThumbnail(_ url: URL) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var rect = NSRect(x: 0, y: 0, width: 128, height: 128)
        return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// The image encoded as PNG. (`CGImageDestination` is ImageIO's encoder; it writes into
    /// the mutable data and `Finalize` flushes it.)
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The hex value ("#2B59D6") of a colour as apps put it on the clipboard: an `NSColor`
    /// archived with `NSKeyedArchiver`. Converted to sRGB first, because a colour picked in a
    /// wide-gamut or greyscale space has no red/green/blue of its own.
    static func colorHex(_ archived: Data) -> String? {
        guard let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: archived),
            let rgb = color.usingColorSpace(.sRGB)
        else { return nil }
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X", channel(rgb.redComponent), channel(rgb.greenComponent),
            channel(rgb.blueComponent))
    }
}
