// The editor's state, one per open editor window: the text or picture being edited, and saving it
// as a new item or over the original. The work itself is elsewhere: RichText and ImageEditor
// (ClipSystem) convert and transform, the Store writes; this class sequences them.
import ClipCore
import ClipSystem
import SwiftUI
import UniformTypeIdentifiers

@Observable final class ItemEditor {
    /// The item being edited, or nil for a new text item.
    let original: ClipboardItem?
    /// The text in the editor, with its bold, italics and so on. Used unless `image` is set.
    var text = AttributedString()
    /// The picture in the editor, as bytes of `imageType`, when the original is an image. Each
    /// rotation or cut-out replaces it; nothing is written until a save.
    private(set) var image: Data?
    /// The clipboard type of `image`: the type it was copied as (a screenshot may be TIFF), or
    /// PNG once a tool has run, since the tools always give back a PNG.
    private var imageType = UTType.png.identifier
    /// True while a save or an image tool runs, so the buttons can step back meanwhile.
    private(set) var isBusy = false
    /// What went wrong last, in the user's words, or nil. Shown under the buttons.
    private(set) var error: String?
    /// Called with the saved item, after a save of either kind. The app model uses it to show
    /// the result in the panel.
    var didSave: (ClipboardItem) -> Void = { _ in }

    private let store: Store
    private let thumbnails: ThumbnailCache

    init(original: ClipboardItem?, store: Store, thumbnails: ThumbnailCache) {
        self.original = original
        self.store = store
        self.thumbnails = thumbnails
    }

    /// Whether the editor shows the picture tools rather than the text box.
    var editsImage: Bool { original?.kind == .image }

    /// Reads the original's bytes into the editor: the first image type for a picture, the
    /// RTF or plain text for anything else. A new item starts empty.
    func load() async {
        guard let original else { return }
        do {
            let data = try await store.data(for: original.id)
            if editsImage {
                let copied = data.firstImage
                image = copied?.data
                imageType = copied?.type ?? imageType
            } else {
                text = try await RichText.attributedString(from: data)
            }
        } catch {
            self.error = "Could not read the item: \(error.localizedDescription)"
        }
    }

    /// Turns the picture a quarter turn.
    func rotate(clockwise: Bool) async {
        guard let image else { return }
        isBusy = true
        defer { isBusy = false }
        guard let turned = await Self.turned(image, clockwise: clockwise) else { return }
        self.image = turned
        imageType = UTType.png.identifier
    }

    /// Off the main thread: a big photo takes over a second to decode and encode.
    @concurrent private static func turned(_ image: Data, clockwise: Bool) async -> Data? {
        ImageEditor.rotated(image, clockwise: clockwise)
    }

    /// Cuts the subject out of the picture, leaving the rest transparent. Says so when Vision
    /// finds nothing in front to keep.
    func removeBackground() async {
        guard let image else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if let cutOut = try await ImageEditor.removingBackground(from: image) {
                self.image = cutOut
                imageType = UTType.png.identifier
                error = nil
            } else {
                error = "No subject was found in this picture."
            }
        } catch {
            self.error = "Could not remove the background: \(error.localizedDescription)"
        }
    }

    /// Writes the editor's content to the history: over the original when `replacing` (same card,
    /// same place, new bytes), else as a new item at the top. Returns whether it worked; the error
    /// is kept otherwise.
    func save(replacing: Bool) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await clipboardData()
            let saved: ClipboardItem?
            if replacing, let original {
                saved = try await store.replaceData(for: original.id, with: data)
                thumbnails.forget(original.id)
            } else {
                saved = try await store.save(CapturedCopy(data: data, sourceApp: sourceApp, copiedAt: .now))
            }
            guard let saved else {
                error = "This item was deleted in the meantime."
                return false
            }
            thumbnails.enrichInBackground(saved)
            didSave(saved)
            return true
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    /// The bytes to store, in the shape a copy from another app has: the picture under its real
    /// type, RTF plus plain text for a text.
    private func clipboardData() async throws -> [ClipboardItemData] {
        if let image { return [ClipboardItemData(type: imageType, data: image)] }
        return try await RichText.clipboardData(for: text)
    }

    /// Whose copy the saved item counts as: the original's app for an edited copy, Yank itself
    /// for a text typed from scratch, so the card's header shows where the content came from.
    private var sourceApp: SourceApp? {
        if let original {
            guard let bundleId = original.sourceAppBundleId else { return nil }
            return SourceApp(bundleId: bundleId, name: original.sourceAppName ?? bundleId)
        }
        return SourceApp(bundleId: Bundle.main.bundleIdentifier ?? "com.thattechedguy.Yank", name: "Yank")
    }
}
