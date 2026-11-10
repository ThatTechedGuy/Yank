import Foundation

// No timer inside: a timed pause is just the moment it ends, compared with the time the caller
// passes in, so a test can ask "is it paused at 3:14?" without waiting.
/// Whether, and until when, the app ignores the clipboard.
public enum PauseState: Equatable, Sendable {
    /// Saving as usual.
    case running
    /// Paused until this moment, then running again on its own.
    case pausedUntil(Date)
    /// Paused until the user chooses Resume. Never ends by itself.
    case pausedUntilResumed

    /// Paused for `duration` from `now`; the app passes `Date()`.
    public static func paused(for duration: Duration, from now: Date) -> PauseState {
        // Whole seconds: the fraction of a second in `duration` is dropped.
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
