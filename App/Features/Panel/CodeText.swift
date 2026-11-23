// Colours code for the card and the large preview. Display only: a paste sends the saved bytes.
// System colours, so the same text reads in light and dark mode.
import ClipCore
import SwiftUI

nonisolated enum CodeText {
    /// Whether an item's language is one to highlight: set, and not "none".
    static func isCode(_ language: String?) -> Bool { language.map { $0 != Language.none } ?? false }

    /// The text with its comments, strings, numbers and keywords coloured.
    static func attributed(_ text: String, language: String) -> AttributedString {
        var result = AttributedString()
        for piece in Highlight.pieces(of: text, language: language) {
            var part = AttributedString(String(piece.text))
            switch piece.kind {
            case .comment: part.foregroundColor = Color(nsColor: .secondaryLabelColor)
            case .string: part.foregroundColor = Color(nsColor: .systemRed)
            case .number: part.foregroundColor = Color(nsColor: .systemBlue)
            case .keyword: part.foregroundColor = Color(nsColor: .systemPurple)
            case nil: break
            }
            result += part
        }
        return result
    }
}
