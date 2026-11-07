// One card in the row: what one saved copy looks like. Top: what kind of thing it is and how
// long ago it was copied. Middle: the text (or the item's own name, if renamed). Bottom: the
// ⌘1–⌘9 hint for the first nine cards and the app it came from. The selected card gets a
// coloured outline. ≈ a list-row component that gets its item as a prop.
import ClipCore
import SwiftUI

struct ItemCard: View {
    let item: ClipboardItem
    /// 1 to 9 for the first nine cards (the future ⌘1–⌘9 paste shortcut), nil for the rest.
    let shortcutNumber: Int?
    let isSelected: Bool

    /// Every card has the same width so the row scrolls evenly; the height comes from the
    /// panel. (`static` = one shared value for the type, not one per card.)
    static let width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(kindName, systemImage: kindSymbol)
                    .font(.caption.weight(.semibold))
                Spacer()
                // "2 minutes ago", "yesterday". `TimelineView` re-renders its content on a
                // schedule, here once a minute, so a card left on screen keeps its time right.
                TimelineView(.everyMinute) { _ in
                    Text(item.copiedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // The renamed title wins over the saved text. Images have no text, so they show
            // their kind instead until a preview exists.
            Text(item.title ?? (item.cardText.isEmpty ? kindName : item.cardText))
                .font(.body)
                .lineLimit(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if let shortcutNumber {
                    Text("⌘\(shortcutNumber)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.sourceAppName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        // The selection outline: the user's accent colour when selected, nothing otherwise.
        // Drawing a clear stroke when not selected keeps the card the same size either way.
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
        // Names for the UI tests and for VoiceOver: "card-42", marked selected or not.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card-\(item.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    /// The SF Symbol icon for the kind (browse them in Apple's free SF Symbols app).
    private var kindSymbol: String {
        switch item.kind {
        case .text: "doc.text"
        case .image: "photo"
        case .link: "link"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }
}
