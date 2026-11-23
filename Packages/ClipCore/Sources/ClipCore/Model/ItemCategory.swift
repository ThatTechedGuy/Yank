import Foundation

// Items point at a category by id, so renaming one keeps its items. The model may only pick from
// this list (see Labeller), which is what keeps categories from multiplying.
/// One of the user's categories: a row of `itemCategory`, edited in Settings › Labels.
public struct ItemCategory: Identifiable, Hashable, Sendable, Codable {
    public var id: Int64
    public var name: String
    /// The one line the model reads to decide whether a copy belongs here.
    public var about: String
    /// Where it sits in the list, 0 first.
    public var position: Int

    public init(id: Int64, name: String, about: String, position: Int) {
        self.id = id
        self.name = name
        self.about = about
        self.position = position
    }

    // Migration v6 inserts the starting list in a fixed order, so these two always have these ids.
    /// Where the items of a removed category go. Cannot be removed.
    public static let otherId: Int64 = 8
    /// Set by `Credentials.detect`, never by the model. Cannot be removed.
    public static let credentialId: Int64 = 4

    /// Whether Settings may remove it.
    public var isBuiltIn: Bool { id == Self.otherId || id == Self.credentialId }
}
