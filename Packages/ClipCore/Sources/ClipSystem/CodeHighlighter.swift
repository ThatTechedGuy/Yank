// Display only: the cards and the Space preview colour code, and a paste still sends the saved
// bytes. highlight.js runs in a JavaScriptCore context, which one thread at a time may use, so
// the work goes through this actor.
import AppKit
import ClipCore
import Highlighter
import SwiftUI

/// Colours code with highlight.js, in GitHub's light and dark themes.
public actor CodeHighlighter {
    public static let shared = CodeHighlighter()

    /// One per theme, made on first use (about 40 ms each): switching one engine's theme rereads
    /// its CSS on every call.
    private var engines: [ColorScheme: Highlighter] = [:]

    /// The text with highlight.js's colours for `language` (one of `Language.all`), as SwiftUI
    /// colours, so a `Text` keeps its own font. The text uncoloured when highlight.js fails.
    public func highlight(_ text: String, language: String, scheme: ColorScheme) -> AttributedString {
        guard let engine = engine(for: scheme),
            let coloured = engine.highlight(text, as: Self.alias(language))
        else { return AttributedString(text) }
        var result = AttributedString()
        coloured.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: coloured.length)
        ) { colour, range, _ in
            var run = AttributedString(coloured.attributedSubstring(from: range).string)
            if let colour = colour as? NSColor { run.foregroundColor = Color(nsColor: colour) }
            result += run
        }
        return result
    }

    private func engine(for scheme: ColorScheme) -> Highlighter? {
        if let engine = engines[scheme] { return engine }
        guard let engine = Highlighter() else { return nil }
        engine.setTheme(scheme == .dark ? "github-dark" : "github")
        // highlight.js gives up on code it finds invalid; a clipboard snippet often is a fragment.
        engine.ignoreIllegals = true
        engines[scheme] = engine
        return engine
    }

    /// highlight.js's name for one of `Language.all`.
    static func alias(_ language: String) -> String {
        switch language {
        case "Shell": "bash"
        case "HTML": "xml"
        case "C++": "cpp"
        case "C#": "csharp"
        default: language.lowercased()
        }
    }
}
