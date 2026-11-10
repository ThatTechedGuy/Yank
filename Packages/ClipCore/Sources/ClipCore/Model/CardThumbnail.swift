import Foundation

// A PNG of at most 512 pixels on its long side, made once after the copy is saved (see Enricher).
// The card decodes this instead of the full-size image, so a row of ten thousand cards never
// touches a 50 MB TIFF. It goes away with its item.
/// One row of `cardThumbnail`: the card-sized PNG of one item.
public struct CardThumbnail: Hashable, Sendable, Codable {
    /// The item it belongs to; also the row's primary key, so an item has one thumbnail at most.
    public var clipboardItemId: Int64
    /// The PNG bytes.
    public var png: Data
    /// The PNG's size in pixels. Stored so a card can reserve the right space before decoding.
    public var width: Int
    public var height: Int

    public init(clipboardItemId: Int64, png: Data, width: Int, height: Int) {
        self.clipboardItemId = clipboardItemId
        self.png = png
        self.width = width
        self.height = height
    }
}

// A nil part always means "leave what is stored", so the thumbnail can be saved first and the
// slower image text added later.
/// What to add to a saved item: thumbnail, footer detail, text found in an image, page title.
public struct CardPreview: Hashable, Sendable {
    public var thumbnail: CardThumbnail?
    /// The footer line, such as "1280 × 800" or "#2B59D6"; nil keeps what the save stored.
    public var detail: String?
    /// The words read out of an image, so search can find a screenshot by what it says.
    public var imageText: String?
    /// The title of the page a link points at, such as "Apple", shown on the card and searched.
    public var linkPageTitle: String?

    public init(
        thumbnail: CardThumbnail? = nil, detail: String? = nil, imageText: String? = nil,
        linkPageTitle: String? = nil
    ) {
        self.thumbnail = thumbnail
        self.detail = detail
        self.imageText = imageText
        self.linkPageTitle = linkPageTitle
    }
}
