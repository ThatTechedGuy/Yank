import Foundation

// The raw copy CaptureService hands to Store, which derives the kind, card text and fingerprint
// from it off the main thread.
/// One copy as read from the clipboard, before it is saved.
public struct CapturedCopy: Sendable {
    /// Every type of every pasteboard item, in the order the source app listed them.
    public var data: [ClipboardItemData]
    /// The app in front when the copy happened. `nil` when no app was in front or it has no
    /// bundle id.
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
