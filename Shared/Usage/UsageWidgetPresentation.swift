import Foundation

nonisolated struct UsageWidgetTimelineSchedule: Equatable, Sendable {
    let nextLocalMidnight: Date?
    let boundaryEntryAt: Date?
    let refreshAt: Date
}

nonisolated struct UsageWidgetDayPresentation: Equatable, Identifiable, Sendable {
    let date: Date
    let dayKey: String
    let downloaded: UInt64?
    let uploaded: UInt64?

    var id: String { dayKey }
    var hasRecord: Bool { downloaded != nil && uploaded != nil }
}

nonisolated struct UsageWidgetReadingPresentation: Equatable, Sendable {
    let range: UsageHistoryRange
    let days: [UsageWidgetDayPresentation]
    let timeZoneIdentifier: String
    let dataUnit: DataDisplayUnit
    let savedAt: Date
    let lastObservedAt: Date?
    let downloaded: UInt64
    let uploaded: UInt64
    let combined: UInt64
    let average: UInt64?
    let maximumDailyBytes: UInt64

    var scale: Double { UsageChartPresentation.scale(maximumBytes: maximumDailyBytes, unit: dataUnit) }
    var scaleLabel: String { UsageChartPresentation.scaleLabel(scale: scale, unit: dataUnit) }

    func axisDayKeys(maximumCount: Int) -> [String] {
        guard maximumCount > 0, !days.isEmpty else { return [] }
        guard days.count > maximumCount else { return days.map(\.dayKey) }
        guard maximumCount > 1 else { return [days.last!.dayKey] }
        return (0..<maximumCount).map { index in
            let position = Int((Double(index) * Double(days.count - 1) / Double(maximumCount - 1)).rounded())
            return days[position].dayKey
        }
    }
}

nonisolated enum UsageWidgetPresentation: Equatable, Sendable {
    case openAppToLoadUsage(range: UsageHistoryRange)
    case unavailable(range: UsageHistoryRange)
    case noUsageHistory(UsageWidgetReadingPresentation)
    case noDataInRange(UsageWidgetReadingPresentation)
    case readings(UsageWidgetReadingPresentation)

    static func timelineSchedule(now: Date, calendar: Calendar = UsageHistory.calendar()) -> UsageWidgetTimelineSchedule {
        let thirtyMinuteDeadline = now.addingTimeInterval(30 * 60)
        let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0), matchingPolicy: .nextTime,
                                         repeatedTimePolicy: .first, direction: .forward)
        let refreshAt = min(midnight ?? thirtyMinuteDeadline, thirtyMinuteDeadline)
        let boundaryEntryAt = midnight.flatMap { $0 <= thirtyMinuteDeadline ? $0 : nil }
        return UsageWidgetTimelineSchedule(nextLocalMidnight: midnight,
                                           boundaryEntryAt: boundaryEntryAt,
                                           refreshAt: refreshAt)
    }

    var range: UsageHistoryRange {
        switch self {
        case .openAppToLoadUsage(let range), .unavailable(let range): range
        case .noUsageHistory(let reading), .noDataInRange(let reading), .readings(let reading): reading.range
        }
    }

    static func make(snapshot: UsageWidgetSnapshot?, range: UsageHistoryRange, now: Date,
                     calendar: Calendar = UsageHistory.calendar()) -> UsageWidgetPresentation {
        guard let snapshot else { return .openAppToLoadUsage(range: range) }
        guard snapshot.savedAt <= now,
              snapshot.lastObservedAt.map({ $0 <= now }) != false,
              snapshot.records.allSatisfy({ $0.lastObservedAt <= now }),
              (try? snapshot.validate()) != nil else {
            return .unavailable(range: range)
        }

        let historyDays = UsageHistory.days(records: snapshot.records, range: range, now: now, calendar: calendar)
        let days = historyDays.map { day in
            UsageWidgetDayPresentation(date: day.date, dayKey: day.dayKey,
                                       downloaded: day.record?.downloaded, uploaded: day.record?.uploaded)
        }
        let totals = UsageHistory.totals(historyDays)
        let summary = UsageWidgetReadingPresentation(
            range: range,
            days: days,
            timeZoneIdentifier: calendar.timeZone.identifier,
            dataUnit: snapshot.dataUnit,
            savedAt: snapshot.savedAt,
            lastObservedAt: snapshot.lastObservedAt,
            downloaded: totals.downloaded,
            uploaded: totals.uploaded,
            combined: UsageHistory.add(totals.downloaded, totals.uploaded),
            average: UsageHistory.average(historyDays),
            maximumDailyBytes: historyDays.compactMap { $0.record?.combined }.max() ?? 0
        )

        if snapshot.records.isEmpty { return .noUsageHistory(summary) }
        if historyDays.allSatisfy({ $0.record == nil }) { return .noDataInRange(summary) }
        return .readings(summary)
    }
}
