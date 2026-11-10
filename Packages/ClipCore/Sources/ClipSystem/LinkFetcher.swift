// The only place Yank goes on the network. The Enricher in ClipCore decides whether to call it at
// all (link previews on, address not local); this adapter only does the fetch.
import ClipCore
import Foundation
import LinkPresentation

/// The real `LinkFetching`: asks the page itself, through LinkPresentation.
public struct LinkFetcher: LinkFetching {
    /// How long one page may take before it is given up on; the card then keeps showing its
    /// address.
    public static let timeout: Duration = .seconds(10)

    public init() {}

    public func fetch(_ url: URL) async throws -> LinkPreview {
        // `LinkMetadata` runs the page's scripts, so a site that writes its title with JavaScript
        // still gets one. `includeSubresources` is what also fetches the icon file itself.
        // shortcut: an address that never answers (a connection that is swallowed, not
        // refused) has taken 60 s in testing despite `timeout`; wrap this in a racing task if
        // that ever shows up for public addresses.
        let metadata = try await LinkMetadata(fetching: url, timeout: Self.timeout, includeSubresources: true)
        var preview = LinkPreview(title: metadata.title)
        // The icon comes back in whatever format the site serves (PNG, ICO, SVG…). A site with
        // no icon, or one ImageIO cannot read, simply has no thumbnail.
        if let icon = try? await metadata.media(.icon, as: Data.self),
            let thumbnail = Thumbnailer.imageThumbnail(icon)
        {
            preview.icon = LinkPreview.Icon(
                png: thumbnail.png, width: thumbnail.width, height: thumbnail.height)
        }
        return preview
    }
}
