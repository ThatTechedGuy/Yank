// One card in the row: what one saved copy looks like, laid out the way Paste lays out its
// cards. Top: a header tinted with the source app's icon colour, naming the kind of thing it
// is, how long ago it was copied, and the app's icon. Middle: the content, as a preview: the
// text (or the item's own name, if renamed), the picture for an image or a file, a swatch for
// a colour. Bottom: the ⌘1–⌘9 hint for the first nine cards and one detail: how long the text
// is, the image's size, the link's site, the file's size, the colour's hex value. The selected
// card gets a coloured outline. ≈ a list-row component that gets its item as a prop.
import AppKit
import ClipCore
import ClipSystem
import SwiftUI

struct ItemCard: View {
    let item: ClipboardItem
    /// 1 to 9 for the first nine cards (the ⌘1–⌘9 paste shortcut), nil for the rest.
    let shortcutNumber: Int?
    let isSelected: Bool
    /// The card's width, set by the row from the panel's height so cards scale with it.
    let width: CGFloat

    @Environment(ThumbnailCache.self) private var thumbnails
    @Environment(\.sourceAppIcons) private var appIcons

    static let cornerRadius: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            footer
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(.background.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        // The selection outline: the user's accent colour when selected, nothing otherwise.
        // Drawing a clear stroke when not selected keeps the card the same size either way.
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
        // Names for the UI tests and for VoiceOver: "card-42", marked selected or not.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card-\(item.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The tinted band: kind on the left, age and app icon on the right.
    private var header: some View {
        let tint = appIcons.tint(for: item.sourceAppBundleId)
        return HStack(spacing: 6) {
            Text(kindName)
                .font(.caption.weight(.semibold))
            Spacer()
            // "2 minutes ago", "yesterday". `TimelineView` re-renders its content on a
            // schedule, here once a minute, so a card left on screen keeps its time right.
            TimelineView(.everyMinute) { _ in
                Text(item.copiedAt, format: .relative(presentation: .named))
                    .font(.caption)
            }
            Image(nsImage: appIcons.icon(for: item.sourceAppBundleId))
                .resizable()
                .frame(width: 16, height: 16)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(Self.readableText(on: tint))
        .background(Color(nsColor: tint))
    }

    /// The preview: picture, swatch or text, by kind.
    @ViewBuilder private var content: some View {
        if item.kind == .color, let color = Self.color(hex: item.cardDetail ?? "") {
            color
        } else if let image = thumbnails.image(for: item) {
            // A photo fills the card, like a thumbnail in Photos; a file's preview (a page, an
            // icon) is shown whole, like in Finder. The picture is drawn as an overlay on an
            // empty box so that a filling picture, which is bigger than the box, cannot push
            // the card's header and footer out of place; `clipped` cuts off the overflow.
            Color.clear.overlay {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: item.kind == .image ? .fill : .fit)
                    .padding(item.kind == .file ? 12 : 0)
            }
        } else {
            // The renamed title wins over the saved text. An image whose thumbnail has not
            // arrived yet shows nothing here; it fills in a moment later.
            Text(item.title ?? item.cardText)
                .font(.body)
                .lineLimit(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
        }
    }

    /// "⌘1 · 52 characters": the shortcut, when there is one, and the detail, when known.
    private var footer: some View {
        let parts = [shortcutNumber.map { "⌘\($0)" }, item.cardDetail].compactMap { $0 }
        // A space keeps the footer's height when both parts are missing.
        return Text(parts.isEmpty ? " " : parts.joined(separator: " · "))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    /// The kind as the user reads it on the card.
    private var kindName: String {
        switch item.kind {
        case .text: "Text"
        case .image: "Image"
        case .link: "Link"
        case .file: "File"
        case .color: "Color"
        }
    }

    /// White on a dark tint, black on a light one (a yellow icon, say), by the W3C's formula
    /// for how bright a colour looks.
    private static func readableText(on tint: NSColor) -> Color {
        let rgb = tint.usingColorSpace(.sRGB) ?? tint
        let brightness = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return brightness > 0.65 ? .black : .white
    }

    /// "#2B59D6" as a colour; nil for anything else.
    static func color(hex: String) -> Color? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else {
            return nil
        }
        return Color(
            red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

// The app-icon cache travels to every card through SwiftUI's environment (≈ a React context),
// so the row does not have to pass it down by hand. `@Entry` writes the environment key
// boilerplate; the app sets the one shared instance on the panel's root view. (The default
// has to be a single stored object: SwiftUI would otherwise make a new, empty cache on every
// read.)
extension EnvironmentValues {
    private static let defaultSourceAppIcons = SourceAppIcons()
    @Entry var sourceAppIcons = defaultSourceAppIcons
}
