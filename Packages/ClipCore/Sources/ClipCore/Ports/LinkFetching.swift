import Foundation

// A port (≈ a TS interface) for the one thing in Yank that uses the network: asking a web page
// for its title and icon, so a link card can say "Apple" with the Apple logo instead of a bare
// address. The core only knows "fetch this address"; ClipSystem's LinkFetcher does it with
// Apple's LinkPresentation framework, and tests use a fake that records which addresses were
// asked for, because a test must never go on the network and must prove that a local address
// never does. `Sendable`, because the Enricher calls it from a background task.

/// Fetches a web page's title and icon.
public protocol LinkFetching: Sendable {
    /// The page's title and icon, as far as it has them. Throws when the page could not be
    /// reached within the fetcher's time limit.
    func fetch(_ url: URL) async throws -> LinkPreview
}

/// What a web page says about itself: its title and its icon, either of which it may lack.
public struct LinkPreview: Hashable, Sendable {
    public var title: String?
    /// The site's icon as a PNG, at most `Thumbnailer.maxPixelSize` on its long side, with
    /// its pixel size; nil when the page offers none. Kept as the card's thumbnail.
    public var icon: Icon?

    public struct Icon: Hashable, Sendable {
        public var png: Data
        public var width: Int
        public var height: Int

        public init(png: Data, width: Int, height: Int) {
            self.png = png
            self.width = width
            self.height = height
        }
    }

    public init(title: String? = nil, icon: Icon? = nil) {
        self.title = title
        self.icon = icon
    }
}
