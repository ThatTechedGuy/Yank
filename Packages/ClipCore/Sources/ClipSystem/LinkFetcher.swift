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
        // still gets one. `includeSubresources` is what also fetches the icon and image files.
        // shortcut: an address that never answers (a connection that is swallowed, not
        // refused) has taken 60 s in testing despite `timeout`; wrap this in a racing task if
        // that ever shows up for public addresses.
        let metadata = try await LinkMetadata(fetching: url, timeout: Self.timeout, includeSubresources: true)
        // Pictures come back in whatever format the site serves (PNG, ICO, SVG, JPEG…). One the
        // page lacks, or ImageIO cannot read, is simply missing.
        return LinkPreview(
            title: metadata.title, icon: await Self.png(of: .icon, in: metadata),
            // A page image is usually a photo, kept forever with the link: JPEG keeps it small.
            image: await Self.png(of: .image, in: metadata, lossy: true))
    }

    private static func png(
        of attachment: LinkMetadata.Attachment, in metadata: LinkMetadata, lossy: Bool = false
    ) async -> LinkPreview.PNG? {
        guard let data = try? await metadata.media(attachment, as: Data.self),
            let thumbnail = Thumbnailer.imageThumbnail(data, lossy: lossy)
        else { return nil }
        return LinkPreview.PNG(png: thumbnail.png, width: thumbnail.width, height: thumbnail.height)
    }
}
