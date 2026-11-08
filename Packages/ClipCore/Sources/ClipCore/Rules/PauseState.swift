import Foundation

// Whether saving is switched off for a while. The user picks "Pause for 15 minutes", "for 1
// hour" or "until I resume" from the menu bar; the capture loop asks this value on every tick
// whether it should skip the clipboard. It is a plain value with no timer inside: a timed pause
// is just the moment it ends, and "is it over?" is a comparison with the time the caller passes
// in. That keeps it free of clocks, so a test can ask "is it paused at 3:14?" without waiting.
// ≈ a tiny discriminated union in TS: `{ kind: 'running' } | { kind: 'until', date } | ...`.
/// Whether, and until when, the app ignores the clipboard.
public enum PauseState: Equatable, Sendable {
    /// Saving as usual.
    case running
    /// Paused until this moment, then running again on its own.
    case pausedUntil(Date)
    /// Paused until the user chooses Resume. Never ends by itself.
    case pausedUntilResumed

    /// Paused for `duration` from `now`. The caller passes the time so this stays a pure
    /// function; the app passes `Date()`.
    public static func paused(for duration: Duration, from now: Date) -> PauseState {
        // A Duration counts in attoseconds; `TimeInterval` (what Date adds) is seconds.
        .pausedUntil(now + TimeInterval(duration.components.seconds))
    }

    /// Whether saving is off at the given moment.
    public func isPaused(at now: Date) -> Bool {
        switch self {
        case .running: false
        case .pausedUntil(let end): now < end
        case .pausedUntilResumed: true
        }
    }
}
