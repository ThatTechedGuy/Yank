import Foundation

// Display only: the card and the preview colour these pieces, and a paste still sends the saved
// bytes. A scanner, not a parser: comments, strings, numbers and keywords are what make code
// readable at a glance, and a wrong guess costs one oddly coloured word.
/// Splits code into the pieces a highlighter colours.
public enum Highlight {
    public enum Kind: Sendable, Equatable { case comment, string, number, keyword }

    /// The text cut into pieces in order, each with its kind or nil for plain. Joined back they
    /// are the text exactly.
    public static func pieces(of text: String, language: String) -> [(text: Substring, kind: Kind?)] {
        let rules = Rules(language)
        let bytes = Array(text.utf8)
        var pieces: [(Int, Int, Kind?)] = []
        var plainStart = 0
        var i = 0
        func emit(_ end: Int, _ kind: Kind) {
            if plainStart < i { pieces.append((plainStart, i, nil)) }
            pieces.append((i, end, kind))
            i = end
            plainStart = end
        }
        let lineComments = rules.lineComment.map { Array($0.utf8) }
        let blockComment = rules.blockComment.map { (Array($0.0.utf8), Array($0.1.utf8)) }
        func starts(_ s: [UInt8], at: Int) -> Bool {
            at + s.count <= bytes.count && bytes[at..<at + s.count].elementsEqual(s)
        }
        /// The offset just past the next `s` from `from`, or nil.
        func find(_ s: [UInt8], from: Int) -> Int? {
            var j = from
            while j < bytes.count {
                if starts(s, at: j) { return j + s.count }
                j += 1
            }
            return nil
        }
        func isWord(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
                || b >= 0x80
        }
        while i < bytes.count {
            let b = bytes[i]
            if let line = lineComments.first(where: { starts($0, at: i) }) {
                emit(find([0x0A], from: i + line.count).map { $0 - 1 } ?? bytes.count, .comment)
            } else if let (open, close) = blockComment, starts(open, at: i) {
                emit(find(close, from: i + open.count) ?? bytes.count, .comment)
            } else if rules.quotes.contains(b) {
                var j = i + 1
                // A backtick string may run over lines; the others stop at the line's end, so a
                // stray quote colours one line, not the rest of the text.
                while j < bytes.count, bytes[j] != b, b == 0x60 || bytes[j] != 0x0A {
                    j += bytes[j] == 0x5C ? 2 : 1
                }
                emit(min(j + 1, bytes.count), .string)
            } else if b >= 0x30 && b <= 0x39 && (i == 0 || !isWord(bytes[i - 1])) {
                var j = i + 1
                while j < bytes.count, isWord(bytes[j]) || bytes[j] == 0x2E { j += 1 }
                emit(j, .number)
            } else if isWord(b) && (i == 0 || !isWord(bytes[i - 1])) {
                var j = i + 1
                while j < bytes.count, isWord(bytes[j]) { j += 1 }
                if rules.keywords.contains(String(decoding: bytes[i..<j], as: UTF8.self)) {
                    emit(j, .keyword)
                } else {
                    i = j
                }
            } else {
                i += 1
            }
        }
        if plainStart < bytes.count { pieces.append((plainStart, bytes.count, nil)) }
        // Every cut is next to an ASCII byte, so each offset falls on a character boundary.
        let utf8 = text.utf8
        return pieces.map { start, end, kind in
            (
                text[
                    utf8.index(utf8.startIndex, offsetBy: start)..<utf8.index(utf8.startIndex, offsetBy: end)],
                kind
            )
        }
    }

    private struct Rules {
        var lineComment: [String] = []
        var blockComment: (String, String)?
        var quotes: Set<UInt8> = [0x22, 0x27]  // " '
        var keywords: Set<String> = []

        init(_ language: String) {
            let cStyle = (["//"], ("/*", "*/"))
            switch language {
            case "Swift":
                (lineComment, blockComment) = cStyle
                quotes = [0x22]
                keywords = [
                    "func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum",
                    "protocol",
                    "extension", "import", "for", "in", "while", "switch", "case", "default", "self", "nil",
                    "true",
                    "false", "try", "await", "async", "throws", "public", "private", "static", "init", "some",
                    "any",
                ]
            case "Python":
                lineComment = ["#"]
                keywords = [
                    "def", "class", "return", "if", "elif", "else", "for", "while", "in", "import", "from",
                    "as",
                    "with", "try", "except", "finally", "raise", "None", "True", "False", "and", "or", "not",
                    "lambda", "yield", "async", "await", "pass", "self",
                ]
            case "JavaScript", "TypeScript":
                (lineComment, blockComment) = cStyle
                quotes = [0x22, 0x27, 0x60]
                keywords = [
                    "function", "const", "let", "var", "if", "else", "return", "for", "while", "class", "new",
                    "import", "export", "from", "default", "async", "await", "try", "catch", "throw", "null",
                    "undefined", "true", "false", "this", "typeof", "interface", "type",
                ]
            case "Shell":
                lineComment = ["#"]
                quotes = [0x22, 0x27, 0x60]
                keywords = [
                    "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac",
                    "function", "return", "export", "local", "echo", "cd", "sudo",
                ]
            case "SQL":
                lineComment = ["--"]
                blockComment = ("/*", "*/")
                let words = [
                    "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
                    "create",
                    "table", "join", "left", "on", "and", "or", "not", "null", "order", "by", "group",
                    "limit", "as",
                ]
                keywords = Set(words + words.map { $0.uppercased() })
            case "JSON": keywords = ["true", "false", "null"]
            case "YAML":
                lineComment = ["#"]
                keywords = ["true", "false", "null", "yes", "no"]
            case "HTML": blockComment = ("<!--", "-->")
            case "CSS": blockComment = ("/*", "*/")
            case "Ruby":
                lineComment = ["#"]
                keywords = [
                    "def", "end", "class", "module", "if", "elsif", "else", "unless", "do", "return", "nil",
                    "true", "false", "self", "require", "yield",
                ]
            case "Go", "Rust", "C", "C++", "C#", "Java", "Kotlin", "PHP":
                (lineComment, blockComment) = cStyle
                if language == "Rust" { quotes = [0x22] }
                if language == "Go" { quotes = [0x22, 0x27, 0x60] }
                if language == "PHP" { lineComment = ["//", "#"] }
                keywords = [
                    "func", "fn", "let", "mut", "var", "val", "const", "if", "else", "return", "for", "while",
                    "switch", "case", "break", "continue", "struct", "class", "enum", "interface", "impl",
                    "trait",
                    "pub", "public", "private", "static", "void", "int", "new", "import", "package", "use",
                    "include", "namespace", "true", "false", "null", "nil", "this", "self", "match", "type",
                    "function", "echo",
                ]
            default: break
            }
        }
    }
}
