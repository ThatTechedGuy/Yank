// The five kinds of card the panel shows. Every saved copy is exactly one of these, decided once
// at save time by `ItemKind.detect` (in KindDetection.swift) from the clipboard types it carries.
// The kind then picks the card text, the fingerprint and how the card is drawn.
//
// A Swift `enum` is like a TS string-literal union (`"text" | "image" | ...`) but every `switch`
// over it must cover every case: add a kind here and the compiler points at each switch to update.
//
// `: String` stores each case as its name ("image"), which is what goes in the database column,
// like an Android enum's `name()`. `Codable` lets GRDB read and write it as that string.
// `Sendable` means the compiler has checked it is safe to pass between threads, which is always
// true for a plain enum. `CaseIterable` gives `allCases`, a list of every kind, for the kind
// filter menu later.
/// What a saved copy is: text, image, link, file or colour.
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case link
    case file
    case color
}
