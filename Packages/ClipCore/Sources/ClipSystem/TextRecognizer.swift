// Reads the words in a copied image with Vision, Apple's on-device computer-vision framework,
// so search can find a screenshot of an error message by the words in it. Nothing leaves the
// Mac: the text model ships with macOS. The Enricher in ClipCore calls `text(in:)` after each
// image is saved, from a background task; nothing here needs the main thread.
import ClipCore
import Vision

/// Finds the text in an image.
public enum TextRecognizer {
    /// The words in an image copy, one recognised line per line of text, top to bottom. Nil
    /// when the copy holds no image Vision can read, or no words. (≈ `Tesseract.recognize`,
    /// but built in and offline.)
    public static func text(in data: [ClipboardItemData]) async -> String? {
        guard let image = data.firstImage else { return nil }
        return await text(in: image.data)
    }

    /// The words in one image's bytes (PNG, TIFF, JPEG…), or nil.
    public static func text(in image: Data) async -> String? {
        var request = RecognizeTextRequest()
        // `.accurate` reads small screenshot text that the fast mode misses, and runs in the
        // background anyway. Language correction fixes words the model nearly read, and the
        // language is detected per image so a copied French paragraph comes out as French.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        guard let observations = try? await request.perform(on: image) else { return nil }
        // Each observation is one line of text with a few guesses; the top one is kept.
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
