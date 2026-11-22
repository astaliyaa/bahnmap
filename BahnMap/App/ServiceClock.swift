import Foundation

/// Converts between wall-clock dates and timetable (service day, seconds) pairs.
enum ServiceClock {
    static let timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    static func civilDay(_ date: Date) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return CivilDate.days(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Day index into the timetable and seconds since that day's midnight.
    static func query(_ date: Date, _ tt: Timetable) -> (day: Int32, seconds: Int32) {
        let day = Int32(civilDay(date) - Int(tt.data.firstDay))
        let start = calendar.startOfDay(for: date)
        return (day, Int32(date.timeIntervalSince(start)))
    }

    static func isCovered(_ date: Date, _ tt: Timetable) -> Bool {
        let d = query(date, tt).day
        return d >= 0 && d < tt.data.dayCount
    }

    static func date(civilDay: Int) -> Date {
        let c = CivilDate.components(civilDay)
        return calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) ?? Date()
    }

    static func hhmm(_ seconds: Int32) -> String {
        let s = ((Int(seconds) % 86400) + 86400) % 86400
        return String(format: "%02d:%02d", s / 3600, (s / 60) % 60)
    }

    static func duration(_ seconds: Int32) -> String {
        let m = Int(seconds) / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func shortDuration(_ seconds: Int32) -> String {
        let m = Int(seconds) / 60
        return m < 60 ? "\(m)′" : String(format: "%d:%02d h", m / 60, m % 60)
    }

    static func dateString(civilDay: Int) -> String {
        date(civilDay: civilDay).formatted(date: .abbreviated, time: .omitted)
    }
}
