import Foundation
import os

// Wraps `OSSignposter` with the same calls. A debug build also remembers the last durations of
// every marker name for the Developer window, because the sandbox gives an app no way to read its
// own signposts back from the system log. A release build records nothing.
/// Timing markers for Instruments that, in debug builds, also keep their last durations.
public struct TimingSignposter: Sendable {
    private let signposter: OSSignposter

    /// What `beginInterval` hands out and `endInterval` takes back: the signpost's own state
    /// and, in debug builds, when the interval began.
    public struct IntervalState: Sendable {
        fileprivate let signpost: OSSignpostIntervalState
        #if DEBUG
            fileprivate let start: ContinuousClock.Instant
        #endif
    }

    init(subsystem: String, category: String) {
        signposter = OSSignposter(subsystem: subsystem, category: category)
    }

    /// Starts an interval. Signposts require a literal `name`, so it costs nothing to record.
    public func beginInterval(_ name: StaticString) -> IntervalState {
        #if DEBUG
            IntervalState(signpost: signposter.beginInterval(name), start: .now)
        #else
            IntervalState(signpost: signposter.beginInterval(name))
        #endif
    }

    /// Ends the interval `beginInterval` started, with the same name.
    public func endInterval(_ name: StaticString, _ state: IntervalState) {
        signposter.endInterval(name, state.signpost)
        #if DEBUG
            record(TimingInterval(name: "\(name)", endedAt: .now, duration: .now - state.start))
        #endif
    }

    #if DEBUG
        /// How many durations are kept per marker name. Enough for a "p95 over 20 tries" check.
        public static let keptPerName = 20

        // The lock is a reference, so every copy of this struct shares one list.
        private let recent = OSAllocatedUnfairLock<[TimingInterval]>(initialState: [])

        /// Every remembered interval, oldest first, at most `keptPerName` per marker name.
        public var recentIntervals: [TimingInterval] {
            recent.withLock { $0 }
        }

        /// Adds one finished interval and forgets the oldest with the same name beyond the limit.
        private func record(_ interval: TimingInterval) {
            recent.withLock { intervals in
                intervals.append(interval)
                if intervals.count(where: { $0.name == interval.name }) > Self.keptPerName,
                    let oldest = intervals.firstIndex(where: { $0.name == interval.name })
                {
                    intervals.remove(at: oldest)
                }
            }
        }
    #endif
}

#if DEBUG
    /// One finished timing marker: its name, when it ended and how long it took.
    public struct TimingInterval: Sendable, Identifiable, Hashable {
        /// A fresh id per interval, so a chart can tell two intervals of the same length apart.
        public let id = UUID()
        public let name: String
        public let endedAt: Date
        public let duration: Duration

        public init(name: String, endedAt: Date, duration: Duration) {
            self.name = name
            self.endedAt = endedAt
            self.duration = duration
        }
    }
#endif
