import SwiftUI
import Testing

@testable import ClipSystem

struct CodeHighlighterTests {
    // The card shows these characters, so highlighting must not add, drop or move one; a
    // keyword and a plain name must come out in different colours.
    @Test(arguments: ["Swift", "Shell", "C++", "HTML"])
    func keepsTheTextAndColoursIt(language: String) async {
        let code = "let s = \"héllo 🙂\" // note\nfunc  add() { return 42 }\n<a href=\"x\">"
        let result = await CodeHighlighter.shared.highlight(code, language: language, scheme: .light)
        #expect(String(result.characters) == code)
        #expect(Set(result.runs.map(\.foregroundColor)).count > 1)
    }
}
