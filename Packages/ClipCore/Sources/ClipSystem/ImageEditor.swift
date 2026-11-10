// Both edits give back a PNG, because PNG keeps the transparent pixels a cut-out needs and every
// app can paste it. Everything runs on the Mac; nothing leaves it.
import ClipCore
import CoreImage
import ImageIO
import Vision

/// Rotating and cutting out a copied image.
public enum ImageEditor {
    /// The picture turned a quarter turn, as a PNG. Nil when the bytes are not an image.
    /// (`.right` is the tag for "the left edge is now the top", which is a clockwise turn.)
    public static func rotated(_ image: Data, clockwise: Bool) -> Data? {
        guard let source = CIImage(data: image) else { return nil }
        return png(source.oriented(clockwise ? .right : .left))
    }

    /// The picture with everything but its subject made transparent, as a PNG. Nil when the
    /// bytes are not an image, or Vision finds no subject in it (a flat colour, a texture).
    public static func removingBackground(from image: Data) async throws -> Data? {
        // Vision reports bytes that are not an image as a cancelled request, which reads like
        // a failure; checking first turns that into the plain "nil" the caller expects.
        guard CIImage(data: image) != nil else { return nil }
        let request = GenerateForegroundInstanceMaskRequest()
        guard let observation = try await request.perform(on: image) else { return nil }
        // Not cropped, so the picture keeps its size and the subject stays where it was.
        let masked = try observation.generateMaskedImage(
            for: observation.allInstances, imageFrom: ImageRequestHandler(image),
            croppedToInstancesExtent: false)
        return png(CIImage(cvPixelBuffer: masked))
    }

    /// One renderer for every edit: a `CIContext` is costly to create and safe to share.
    private static let context = CIContext()

    private static func png(_ image: CIImage) -> Data? {
        guard let rendered = context.createCGImage(image, from: image.extent) else { return nil }
        return Thumbnailer.pngData(rendered)
    }
}
