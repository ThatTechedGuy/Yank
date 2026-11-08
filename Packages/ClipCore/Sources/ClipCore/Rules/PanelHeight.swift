import Foundation

// How tall the panel is, in points. The user drags its top edge; the height is saved and kept
// between a minimum and a maximum (Paste's own values), so the panel can never be dragged to a
// sliver or to half the screen. The numbers live here, with the rule that clamps them, so a
// test can pin them without a window. (A point is a layout unit; on a Retina screen it is two
// pixels, ≈ a CSS px or an Android dp.)
/// The panel's height and its limits.
public enum PanelHeight {
    /// The height on first launch, before the user has dragged.
    public static let initial: Double = 332
    public static let minimum: Double = 252
    public static let maximum: Double = 412

    /// `height`, pulled back inside the limits. ≈ `Math.min(max, Math.max(min, h))`.
    public static func clamped(_ height: Double) -> Double {
        min(maximum, max(minimum, height))
    }
}
