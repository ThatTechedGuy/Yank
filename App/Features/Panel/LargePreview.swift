// The whole item, shown above the selected card on Space: full text with its counts, a link with
// its site, a colour with its hex value. Images and files go to Quick Look instead (see
// `PanelModel.togglePreview`).
import ClipCore
import SwiftUI

struct LargePreview: View {
    let item: ClipboardItem
    let model: PanelModel

    /// The item's full text once read; nil while it loads. The card only has the first 200
    /// characters.
    @State private var text: String?
    /// The full text's counts, made once when it lands rather than on every draw (counting a
    /// long text walks all of it). Nil while the text loads; the card's text stands in.
    @State private var counts: TextCounts?

    /// How much of the text is drawn. Laying out one `Text` of a whole log file (tens of MB)
    /// would stall the panel for seconds. The counts below the text still cover all of it.
    static let shownCharacters = 200_000

    private var fullText: String { text ?? item.cardText }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch item.kind {
            case .color:
                (ItemCard.color(hex: item.cardDetail ?? "") ?? Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.cardDetail ?? "")
                    .font(.title3.monospaced())
            default:
                ScrollView {
                    Text(String(fullText.prefix(Self.shownCharacters)))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider()
                // "52 characters · 9 words" for text; the site for a link, as on its card.
                Text(
                    item.kind == .link
                        ? item.cardDetail ?? "" : (counts ?? TextCounts(item.cardText)).description
                )
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
            counts = TextCounts(fullText)
        }
    }
}
