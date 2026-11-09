import Foundation

// The short text a card shows, `cardText`, 200 characters, and the longer text search reads.
// Both are computed once at save time so the list never touches the item's bytes.
/// Builds the card text for a copy.
public enum CardText {
    public static let maxLength = 200

    /// The card text for a copy of the given kind.
    public static func make(kind: ItemKind, data: [ClipboardItemData]) -> String {
        switch kind {
        case .file:
            // One line per file: the file's name, from its URL. Finder gives one pasteboard item
            // per file, so `filter` keeps just the file-url entries and `compactMap` drops any
            // that don't parse (compactMap = map, then throw away the nils; ≈ `.map().filter()`).
            let names = data.filter { $0.type == ClipboardType.fileURL }
                .compactMap { URL(string: $0.text)?.lastPathComponent }
            return String(names.joined(separator: "\n").prefix(maxLength))
        case .link:
            return condense(data.linkAddress)
        case .text, .image, .color:
            // Text: the plain text. Images and colours have none, so the card text is
            // empty; the card draws the picture or swatch instead. An image copied from
            // a browser sometimes carries its URL as text, which is useful on the card.
            let text = data.first { $0.type == ClipboardType.plainText }?.text ?? ""
            return condense(text)
        }
    }

    /// How many characters of a text copy search can see. Far more than a card shows, so a word
    /// deep in a long email is found, but capped so one 50 MB log cannot bloat the search index.
    public static let maxSearchLength = 20_000

    /// What the search index reads for a copy: the start of a text copy's plain text, and for
    /// every other kind the same text as its card. Whitespace needs no tidying here, because the
    /// index splits the text into words itself.
    public static func searchText(kind: ItemKind, data: [ClipboardItemData]) -> String {
        guard kind == .text, let text = data.first(where: { $0.type == ClipboardType.plainText })?.text
        else { return make(kind: kind, data: data) }
        return String(text.prefix(maxSearchLength))
    }

    // Collapses runs of whitespace to one space and cuts at maxLength, so a card shows a line
    // or two of real words instead of indentation. `split(whereSeparator:)` drops empty pieces.
    private static func condense(_ text: String) -> String {
        // Only the start of the text can end up on the card, so only look at that much. Without
        // this, a 50 MB copied log file would be split into words just to keep 200 characters.
        // 4 KB is plenty: even if the text were all whitespace, 200 real characters fit before it.
        // shortcut: a 4 KB prefix that is all whitespace gives an empty card; raise the limit if
        // that ever shows up in practice.
        let words = text.prefix(4096).split(whereSeparator: \.isWhitespace)
        // Cut to the limit. Short text stays whole: `prefix(n)` is a `slice(0, n)` that never goes
        // out of range.
        return String(words.joined(separator: " ").prefix(maxLength))
    }
}
