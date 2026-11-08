// Fetches a web page's title and icon with LinkPresentation, the framework behind the link
// previews in Messages and Notes, so a link card can say "Apple" with the Apple logo instead
// of a bare address. This is the only place Yank goes on the network. The Enricher in ClipCore
// decides whether to call it at all (link previews on, address not local); this adapter only
// does the fetch. ≈ a `fetch` + `<title>` and favicon parser, done by the system.
import ClipCore
import Foundation
import LinkPresentation

/// The real `LinkFetching`: asks the page itself, through LinkPresentation.
public struct LinkFetcher: LinkFetching {
    /// How long one page may take before it is given up on. A page that has not answered in
    /// ten seconds is not worth a card's title; the card keeps showing its address.
    public static let timeout: Duration = .seconds(10)

    public init() {}

    public func fetch(_ url: URL) async throws -> LinkPreview {
        // `LinkMetadata` loads the page the way Safari would (it runs the page's scripts, so a
        // site that writes its title with JavaScript still gets one) and reads its title and
        // icon. `includeSubresources` is what also fetches the icon file itself.
        // shortcut: an address that never answers (a connection that is swallowed, not
        // refused) has taken 60 s in testing despite `timeout`; wrap this in a racing task if
        // that ever shows up for public addresses.
        let metadata = try await LinkMetadata(fetching: url, timeout: Self.timeout, includeSubresources: true)
        var preview = LinkPreview(title: metadata.title)
        // The icon comes back in whatever format the site serves (PNG, ICO, SVG…); the same
        // ImageIO step that shrinks a photo turns it into a card-sized PNG. A site with no
        // icon, or one ImageIO cannot read, simply has no thumbnail.
        if let icon = try? await metadata.media(.icon, as: Data.self),
            let thumbnail = Thumbnailer.imageThumbnail(icon)
        {
            preview.icon = LinkPreview.Icon(
                png: thumbnail.png, width: thumbnail.width, height: thumbnail.height)
        }
        return preview
    }
}
