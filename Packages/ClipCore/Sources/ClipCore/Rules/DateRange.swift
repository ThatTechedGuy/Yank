import Foundation

// Days are counted with the calendar, not as 24-hour blocks, so the day the clocks change (23 or
// 25 hours long) still starts at its own midnight. A fixed `86_400 * 7` would be an hour out
// after every change. The filter menu lists the cases in this order.
/// How far back the panel looks: today, the last 7 or 30 days, or any time.
public enum DateRange: String, CaseIterable, Sendable {
    /// The local calendar day that `now` falls in, from its midnight.
    case today
    /// Today and the six calendar days before it: seven days, from the first one's midnight.
    case lastSevenDays
    /// Today and the 29 calendar days before it.
    case lastThirtyDays
    /// No limit.
    case anyTime

    /// The moment the range starts, or nil for `anyTime`. Takes the time and the calendar instead
    /// of reading the clock, so tests can pick both; the app passes `Calendar.current`.
    public func start(now: Date, calendar: Calendar) -> Date? {
        // The longer ranges start N-1 days before today's midnight, so today is one of the N days.
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .lastSevenDays: return calendar.date(byAdding: .day, value: -6, to: today)
        case .lastThirtyDays: return calendar.date(byAdding: .day, value: -29, to: today)
        case .anyTime: return nil
        }
    }
}
