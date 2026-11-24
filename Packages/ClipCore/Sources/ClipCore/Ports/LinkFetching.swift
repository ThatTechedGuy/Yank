import Foundation

// The one thing in Yank that uses the network. A port so tests never go on the network and can
// prove that a local address is never fetched.

/// Fetches a web page's title, icon and preview image.
public protocol LinkFetching: Sendable {
    /// The page's title, icon and preview image, as far as it has them. Throws when the page
    /// could not be reached within the fetcher's time limit.
    func fetch(_ url: URL) async throws -> LinkPreview
}

/// What a web page says about itself: its title, its icon and its preview image (the picture a
/// chat app shows for the link, og:image), any of which it may lack.
public struct LinkPreview: Hashable, Sendable {
    public var title: String?
    /// The site's icon; nil when the page offers none. The card's thumbnail when the page has no
    /// preview image.
    public var icon: PNG?
    /// The page's preview image; nil when the page offers none. The card's thumbnail when present.
    public var image: PNG?

    /// A picture at most `Thumbnailer.maxPixelSize` on its long side, with its pixel size: a PNG,
    /// or a JPEG for an opaque page image.
    public struct PNG: Hashable, Sendable {
        public var png: Data
        public var width: Int
        public var height: Int

        public init(png: Data, width: Int, height: Int) {
            self.png = png
            self.width = width
            self.height = height
        }
    }

    public init(title: String? = nil, icon: PNG? = nil, image: PNG? = nil) {
        self.title = title
        self.icon = icon
        self.image = image
    }
}
