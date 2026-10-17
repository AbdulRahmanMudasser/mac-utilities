import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct UsageHistoryTests {
    @MainActor private final class Fixture {
        let directory: URL
        var url: URL { directory.appendingPathComponent("today-usage.json") }
        var date = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
        var calendar = UsageHistory.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        var counters = ["en0": InterfaceByteCount(downloaded: 1_000, uploaded: 500)]
        var counterFailure = false
        var boot = "test-boot-A"

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-history-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func makeMonitor() -> UsageMonitor {
            UsageMonitor(stateURL: url, startAutomatically: false, now: { self.date },
                calendar: { self.calendar }, readCounters: {
                    if self.counterFailure { throw CocoaError(.fileReadUnknown) }
                    return self.counters
                }, bootIdentifier: { self.boot })
        }

        func advance(_ seconds: TimeInterval = 1, download: UInt64 = 0, upload: UInt64 = 0) {
            date = date.addingTimeInterval(seconds)
            counters["en0"]!.downloaded += download
            counters["en0"]!.uploaded += upload
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func savedLegacy(day: String = "2026-10-15", download: UInt64 = 120, upload: UInt64 = 40) throws {
            var state = PersistedUsage(localDayKey: day, timeZoneIdentifier: "GMT")
            state.downloaded = download
            state.uploaded = upload
            state.interfaceCounters = counters
            state.lastSampleDate = date.addingTimeInterval(-60)
            try UsageStateStore.saveState(state, at: url)
        }
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test(arguments: [1, 2, 3])
    func formerlyPausedSnapshotsStartCollectingWithoutImportingTheGap(_ version: Int) throws {
        let f = try Fixture()
        defer { f.remove() }
        let saved = PersistedUsage(schemaVersion: version, localDayKey: "2026-10-15",
            downloaded: 120, uploaded: 40, interfaceCounters: [:], lastSampleDate: nil,
            history: version == 3 ? [] : nil, bootIdentifier: f.boot)
        try UsageStateStore.saveState(saved, at: f.url)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.url)) as? [String: Any])
        json["wasPaused"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: f.url)
        f.advance(60, download: 9_000, upload: 9_000)
        let monitor = f.makeMonitor()
        #expect(monitor.combinedToday == 160)
        #expect(monitor.counterError == nil)
        let previousHistory = monitor.historyRecords.reduce(UInt64(0)) { $0 + $1.combined }
        f.advance(download: 10, upload: 2)
        monitor.sample()
        #expect(monitor.combinedToday == 172)
        #expect(monitor.historyRecords.reduce(UInt64(0)) { $0 + $1.combined } == previousHistory + 12)
        monitor.flush()
        let rewritten = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.url)) as? [String: Any])
        #expect(rewritten["wasPaused"] == nil)
    }

    @Test(arguments: [1, 2])
    func supportedLegacySchemasMigrateWithAnAbsentTimeZone(_ version: Int) throws {
        let f = try Fixture()
        defer { f.remove() }
        var legacy = PersistedUsage(schemaVersion: version, localDayKey: "2026-10-15",
                                    downloaded: 120, uploaded: 40)
        legacy.timeZoneIdentifier = nil
        legacy.lastSampleDate = f.date
        try UsageStateStore.saveState(legacy, at: f.url)
        let monitor = f.makeMonitor()
        #expect(monitor.historyWritable)
        #expect(monitor.combinedToday == 160)
        #expect(monitor.historyRecords.first?.combined == 160)
        #expect(try UsageStateStore.readState(at: f.url)?.schemaVersion == 3)
    }

    @Test
    func legacyMigrationKeepsSavedBytesAndDoesNotCountUnknownBootGap() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.savedLegacy()
        f.counters["en0"]!.downloaded += 900
        let first = f.makeMonitor()
        #expect(first.downloadedToday == 120)
        #expect(first.historyRecords.count == 1)
        #expect(first.historyRecords.first?.downloaded == 120)
        #expect(first.historyRecords.first?.uploaded == 40)
        #expect(first.historyRecords.first?.isIncomplete == true)
        first.flush()
        let restarted = f.makeMonitor()
        #expect(restarted.historyRecords.count == 1)
        #expect(restarted.historyRecords.first?.downloaded == 120)
        #expect(try UsageStateStore.readState(at: f.url)?.schemaVersion == 3)
    }

    @Test
    func previousDayMigrationPreservesOldDayWithoutInventingToday() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.savedLegacy(day: "2026-10-13")
        let monitor = f.makeMonitor()
        #expect(monitor.downloadedToday == 0)
        #expect(monitor.historyRecords.map(\.dayKey) == ["2026-10-13"])
        #expect(monitor.historyRecords.first?.combined == 160)
        let days = UsageHistory.days(records: monitor.historyRecords, range: .sevenDays, now: f.date, calendar: f.calendar)
        #expect(days.first(where: { $0.dayKey == "2026-10-14" })?.record == nil)
        #expect(days.last?.record == nil)
    }

    @Test
    func sameBootRestartRecoversOneSameDayDeltaButRebootRebaselines() throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = f.makeMonitor()
        f.advance(download: 100, upload: 25)
        first.sample()
        first.flush()
        f.advance(20, download: 300, upload: 75)
        let restarted = f.makeMonitor()
        #expect(restarted.downloadedToday == 400)
        #expect(restarted.historyRecords.first?.downloaded == 400)
        restarted.flush()
        f.boot = "test-boot-B"
        f.advance(download: 5_000, upload: 4_000)
        let rebooted = f.makeMonitor()
        #expect(rebooted.downloadedToday == 400)
        #expect(rebooted.historyRecords.first?.uploaded == 100)
        f.advance(download: 10, upload: 2)
        rebooted.sample()
        #expect(rebooted.historyRecords.first?.downloaded == 410)
    }

    @Test
    func firstBaselineIsNoDataButComparableZeroIntervalIsRecorded() throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = f.makeMonitor()
        #expect(monitor.historyRecords.isEmpty)
        f.advance()
        monitor.sample()
        #expect(monitor.historyRecords.count == 1)
        #expect(monitor.historyRecords.first?.combined == 0)
        let days = UsageHistory.days(records: monitor.historyRecords, range: .sevenDays, now: f.date, calendar: f.calendar)
        #expect(days.dropLast().allSatisfy { $0.record == nil })
        #expect(days.last?.record?.combined == 0)
    }

    @Test
    func rollingRangesAndMonthAreInclusiveAcrossLeapDayAndYear() {
        let calendar = UsageHistory.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        let now = date("2028-03-01T12:00:00Z")
        for (range, count, first) in [(UsageHistoryRange.sevenDays, 7, "2028-02-24"),
                                     (.fifteenDays, 15, "2028-02-16"),
                                     (.thirtyDays, 30, "2028-02-01")] {
            let days = range.dates(through: now, calendar: calendar)
            #expect(days.count == count)
            #expect(UsageHistory.key(for: days.first!, calendar: calendar) == first)
            #expect(UsageHistory.key(for: days.last!, calendar: calendar) == "2028-03-01")
            #expect(Set(days).count == count)
        }
        #expect(UsageHistoryRange.thisMonth.dates(through: now, calendar: calendar).count == 1)
        #expect(UsageHistoryRange.thisMonth.dates(through: date("2028-02-29T23:00:00Z"), calendar: calendar).count == 29)
        let newYear = UsageHistoryRange.sevenDays.dates(through: date("2027-01-02T00:01:00Z"), calendar: calendar)
        #expect(UsageHistory.key(for: newYear.first!, calendar: calendar) == "2026-12-27")
    }

    @Test
    func rangeUsesCalendarDaysAcrossBothDaylightSavingChanges() throws {
        let calendar = UsageHistory.calendar(timeZone: try #require(TimeZone(identifier: "America/Los_Angeles")))
        for (instant, expectedDuration) in [("2026-03-10T12:00:00Z", 6.0 * 86_400 - 3_600),
                                            ("2026-11-03T12:00:00Z", 6.0 * 86_400 + 3_600)] {
            let days = UsageHistoryRange.sevenDays.dates(through: date(instant), calendar: calendar)
            #expect(days.count == 7)
            #expect(days.last!.timeIntervalSince(days.first!) == expectedDuration)
            #expect(days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
        }
    }

    @Test
    func resetConsumesPendingBytesAndPreservesIndependentDailyHistory() throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = f.makeMonitor()
        f.advance(download: 100, upload: 20)
        monitor.resetToday()
        #expect(monitor.combinedToday == 0)
        #expect(monitor.historyRecords.first?.combined == 120)
        f.advance(download: 50, upload: 10)
        monitor.sample()
        #expect(monitor.combinedToday == 60)
        f.advance(download: 30, upload: 5)
        monitor.resetToday()
        #expect(monitor.combinedToday == 0)
        #expect(monitor.historyRecords.first?.combined == 215)
        monitor.flush()
        let restarted = f.makeMonitor()
        #expect(restarted.combinedToday == 0)
        #expect(restarted.historyRecords.first?.combined == 215)
    }

    @Test
    func midnightDiscardsUnassignableDeltaAndKeepsPreviousRecord() throws {
        let f = try Fixture()
        defer { f.remove() }
        f.date = date("2026-10-15T23:59:57Z")
        let monitor = f.makeMonitor()
        f.advance(download: 10, upload: 2)
        monitor.sample()
        f.advance(10, download: 800, upload: 600)
        monitor.sample()
        #expect(monitor.combinedToday == 0)
        #expect(monitor.historyRecords.map(\.dayKey) == ["2026-10-15"])
        f.advance(download: 5, upload: 1)
        monitor.sample()
        #expect(monitor.historyRecords.last?.combined == 6)
        #expect(monitor.historyRecords.first?.combined == 12)
    }

    @Test
    func failedCountersAdvanceDayAndRecoveryDoesNotCountUnknownBytes() throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = f.makeMonitor()
        f.advance(download: 40, upload: 10)
        monitor.sample()
        f.counterFailure = true
        f.advance(86_400, download: 1_000, upload: 1_000)
        monitor.sample()
        #expect(monitor.combinedToday == 0)
        #expect(monitor.counterError != nil)
        #expect(monitor.historyRecords.count == 1)
        monitor.resetToday()
        f.counterFailure = false
        f.advance(download: 5_000, upload: 5_000)
        monitor.sample()
        #expect(monitor.combinedToday == 0)
        #expect(monitor.counterError == nil)
        f.advance(download: 8, upload: 2)
        monitor.sample()
        #expect(monitor.combinedToday == 10)
        #expect(monitor.historyRecords.last?.combined == 10)
    }

    @Test
    func changedTimeZoneAndBackwardClockRebaselineWithoutOverwritingDates() throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = f.makeMonitor()
        f.advance(download: 100, upload: 20)
        monitor.sample()
        f.calendar.timeZone = try #require(TimeZone(identifier: "Asia/Karachi"))
        f.advance(download: 1_000, upload: 1_000)
        monitor.sample()
        #expect(monitor.historyRecords.first?.combined == 120)
        f.advance(download: 10, upload: 2)
        monitor.sample()
        #expect(monitor.historyRecords.first?.combined == 132)
        f.advance(-30, download: 5_000, upload: 5_000)
        monitor.sample()
        #expect(monitor.historyRecords.first?.combined == 132)
        f.advance(download: 5, upload: 1)
        monitor.sample()
        #expect(monitor.historyRecords.first?.combined == 138)
    }

    @Test
    func revisitingCivilDateMergesRatherThanReplacingHistory() throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = f.makeMonitor()
        f.advance(download: 100, upload: 10)
        monitor.sample()
        f.advance(86_400, download: 1_000)
        monitor.sample()
        f.advance(download: 200, upload: 20)
        monitor.sample()
        f.advance(-86_400, download: 3_000)
        monitor.sample()
        f.advance(download: 50, upload: 5)
        monitor.sample()
        #expect(monitor.historyRecords.map(\.dayKey) == ["2026-10-15", "2026-10-16"])
        #expect(monitor.historyRecords.first?.combined == 165)
        #expect(monitor.historyRecords.last?.combined == 220)
    }

    @Test
    func clearAccountsPendingTodayAndDoesNotReimportOnRestart() throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = f.makeMonitor()
        f.advance(download: 100, upload: 20)
        monitor.sample()
        f.advance(download: 50, upload: 5)
        monitor.clearHistory()
        #expect(monitor.combinedToday == 175)
        #expect(monitor.historyRecords.isEmpty)
        let restarted = f.makeMonitor()
        #expect(restarted.combinedToday == 175)
        #expect(restarted.historyRecords.isEmpty)
        f.advance(download: 10, upload: 2)
        restarted.sample()
        #expect(restarted.historyRecords.first?.combined == 12)
        #expect(restarted.combinedToday == 187)
    }

    @Test(arguments: [Data("not-json".utf8), Data("{\"schemaVersion\":99}".utf8)])
    func malformedOrUnsupportedFileIsProtectedFromSamplingClearAndFlush(_ original: Data) throws {
        let f = try Fixture()
        defer { f.remove() }
        try original.write(to: f.url)
        let monitor = f.makeMonitor()
        #expect(!monitor.historyWritable)
        #expect(monitor.historyError != nil)
        f.advance(download: 100, upload: 20)
        monitor.sample()
        monitor.clearHistory()
        monitor.flush()
        monitor.shutdown()
        #expect(try Data(contentsOf: f.url) == original)
    }

    @Test
    func futureCompleteSnapshotRemainsUnchanged() throws {
        let f = try Fixture()
        defer { f.remove() }
        var state = PersistedUsage(localDayKey: "2026-10-15", history: [])
        state.schemaVersion = 99
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode(state)
        try original.write(to: f.url)
        let monitor = f.makeMonitor()
        #expect(!monitor.historyWritable)
        #expect(monitor.historyError != nil)
        monitor.clearHistory()
        #expect(try Data(contentsOf: f.url) == original)
    }

    @Test
    func transientWriteFailureRetainsMemoryAndRetrySavesIt() throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = f.makeMonitor()
        f.advance(download: 100, upload: 20)
        monitor.sample()
        try FileManager.default.removeItem(at: f.url)
        try FileManager.default.createDirectory(at: f.url, withIntermediateDirectories: true)
        monitor.flush()
        #expect(monitor.historyWritable)
        #expect(monitor.historyError != nil)
        #expect(monitor.historyRecords.first?.combined == 120)
        try FileManager.default.removeItem(at: f.url)
        monitor.flush()
        #expect(monitor.historyError == nil)
        #expect(try UsageStateStore.readState(at: f.url)?.history?.first?.combined == 120)
    }

    @Test
    func validationRejectsDuplicateInvalidDaysReversedTimesAndOverflow() throws {
        let at = date("2026-10-15T12:00:00Z")
        let record = DailyUsageRecord(dayKey: "2026-10-15", downloaded: 1, uploaded: 2,
            firstObservedAt: at, lastObservedAt: at, isIncomplete: false)
        var valid = PersistedUsage(schemaVersion: 3, localDayKey: record.dayKey, history: [record])
        try UsageStateStore.validate(valid)
        valid.history = [record, record]
        #expect(throws: (any Error).self) { try UsageStateStore.validate(valid) }
        valid.history = [record]
        valid.history![0].dayKey = "2026-02-30"
        #expect(throws: (any Error).self) { try UsageStateStore.validate(valid) }
        valid.history = [record]
        valid.history![0].firstObservedAt = at.addingTimeInterval(1)
        #expect(throws: (any Error).self) { try UsageStateStore.validate(valid) }
        valid.history = [record]
        valid.history![0].downloaded = .max
        #expect(throws: (any Error).self) { try UsageStateStore.validate(valid) }
        valid.history = []
        valid.downloaded = .max
        valid.uploaded = 1
        #expect(throws: (any Error).self) { try UsageStateStore.validate(valid) }
        #expect(UsageHistory.add(.max, 1) == .max)
        #expect(UsageHistory.validKey("2028-02-29"))
        #expect(!UsageHistory.validKey("2026-02-29"))
        #expect(!UsageHistory.validKey("2026-2-01"))
    }

    @Test
    func selectionAverageUsesAllRangeDaysAndAvoidsOverflow() {
        let at = date("2026-10-15T12:00:00Z")
        func day(_ value: UInt64?) -> UsageHistoryDay {
            UsageHistoryDay(date: at, dayKey: "2026-10-15", record: value.map {
                DailyUsageRecord(dayKey: "2026-10-15", downloaded: $0, uploaded: 0,
                                 firstObservedAt: at, lastObservedAt: at, isIncomplete: true)
            })
        }
        #expect(UsageHistory.average([]) == nil)
        #expect(UsageHistory.average([day(nil)]) == nil)
        #expect(UsageHistory.average([day(12), day(0), day(nil)]) == 4)
        #expect(UsageHistory.average([day(5), day(6)]) == 5)
        #expect(UsageHistory.average([day(.max), day(.max)]) == .max)
    }

    @Test
    func rangeTotalsIncludeOnlyStoredValuesAndSaturateSafely() {
        let calendar = UsageHistory.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        let at = date("2026-10-15T12:00:00Z")
        let records = [DailyUsageRecord(dayKey: "2026-10-15", downloaded: 12, uploaded: 3,
            firstObservedAt: at, lastObservedAt: at, isIncomplete: true),
            DailyUsageRecord(dayKey: "2026-10-01", downloaded: 100, uploaded: 20,
            firstObservedAt: at, lastObservedAt: at, isIncomplete: true)]
        let week = UsageHistory.days(records: records, range: .sevenDays, now: at, calendar: calendar)
        #expect(UsageHistory.totals(week) == InterfaceByteCount(downloaded: 12, uploaded: 3))
        let month = UsageHistory.days(records: records, range: .thisMonth, now: at, calendar: calendar)
        #expect(UsageHistory.totals(month) == InterfaceByteCount(downloaded: 112, uploaded: 23))
        #expect(month.filter { $0.record == nil }.count == 13)
    }

    @Test
    func counterChangesKeepKnownDirectionWithoutImportingNewInterfaceTotals() throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = f.makeMonitor()
        f.advance(download: 100, upload: 20)
        monitor.sample()
        f.advance()
        f.counters["en0"] = InterfaceByteCount(downloaded: 5, uploaded: 550)
        f.counters["en1"] = InterfaceByteCount(downloaded: 90_000, uploaded: 80_000)
        monitor.sample()
        #expect(monitor.historyRecords.first?.downloaded == 100)
        #expect(monitor.historyRecords.first?.uploaded == 50)
        #expect(monitor.isIncomplete)
        f.advance()
        f.counters = ["en9": InterfaceByteCount(downloaded: 1_000_000, uploaded: 1_000_000)]
        monitor.sample()
        #expect(monitor.historyRecords.first?.combined == 150)
    }

    @Test
    func nearLimitSnapshotRemainsValidAndWritableAfterFurtherTraffic() throws {
        let f = try Fixture()
        defer { f.remove() }
        let record = DailyUsageRecord(dayKey: "2026-10-15", downloaded: .max - 10, uploaded: 5,
            firstObservedAt: f.date, lastObservedAt: f.date, isIncomplete: true)
        var state = PersistedUsage(schemaVersion: 3, localDayKey: record.dayKey,
            timeZoneIdentifier: f.calendar.timeZone.identifier, downloaded: record.downloaded,
            uploaded: record.uploaded, interfaceCounters: f.counters, lastSampleDate: f.date,
            history: [record], bootIdentifier: f.boot)
        try UsageStateStore.saveState(state, at: f.url)
        let monitor = f.makeMonitor()
        f.advance(download: 3, upload: 20)
        monitor.sample()
        monitor.flush()
        #expect(monitor.historyWritable)
        #expect(monitor.historyError == nil)
        #expect(monitor.combinedToday == .max)
        #expect(monitor.downloadedToday == UInt64.max - 7)
        #expect(monitor.uploadedToday == 7)
        #expect(monitor.historyRecords.first?.combined == .max)
        state = try #require(try UsageStateStore.readState(at: f.url))
        try UsageStateStore.validate(state)
        f.advance(download: 50, upload: 50)
        monitor.sample()
        monitor.flush()
        #expect(monitor.historyError == nil)
        #expect(monitor.historyRecords.first?.combined == .max)
        #expect(try UsageStateStore.readState(at: f.url)?.combined == .max)
    }

    @Test
    func bothDirectionCounterResetDoesNotFabricateZeroObservation() throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = f.makeMonitor()
        f.advance()
        f.counters["en0"] = InterfaceByteCount(downloaded: 10, uploaded: 5)
        monitor.sample()
        #expect(monitor.historyRecords.isEmpty)
        #expect(monitor.combinedToday == 0)
        #expect(monitor.isIncomplete)
        f.advance(download: 4, upload: 2)
        monitor.sample()
        #expect(monitor.historyRecords.count == 1)
        #expect(monitor.historyRecords.first?.combined == 6)
        #expect(monitor.combinedToday == 6)
    }

    @Test
    func legacyWithoutLastSampleDateMigratesTotalsWithoutRecoveringUnknownGap() throws {
        let f = try Fixture()
        defer { f.remove() }
        var legacy = PersistedUsage(localDayKey: "2026-10-14", timeZoneIdentifier: "GMT",
            downloaded: 123, uploaded: 45, interfaceCounters: f.counters)
        legacy.lastSampleDate = nil
        try UsageStateStore.saveState(legacy, at: f.url)
        let monitor = f.makeMonitor()
        #expect(monitor.combinedToday == 0)
        #expect(monitor.historyRecords.count == 1)
        #expect(monitor.historyRecords.first?.dayKey == "2026-10-14")
        #expect(monitor.historyRecords.first?.combined == 168)
        #expect(monitor.historyRecords.first?.isIncomplete == true)
        monitor.flush()
        let restarted = f.makeMonitor()
        #expect(restarted.historyRecords.first?.combined == 168)
        #expect(restarted.historyRecords.count == 1)
    }

    @Test
    func backwardClockDoesNotBlockPersistenceBehindOldWriteTimestamp() throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = f.makeMonitor()
        f.advance(6, download: 10, upload: 2)
        monitor.sample()
        #expect(try UsageStateStore.readState(at: f.url)?.history?.first?.combined == 12)
        f.advance(-30, download: 1_000, upload: 1_000)
        monitor.sample()
        #expect(try UsageStateStore.readState(at: f.url)?.lastSampleDate == f.date)
        f.advance(6, download: 4, upload: 1)
        monitor.sample()
        #expect(try UsageStateStore.readState(at: f.url)?.history?.first?.combined == 17)
    }

    @Test func sandboxedTargetReadsRealCountersAndBootIdentityIntoIsolatedHistory() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = UsageMonitor(stateURL: f.url, startAutomatically: false)
        #expect(monitor.counterError == nil)
        try await Task.sleep(for: .milliseconds(150))
        monitor.sample()
        monitor.flush()
        let saved = try #require(try UsageStateStore.readState(at: f.url))
        #expect(saved.schemaVersion == 3)
        #expect(saved.bootIdentifier?.isEmpty == false)
        #expect(saved.history?.count == 1)
        #expect(monitor.historyError == nil)
    }

    @Test func applicationTerminationFlushesPendingUsageToTheLedger() throws {
        let f = try Fixture()
        defer { f.remove() }
        let monitor = f.makeMonitor()
        f.advance(download: 100, upload: 20)
        let delegate = AppDelegate()
        delegate.monitor = monitor
        delegate.applicationWillTerminate(Notification(name: Notification.Name("Usage History Test Termination")))
        #expect(try UsageStateStore.readState(at: f.url)?.history?.first?.combined == 120)
    }
}
