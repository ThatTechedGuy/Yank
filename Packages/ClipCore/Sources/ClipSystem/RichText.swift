// Turns a copy's text into something the editor can show with its bold and italics, and
// back into clipboard bytes once the user is done. The editor works on `AttributedString`,
// Foundation's "text with formatting runs" (≈ a Draft.js / Slate document: characters plus
// ranges of attributes), which SwiftUI's TextEditor edits directly. The clipboard, though,
// speaks RTF (Rich Text Format, the 1987 Microsoft format every Mac text app still copies as),
// so each side needs a conversion. Both go through `AttributedTextFormatting.Transferable`,
// SwiftUI's own RTF import and export: it reads and writes the same attributes the TextEditor
// uses (font, colour, underline), so what the editor shows is what the RTF says.
import ClipCore
import SwiftUI
import UniformTypeIdentifiers

/// The editor's text ↔ clipboard bytes.
public enum RichText {
    /// Clipboard type of RTF bytes, as the source apps name it.
    public static let rtfType = UTType.rtf.identifier

    /// The text of a copy with its formatting, for the editor: from its RTF when the source app
    /// offered one, else its plain text with no formatting. Empty when the copy has neither.
    public static func attributedString(from data: [ClipboardItemData]) async throws -> AttributedString {
        if let rtf = data.first(where: { $0.type == rtfType }) {
            let imported = try await AttributedTextFormatting.Transferable(importing: rtf.data, contentType: .rtf)
            return try AttributedString(transferable: imported, in: EnvironmentValues())
        }
        return AttributedString(data.first { $0.type == ClipboardType.plainText }?.text ?? "")
    }

    /// The clipboard bytes for the edited text, best type first the way a source app lists
    /// them: RTF with the formatting, then the plain text. Pasting into an app that takes rich
    /// text gets the bold; a plain text field gets the words. (An `EnvironmentValues()` with
    /// nothing set is the plain environment the export resolves relative fonts against.)
    public static func clipboardData(for text: AttributedString) async throws -> [ClipboardItemData] {
        let rtf = try await AttributedTextFormatting.Transferable(text: text, in: EnvironmentValues())
            .exported(as: .rtf)
        return [
            ClipboardItemData(type: rtfType, data: rtf),
            ClipboardItemData(type: ClipboardType.plainText, data: Data(text.characters.map { $0 }.description.utf8)),
        ]
    }
}
