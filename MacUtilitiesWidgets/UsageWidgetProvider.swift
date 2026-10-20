import Foundation
import WidgetKit

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let presentation: UsageWidgetPresentation
}

struct UsageWidgetProvider: AppIntentTimelineProvider {
    typealias Entry = UsageWidgetEntry
    typealias Intent = UsageWidgetConfigurationIntent

    private enum SnapshotReadFailure: Error {
        case missingProjection
        case missingFile
        case unavailable
    }

    func placeholder(in context: Context) -> UsageWidgetEntry {
        Self.previewEntry(range: .thisMonth, now: .now)
    }

    func snapshot(for configuration: UsageWidgetConfigurationIntent, in context: Context) async -> UsageWidgetEntry {
        let now = Date()
        if context.isPreview { return Self.previewEntry(range: configuration.historyRange, now: now) }
        return makeEntry(from: readSnapshot(), range: configuration.historyRange, now: now)
    }

    func timeline(for configuration: UsageWidgetConfigurationIntent, in context: Context) async -> Timeline<UsageWidgetEntry> {
        let now = Date()
        let range = configuration.historyRange
        if context.isPreview {
            return Timeline(entries: [Self.previewEntry(range: range, now: now)], policy: .after(now.addingTimeInterval(30 * 60)))
        }

        let calendar = UsageHistory.calendar()
        let schedule = UsageWidgetPresentation.timelineSchedule(now: now, calendar: calendar)
        let snapshot = readSnapshot()
        let first = makeEntry(from: snapshot, range: range, now: now, calendar: calendar)
        var entries = [first]
        if let boundaryEntryAt = schedule.boundaryEntryAt {
            entries.append(makeEntry(from: snapshot, range: range, now: boundaryEntryAt, calendar: calendar))
        }
        return Timeline(entries: entries, policy: .after(schedule.refreshAt))
    }

    private func readSnapshot() -> Result<UsageWidgetSnapshot, SnapshotReadFailure> {
        for attempt in 0..<2 {
            do {
                let paths = try UsageStoragePaths.resolve()
                return .success(try UsageWidgetSnapshotReader.read(at: paths.stateURL))
            } catch let error as UsageWidgetSnapshotReader.ReadError {
                if case .missingProjection = error { return .failure(.missingProjection) }
                if attempt == 1 { return .failure(.unavailable) }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                if attempt == 1 { return .failure(.missingFile) }
            } catch {
                if attempt == 1 { return .failure(.unavailable) }
            }
        }
        return .failure(.unavailable)
    }

    private func makeEntry(from result: Result<UsageWidgetSnapshot, SnapshotReadFailure>,
                           range: UsageHistoryRange, now: Date,
                           calendar: Calendar = UsageHistory.calendar()) -> UsageWidgetEntry {
        let presentation: UsageWidgetPresentation
        switch result {
        case .success(let snapshot):
            presentation = .make(snapshot: snapshot, range: range, now: now, calendar: calendar)
        case .failure(.missingProjection), .failure(.missingFile):
            presentation = .openAppToLoadUsage(range: range)
        case .failure(.unavailable):
            presentation = .unavailable(range: range)
        }
        return UsageWidgetEntry(date: now, presentation: presentation)
    }

    static func previewEntry(range: UsageHistoryRange, now: Date) -> UsageWidgetEntry {
        let calendar = UsageHistory.calendar()
        let days = range.dates(through: now, calendar: calendar)
        let records = days.enumerated().compactMap { index, date -> DailyUsageRecord? in
            guard index.isMultiple(of: 4) || index == days.count - 1 else { return nil }
            return DailyUsageRecord(dayKey: UsageHistory.key(for: date, calendar: calendar),
                                    downloaded: UInt64(4 + index) * 1_000_000,
                                    uploaded: UInt64(1 + index / 2) * 1_000_000,
                                    firstObservedAt: date, lastObservedAt: date, isIncomplete: false)
        }
        let fixture = UsageWidgetSnapshot(savedAt: now, lastObservedAt: records.last?.lastObservedAt,
                                          timeZoneIdentifier: calendar.timeZone.identifier,
                                          dataUnit: .decimal, records: records)
        return UsageWidgetEntry(date: now, presentation: .make(snapshot: fixture, range: range, now: now, calendar: calendar))
    }
}
