import Foundation

// The small picture a card shows for an image or a file: a PNG of at most 512 pixels on its
// long side, made once after the copy is saved (see Enricher) and kept in the `cardThumbnail`
// table, one per item at most. The card decodes this instead of the full-size image, so a row
// of ten thousand cards never touches a 50 MB TIFF. It goes away with its item.
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

// What the Enricher adds to a card after a copy is saved, worked out from the item's bytes by
// ClipSystem: a thumbnail for images and files, a one-line detail for the card's footer where
// the save itself could not compute it (an image's pixel size, a colour's hex value). Either
// part may be missing: text and links need nothing from here at all.
/// A thumbnail and/or footer detail to add to a saved item.
public struct CardPreview: Hashable, Sendable {
    public var thumbnail: CardThumbnail?
    /// The footer line, such as "1280 × 800" or "#2B59D6"; nil keeps what the save stored.
    public var detail: String?

    public init(thumbnail: CardThumbnail? = nil, detail: String? = nil) {
        self.thumbnail = thumbnail
        self.detail = detail
    }
}
