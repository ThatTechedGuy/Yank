// Apple's on-device model: nothing leaves the Mac. The Enricher in ClipCore calls `labels` from a
// background task and asks `isAvailable` before each call.
import ClipCore
import FoundationModels

/// Asks the on-device model for a copy's category, language and title.
public enum Labeller {
    /// Why labelling cannot run on this Mac, or nil when the model is ready. Settings shows it.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac cannot run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is off. Turn it on in System Settings › Apple Intelligence & Siri."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model."
        case .unavailable: "Apple Intelligence is not available."
        }
    }

    /// The labels for `text`. `anyOf:` limits the category and language to the given lists, so
    /// the model cannot invent one. A new session per call, so one copy never colours the next.
    public static func labels(for text: String, categories: [ItemCategory]) async throws -> Labels {
        let category = DynamicGenerationSchema(name: "category", anyOf: categories.map(\.name))
        let language = DynamicGenerationSchema(name: "language", anyOf: Language.all)
        let root = DynamicGenerationSchema(
            name: "Labels",
            properties: [
                .init(name: "category", schema: category),
                .init(name: "language", description: "The programming language, or none", schema: language),
                .init(
                    name: "title", description: "What the text is, in at most six words",
                    schema: .init(type: String.self)),
            ])
        // The `anyOf:` schemas are inline; listing them as dependencies too fails with duplicateType.
        let schema = try GenerationSchema(root: root, dependencies: [])
        let list = categories.map { "- \($0.name): \($0.about)" }.joined(separator: "\n")
        let session = LanguageModelSession(
            instructions: """
                You label text that someone copied to the clipboard. Choose the one category that \
                fits best:
                \(list)
                Choose the programming or markup language, or none if it is not code. Give a short \
                title of at most six words that says what the text is.
                """)
        let content = try await session.respond(to: text, schema: schema).content
        return Labels(
            category: try content.value(String.self, forProperty: "category"),
            language: try content.value(String.self, forProperty: "language"),
            title: try content.value(String.self, forProperty: "title"))
    }
}
