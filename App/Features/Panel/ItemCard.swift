// One card in the row, laid out like Paste's: a 48-point header tinted with the source app's icon
// colour (the kind, the age, and the big app icon clipped at the corner), a preview of the content
// that fades out at the bottom, and a centred footer with the ⌘1–⌘9 hint and one detail.
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
    /// The name of the item's category, once labelled.
    let categoryName: String?
    /// Reads the item's full text, for a code card: the card text has its line breaks folded.
    let loadText: () async -> String?

    /// A code card's first lines, coloured; nil for anything else, and while they load.
    @State private var code: AttributedString?
    @Environment(\.colorScheme) private var colorScheme

    @Environment(ThumbnailCache.self) private var thumbnails
    @Environment(\.sourceAppIcons) private var appIcons
    /// With Increase Contrast on, every card gets a visible edge, not only the selected ones,
    /// so cards stand apart from the glass behind them.
    @Environment(\.colorSchemeContrast) private var contrast

    static let cornerRadius: CGFloat = 14
    /// Paste's card body: white, or near black in dark mode. Text on it is `.primary` and
    /// `.secondary`, which land on Paste's #262626/#DCDCDC and #7F7F7F/#959595.
    private static let bodyColor = Color(light: 0xFFFFFF, dark: 0x141414)

    var body: some View {
        // Text runs out in a fade above the footer; a swatch or picture fills the body whole.
        let fades = item.kind == .text || item.kind == .link
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(
                            colors: [.black, fades ? .clear : .black], startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 32)
                    }
                }
            footer
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Self.bodyColor)
        .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
        // The outline sits outside the card with no gap, so the card keeps its size selected or
        // not.
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius + 4, style: .continuous)
                .strokeBorder(outlineColor, lineWidth: isSelected ? 4 : 1)
                .padding(isSelected ? -4 : -1)
        }
        // To VoiceOver the card is one element that reads as one sentence, the label replacing
        // the pieces' own words. The id is for the UI tests.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenDescription)
        .accessibilityIdentifier("card-\(item.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // shortcut: each code card reads its item's bytes as it comes on screen; save its first
        // lines with the item if scrolling a row of code ever stutters.
        // The source app's RTF is not used: an editor in a dark theme copies near-white text,
        // which vanished on the card. Our own colours follow the panel's appearance instead.
        .task(id: "\(item.id) \(item.language ?? "") \(item.contentFingerprint) \(colorScheme)") {
            code = await loadCode()
        }
    }

    /// The first 800 characters coloured, more than the card's lines can hold.
    private func loadCode() async -> AttributedString? {
        guard item.kind == .text, let language = item.language, Language.isCode(language),
            let text = await loadText()
        else { return nil }
        return await CodeHighlighter.shared.highlight(
            String(text.prefix(800)), language: language, scheme: colorScheme)
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
        let category = categoryName.map { ", \($0)" } ?? ""
        return
            "Card \(position) of \(listSize). \(item.kind.displayName)\(category)\(source), \(age): \(spokenContent)"
    }

    /// The preview in words: a missing file's notice or a renamed card's own name first, then
    /// by kind the text, the picture's size, the page title and address, or the colour's hex
    /// value.
    private var spokenContent: String {
        if fileIsMissing { return "File no longer exists" }
        if let title = item.title { return title }
        if let title = item.labelTitle { return "\(title). \(item.cardText)" }
        switch item.kind {
        case .image, .color: return item.cardDetail ?? item.cardText
        case .link: return [item.linkPageTitle, item.cardText].compactMap { $0 }.joined(separator: ", ")
        case .text, .file: return item.cardText
        }
    }

    /// The tinted band: the kind over the age on the left, and the app's icon drawn large at the
    /// top right, cut off by the card's corner.
    private var header: some View {
        let tint = appIcons.tint(for: item.sourceAppBundleId)
        return VStack(alignment: .leading, spacing: 1) {
            Text([item.kind.displayName, categoryName].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 15, weight: .semibold))
            // Re-rendered once a minute, so a card left on screen keeps its age right.
            TimelineView(.everyMinute) { _ in
                Text(item.copiedAt, format: .relative(presentation: .named))
                    .font(.system(size: 12))
                    .opacity(0.9)
            }
        }
        .lineLimit(1)
        .padding(.leading, 12)
        .padding(.trailing, 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 48)
        .foregroundStyle(Self.readableText(on: tint))
        .background(alignment: .topTrailing) {
            Image(nsImage: appIcons.icon(for: item.sourceAppBundleId))
                .resizable()
                .frame(width: 64, height: 64)
                .offset(x: 4, y: -4)
        }
        .background(Color(nsColor: tint))
        .clipped()
    }

    /// The preview: picture, swatch or text, by kind.
    @ViewBuilder private var content: some View {
        if fileIsMissing {
            Text("File no longer exists")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.kind == .color, let color = Self.color(hex: item.cardDetail ?? "") {
            // The swatch fills the body, its hex value large in the middle.
            color.overlay {
                Text(item.cardDetail ?? "")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Self.readableText(on: NSColor(color)))
            }
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
                    Text(heading).font(.system(size: 13, weight: .semibold)).lineLimit(3)
                    Text(item.cardText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(item.cardText).font(.system(size: 13)).lineLimit(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
        } else if item.kind == .text {
            // The model's title (or your own name) over the text; code keeps its lines, coloured.
            VStack(alignment: .leading, spacing: 4) {
                if let heading = item.title ?? item.labelTitle {
                    Text(heading).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                }
                if let code {
                    Text(code).font(.system(size: 11, design: .monospaced)).lineLimit(14)
                } else if item.title == nil {
                    Text(item.cardText).font(.system(size: 13)).lineSpacing(3).lineLimit(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
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
                .font(.system(size: 13))
                .lineLimit(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        }
    }

    /// "⌘1 · Swift · 52 characters", centred: the shortcut, the language of code, and the
    /// detail, when known. An image's size sits in a grey capsule, as in Paste.
    private var footer: some View {
        let language = item.language.flatMap { Language.isCode($0) ? $0 : nil }
        let parts = [shortcutNumber.map { "⌘\($0)" }, language, item.cardDetail].compactMap { $0 }
        let isImage = item.kind == .image && !fileIsMissing
        // A space keeps the footer's height when both parts are missing.
        return Text(parts.isEmpty ? " " : parts.joined(separator: " · "))
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(isImage ? Color(light: 0x727272, dark: 0xF2F2F2) : .secondary)
            .lineLimit(1)
            .padding(.horizontal, isImage ? 8 : 0)
            .padding(.vertical, isImage ? 2 : 0)
            .background(isImage ? Color(light: 0xE5E5E5, dark: 0x646464) : .clear, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
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
        return Color(rgb: value)
    }
}

extension Color {
    /// 0x2B59D6 as an sRGB colour.
    init(rgb value: UInt32) {
        self.init(
            red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    /// One colour in light mode and another in dark, switching with the view's appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                NSColor(
                    Color(rgb: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light))
            })
    }
}

// The app sets the one shared icon cache on the panel's root view. The default has to be a single
// stored object: SwiftUI would otherwise make a new, empty cache on every read.
extension EnvironmentValues {
    private static let defaultSourceAppIcons = SourceAppIcons()
    @Entry var sourceAppIcons = defaultSourceAppIcons
}
