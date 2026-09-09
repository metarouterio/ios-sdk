import Foundation

/// Shared monotonic clock for elapsed-time windows (bridge dedup TTL, session
/// inactivity timeout).
///
/// Monotonic: immune to wall-clock jumps (NTP, user time changes), and — unlike
/// `ProcessInfo.systemUptime` or `mach_absolute_time`, which pause in deep sleep —
/// `mach_continuous_time` is documented to keep incrementing while the device is
/// asleep, so a window measures real elapsed time, which is what both a redelivery
/// window and an inactivity window mean. Resets on process restart, so values must
/// never be persisted — cross-restart elapsed time needs wall-clock.
internal enum MonotonicClock {
    // The tick→nanosecond scaling factors are process-constant; fetch once, not on
    // every clock read.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func continuousMillis() -> Int64 {
        let nanos = mach_continuous_time() * UInt64(timebase.numer) / UInt64(timebase.denom)
        return Int64(nanos / 1_000_000)
    }
}
