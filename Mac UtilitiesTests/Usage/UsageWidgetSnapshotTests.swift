import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct UsageWidgetSnapshotTests {
    private let date = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
    private var calendar: Calendar { UsageHistory.calendar(timeZone: TimeZone(secondsFromGMT: 0)!) }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-projection-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func record(offset: Int, downloaded: UInt64 = 100, uploaded: UInt64 = 20) -> DailyUsageRecord {
        let day = calendar.date(byAdding: .day, value: offset, to: date)!
        return DailyUsageRecord(dayKey: UsageHistory.key(for: day, calendar: calendar), downloaded: downloaded,
            uploaded: uploaded, firstObservedAt: day.addingTimeInterval(-10), lastObservedAt: day, isIncomplete: false)
    }

    @Test func nearLimitEnvelopeReadsOnlyProjection() throws {
        let snapshot = try UsageSnapshotPublisher.snapshot(for: PersistedUsage(schemaVersion: 3,
            localDayKey: "2026-10-17", history: [record(offset: 0)]), at: date, unit: .decimal, calendar: calendar)
        var envelope = PersistedUsage(schemaVersion: 3, localDayKey: "2026-10-17",
            timeZoneIdentifier: "GMT", incompleteReason: "", history: snapshot.records, widgetSnapshot: snapshot)
        let overhead = try UsageStateStore.encoded(envelope).count
        envelope.incompleteReason = String(repeating: "x", count: UsageStorageLimits.maximumEnvelopeBytes - overhead)
        let data = try UsageStateStore.encoded(envelope)
        #expect(data.count == UsageStorageLimits.maximumEnvelopeBytes)
        #expect(try UsageWidgetSnapshotReader.decode(data) == snapshot)
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("near-limit.json")
        try UsageStateStore.saveState(envelope, at: file)
        #expect(try UsageWidgetSnapshotReader.read(at: file) == snapshot)
    }

    @Test func boundedProjectionUsesCurrentCalendarWindowAndKeepsObservedZero() throws {
        let records = (-40...4).map { record(offset: $0, downloaded: $0 == -1 ? 0 : 100, uploaded: 0) }
        let state = PersistedUsage(schemaVersion: 3, localDayKey: "2026-10-17", history: records)
        let snapshot = try UsageSnapshotPublisher.snapshot(for: state, at: date, unit: .binary, calendar: calendar)
        #expect(snapshot.records.count == 31)
        #expect(snapshot.records.first?.dayKey == "2026-09-17")
        #expect(snapshot.records.last?.dayKey == "2026-10-17")
        #expect(snapshot.records.first(where: { $0.dayKey == "2026-10-16" })?.combined == 0)
        #expect(snapshot.dataUnit == .binary)
        for range in UsageHistoryRange.allCases {
            let full = UsageHistory.days(records: records, range: range, now: date, calendar: calendar)
            let projected = UsageHistory.days(records: snapshot.records, range: range, now: date, calendar: calendar)
            #expect(UsageHistory.totals(full) == UsageHistory.totals(projected))
        }
    }

    @Test func publicationTimeDoesNotChangeObservationTimeOrFillMissingDates() throws {
        let state = PersistedUsage(schemaVersion: 3, localDayKey: "2026-10-17", history: [record(offset: -2)])
        let first = try UsageSnapshotPublisher.snapshot(for: state, at: date, unit: .decimal, calendar: calendar)
        let later = try UsageSnapshotPublisher.snapshot(for: state, at: date.addingTimeInterval(600), unit: .decimal, calendar: calendar)
        #expect(later.savedAt > first.savedAt)
        #expect(later.lastObservedAt == first.lastObservedAt)
        #expect(later.records.count == 1)
        let days = UsageHistory.days(records: later.records, range: .sevenDays, now: date, calendar: calendar)
        #expect(days.filter { $0.record == nil }.count == 6)
    }

    @Test func resetAndClearUseOneCommittedEnvelopeAndPublishAfterSuccess() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("today-usage.json")
        let original = PersistedUsage(schemaVersion: 3, localDayKey: "2026-10-17", downloaded: 9, uploaded: 2,
            history: [record(offset: 0)])
        try UsageStateStore.saveState(original, at: file)
        let monitor = UsageMonitor(stateURL: file, startAutomatically: false, now: { self.date },
            calendar: { self.calendar }, readCounters: { [:] }, bootIdentifier: { "test" })
        defer { monitor.shutdown() }
        var published: [UsageWidgetSnapshot] = []
        monitor.onSnapshotCommitted = { snapshot in
            #expect((try? UsageWidgetSnapshotReader.read(at: file)) == snapshot)
            published.append(snapshot)
        }
        monitor.resetToday()
        #expect(monitor.combinedToday == 0)
        #expect(try UsageWidgetSnapshotReader.read(at: file).records.first?.combined == 120)
        monitor.dataUnit = .binary
        #expect(try UsageWidgetSnapshotReader.read(at: file).dataUnit == .binary)
        monitor.clearHistory()
        #expect(try UsageStateStore.readState(at: file)?.history == [])
        #expect(try UsageWidgetSnapshotReader.read(at: file).records == [])
        #expect(published.last?.records == [])
        #expect(published.last?.lastObservedAt == nil)
    }

    @Test func verificationLaunchCannotCollectOrClearAndUsesIsolatedPreferences() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("today-usage.json")
        let state = PersistedUsage(schemaVersion: 3, localDayKey: "2026-10-17", history: [record(offset: 0)])
        try UsageStateStore.saveState(state, at: file)
        let original = try Data(contentsOf: file)
        let savedPreference = UserDefaults.standard.object(forKey: "dataDisplayUnit") as? String
        var reads = 0
        let monitor = UsageMonitor(startAutomatically: false,
            storagePaths: UsageStoragePaths(stateURL: file, isVerification: true),
            now: { self.date }, calendar: { self.calendar }, readCounters: { reads += 1; return [:] })
        defer { monitor.shutdown() }
        monitor.clearHistory()
        monitor.resetToday()
        monitor.dataUnit = .binary
        #expect(reads == 0)
        #expect(!monitor.isMonitoringActive)
        #expect(monitor.collectionStatus == "Monitoring Unavailable")
        #expect(monitor.historyRecords == state.history)
        #expect(try Data(contentsOf: file) == original)
        #expect(UserDefaults.standard.object(forKey: "dataDisplayUnit") as? String == savedPreference)
    }

    @Test func failedClearCannotPublishUntilItsAtomicWriteSucceeds() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("today-usage.json")
        let backup = directory.appendingPathComponent("last-good.json")
        try UsageStateStore.saveState(PersistedUsage(schemaVersion: 3, localDayKey: "2026-10-17", history: [record(offset: 0)]), at: file)
        let monitor = UsageMonitor(stateURL: file, startAutomatically: false, now: { self.date },
            calendar: { self.calendar }, readCounters: { [:] }, bootIdentifier: { "test" })
        defer { monitor.shutdown() }
        let bytes = try Data(contentsOf: file)
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var commits = 0
        monitor.onSnapshotCommitted = { _ in commits += 1 }
        monitor.clearHistory()
        #expect(commits == 0)
        #expect(monitor.historyError != nil)
        #expect(try Data(contentsOf: backup) == bytes)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        monitor.flush()
        #expect(commits == 1)
        #expect(try UsageWidgetSnapshotReader.read(at: file).records.isEmpty)
        #expect(try UsageStateStore.readState(at: file)?.history == [])
    }

    @Test func derivedReaderRejectsAbsentUnsupportedDuplicateAndInvalidProjections() throws {
        let good = try UsageSnapshotPublisher.snapshot(for: PersistedUsage(schemaVersion: 3,
            localDayKey: "2026-10-17", history: [record(offset: 0)]), at: date, unit: .decimal, calendar: calendar)
        var state = PersistedUsage(schemaVersion: 3, localDayKey: "2026-10-17", history: [])
        #expect(throws: (any Error).self) { try UsageWidgetSnapshotReader.decode(UsageStateStore.encoded(state)) }
        state.widgetSnapshot = good
        #expect(try UsageWidgetSnapshotReader.decode(UsageStateStore.encoded(state)) == good)
        state.schemaVersion = 99
        #expect(throws: (any Error).self) { try UsageWidgetSnapshotReader.decode(UsageStateStore.encoded(state)) }
        var invalid = good
        invalid.lastObservedAt = nil
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.lastObservedAt = date.addingTimeInterval(-1)
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = good
        invalid.records += invalid.records
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = good
        invalid.schemaVersion = 99
        #expect(throws: (any Error).self) { try invalid.validate() }
        for offset in [-31, 1] {
            invalid = good
            invalid.records = [record(offset: offset)]
            #expect(throws: (any Error).self) { try invalid.validate() }
            state.schemaVersion = 3
            state.widgetSnapshot = invalid
            #expect(throws: (any Error).self) {
                try UsageWidgetSnapshotReader.decode(UsageStateStore.encoded(state))
            }
        }
    }

    @Test func validCoreWithBrokenProjectionIsRebuiltByTheMonitor() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("today-usage.json")
        let state = PersistedUsage(schemaVersion: 3, localDayKey: "2026-10-17", downloaded: 9, uploaded: 2,
            history: [record(offset: 0)])
        var json = try #require(JSONSerialization.jsonObject(with: UsageStateStore.encoded(state)) as? [String: Any])
        json["widgetSnapshot"] = ["schemaVersion": 99]
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let monitor = UsageMonitor(stateURL: file, startAutomatically: false, now: { self.date },
            calendar: { self.calendar }, readCounters: { [:] }, bootIdentifier: { "test" })
        defer { monitor.shutdown() }
        #expect(monitor.combinedToday == 11)
        #expect(try UsageWidgetSnapshotReader.read(at: file).records.first?.combined == 120)
    }

    @Test func structurallyValidProjectionCannotDisagreeWithCanonicalHistory() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("today-usage.json")
        var state = PersistedUsage(schemaVersion: 3, localDayKey: "2026-10-17", history: [record(offset: 0)])
        var projection = try UsageSnapshotPublisher.snapshot(for: state, at: date, unit: .decimal, calendar: calendar)
        projection.records[0].downloaded += 1
        try projection.validate()
        state.widgetSnapshot = projection
        #expect(throws: (any Error).self) { try UsageStateStore.saveState(state, at: file) }
        try UsageStateStore.encoded(state).write(to: file)
        let loaded = try #require(try UsageStateStore.readState(at: file))
        #expect(loaded.history == state.history)
        #expect(loaded.widgetSnapshot == nil)
    }

    @Test func pathResolutionHasNoSilentLegacyFallbackAndRejectsTraversal() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let info: [String: Any] = ["MacUtilitiesAppGroupIdentifier": "TEST.shared"]
        let paths = try UsageStoragePaths.resolve(info: info, groupContainer: { _ in directory })
        #expect(paths.stateURL.path.hasSuffix("Library/Application Support/MacUtilities/today-usage.json"))
        #expect(!paths.isVerification)
        #expect(throws: (any Error).self) { try UsageStoragePaths.resolve(info: [:], groupContainer: { _ in directory }) }
        #expect(throws: (any Error).self) { try UsageStoragePaths.resolve(info: info, groupContainer: { _ in nil }) }
        var bad = info
        bad["MACUTILITIES_VERIFICATION_NAMESPACE"] = "../other"
        #expect(throws: (any Error).self) { try UsageStoragePaths.resolve(info: bad, groupContainer: { _ in directory }) }
        let namespace = UUID().uuidString
        bad["MACUTILITIES_VERIFICATION_NAMESPACE"] = namespace
        let verification = try UsageStoragePaths.resolve(info: bad, groupContainer: { _ in directory })
        #expect(verification.isVerification)
        #expect(verification.stateURL.path.contains("Verification/" + namespace))
    }

    @Test func startupFailureCannotAdvertiseMonitoringOrOverwriteProtectedStorage() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("today-usage.json")
        let original = Data("invalid snapshot".utf8)
        try original.write(to: file)
        var reads = 0
        let monitor = UsageMonitor(stateURL: file, startAutomatically: false,
            readCounters: { reads += 1; return [:] })
        #expect(monitor.collectionStatus == "Monitoring Unavailable")
        #expect(reads == 0)
        monitor.sample()
        monitor.resetToday()
        monitor.clearHistory()
        monitor.shutdown()
        #expect(try Data(contentsOf: file) == original)
    }
}
