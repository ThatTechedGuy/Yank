// The whole item, shown above the selected card when the user presses Space: the full text
// with its character and word counts, the link with its site, the colour with its hex value.
// Images and files do not come here; Space opens them in Quick Look, the system's own viewer
// (see PanelView). ≈ a modal that shows the full record behind a list row.
//
// The card only has the first 200 characters of the text, so the full text is read from the
// database when the preview opens, in a `.task`: SwiftUI starts it when the view appears and
// cancels it if the view goes away first (≈ a `useEffect` with cleanup).
import ClipCore
import SwiftUI

struct LargePreview: View {
    let item: ClipboardItem
    let model: PanelModel

    /// The item's full text once read; nil while it loads.
    @State private var text: String?

    /// How much of the text is drawn. Laying out one `Text` of a whole log file (tens of MB)
    /// would stall the panel for seconds; this much is more than anyone reads in a preview.
    /// The counts below the text still cover all of it.
    static let shownCharacters = 200_000

    private var fullText: String { text ?? item.cardText }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch item.kind {
            case .color:
                // The swatch and its value, which is what a designer wants to copy from it.
                (ItemCard.color(hex: item.cardDetail ?? "") ?? Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.cardDetail ?? "")
                    .font(.title3.monospaced())
            default:
                // Text and links: all of it, scrolling, selectable so a bit can be copied out.
                ScrollView {
                    Text(String(fullText.prefix(Self.shownCharacters)))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider()
                // "52 characters · 9 words" for text; the site for a link, as on its card.
                Text(item.kind == .link ? item.cardDetail ?? "" : TextCounts(fullText).description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("preview-detail")
            }
        }
        .padding(12)
        .frame(width: 420, height: 300)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("large-preview")
        .task(id: item.id) {
            text = await model.fullText(for: item)
        }
    }
}
