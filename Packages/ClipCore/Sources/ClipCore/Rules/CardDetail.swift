import Foundation

// Computed once at save time from the copy's bytes, so the list never reads them again. Images
// need their pixels decoded and colours their value unarchived, which takes AppKit; those two are
// filled in later by the Enricher.
/// Builds the footer detail for a copy.
public enum CardDetail {
    /// The detail for a copy of the given kind, or nil when it has to wait for the Enricher.
    public static func make(kind: ItemKind, data: [ClipboardItemData]) -> String? {
        switch kind {
        case .text:
            guard let text = data.first(where: { $0.type == ClipboardType.plainText })?.text else {
                return nil
            }
            // shortcut: counting characters walks the whole text, about 0.1 s for a 50 MB copy,
            // off the main thread; cap it if a huge copy is ever seen to delay the next one.
            let count = text.count
            return "\(count) \(count == 1 ? "character" : "characters")"
        case .file:
            // The URLs came from the clipboard, which is what lets the sandbox read the files. A
            // file that has gone since the copy has no size, and the card then shows nothing here.
            let urls = data.filter { $0.type == ClipboardType.fileURL }.compactMap { URL(string: $0.text) }
            if urls.count > 1 { return "\(urls.count) files" }
            guard let url = urls.first,
                let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { return nil }
            // "212 KB", in the user's locale, the way Finder shows sizes.
            return ByteCountFormatStyle(style: .file).format(Int64(size))
        case .link:
            // The site without "www.", which is how Safari's address bar shows it.
            guard let host = URL(string: data.linkAddress)?.host() else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        case .image, .color:
            return nil
        }
    }
}

// Words are runs of non-whitespace: "don't" is one, "3 pm" is two, and a run of punctuation on
// its own counts too.
/// How many characters and words a text has.
public struct TextCounts: Hashable, Sendable {
    public let characters: Int
    public let words: Int

    public init(_ text: String) {
        characters = text.count
        words = text.split(whereSeparator: \.isWhitespace).count
    }

    /// The counts as the user reads them: "52 characters · 9 words".
    public var description: String {
        "\(characters) \(characters == 1 ? "character" : "characters") · \(words) \(words == 1 ? "word" : "words")"
    }
}
