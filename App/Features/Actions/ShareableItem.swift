// What "Share…" hands to the system share sheet. `ShareLink` asks for the bytes only when a service
// is picked, so nothing is read from the database just to show the menu. Images and files go as the
// file Quick Look previews, so Mail or Messages get a real attachment.
import ClipCore
import CoreTransferable
import UniformTypeIdentifiers

struct ShareableItem: Transferable {
    let item: ClipboardItem
    let store: Store

    /// Plain text for text, links and colours, a file for images and files; `exportingCondition`
    /// turns off the representation that does not fit the kind.
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { shareable in
            let data = try await shareable.store.data(for: shareable.item.id)
            // A colour card has no plain text; its hex value is what it shows and what it shares.
            let text = data.first { $0.type == ClipboardType.plainText }?.text
            return Data((text ?? shareable.item.cardDetail ?? shareable.item.cardText).utf8)
        }
        .exportingCondition { !$0.isFile }
        FileRepresentation(exportedContentType: .data) { shareable in
            guard let url = try await shareable.store.quickLookFile(for: shareable.item) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
        .exportingCondition(\.isFile)
    }

    private var isFile: Bool { item.kind == .image || item.kind == .file }
}
