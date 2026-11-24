import Foundation

// The bytes live separately in `ClipboardItemData` rows, so listing items never loads images.
// `Codable` maps a database row onto this by name: a property's name is its column's name.
/// One saved copy: a row of `clipboardItem`.
public struct ClipboardItem: Identifiable, Hashable, Sendable, Codable {
    /// SQLite's row id, assigned by the database on insert.
    public var id: Int64
    public var kind: ItemKind
    /// Your own name for the item, set by Rename. Replaces the first line on the card.
    public var title: String?
    /// The first 400 characters, tidied: what the card shows.
    public var cardText: String
    /// The one line in the card's footer: "52 characters", "212 KB", "apple.com", "1280 × 800",
    /// "#2B59D6". Set at save time (see `CardDetail`), or by the Enricher when it needs the
    /// bytes decoded. Nil until then.
    public var cardDetail: String?
    /// Bundle id of the app you copied from, such as "com.apple.Safari".
    public var sourceAppBundleId: String?
    /// Display name of that app, such as "Safari".
    public var sourceAppName: String?
    /// When the item was first saved.
    public var createdAt: Date
    /// When it was last copied. A repeat copy moves the item to the top by updating this.
    public var copiedAt: Date
    /// SHA-256 of the content (see `DuplicateKey`). A repeat copy is found by it.
    public var contentFingerprint: String
    /// Text read out of an image by Vision (OCR), searchable.
    public var imageText: String?
    /// The web page's title fetched for a link, searchable.
    public var linkPageTitle: String?
    /// The pinboard the item is on, if any.
    public var pinboardId: Int64?
    /// Its `ItemCategory`: set by the model, by a credential pattern, or by hand. Nil until labelled.
    public var categoryId: Int64?
    /// One of `Language.all`, "none" for anything that is not code. Nil until labelled.
    public var language: String?
    /// The model's name for a long text or code, at most six words. Never replaces `title`.
    public var labelTitle: String?
    /// Set when the user picked the category or language in the actions menu; the model then
    /// leaves that label alone.
    public var categorySetByHand = false
    public var languageSetByHand = false

    public init(
        id: Int64, kind: ItemKind, title: String? = nil, cardText: String, cardDetail: String? = nil,
        sourceAppBundleId: String? = nil, sourceAppName: String? = nil, createdAt: Date,
        copiedAt: Date, contentFingerprint: String, imageText: String? = nil,
        linkPageTitle: String? = nil, pinboardId: Int64? = nil, categoryId: Int64? = nil,
        language: String? = nil, labelTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.cardText = cardText
        self.cardDetail = cardDetail
        self.sourceAppBundleId = sourceAppBundleId
        self.sourceAppName = sourceAppName
        self.createdAt = createdAt
        self.copiedAt = copiedAt
        self.contentFingerprint = contentFingerprint
        self.imageText = imageText
        self.linkPageTitle = linkPageTitle
        self.pinboardId = pinboardId
        self.categoryId = categoryId
        self.language = language
        self.labelTitle = labelTitle
    }
}
