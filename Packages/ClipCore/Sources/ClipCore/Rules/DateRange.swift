import Foundation

// The "Date" choices in the panel's filter menu, and the rule that turns each one into a
// moment: everything copied at or after it is inside the range. The rule takes the current
// time and the calendar as arguments instead of reading the clock itself, so it is a pure
// function (≈ a date-fns helper you pass `now` to) and a test can ask "where does 'today'
// start at 9:30 on 9 November in Brisbane?" without waiting or changing the Mac's clock.
//
// Days are counted with the calendar, not as 24-hour blocks: `Calendar.startOfDay` gives local
// midnight, and `date(byAdding: .day)` steps back whole days, so the day the clocks change
// (23 or 25 hours long) still starts at its own midnight. A fixed `86_400 * 7` would be an
// hour out after every change.
//
// `: String` stores each case as its name, so a saved filter could be a plain string;
// `CaseIterable` gives `allCases` for the menu, in this order.
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

    /// The moment the range starts, or nil for `anyTime`. `now` is the current time and
    /// `calendar` decides where days begin (its time zone) and how long they are; the app
    /// passes `Calendar.current`.
    public func start(now: Date, calendar: Calendar) -> Date? {
        // "Today" starts at midnight; the longer ranges start at the midnight N-1 days before
        // that, so that today itself is one of the N days.
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .lastSevenDays: return calendar.date(byAdding: .day, value: -6, to: today)
        case .lastThirtyDays: return calendar.date(byAdding: .day, value: -29, to: today)
        case .anyTime: return nil
        }
    }
}
