import Foundation

/// The initial book uses the same Shanghai calendar as monthly consumption and date filters.
enum BookDate {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = timeZone; return value
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
