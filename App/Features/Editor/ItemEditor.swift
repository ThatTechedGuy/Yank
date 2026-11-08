// The editor's state and its two ways out: what the editor window shows (a text with its
// formatting, or a picture), the changes made to it, and saving as a new item or over the
// original. The view reads it and re-renders when it changes (`@Observable`, like the
// panel's model). One of these is made per open editor window; it holds the item being
// edited, or nil for a blank text item typed from scratch. ≈ a form's state object.
//
// The work itself is elsewhere: RichText and ImageEditor (ClipSystem) convert and transform,
// the Store writes. This class only sequences them and keeps the result.
import ClipCore
import ClipSystem
import SwiftUI
import UniformTypeIdentifiers

@Observable final class ItemEditor {
    /// The item being edited, or nil for a new text item.
    let original: ClipboardItem?
    /// The text in the editor, with its bold, italics and so on. Used unless `image` is set.
    var text = AttributedString()
    /// The picture in the editor, as PNG bytes, when the original is an image. Each rotation
    /// or cut-out replaces it; nothing is written until a save.
    private(set) var image: Data?
    /// True while a save or an image tool runs, so the buttons can step back meanwhile.
    private(set) var isBusy = false
    /// What went wrong last, in the user's words, or nil. Shown under the buttons.
    private(set) var error: String?
    /// Called with the saved item, after a save of either kind. The app model uses it to show
    /// the result in the panel.
    var didSave: (ClipboardItem) -> Void = { _ in }

    private let store: Store
    private let enricher: Enricher
    private let thumbnails: ThumbnailCache

    init(original: ClipboardItem?, store: Store, enricher: Enricher, thumbnails: ThumbnailCache) {
        self.original = original
        self.store = store
        self.enricher = enricher
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
                image =
                    ClipboardType.images.lazy
                    .compactMap({ type in data.first { $0.type == type } }).first?.data
            } else {
                text = try await RichText.attributedString(from: data)
            }
        } catch {
            self.error = "Could not read the item: \(error.localizedDescription)"
        }
    }

    /// Turns the picture a quarter turn, the way Preview's Rotate Left and Rotate Right do.
    func rotate(clockwise: Bool) {
        guard let image, let turned = ImageEditor.rotated(image, clockwise: clockwise) else { return }
        self.image = turned
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
                error = nil
            } else {
                error = "No subject was found in this picture."
            }
        } catch {
            self.error = "Could not remove the background: \(error.localizedDescription)"
        }
    }

    /// Writes the editor's content to the history: over the original when `replacing` (same
    /// card, same place, new bytes), else as a new item at the top. The new bytes get their
    /// preview in the background the way a fresh copy does, and the card's cached picture is
    /// dropped so it draws the new one. Returns whether it worked; the error is kept otherwise.
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
            enricher.enrichInBackground(saved)
            didSave(saved)
            return true
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    /// The bytes to store, in the shape a copy from another app has: a PNG for a picture, RTF
    /// plus plain text for a text.
    private func clipboardData() async throws -> [ClipboardItemData] {
        if let image { return [ClipboardItemData(type: UTType.png.identifier, data: image)] }
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
