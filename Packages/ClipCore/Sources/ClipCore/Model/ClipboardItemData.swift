import Foundation

// Every type of every pasteboard item is stored, so a paste can offer the other app exactly what
// the source app offered.
/// The bytes of one clipboard type of one saved copy: one row of the `clipboardItemData` table.
public struct ClipboardItemData: Hashable, Sendable {
    /// Which of several pasteboard items this belongs to. A Finder copy of three files is three
    /// pasteboard items, each with its own file URL; everything else is one item, index 0.
    public var pasteboardItemIndex: Int
    /// The clipboard type, a Uniform Type Identifier such as "public.utf8-plain-text" or
    /// "public.png"; see `ClipboardType` for the ones we look at.
    public var type: String
    /// The bytes the source app put on the clipboard for that type.
    public var data: Data

    public init(pasteboardItemIndex: Int = 0, type: String, data: Data) {
        self.pasteboardItemIndex = pasteboardItemIndex
        self.type = type
        self.data = data
    }

    /// The data as UTF-8 text. Bad UTF-8 becomes "�" instead of failing, so a broken copy still
    /// becomes an item.
    public var text: String { String(decoding: data, as: UTF8.self) }

    /// True for a file location whose file is no longer there. Such an item cannot be pasted or
    /// dragged, since the other app would only get a dead link. False for every other type.
    public var isMissingFile: Bool {
        guard type == ClipboardType.fileURL, let url = URL(string: text) else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }
}

extension [ClipboardItemData] {
    /// Whether any file location in the copy points at a file that is gone (`isMissingFile`).
    /// Runs off the caller's thread, so a slow or sleeping volume never stalls the panel.
    @concurrent public func hasMissingFile() async -> Bool { contains(where: \.isMissingFile) }

    /// The web address of a link copy, trimmed: its URL type, else its plain text. The URL type
    /// comes first because the plain text can be a label ("click here"). The one rule for this,
    /// so the card, the fingerprint and the fetch can never disagree about which link it is.
    public var linkAddress: String {
        let address =
            first { $0.type == ClipboardType.url }?.text
            ?? first { $0.type == ClipboardType.plainText }?.text ?? ""
        return address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first image type the copy offers, in `ClipboardType.images` order. The one rule for
    /// this, so the thumbnail, the recognizer, the fingerprint and the editor pick the same image.
    public var firstImage: ClipboardItemData? {
        ClipboardType.images.lazy.compactMap { type in first { $0.type == type } }.first
    }
}

// Plain strings because ClipCore may not import AppKit or UniformTypeIdentifiers
// (scripts/check-imports.sh enforces it). ClipSystem uses the same strings.
/// Clipboard types (UTIs) the app recognises.
public enum ClipboardType {
    /// Plain text. Nearly every copy has it; it is the text we show, search and fingerprint.
    public static let plainText = "public.utf8-plain-text"
    /// A web address, put there by Safari's address bar and most browsers.
    public static let url = "public.url"
    /// A file's location, put there by Finder. Several files are several pasteboard items.
    public static let fileURL = "public.file-url"
    /// A colour from the system colour picker (`NSColor` archived).
    public static let color = "com.apple.cocoa.pasteboard.color"
    // shortcut: a fixed list instead of asking macOS whether a type conforms to public.image,
    // which needs UniformTypeIdentifiers; add a type here if an app's image copy shows as text.
    /// Image types, in the order we prefer them for fingerprinting.
    public static let images = [
        "public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif",
        "public.image",
    ]
}
