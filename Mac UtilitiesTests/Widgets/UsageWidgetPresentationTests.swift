import Foundation
import Testing
@testable import Mac_Utilities

struct UsageWidgetPresentationTests {
    private let utc = UsageHistory.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func record(_ dayKey: String, downloaded: UInt64 = 1_000, uploaded: UInt64 = 250,
                        observedAt: Date) -> DailyUsageRecord {
        DailyUsageRecord(dayKey: dayKey, downloaded: downloaded, uploaded: uploaded,
                         firstObservedAt: observedAt, lastObservedAt: observedAt, isIncomplete: false)
    }

    private func snapshot(savedAt: Date, lastObservedAt: Date? = nil, unit: DataDisplayUnit = .decimal,
                          records: [DailyUsageRecord], zone: String = "GMT") -> UsageWidgetSnapshot {
        UsageWidgetSnapshot(savedAt: savedAt, lastObservedAt: lastObservedAt ?? records.map(\.lastObservedAt).max(),
                            timeZoneIdentifier: zone, dataUnit: unit, records: records)
    }

    @MainActor
    @Test func configurationsKeepIndependentRanges() {
        let first = UsageWidgetConfigurationIntent()
        let second = UsageWidgetConfigurationIntent()
        #expect(first.historyRange == .thisMonth)
        second.range = .sevenDays
        #expect(first.historyRange == .thisMonth)
        #expect(second.historyRange == .sevenDays)
        for range in UsageHistoryRange.allCases {
            #expect(UsageWidgetRange(range).historyRange == range)
        }
    }

    @Test
    func projectsAllRangesAndBothUnitsWithoutChangingTheirTotals() {
        let now = date("2026-10-15T12:00:00Z")
        let allDays = UsageHistoryRange.thirtyDays.dates(through: now, calendar: utc)
        let records = allDays.enumerated().map { index, day in
            record(UsageHistory.key(for: day, calendar: utc), downloaded: UInt64(index + 1) * 1_000,
                   uploaded: UInt64(index + 1) * 100, observedAt: day.addingTimeInterval(3600))
        }

        for range in UsageHistoryRange.allCases {
            let expectedDays = UsageHistory.days(records: records, range: range, now: now, calendar: utc)
            let expectedTotals = UsageHistory.totals(expectedDays)
            var decimal = UsageWidgetPresentation.make(
                snapshot: snapshot(savedAt: now, lastObservedAt: records.last?.lastObservedAt,
                                  unit: .decimal, records: records), range: range, now: now, calendar: utc)
            guard case .readings(let decimalReading) = decimal else {
                Issue.record("Expected saved readings for \(range.rawValue)")
                continue
            }
            #expect(decimalReading.days.count == range.dates(through: now, calendar: utc).count)
            #expect(decimalReading.downloaded == expectedTotals.downloaded)
            #expect(decimalReading.uploaded == expectedTotals.uploaded)
            #expect(decimalReading.average == UsageHistory.average(expectedDays))
            #expect(decimalReading.dataUnit == .decimal)
            #expect(decimalReading.scaleLabel == "MB")

            decimal = .make(snapshot: snapshot(savedAt: now, lastObservedAt: records.last?.lastObservedAt,
                                               unit: .binary, records: records),
                            range: range, now: now, calendar: utc)
            guard case .readings(let binaryReading) = decimal else {
                Issue.record("Expected binary saved readings for \(range.rawValue)")
                continue
            }
            #expect(binaryReading.downloaded == expectedTotals.downloaded)
            #expect(binaryReading.uploaded == expectedTotals.uploaded)
            #expect(binaryReading.average == UsageHistory.average(expectedDays))
            #expect(binaryReading.dataUnit == .binary)
            #expect(binaryReading.scaleLabel == "MiB")
        }
    }

    @Test
    func separatesMissingProjectionInvalidDataEmptyHistoryNoRangeDataAndRecordedZero() {
        let now = date("2026-10-15T12:00:00Z")
        #expect(UsageWidgetPresentation.make(snapshot: nil, range: .sevenDays, now: now, calendar: utc)
                == .openAppToLoadUsage(range: .sevenDays))

