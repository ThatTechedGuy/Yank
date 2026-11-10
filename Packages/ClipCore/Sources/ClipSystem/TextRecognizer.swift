// Nothing leaves the Mac: the text model ships with macOS. The Enricher in ClipCore calls this
// from a background task; nothing here needs the main thread.
import ClipCore
import Vision

/// Finds the text in an image.
public enum TextRecognizer {
    /// The words in an image copy, one recognised line per line of text, top to bottom. Nil
    /// when the copy holds no image Vision can read, or no words.
    public static func text(in data: [ClipboardItemData]) async -> String? {
        guard let image = data.firstImage else { return nil }
        return await text(in: image.data)
    }

    /// The words in one image's bytes (PNG, TIFF, JPEG…), or nil.
    public static func text(in image: Data) async -> String? {
        var request = RecognizeTextRequest()
        // `.accurate` reads small screenshot text that the fast mode misses, and runs in the
        // background anyway.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        guard let observations = try? await request.perform(on: image) else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
