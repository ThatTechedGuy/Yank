// Captured at the moment the clipboard changes, because the app in front then is the one that
// copied. Stored on the item, so a card can say "from Safari" even if Safari is later deleted.
/// The app a copy came from.
public struct SourceApp: Hashable, Sendable {
    /// The app's bundle identifier, such as "com.apple.Safari". Stable across renames and
    /// languages, so it is what the ignored-apps list compares.
    public var bundleId: String
    /// The name the user sees, such as "Safari", in the user's language.
    public var name: String

    public init(bundleId: String, name: String) {
        self.bundleId = bundleId
        self.name = name
    }
}
