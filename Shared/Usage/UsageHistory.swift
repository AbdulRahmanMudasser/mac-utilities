import Foundation

nonisolated struct DailyUsageRecord: Codable, Equatable, Identifiable, Sendable {
    var dayKey: String
    var downloaded: UInt64
    var uploaded: UInt64
    var firstObservedAt: Date
    var lastObservedAt: Date
    var isIncomplete: Bool

    var id: String { dayKey }
    var combined: UInt64 { UsageHistory.add(downloaded, uploaded) }
}

nonisolated enum UsageHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case thisMonth = "This Month"
    case thirtyDays = "30 Days"
    case fifteenDays = "15 Days"
    case sevenDays = "7 Days"

    var id: Self { self }

    var averageTitle: String {
        switch self {
        case .thisMonth: "Month Average"
        case .sevenDays: "7 Day Average"
        case .fifteenDays: "15 Day Average"
        case .thirtyDays: "30 Day Average"
        }
    }

    func dates(through now: Date, calendar: Calendar = UsageHistory.calendar()) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let count: Int
        switch self {
        case .thisMonth: count = calendar.component(.day, from: today)
        case .thirtyDays: count = 30
        case .fifteenDays: count = 15
        case .sevenDays: count = 7
        }
        return (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }
}

nonisolated struct UsageHistoryDay: Identifiable, Equatable, Sendable {
    let date: Date
    let dayKey: String
    let record: DailyUsageRecord?
    var id: String { dayKey }
}

nonisolated struct MonthlyUsage: Identifiable, Equatable, Sendable {
    let month: Int
    var downloaded: UInt64
    var uploaded: UInt64
    var id: Int { month }
    var combined: UInt64 { UsageHistory.add(downloaded, uploaded) }
}

nonisolated struct UsageMonthID: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.year == rhs.year ? lhs.month < rhs.month : lhs.year < rhs.year
    }
}

nonisolated struct UsageMonthDifference: Equatable, Sendable {
    let magnitude: UInt64
    let comparison: ComparisonResult
}

nonisolated enum UsageHistory {
    static func difference(from baseline: UInt64, to value: UInt64) -> UsageMonthDifference {
        if value > baseline { return UsageMonthDifference(magnitude: value - baseline, comparison: .orderedDescending) }
        if value < baseline { return UsageMonthDifference(magnitude: baseline - value, comparison: .orderedAscending) }
        return UsageMonthDifference(magnitude: 0, comparison: .orderedSame)
    }
    static func years(records: [DailyUsageRecord], currentYear: Int) -> [Int] {
        let years = records.compactMap { record -> Int? in
            guard validKey(record.dayKey) else { return nil }
            return Int(record.dayKey.prefix(4))
        }
        return Set(years + [currentYear]).sorted(by: >)
    }

    static func monthly(records: [DailyUsageRecord], year: Int) -> [MonthlyUsage] {
        var months: [Int: MonthlyUsage] = [:]
        for record in records {
            guard validKey(record.dayKey) else { continue }
            let parts = record.dayKey.split(separator: "-")
            guard Int(parts[0]) == year, let month = Int(parts[1]) else { continue }
            var total = months[month] ?? MonthlyUsage(month: month, downloaded: 0, uploaded: 0)
            total.downloaded = add(total.downloaded, record.downloaded)
            total.uploaded = add(total.uploaded, record.uploaded)
            months[month] = total
        }
        return months.values.sorted { $0.month < $1.month }
    }
    nonisolated static func calendar(timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func key(for date: Date, calendar: Calendar = calendar()) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func validKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard key.count == 10, parts.count == 3, (1...9999).contains(parts[0]),
              (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return false }
        let calendar = calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
        return self.key(for: date, calendar: calendar) == key
    }

    static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let sum = a.addingReportingOverflow(b)
        return sum.overflow ? .max : sum.partialValue
    }

    // Preserve the envelope's combined-byte invariant even at the integer ceiling.
    static func accumulating(_ delta: InterfaceByteCount, into current: InterfaceByteCount) -> InterfaceByteCount {
        let available = UInt64.max - add(current.downloaded, current.uploaded)
        let download = min(delta.downloaded, available)
        let upload = min(delta.uploaded, available - download)
        return InterfaceByteCount(downloaded: current.downloaded + download, uploaded: current.uploaded + upload)
    }

    static func days(records: [DailyUsageRecord], range: UsageHistoryRange, now: Date,
                     calendar: Calendar = calendar()) -> [UsageHistoryDay] {
        let indexed = Dictionary(records.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
        return range.dates(through: now, calendar: calendar).map {
            let key = key(for: $0, calendar: calendar)
            return UsageHistoryDay(date: $0, dayKey: key, record: indexed[key])
        }
    }

    // Average observed traffic over every calendar day in the selected range.
    static func average(_ days: [UsageHistoryDay]) -> UInt64? {
        let records = days.compactMap(\.record)
        guard !days.isEmpty, !records.isEmpty else { return nil }
        let count = UInt64(days.count)
        // Divide before summing so even very large range totals cannot overflow.
        let whole = records.reduce(UInt64(0)) { $0 + $1.combined / count }
        let remainder = records.reduce(UInt64(0)) { $0 + $1.combined % count }
        return whole + remainder / count
    }

    static func totals(_ days: [UsageHistoryDay]) -> InterfaceByteCount {
        days.reduce(InterfaceByteCount(downloaded: 0, uploaded: 0)) { total, day in
            InterfaceByteCount(downloaded: add(total.downloaded, day.record?.downloaded ?? 0),
                               uploaded: add(total.uploaded, day.record?.uploaded ?? 0))
        }
    }

}
