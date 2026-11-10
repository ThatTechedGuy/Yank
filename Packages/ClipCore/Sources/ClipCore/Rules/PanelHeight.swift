import Foundation

// In points. The user drags the panel's top edge; the limits keep it from becoming a sliver or
// half the screen.
/// The panel's height and its limits.
public enum PanelHeight {
    /// The height on first launch, before the user has dragged.
    public static let initial: Double = 332
    public static let minimum: Double = 252
    public static let maximum: Double = 412

    /// `height`, pulled back inside the limits.
    public static func clamped(_ height: Double) -> Double {
        min(maximum, max(minimum, height))
    }
}
