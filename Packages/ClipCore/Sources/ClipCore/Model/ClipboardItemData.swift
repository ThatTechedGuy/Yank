// Foundation is Swift's "batteries": Data, Date, URL, String extras, FileManager. ≈ Node's built-in
// modules plus lodash. Nearly every file imports it.
import Foundation

// A pasteboard (Apple's word for the clipboard) holds one or more *pasteboard items*. Each item
// carries the same content in several *types*, best first: Safari copies rich text as RTF, HTML and
// plain text; Preview copies an image as TIFF and PNG. Apple calls the bytes for one type a
// "representation". We store every one of them, so a paste can offer the other app exactly what
// the source app offered.
//
// These values travel from the main thread (where the clipboard is read) to the Store's
// background work. A `struct` is a value type: handing one over copies it, so no two threads ever
// share it, the way a number or a frozen TS object can't be changed under you. Swift's `Data` is a
// byte buffer like `Uint8Array` or Android's `byte[]`; it is also a value, and copying it is cheap
// because the bytes are only duplicated if one side changes them.
/// The bytes of one clipboard type of one saved copy. ≈ one row of the `clipboardItemData` table.
public struct ClipboardItemData: Hashable, Sendable {
    /// Which of several pasteboard items this belongs to. A Finder copy of three files is three
    /// pasteboard items, each with its own file URL; everything else is one item, index 0.
    public var pasteboardItemIndex: Int
    /// The clipboard type, a Uniform Type Identifier such as "public.utf8-plain-text" or
    /// "public.png". UTIs are Apple's MIME types; see `ClipboardType` for the ones we look at.
    public var type: String
    /// The bytes the source app put on the clipboard for that type.
    public var data: Data

    // ClipSystem and the tests build these from outside this module, so the initializer has to be
    // written out: the one Swift generates for free is only visible inside the module. `= 0` is a
    // default, because almost every copy is a single pasteboard item.
    public init(pasteboardItemIndex: Int = 0, type: String, data: Data) {
        self.pasteboardItemIndex = pasteboardItemIndex
        self.type = type
        self.data = data
    }

    // The rules (kind detection, card text, fingerprint) and the tests read plain-text types
    // through this. Bad UTF-8 is replaced with "�" instead of failing, so a broken copy still
    // becomes an item. (`String(decoding:as:)` ≈ TextDecoder.)
    /// The data as UTF-8 text.
    public var text: String { String(decoding: data, as: UTF8.self) }

    /// True for a file location whose file is no longer there: the user moved or deleted it
    /// since the copy. Such an item cannot be pasted or dragged, since the other app would
    /// only get a dead link; the card says so instead. False for every other type.
    public var isMissingFile: Bool {
        guard type == ClipboardType.fileURL, let url = URL(string: text) else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }
}

// `extension [ClipboardItemData]` adds a member to arrays of this one type.
extension [ClipboardItemData] {
    /// The web address of a link copy: its URL type, or its plain text when an app offered only
    /// that, without the spaces and line breaks around it. The URL type comes first because the
    /// plain text can be a label ("click here") rather than the address. The one rule for this,
    /// so the card, the fingerprint and the fetch can never disagree about which link it is.
    public var linkAddress: String {
        let address =
            first { $0.type == ClipboardType.url }?.text
            ?? first { $0.type == ClipboardType.plainText }?.text ?? ""
        return address.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// UTIs the rules care about. Defined here, as strings, because ClipCore may not import AppKit
// (where `NSPasteboard.PasteboardType` lives) or UniformTypeIdentifiers; the import check enforces
// that so the core stays testable without macOS UI frameworks. ClipSystem uses the same strings.
//
// An enum with no cases is Swift's idiom for a namespace of constants (≈ a TS `namespace` or a
// Kotlin `object`): it can't be instantiated, only its `static` members are used.
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
