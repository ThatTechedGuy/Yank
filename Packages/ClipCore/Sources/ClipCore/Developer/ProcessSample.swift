import Foundation

// For the Developer window of a debug build. The memory number is the "physical footprint" the
// `footprint` tool and Instruments report, which the app's memory limits are written against.
// `proc_pid_rusage` takes a few microseconds, so sampling once a second costs nothing.
#if DEBUG
    /// This process's CPU time and memory footprint at one moment.
    public struct ProcessSample: Sendable {
        /// CPU time used by the process so far, user and kernel time together.
        public let cpuTime: Duration
        /// Physical footprint in bytes: the memory the process is charged for.
        public let footprint: Int
        /// When the sample was taken, on a clock that only moves forward.
        public let takenAt: ContinuousClock.Instant

        public init(cpuTime: Duration, footprint: Int, takenAt: ContinuousClock.Instant) {
            self.cpuTime = cpuTime
            self.footprint = footprint
            self.takenAt = takenAt
        }

        /// Reads the process's current numbers from the kernel.
        public static func current() -> ProcessSample {
            // Version 4 of the struct has every field we read.
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { untyped in
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, untyped)
                }
            }
            // The kernel reports CPU time in Mach ticks, not nanoseconds: 125/3 ns each on Apple
            // silicon.
            var timebase = mach_timebase_info()
            mach_timebase_info(&timebase)
            let ticks = status == 0 ? info.ri_user_time + info.ri_system_time : 0
            let nanoseconds = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
            return ProcessSample(
                cpuTime: .nanoseconds(Int64(nanoseconds)),
                footprint: status == 0 ? Int(info.ri_phys_footprint) : 0,
                takenAt: .now)
        }

        /// The share of one CPU core this process used between `earlier` and this sample, as a
        /// percentage: 100 means one core busy the whole time. Zero when no time has passed.
        public func cpuPercent(since earlier: ProcessSample) -> Double {
            let wall = takenAt - earlier.takenAt
            guard wall > .zero else { return 0 }
            return (cpuTime - earlier.cpuTime) / wall * 100
        }
    }
#endif
