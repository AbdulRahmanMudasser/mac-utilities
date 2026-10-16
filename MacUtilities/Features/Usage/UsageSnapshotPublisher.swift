import Foundation

nonisolated enum UsageSnapshotPublisher {
    static func snapshot(for state: PersistedUsage, at date: Date, unit: DataDisplayUnit,
                         calendar: Calendar) throws -> UsageWidgetSnapshot {
        let today = calendar.startOfDay(for: date)
        let keys = Set((0..<UsageStorageLimits.maximumRecords).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { UsageHistory.key(for: $0, calendar: calendar) }
        })
        let records = (state.history ?? []).filter { keys.contains($0.dayKey) }.sorted { $0.dayKey < $1.dayKey }
        let snapshot = UsageWidgetSnapshot(savedAt: date,
            lastObservedAt: (state.history ?? []).map(\.lastObservedAt).max(),
            timeZoneIdentifier: calendar.timeZone.identifier, dataUnit: unit, records: records)
        try snapshot.validate()
        return snapshot
    }
}
