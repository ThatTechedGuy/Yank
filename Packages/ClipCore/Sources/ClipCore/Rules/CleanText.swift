import Foundation

// Used only on the way out (⌥Return, "Paste Cleaned"): the saved item keeps the bytes as copied.
/// Tidies text copied from a terminal or a log for pasting.
public enum CleanText {
    /// The text without ANSI colour codes and leading shell prompts ("$ ", "% ", "user@host:~$ "),
    /// then pretty-printed if what is left is a JSON object or array.
    public static func clean(_ text: String) -> String {
        let stripped =
            text
            .replacing(/\x1B\[[0-?]*[ -\/]*[@-~]/, with: "")
            .replacing(
                /^[ \t]*(?:[\w.\-]+@[\w.\-]+(?::[^\s$%]*)?[ ]?)?[$%❯] +/.anchorsMatchLineEndings(), with: "")
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
            (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
        else { return stripped }
        return reindent(trimmed)
    }

    /// Valid JSON laid out two spaces per level. By hand rather than through JSONSerialization,
    /// which would reorder the keys and rewrite the numbers.
    private static func reindent(_ json: String) -> String {
        let chars = Array(json)
        var out = ""
        var depth = 0
        var inString = false
        var escaped = false
        var i = 0
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        while i < chars.count {
            let c = chars[i]
            i += 1
            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                var j = i
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                    out += "\(c)\(chars[j])"
                    i = j + 1
                } else {
                    depth += 1
                    out.append(c)
                    newline()
                }
            case "}", "]":
                depth -= 1
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":": out += ": "
            case _ where c.isWhitespace: break
            default: out.append(c)
            }
        }
        return out
    }
}
