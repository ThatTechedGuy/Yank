// One card in the row: a header tinted with the source app's icon colour, a preview of the
// content, and a footer with the ⌘1–⌘9 hint and one detail (length, size, site or hex value).
import AppKit
import ClipCore
import ClipSystem
import SwiftUI

struct ItemCard: View {
    let item: ClipboardItem
    /// 1 to 9 for the first nine cards (the ⌘1–⌘9 paste shortcut), nil for the rest.
    let shortcutNumber: Int?
    let isSelected: Bool
    /// The one selected card the keys act from; the other selected cards get a fainter outline.
    let isLead: Bool
    /// True for a file card whose file has gone from the disk since it was copied.
    let fileIsMissing: Bool
    /// The card's width, set by the row from the panel's height so cards scale with it.
    let width: CGFloat
    /// Where the card sits in the row, from 1, and how many cards the row holds ("20", or
    /// "200 or more"), for the sentence VoiceOver reads: "Card 1 of 20. …".
    let position: Int
    let listSize: String

    @Environment(ThumbnailCache.self) private var thumbnails
    @Environment(\.sourceAppIcons) private var appIcons
    /// With Increase Contrast on, every card gets a visible edge, not only the selected ones,
    /// so cards stand apart from the frosted background behind them.
    @Environment(\.colorSchemeContrast) private var contrast

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
        // The outline is an overlay, so the card keeps its size selected or not.
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .stroke(outlineColor, lineWidth: isSelected ? 3 : 1)
        )
        // To VoiceOver the card is one element that reads as one sentence, the label replacing
        // the pieces' own words. The id is for the UI tests.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenDescription)
        .accessibilityIdentifier("card-\(item.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var outlineColor: Color {
        if isLead { return .accentColor }
        if isSelected { return Color.accentColor.opacity(0.45) }
        return contrast == .increased ? Color.primary.opacity(0.6) : .clear
    }

    /// What VoiceOver reads: "Card 1 of 20. Text from Safari, 2 minutes ago: Hello world". The
    /// age uses the same wording as the header.
    private var spokenDescription: String {
        let source = item.sourceAppName.map { " from \($0)" } ?? ""
        let age = item.copiedAt.formatted(.relative(presentation: .named))
        return "Card \(position) of \(listSize). \(item.kind.displayName)\(source), \(age): \(spokenContent)"
    }

    /// The preview in words: a missing file's notice or a renamed card's own name first, then
    /// by kind the text, the picture's size, the page title and address, or the colour's hex
    /// value.
    private var spokenContent: String {
        if fileIsMissing { return "File no longer exists" }
        if let title = item.title { return title }
        switch item.kind {
        case .image, .color: return item.cardDetail ?? item.cardText
        case .link: return [item.linkPageTitle, item.cardText].compactMap { $0 }.joined(separator: ", ")
        case .text, .file: return item.cardText
        }
    }

    /// The tinted band: kind on the left, age and app icon on the right.
    private var header: some View {
        let tint = appIcons.tint(for: item.sourceAppBundleId)
        return HStack(spacing: 6) {
            Text(item.kind.displayName)
                .font(.caption.weight(.semibold))
            Spacer()
            // Re-rendered once a minute, so a card left on screen keeps its age right.
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
        if fileIsMissing {
            Text("File no longer exists")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.kind == .color, let color = Self.color(hex: item.cardDetail ?? "") {
            color
        } else if item.kind == .link {
            // Once the page has been fetched: the site's icon, the page's title and the address
            // underneath; until then (or with previews off) just the address. The renamed title
            // wins over the page's.
            VStack(alignment: .leading, spacing: 8) {
                if let icon = thumbnails.image(for: item) {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if let heading = item.title ?? item.linkPageTitle {
                    Text(heading).font(.body.weight(.semibold)).lineLimit(3)
                    Text(item.cardText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(item.cardText).font(.body).lineLimit(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
        } else if let image = thumbnails.image(for: item) {
            // A photo fills the card; a file's preview (a page, an icon) is shown whole. The
            // picture is an overlay on an empty box so that a filling picture, which is bigger
            // than the box, cannot push the card's header and footer out of place.
            Color.clear.overlay {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: item.kind == .image ? .fill : .fit)
                    .padding(item.kind == .file ? 12 : 0)
            }
        } else {
            // An image whose thumbnail has not arrived yet lands here and fills in a moment later.
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

// The app sets the one shared icon cache on the panel's root view. The default has to be a single
// stored object: SwiftUI would otherwise make a new, empty cache on every read.
extension EnvironmentValues {
    private static let defaultSourceAppIcons = SourceAppIcons()
    @Entry var sourceAppIcons = defaultSourceAppIcons
}
