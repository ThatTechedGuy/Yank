// Decided once at save time by `ItemKind.detect` (KindDetection.swift). The database column
// stores the case's name.
/// What a saved copy is: text, image, link, file or colour.
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case link
    case file
    case color
}