        let futureSavedAt = snapshot(savedAt: now.addingTimeInterval(1), records: [])
        #expect(UsageWidgetPresentation.make(snapshot: futureSavedAt, range: .sevenDays, now: now, calendar: utc)
                == .unavailable(range: .sevenDays))

        let futureObservation = snapshot(savedAt: now, lastObservedAt: now.addingTimeInterval(1), records: [])
        #expect(UsageWidgetPresentation.make(snapshot: futureObservation, range: .sevenDays, now: now, calendar: utc)
                == .unavailable(range: .sevenDays))

        let futureRecord = snapshot(savedAt: now,
                                    records: [record("2026-10-15", observedAt: now.addingTimeInterval(1))])
        #expect(UsageWidgetPresentation.make(snapshot: futureRecord, range: .sevenDays, now: now, calendar: utc)
                == .unavailable(range: .sevenDays))

        let malformed = snapshot(savedAt: now, records: [record("2026-02-31", observedAt: now)])
        #expect(UsageWidgetPresentation.make(snapshot: malformed, range: .sevenDays, now: now, calendar: utc)
                == .unavailable(range: .sevenDays))

        guard case .noUsageHistory = UsageWidgetPresentation.make(
            snapshot: snapshot(savedAt: now, records: []), range: .sevenDays, now: now, calendar: utc) else {
            Issue.record("A valid empty projection should be distinct from unavailable data")
            return
        }

        let oldDay = date("2026-10-01T12:00:00Z")
        let outsideRange = snapshot(savedAt: now, records: [record("2026-10-01", observedAt: oldDay)])
        guard case .noDataInRange = UsageWidgetPresentation.make(
            snapshot: outsideRange, range: .sevenDays, now: now, calendar: utc) else {
            Issue.record("Older history outside the selected range should not become an empty ledger")
            return
        }

        let zeroRecord = record("2026-10-15", downloaded: 0, uploaded: 0, observedAt: now)
        guard case .readings(let zero) = UsageWidgetPresentation.make(
            snapshot: snapshot(savedAt: now, lastObservedAt: now, records: [zeroRecord]),
            range: .sevenDays, now: now, calendar: utc) else {
            Issue.record("Recorded zero usage should remain a reading")
            return
        }
        #expect(zero.days.last?.hasRecord == true)
        #expect(zero.days.last?.downloaded == 0)
        #expect(zero.days.last?.uploaded == 0)
        #expect(zero.combined == 0)
    }

    @Test
    func preservesObservationFreshnessAndDoesNotMoveOldBytesIntoToday() {
        let savedAt = date("2026-10-15T12:00:00Z")
        let observedAt = date("2026-10-15T11:00:00Z")
        let saved = snapshot(savedAt: savedAt, lastObservedAt: observedAt,
                             records: [record("2026-10-15", downloaded: 42, uploaded: 5, observedAt: observedAt)])

        guard case .readings(let first) = UsageWidgetPresentation.make(
            snapshot: saved, range: .sevenDays, now: savedAt, calendar: utc),
              case .readings(let refreshed) = UsageWidgetPresentation.make(
                snapshot: saved, range: .sevenDays, now: date("2026-10-16T00:01:00Z"), calendar: utc) else {
            Issue.record("Expected saved entries before and after midnight")
            return
        }
        #expect(first.savedAt == savedAt)
        #expect(first.lastObservedAt == observedAt)
        #expect(refreshed.savedAt == savedAt)
        #expect(refreshed.lastObservedAt == observedAt)
        #expect(refreshed.days.last?.dayKey == "2026-10-16")
        #expect(refreshed.days.last?.hasRecord == false)
        #expect(refreshed.days.first(where: { $0.dayKey == "2026-10-15" })?.downloaded == 42)
    }

    @Test
    func calendarAndTimeZoneChangesKeepSavedCivilKeysAndUseCurrentLocalDays() {
        let now = date("2026-03-09T06:30:00Z")
        let savedAt = date("2026-03-09T06:00:00Z")
        let observedAt = date("2026-03-09T05:30:00Z")
        let saved = snapshot(savedAt: savedAt, lastObservedAt: observedAt,
                             records: [record("2026-03-08", downloaded: 700, uploaded: 30, observedAt: observedAt)],
                             zone: "America/Los_Angeles")
        let losAngeles = UsageHistory.calendar(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let utcCalendar = utc

        guard case .readings(let pacific) = UsageWidgetPresentation.make(
            snapshot: saved, range: .sevenDays, now: now, calendar: losAngeles),
              case .readings(let universal) = UsageWidgetPresentation.make(
                snapshot: saved, range: .sevenDays, now: now, calendar: utcCalendar) else {
            Issue.record("Expected existing March usage in both current calendar projections")
            return
        }
        #expect(pacific.days.count == 7)
        #expect(universal.days.count == 7)
        #expect(pacific.days.last?.dayKey == "2026-03-08")
        #expect(universal.days.last?.dayKey == "2026-03-09")
        #expect(pacific.days.first(where: { $0.dayKey == "2026-03-08" })?.downloaded == 700)
        #expect(universal.days.first(where: { $0.dayKey == "2026-03-08" })?.downloaded == 700)
        #expect(universal.days.last?.hasRecord == false)
        #expect(pacific.lastObservedAt == observedAt)
        #expect(universal.lastObservedAt == observedAt)
    }

    @Test
    func timelineUsesTheEarlierOfThirtyMinutesAndMonthBoundaryWithTheSameProjection() {
        let calendar = utc
        let ordinaryNow = date("2026-10-31T23:15:00Z")
        let ordinary = UsageWidgetPresentation.timelineSchedule(now: ordinaryNow, calendar: calendar)
        #expect(ordinary.nextLocalMidnight == date("2026-11-01T00:00:00Z"))
        #expect(ordinary.boundaryEntryAt == nil)
        #expect(ordinary.refreshAt == date("2026-10-31T23:45:00Z"))

        let nearMidnight = date("2026-10-31T23:45:00Z")
        let boundary = UsageWidgetPresentation.timelineSchedule(now: nearMidnight, calendar: calendar)
        let midnight = date("2026-11-01T00:00:00Z")
        #expect(boundary.nextLocalMidnight == midnight)
        #expect(boundary.boundaryEntryAt == midnight)
        #expect(boundary.refreshAt == midnight)
        guard let boundaryEntryAt = boundary.boundaryEntryAt else {
            Issue.record("The close midnight should have a boundary entry")
            return
        }

        let observedAt = date("2026-10-31T23:00:00Z")
        let saved = snapshot(savedAt: nearMidnight, lastObservedAt: observedAt,
                             records: [record("2026-10-31", downloaded: 800, uploaded: 200, observedAt: observedAt)])
        guard case .readings(let beforeBoundary) = UsageWidgetPresentation.make(
            snapshot: saved, range: .thisMonth, now: nearMidnight, calendar: calendar),
              case .noDataInRange(let afterBoundary) = UsageWidgetPresentation.make(
                snapshot: saved, range: .thisMonth, now: boundaryEntryAt, calendar: calendar) else {
            Issue.record("Expected the same saved snapshot to remain readable across month rollover")
            return
        }
        #expect(beforeBoundary.savedAt == afterBoundary.savedAt)
        #expect(beforeBoundary.lastObservedAt == afterBoundary.lastObservedAt)
        #expect(afterBoundary.days.map(\.dayKey) == ["2026-11-01"])
        #expect(afterBoundary.days[0].hasRecord == false)
        #expect(afterBoundary.downloaded == 0)
        #expect(afterBoundary.uploaded == 0)
    }

    @Test
    func nextLocalMidnightFollowsActualSpringAndFallDSTDayLengths() {
        let newYork = UsageHistory.calendar(timeZone: TimeZone(identifier: "America/New_York")!)
        let springMidnight = date("2026-03-08T05:00:00Z")
        let spring = UsageWidgetPresentation.timelineSchedule(now: springMidnight, calendar: newYork)
        guard let nextSpringMidnight = spring.nextLocalMidnight else {
            Issue.record("Expected the next midnight after the spring clock change")
            return
        }
        #expect(nextSpringMidnight == date("2026-03-09T04:00:00Z"))
        #expect(nextSpringMidnight.timeIntervalSince(springMidnight) == 23 * 60 * 60)

        let fallMidnight = date("2026-11-01T04:00:00Z")
        let fall = UsageWidgetPresentation.timelineSchedule(now: fallMidnight, calendar: newYork)
        guard let nextFallMidnight = fall.nextLocalMidnight else {
            Issue.record("Expected the next midnight after the fall clock change")
            return
        }
        #expect(nextFallMidnight == date("2026-11-02T05:00:00Z"))
        #expect(nextFallMidnight.timeIntervalSince(fallMidnight) == 25 * 60 * 60)
    }
}
