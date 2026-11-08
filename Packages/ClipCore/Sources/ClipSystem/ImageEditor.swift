// The two things the editor can do to a copied picture: turn it a quarter turn, and cut the
// subject out of its background. Both take the copy's image bytes (PNG, TIFF, JPEG…) and give
// back a PNG, because PNG keeps the transparent pixels that a cut-out needs and every app can
// paste it. Rotation is Core Image's `oriented(_:)`, the same transform Photos applies to a
// sideways photo. The cut-out is Vision's subject lifting (`GenerateForegroundInstanceMaskRequest`),
// the model behind "Copy Subject" in Photos and Preview: it finds the people, pets and objects
// in front, and `generateMaskedImage` keeps those pixels and makes the rest transparent. It
// runs on the Mac; nothing leaves it. Both run on whatever background thread calls them.
import ClipCore
import CoreImage
import ImageIO
import Vision

/// Rotating and cutting out a copied image.
public enum ImageEditor {
    /// The picture turned a quarter turn, as a PNG. `clockwise: true` is "Rotate Right" in
    /// Preview's words; false is "Rotate Left". Nil when the bytes are not an image.
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
        // `allInstances`: every subject found, together. `croppedToInstancesExtent: false`
        // keeps the picture its original size, so the subject stays where it was.
        let masked = try observation.generateMaskedImage(
            for: observation.allInstances, imageFrom: ImageRequestHandler(image),
            croppedToInstancesExtent: false)
        return png(CIImage(cvPixelBuffer: masked))
    }

    /// A Core Image picture rendered to PNG bytes. `CIContext` is the renderer (GPU when
    /// there is one); `Thumbnailer.pngData` is the encoder the thumbnails already use.
    private static func png(_ image: CIImage) -> Data? {
        guard let rendered = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return Thumbnailer.pngData(rendered)
    }
}
