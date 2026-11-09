// CryptoKit is Apple's hashing and encryption library (SHA-256 here). ≈ Node's `crypto`.
import CryptoKit
import Foundation

// The fingerprint that finds a repeat copy: copy the same thing twice and the item
// moves to the top instead of appearing twice. It hashes only the part of the content that
// defines "the same": apps add different extra types (RTF, HTML, private formats) to the same
// text, and those must not make two copies look different.
/// Computes `contentFingerprint` for a copy.
public enum DuplicateKey {
    /// The SHA-256 hex digest of the copy's defining content.
    public static func make(kind: ItemKind, data: [ClipboardItemData]) -> String {
        // What counts as "the content" per kind. A kind prefix keeps a text "a.png" from
        // colliding with a file named a.png.
        let content: Data
        switch kind {
        case .text:
            // The plain text is what the user sees, so it is what counts; the same words with
            // different RTF around them are one item. A copy with no text at all (rare: RTF
            // only) falls back to its first type's bytes. (`??` is `??` in TS: the first value
            // that isn't nil.)
            content = first(ClipboardType.plainText, in: data) ?? data.first?.data ?? Data()
        case .link:
            // The address, with the spaces and line breaks around it removed: the same link
            // copied from a browser's address bar ("https://a.com") and from a chat message
            // ("https://a.com\n") is one item.
            content = Data(data.linkAddress.utf8)
        case .image:
            // This compares encoded bytes, not pixels.
            // shortcut: the same picture in two encodings (PNG+TIFF from Preview, TIFF only from
            // a screenshot) is always two items; upgrade to a hash of the decoded pixels if repeat
            // image copies pile up in the list.
            content = data.firstImage?.data ?? Data()
        case .file:
            // All file URLs in order: three files copied together are one item.
            content = Data(
                data.filter { $0.type == ClipboardType.fileURL }.map(\.text).joined(separator: "\n")
                    .utf8)
        case .color:
            content = first(ClipboardType.color, in: data) ?? Data()
        }
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: content)
        // Store the hash as 64 hex characters, so it fits a plain text column and is easy to
        // compare in SQL. The digest is a sequence of bytes; `%02x` prints each as two hex digits.
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func first(_ type: String, in data: [ClipboardItemData]) -> Data? {
        data.first { $0.type == type }?.data
    }
}
