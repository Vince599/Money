import Foundation
import LedgerCore

/// The initial book uses the same Shanghai calendar as monthly consumption and date filters.
enum BookDate {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    static var calendar: Calendar { EntryDaySummary.calendar }
    static func month(containing date: Date) -> DateInterval? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let interval = calendar.dateInterval(of: .month, for: date),
              interval.start.timeIntervalSinceReferenceDate.isFinite,
              interval.end.timeIntervalSinceReferenceDate.isFinite,
              interval.start <= date, date < interval.end else { return nil }
        return interval
    }
    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: Locale(identifier: "zh_CN"),
                                       calendar: calendar, timeZone: timeZone))
    }
    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .numeric, time: .shortened, locale: Locale(identifier: "zh_CN"),
                                       calendar: calendar, timeZone: timeZone))
    }
}
