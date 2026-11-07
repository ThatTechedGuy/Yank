import Foundation

// What CaptureService hands to Store after the privacy rules said "save" and the clipboard was
// read. It is the raw copy; Store derives the kind, card text and fingerprint from it, off the
// main thread, and turns it into a `ClipboardItem` row. ≈ a request DTO before it becomes a model.
/// One copy as read from the clipboard, before it is saved.
public struct CapturedCopy: Sendable {
    /// Every type of every pasteboard item, in the order the source app listed them.
    public var data: [ClipboardItemData]
    /// The app in front when the copy happened, so the card can say "from Safari". `nil` when no
    /// app was in front or it has no bundle id. (`SourceApp?` ≈ `SourceApp | null`, checked by
    /// the compiler.)
    public var sourceApp: SourceApp?
    /// When the clipboard changed. Taken the moment the change was noticed, not after the settle
    /// wait, so the item's time is the time of the copy.
    public var copiedAt: Date

    public init(data: [ClipboardItemData], sourceApp: SourceApp?, copiedAt: Date) {
        self.data = data
        self.sourceApp = sourceApp
        self.copiedAt = copiedAt
    }
}
