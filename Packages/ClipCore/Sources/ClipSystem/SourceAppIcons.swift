// The icon and the colour of the app a copy came from, for the card header. macOS keeps every
// installed app's icon; `NSWorkspace` finds the app by its bundle id and hands the icon over.
// The colour is worked out from that icon once per app and remembered, because counting the
// pixels of an icon takes a millisecond or two and a row of cards asks for it on every draw.
// ≈ a memoised selector keyed by bundle id.
import AppKit

/// Icons and header colours of the apps copies come from, cached per app.
@MainActor public final class SourceAppIcons {
    private var icons: [String: NSImage] = [:]
    private var tints: [String: NSColor] = [:]

    public init() {}

    /// The app's icon, or the generic app icon when the app is gone or the id is unknown.
    public func icon(for bundleId: String?) -> NSImage {
        let key = bundleId ?? ""
        if let icon = icons[key] { return icon }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        icons[key] = icon
        return icon
    }

    /// The colour the app's card header is tinted with: the icon's most common clear colour.
    public func tint(for bundleId: String?) -> NSColor {
        let key = bundleId ?? ""
        if let tint = tints[key] { return tint }
        let tint = Self.dominantColor(of: icon(for: bundleId))
        tints[key] = tint
        return tint
    }

    /// The most common clearly coloured pixel of an image, or grey when it has none (a black
    /// and white icon, say). The image is drawn at 128 × 128 pixels, small enough to count
    /// quickly and big enough to be true to the icon. Only fully opaque pixels count, so the
    /// transparent corners and soft edges of an icon do not; only pixels with a saturation
    /// above 0.25 count, so white, black and grey do not. Near-identical shades are counted as
    /// one (each channel rounded to 16 steps), and the answer is the average of the winning
    /// shade, so a flat blue icon gives its blue and a gradient gives its middle.
    public static func dominantColor(of image: NSImage) -> NSColor {
        let size = 128
        // Draw into our own RGBA buffer so the pixels can be read back as plain bytes.
        guard
            let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return .systemGray }
        var rect = CGRect(x: 0, y: 0, width: size, height: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return .systemGray
        }
        context.draw(cgImage, in: rect)

        // Bucket → (count, red sum, green sum, blue sum).
        var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for i in stride(from: 0, to: size * size * 4, by: 4) {
            let red = Int(pixels[i])
            let green = Int(pixels[i + 1])
            let blue = Int(pixels[i + 2])
            guard pixels[i + 3] == 255 else { continue }
            let brightest = max(red, green, blue)
            let darkest = min(red, green, blue)
            // Saturation as colour pickers define it: how far from grey, 0 to 1.
            guard brightest > 0, Double(brightest - darkest) / Double(brightest) > 0.25 else { continue }
            let bucket = (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4)
            let sum = buckets[bucket] ?? (0, 0, 0, 0)
            buckets[bucket] = (sum.count + 1, sum.red + red, sum.green + green, sum.blue + blue)
        }
        guard let best = buckets.values.max(by: { $0.count < $1.count }) else { return .systemGray }
        let channel = { (sum: Int) in CGFloat(sum) / CGFloat(best.count) / 255 }
        return NSColor(
            srgbRed: channel(best.red), green: channel(best.green), blue: channel(best.blue), alpha: 1)
    }
}
