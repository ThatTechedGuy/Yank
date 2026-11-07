import Foundation

// Which kind of card a copy becomes, decided from the types it carries. Pure function
// over the captured data; the tests in KindDetectionTests pin every branch.
//
// `extension` adds members to an existing type, from any file, even types you don't own (≈ C#
// extension methods; TS has no equivalent, Kotlin does). We use it to keep each rule in its own
// file next to its comments.
extension ItemKind {
    /// The kind for a copy, from its types and (for links) its plain text.
    public static func detect(_ data: [ClipboardItemData]) -> ItemKind {
        // The rules below only look at which type names are present, so collect them into a set
        // once. (`\.type` is a key path, Swift's `(d) => d.type`.)
        let types = Set(data.map(\.type))
        // Order: the most specific signal wins. A Finder copy also carries the file's name as
        // plain text, and a Safari image drag carries a URL, so file and image are checked before
        // link and text.
        if types.contains(ClipboardType.fileURL) { return .file }
        if !types.isDisjoint(with: ClipboardType.images) { return .image }
        if types.contains(ClipboardType.color) { return .color }
        if types.contains(ClipboardType.url) { return .link }
        // Plain text that is exactly one web address is a link too: that is how most apps other
        // than browsers copy a URL (Slack, Notes, a terminal).
        if let text = data.first(where: { $0.type == ClipboardType.plainText })?.text,
            Self.isSingleWebAddress(text)
        {
            return .link
        }
        return .text
    }

    // True when the whole text is one http(s) address, so "https://example.com" copied from Slack
    // becomes a link card and not a text card.
    private static func isSingleWebAddress(_ text: String) -> Bool {
        // A single web address is short. Anything longer is text, and saying so up front means a
        // huge copy (a whole log file) is never trimmed or parsed as a URL, which would be slow.
        // shortcut: 2 KB is above every real address but below the 8 KB some browsers accept;
        // raise it if a copied link ever shows as a text card.
        if text.utf8.count > 2048 { return false }
        // Trim, then refuse anything with inner whitespace: a sentence that contains a URL is text.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains(where: \.isWhitespace) { return false }
        // It must parse as a URL with an http or https scheme and a host, so "example.com" with no
        // scheme and "mailto:a@b.c" stay text. (`guard let` is an early return when any part is
        // missing; the unwrapped values stay usable after it.)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return false }
        return true
    }
}
