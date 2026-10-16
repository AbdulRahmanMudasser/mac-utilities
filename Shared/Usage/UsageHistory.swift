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

nonisolated enum UsageHistory {
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

    static func totals(_ days: [UsageHistoryDay]) -> InterfaceByteCount {
        days.reduce(InterfaceByteCount(downloaded: 0, uploaded: 0)) { total, day in
            InterfaceByteCount(downloaded: add(total.downloaded, day.record?.downloaded ?? 0),
                               uploaded: add(total.uploaded, day.record?.uploaded ?? 0))
        }
    }

}
