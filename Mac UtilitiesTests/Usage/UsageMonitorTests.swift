import Foundation
import Testing
@testable import Mac_Utilities

struct UsageMonitorTests {
    @Test @MainActor
    func accumulatesDownloadAndUploadDeltas() {
        let previous = ["en0": InterfaceByteCount(downloaded: 1_000, uploaded: 500)]
        let current = ["en0": InterfaceByteCount(downloaded: 1_400, uploaded: 750)]
        var state = PersistedUsage(localDayKey: "2026-10-13", interfaceCounters: previous)
        state.isIncomplete = false

        let delta = UsageMonitor.applyDelta(from: previous, to: current, in: &state)

        #expect(delta.downloaded == 400)
        #expect(delta.uploaded == 250)
        #expect(state.downloaded == 400)
        #expect(state.uploaded == 250)
        #expect(!state.isIncomplete)
    }

    @Test @MainActor
    func counterResetMarksTotalsPartialWithoutLosingOtherDirection() {
        let previous = ["en0": InterfaceByteCount(downloaded: 1_000, uploaded: 500)]
        let current = ["en0": InterfaceByteCount(downloaded: 900, uploaded: 800)]
        var state = PersistedUsage(localDayKey: "2026-10-13", interfaceCounters: previous)

        let delta = UsageMonitor.applyDelta(from: previous, to: current, in: &state)

        #expect(delta.downloaded == 0)
        #expect(delta.uploaded == 300)
        #expect(state.downloaded == 0)
        #expect(state.uploaded == 300)
        #expect(state.isIncomplete)
        #expect(state.incompleteReason == "An Interface Counter Reset Was Detected.")
    }

    @Test @MainActor
    func interfaceChangesRebaselineNewInterfacesAndMarkTotalsPartial() {
        let previous = ["en0": InterfaceByteCount(downloaded: 1_000, uploaded: 500)]
        let current = [
            "en0": InterfaceByteCount(downloaded: 1_100, uploaded: 600),
            "en1": InterfaceByteCount(downloaded: 8_000, uploaded: 9_000),
        ]
        var state = PersistedUsage(localDayKey: "2026-10-13", interfaceCounters: previous)

        let delta = UsageMonitor.applyDelta(from: previous, to: current, in: &state)

        #expect(delta.downloaded == 100)
        #expect(delta.uploaded == 100)
        #expect(state.downloaded == 100)
        #expect(state.uploaded == 100)
        #expect(state.isIncomplete)
        #expect(state.incompleteReason == "A Network Interface Changed During Collection.")
    }

    @Test @MainActor
    func localDayKeyFollowsCalendarAcrossDaylightSavingTransition() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let beforeFallback = Date(timeIntervalSince1970: 1_793_521_800) // 2026-11-01 01:30 PDT
        let afterFallback = Date(timeIntervalSince1970: 1_793_525_400) // 2026-11-01 01:30 PST
        let nextLocalDay = Date(timeIntervalSince1970: 1_793_606_400) // 2026-11-02 00:00 PST

