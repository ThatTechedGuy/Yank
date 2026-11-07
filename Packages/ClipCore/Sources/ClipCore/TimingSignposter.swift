import Foundation
import os

// Timing markers: a named interval with a start and an end, so the app can be measured against
// its speed limits (opening the panel, a search). Each interval goes to Apple's `OSSignposter`,
// which is what Instruments draws on its timeline, exactly as before. On top of that, a debug
// build remembers the last few durations of every marker name in memory, because the sandbox
// gives an app no way to read its own signposts back from the system log: the Developer window
// shows those remembered durations as a chart. A release build keeps only the signposts and
// records nothing.
//
// Used like the signposter it wraps, so call sites do not change:
//     let state = Log.timing.beginInterval("Open panel")
//     ...
//     Log.timing.endInterval("Open panel", state)
//
// ≈ `performance.mark` + `performance.measure` on the web, with `performance.getEntries()`
// available only in a dev build.
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

    /// Starts an interval. `name` must be a literal string (a `StaticString`), which is what
    /// signposts require so the name costs nothing to record.
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

        // The remembered intervals, shared by every copy of this struct (a struct is copied on
        // assignment, but the lock inside is a reference, so all copies see one list). The lock
        // makes it safe to record from any thread: `withLock` runs the closure while no other
        // thread can touch the list. ≈ a `synchronized` block in Java.
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
