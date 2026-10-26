import Foundation

/// When a nudge is due. Times are local "HH:mm"; days are Calendar weekdays (1 = Sunday … 7 = Saturday).
enum Schedule {
    static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    static func parseTime(_ s: String) -> (hour: Int, minute: Int)? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// "daily", "weekdays", "weekends", or a list like "mon,wed,fri".
    static func parseDays(_ s: String) -> [Int]? {
        switch s.lowercased() {
        case "daily", "every", "everyday", "all": return Array(1...7)
        case "weekdays": return [2, 3, 4, 5, 6]
        case "weekends": return [1, 7]
        default:
            let days = s.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).prefix(3) }
            let nums = days.compactMap { d in dayNames.firstIndex(of: String(d)).map { $0 + 1 } }
            return nums.count == days.count && !nums.isEmpty ? Array(Set(nums)).sorted() : nil
        }
    }

    static func describeDays(_ days: [Int]) -> String {
        let set = Set(days)
        if set.count == 7 { return "daily" }
        if set == [2, 3, 4, 5, 6] { return "weekdays" }
        if set == [1, 7] { return "weekends" }
        return days.sorted().map { dayNames[$0 - 1] }.joined(separator: ",")
    }

    /// The most recent scheduled moment at or before `now` (looks back one day, so a late-evening
    /// nudge missed while the Mac slept past midnight still counts).
    static func lastOccurrence(time: String, days: [Int], before now: Date, calendar cal: Calendar = .current) -> Date? {
        guard let t = parseTime(time) else { return nil }
        for back in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -back, to: now),
                  let at = cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day),
                  at <= now, days.contains(cal.component(.weekday, from: at)) else { continue }
            return at
        }
        return nil
    }

    /// A one-off moment: "yyyy-MM-dd" plus "HH:mm", local time.
    static func moment(date: String, time: String, calendar cal: Calendar = .current) -> Date? {
        let d = date.split(separator: "-").compactMap { Int($0) }
        guard d.count == 3, let t = parseTime(time) else { return nil }
        return cal.date(from: DateComponents(year: d[0], month: d[1], day: d[2], hour: t.hour, minute: t.minute))
    }

    static func dayString(_ date: Date, calendar cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The next scheduled moment after `now`, within the coming week.
    static func nextOccurrence(time: String, days: [Int], after now: Date, calendar cal: Calendar = .current) -> Date? {
        guard let t = parseTime(time) else { return nil }
        for ahead in 0...7 {
            guard let day = cal.date(byAdding: .day, value: ahead, to: now),
                  let at = cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day),
                  at > now, days.contains(cal.component(.weekday, from: at)) else { continue }
            return at
        }
        return nil
    }
}