        #expect(UsageMonitor.localDayKey(for: beforeFallback, calendar: calendar) == "2026-11-01")
        #expect(UsageMonitor.localDayKey(for: afterFallback, calendar: calendar) == "2026-11-01")
        #expect(UsageMonitor.localDayKey(for: nextLocalDay, calendar: calendar) == "2026-11-02")
    }

    @Test @MainActor
    func localDayRolloverClearsTotalsAndUsesFreshInterfaceBaselines() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Karachi"))
        let midnight = try #require(ISO8601DateFormatter().date(from: "2026-10-14T00:00:00+05:00"))
        let currentCounters = ["en0": InterfaceByteCount(downloaded: 8_000, uploaded: 4_000)]
        var state = PersistedUsage(localDayKey: "2026-10-13", interfaceCounters: [
            "en0": InterfaceByteCount(downloaded: 7_000, uploaded: 3_500),
        ])
        state.downloaded = 600
        state.uploaded = 300
        state.isIncomplete = false

        let didRollOver = UsageMonitor.rollOverToCurrentLocalDayIfNeeded(
            at: midnight,
            timeZoneIdentifier: "Asia/Karachi",
            interfaceCounters: currentCounters,
            state: &state,
            calendar: calendar
        )

        #expect(didRollOver)
        #expect(state.localDayKey == "2026-10-14")
        #expect(state.downloaded == 0)
        #expect(state.uploaded == 0)
        #expect(state.interfaceCounters == currentCounters)
        #expect(state.timeZoneIdentifier == "Asia/Karachi")
        #expect(state.isIncomplete)
        #expect(state.incompleteReason == "The Local-Day Boundary Was Sampled Between Intervals.")
    }

    @Test @MainActor
    func sameDayTimeZoneChangePreservesTotalsAndMarksCollectionPartial() {
        var state = PersistedUsage(localDayKey: "2026-10-13")
        state.timeZoneIdentifier = "Asia/Karachi"
        state.downloaded = 1_200
        state.uploaded = 350
        state.isIncomplete = false

        let didChange = UsageMonitor.markTimeZoneChangeIfNeeded("Europe/London", state: &state)

        #expect(didChange)
        #expect(state.localDayKey == "2026-10-13")
        #expect(state.downloaded == 1_200)
        #expect(state.uploaded == 350)
        #expect(state.timeZoneIdentifier == "Europe/London")
        #expect(state.isIncomplete)
        #expect(state.incompleteReason == "The Local Time Zone Changed During Collection.")
    }

    @Test @MainActor
    func unknownSavedTimeZoneIsEstablishedWithoutClaimingItChanged() {
        var state = PersistedUsage(localDayKey: "2026-10-13")
        state.timeZoneIdentifier = nil
        state.isIncomplete = false

        let didChange = UsageMonitor.markTimeZoneChangeIfNeeded("Asia/Karachi", state: &state)

        #expect(!didChange)
        #expect(state.timeZoneIdentifier == "Asia/Karachi")
        #expect(!state.isIncomplete)
        #expect(state.incompleteReason == nil)
    }

    @Test @MainActor
    func legacyAmbiguousTimeZoneWarningIsRewordedWithoutMarkingTotalsComplete() {
        var state = PersistedUsage(localDayKey: "2026-10-13")
        state.timeZoneIdentifier = "Asia/Karachi"
        state.isIncomplete = true
        state.incompleteReason = "The Local Time Zone Changed Or Was Previously Unknown."

        let didChange = UsageMonitor.markTimeZoneChangeIfNeeded("Asia/Karachi", state: &state)

        #expect(!didChange)
        #expect(state.timeZoneIdentifier == "Asia/Karachi")
        #expect(state.isIncomplete)
        #expect(state.incompleteReason == "Today's Usage Includes An Incomplete Previous Collection.")
    }


    @Test @MainActor
    func previouslyRewordedWarningMigratesOnceAndPreservesCounters() {
        var state = PersistedUsage(localDayKey: "2026-10-13")
        state.timeZoneIdentifier = "Asia/Karachi"
        state.downloaded = 1_200
        state.uploaded = 350
        state.incompleteReason = "Today's Usage May Be Partial Because The Previous Local Time Zone Could Not Be Verified."
        #expect(!UsageMonitor.markTimeZoneChangeIfNeeded("Asia/Karachi", state: &state))
        #expect(state.incompleteReason == "Today's Usage Includes An Incomplete Previous Collection.")
        #expect(state.downloaded == 1_200)
        #expect(state.uploaded == 350)
        #expect(state.isIncomplete)
        #expect(!UsageMonitor.markTimeZoneChangeIfNeeded("Asia/Karachi", state: &state))
        #expect(state.incompleteReason == "Today's Usage Includes An Incomplete Previous Collection.")
    }

    @Test @MainActor
    func computesRatesOnlyForFreshPositiveSampleIntervals() {
        #expect(UsageMonitor.rateInBytesPerSecond(bytes: 600, elapsed: 2) == 300)
        #expect(UsageMonitor.rateInBytesPerSecond(bytes: 0, elapsed: 1) == 0)
        #expect(UsageMonitor.rateInBytesPerSecond(bytes: 600, elapsed: 0) == nil)
        #expect(UsageMonitor.rateInBytesPerSecond(bytes: 600, elapsed: 3) == nil)
    }

    @Test @MainActor
    func stateStoreRoundTripsCurrentDayCountersAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("today-usage.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampleDate = Date(timeIntervalSince1970: 1_791_849_600)
        var expected = PersistedUsage(localDayKey: "2026-10-13")
        expected.timeZoneIdentifier = "Asia/Karachi"
        expected.downloaded = 12_345
        expected.uploaded = 6_789
        expected.interfaceCounters = ["en0": InterfaceByteCount(downloaded: 90_000, uploaded: 45_000)]
        expected.lastSampleDate = sampleDate
        expected.isIncomplete = true
        expected.incompleteReason = "Device Counters Are Unavailable."

        try UsageStateStore.saveState(expected, at: url)
        let restored = try #require((try? UsageStateStore.readState(at: url)))

        #expect(restored.localDayKey == expected.localDayKey)
        #expect(restored.timeZoneIdentifier == expected.timeZoneIdentifier)
        #expect(restored.downloaded == expected.downloaded)
        #expect(restored.uploaded == expected.uploaded)
        #expect(restored.interfaceCounters == expected.interfaceCounters)
        #expect(restored.lastSampleDate == expected.lastSampleDate)
        #expect(restored.isIncomplete)
        #expect(restored.incompleteReason == expected.incompleteReason)
    }

    @Test @MainActor
    func invalidSnapshotIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("today-usage.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)

        #expect((try? UsageStateStore.readState(at: url)) == nil)
    }

    @Test @MainActor
    func formatsBothRateUnitsAndDataUnits() {
        #expect(UsageMonitor.formatRate(1_000_000, unit: .megabitsPerSecond) == "8.0 Mbps")
        #expect(UsageMonitor.formatRate(1_000_000, unit: .megabytesPerSecond) == "1.0 MB/s")
        #expect(UsageMonitor.formatMenuBarRates(
            downloadBytesPerSecond: 1_550_000,
            uploadBytesPerSecond: 100_000,
            unit: .megabitsPerSecond
        ) == "↓ 12.4 / ↑ 0.8 Mbps")
        #expect(UsageMonitor.formatMenuBarRates(
            downloadBytesPerSecond: 1_550_000,
            uploadBytesPerSecond: 100_000,
            unit: .megabytesPerSecond
        ) == "↓ 1.6 / ↑ 0.1 MB/s")
        #expect(UsageFormatting.data(1_000_000, unit: .decimal) == "1.0 MB")
        #expect(UsageFormatting.data(1_048_576, unit: .binary) == "1.0 MiB")
    }
}
