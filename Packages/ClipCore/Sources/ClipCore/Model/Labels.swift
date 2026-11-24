import Foundation

/// What the model says about one copy.
public struct Labels: Hashable, Sendable {
    /// How much of a copy the model and the credential patterns read: its first 1,500 characters.
    public static let inputLength = 1_500

    /// A category's name, from the list the model was given.
    public var category: String
    /// One of `Language.all`.
    public var language: String
    public var title: String

    public init(category: String, language: String, title: String) {
        self.category = category
        self.language = language
        self.title = title
    }
}

/// What `Enricher.AskModel` throws when the model cannot answer for now (still loading its
/// assets, or busy with other requests). The item stays queued and is asked again after a wait;
/// any other error drops it from the queue.
public struct ModelNotReady: Error {
    public init() {}
}

/// The languages the model may pick from, and the highlighter knows.
public enum Language {
    /// Not code.
    public static let none = "none"
    /// Whether an item with this language is code, to colour: any but "none".
    public static func isCode(_ language: String) -> Bool { language != none }
    public static let all = [
        none, "Swift", "Python", "JavaScript", "TypeScript", "Shell", "SQL", "JSON", "YAML", "HTML", "CSS",
        "Go", "Rust", "C", "C++", "C#", "Java", "Kotlin", "Ruby", "PHP",
    ]
}
