import Foundation

nonisolated enum UsageAccounting {
    static func migrate(_ state: inout PersistedUsage) {
        guard state.history == nil else { return }
        state.history = []
        let parts = state.localDayKey.split(separator: "-").compactMap { Int($0) }
        let calendar = UsageHistory.calendar(timeZone: TimeZone(identifier: state.timeZoneIdentifier ?? "") ?? .autoupdatingCurrent)
        let savedDay = parts.count == 3 ? calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) : nil
        if let observed = state.lastSampleDate ?? savedDay {
            state.history = [DailyUsageRecord(dayKey: state.localDayKey, downloaded: state.downloaded,
                uploaded: state.uploaded, firstObservedAt: observed, lastObservedAt: observed, isIncomplete: true)]
        }
        state.schemaVersion = 3
    }

    static func record(_ delta: InterfaceByteCount, from start: Date, to end: Date, state: inout PersistedUsage) {
        var history = state.history ?? []
        if let i = history.firstIndex(where: { $0.dayKey == state.localDayKey }) {
            let total = UsageHistory.accumulating(delta, into: InterfaceByteCount(downloaded: history[i].downloaded, uploaded: history[i].uploaded))
            history[i].downloaded = total.downloaded
            history[i].uploaded = total.uploaded
            history[i].firstObservedAt = min(history[i].firstObservedAt, start)
            history[i].lastObservedAt = max(history[i].lastObservedAt, end)
            history[i].isIncomplete = history[i].isIncomplete || state.isIncomplete
        } else {
            let total = UsageHistory.accumulating(delta, into: InterfaceByteCount(downloaded: 0, uploaded: 0))
            history.append(DailyUsageRecord(dayKey: state.localDayKey, downloaded: total.downloaded,
                uploaded: total.uploaded, firstObservedAt: start, lastObservedAt: end, isIncomplete: state.isIncomplete))
        }
        state.history = history.sorted { $0.dayKey < $1.dayKey }
    }
}
