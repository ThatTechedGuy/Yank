import Foundation

// The card text and the longer text search reads are both computed once at save time, so the
// list never touches the item's bytes.
/// Builds the card text for a copy.
public enum CardText {
    public static let maxLength = 200

    /// The card text for a copy of the given kind.
    public static func make(kind: ItemKind, data: [ClipboardItemData]) -> String {
        switch kind {
        case .file:
            // One line per file: the file's name, from its URL.
            let names = data.filter { $0.type == ClipboardType.fileURL }
                .compactMap { URL(string: $0.text)?.lastPathComponent }
            return String(names.joined(separator: "\n").prefix(maxLength))
        case .link:
            return condense(data.linkAddress)
        case .text, .image, .color:
            // Images and colours usually have no plain text, so their card text is empty. An
            // image copied from a browser sometimes carries its URL as text, which is useful on
            // the card.
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
    // or two of real words instead of indentation.
    private static func condense(_ text: String) -> String {
        // Only the start of the text can end up on the card, so only look at that much. Without
        // this, a 50 MB copied log file would be split into words just to keep 200 characters.
        // shortcut: a 4 KB prefix that is all whitespace gives an empty card; raise the limit if
        // that ever shows up in practice.
        let words = text.prefix(4096).split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(maxLength))
    }
}
