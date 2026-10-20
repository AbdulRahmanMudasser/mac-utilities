import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct WidgetReloadCoordinatorTests {
    @MainActor
    private final class ScheduledAction {
        let delay: TimeInterval
        private let operation: @MainActor () -> Void
        private(set) var isCancelled = false

        init(delay: TimeInterval, operation: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.operation = operation
        }

        func cancel() { isCancelled = true }

        func fire() {
            guard !isCancelled else { return }
            operation()
        }
    }

    @MainActor
    private final class ManualScheduler {
        private(set) var actions: [ScheduledAction] = []

        func schedule(
            after delay: TimeInterval,
            operation: @escaping @MainActor () -> Void
        ) -> WidgetReloadCoordinator.ScheduledCancellation {
            let action = ScheduledAction(delay: delay, operation: operation)
            actions.append(action)
            return { action.cancel() }
        }
    }

    @MainActor
    private final class MonitorFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-reload-tests-\(UUID().uuidString)", isDirectory: true)
        var storageDirectory: URL { directory.appendingPathComponent("container", isDirectory: true) }
        var stateURL: URL { storageDirectory.appendingPathComponent("today-usage.json") }
        var date: Date
        var calendar = UsageHistory.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        var counters = ["en0": InterfaceByteCount(downloaded: 1_000, uploaded: 500)]

        init(date: Date? = nil) {
            self.date = date ?? Self.date("2026-10-15T12:00:00Z")
        }

        func makeMonitor() -> UsageMonitor {
            UsageMonitor(stateURL: stateURL, startAutomatically: false,
                preferences: UserDefaults(suiteName: "MacUtilities.WidgetReloadTests.\(UUID().uuidString)"),
                now: { self.date }, calendar: { self.calendar }, readCounters: { self.counters },
                bootIdentifier: { "widget-reload-test-boot" })
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        static func date(_ text: String) -> Date {
            ISO8601DateFormatter().date(from: text)!
        }
    }

    @Test
    func startupPublicationIsDeliveredAfterTheCanonicalWrite() throws {
        let fixture = MonitorFixture()
        defer { fixture.remove() }
        var reasons: [WidgetReloadReason] = []
        let monitor = UsageMonitor(stateURL: fixture.stateURL, startAutomatically: false,
            onSnapshotCommittedWithReason: { snapshot, reason in
                #expect((try? UsageWidgetSnapshotReader.read(at: fixture.stateURL)) == snapshot)
                reasons.append(reason)
            }, now: { fixture.date }, calendar: { fixture.calendar }, readCounters: { fixture.counters })
        defer { monitor.shutdown() }
        #expect(reasons == [.ordinary])
    }

    @Test
    func ordinaryRequestsCoalesceAndReloadAtTheThirtyMinuteBoundary() {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var requestedKinds: [String] = []
        let scheduler = ManualScheduler()
        let coordinator = WidgetReloadCoordinator(widgetKind: "usage-history-kind", now: { date },
            reloadTimelines: { requestedKinds.append($0) },
            schedule: { delay, operation in scheduler.schedule(after: delay, operation: operation) })

        coordinator.requestReload(for: .ordinary)
        #expect(requestedKinds == ["usage-history-kind"])

        date.addTimeInterval(120)
        coordinator.requestReload(for: .ordinary)
        date.addTimeInterval(300)
        coordinator.requestReload(for: .ordinary)

        #expect(requestedKinds == ["usage-history-kind"])
        #expect(scheduler.actions.count == 1)
        #expect(scheduler.actions[0].delay == 1_680)

        date.addTimeInterval(1_380)
        scheduler.actions[0].fire()

        #expect(requestedKinds == ["usage-history-kind", "usage-history-kind"])
    }

    @Test
    func ordinaryRequestAtTheBoundaryConsumesTheScheduledReload() {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var requestedKinds: [String] = []
        let scheduler = ManualScheduler()
        let coordinator = WidgetReloadCoordinator(widgetKind: "usage-history-kind", now: { date },
            reloadTimelines: { requestedKinds.append($0) },
            schedule: { delay, operation in scheduler.schedule(after: delay, operation: operation) })

        coordinator.requestReload(for: .ordinary)
        date.addTimeInterval(1)
        coordinator.requestReload(for: .ordinary)
        let pending = scheduler.actions[0]

        date.addTimeInterval(1_799)
        coordinator.requestReload(for: .ordinary)
        pending.fire()

        #expect(pending.isCancelled)
        #expect(requestedKinds == ["usage-history-kind", "usage-history-kind"])
    }

    @Test
    func immediateRequestsBypassThrottleAndCancelPendingOrdinaryReloads() {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var requestedKinds: [String] = []
        let scheduler = ManualScheduler()
        let coordinator = WidgetReloadCoordinator(widgetKind: "usage-history-kind", now: { date },
            reloadTimelines: { requestedKinds.append($0) },
            schedule: { delay, operation in scheduler.schedule(after: delay, operation: operation) })

        coordinator.requestReload(for: .ordinary)
        date.addTimeInterval(10)
        coordinator.requestReload(for: .ordinary)
        let pending = scheduler.actions[0]

        date.addTimeInterval(10)
        coordinator.requestReload(for: .historyCleared)

        #expect(requestedKinds.count == 2)
        #expect(pending.isCancelled)

        date.addTimeInterval(1)
        pending.fire()
        #expect(requestedKinds.count == 2)
    }

    @Test
    func shutdownCancelsPendingReloadAndRejectsLaterRequests() {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var requestedKinds: [String] = []
        let scheduler = ManualScheduler()
        let coordinator = WidgetReloadCoordinator(widgetKind: "usage-history-kind", now: { date },
            reloadTimelines: { requestedKinds.append($0) },
            schedule: { delay, operation in scheduler.schedule(after: delay, operation: operation) })

        coordinator.requestReload(for: .ordinary)
        date.addTimeInterval(1)
        coordinator.requestReload(for: .ordinary)
        let pending = scheduler.actions[0]

        coordinator.shutdown()
        pending.fire()
        coordinator.requestReload(for: .historyCleared)

        #expect(pending.isCancelled)
        #expect(requestedKinds == ["usage-history-kind"])
    }

    @Test
    func successfulUnitAndClearCommitsKeepLegacyCallbackAndIncludeImmediateReason() {
        let fixture = MonitorFixture()
        let monitor = fixture.makeMonitor()
        defer { monitor.shutdown(); fixture.remove() }
        var legacySnapshots: [UsageWidgetSnapshot] = []
        var reasonedCommits: [(UsageWidgetSnapshot, WidgetReloadReason)] = []
        monitor.onSnapshotCommitted = { legacySnapshots.append($0) }
        monitor.onSnapshotCommittedWithReason = { snapshot, reason in
            reasonedCommits.append((snapshot, reason))
        }

        monitor.dataUnit = .binary

        #expect(legacySnapshots.count == 1)
        #expect(legacySnapshots[0].dataUnit == .binary)
        #expect(reasonedCommits.map { $0.1 } == [.dataUnitChanged])
        #expect(reasonedCommits[0].0 == legacySnapshots[0])

        monitor.clearHistory()

        #expect(reasonedCommits.map { $0.1 } == [.dataUnitChanged, .historyCleared])
        #expect(reasonedCommits[1].0.records.isEmpty)
        #expect(legacySnapshots.count == 2)
    }

    @Test
    func failedImmediateSaveRetainsReasonUntilTheNextSuccessfulCommit() throws {
        let fixture = MonitorFixture()
        let monitor = fixture.makeMonitor()
        defer { monitor.shutdown(); fixture.remove() }
        var reasonedCommits: [WidgetReloadReason] = []
        monitor.onSnapshotCommittedWithReason = { _, reason in reasonedCommits.append(reason) }

        try FileManager.default.removeItem(at: fixture.storageDirectory)
        try Data("blocks directory creation".utf8).write(to: fixture.storageDirectory)
        monitor.dataUnit = .binary

        #expect(reasonedCommits.isEmpty)
        #expect(monitor.historyError != nil)

        try FileManager.default.removeItem(at: fixture.storageDirectory)
        try FileManager.default.createDirectory(at: fixture.storageDirectory, withIntermediateDirectories: true)
        monitor.flush()

        #expect(reasonedCommits == [.dataUnitChanged])
        #expect(monitor.historyError == nil)
    }

    @Test
    func localDayAndTimeZoneCommitsCarryImmediateReasons() throws {
        let rolloverFixture = MonitorFixture(date: MonitorFixture.date("2026-10-15T23:59:00Z"))
        let rolloverMonitor = rolloverFixture.makeMonitor()
        defer { rolloverMonitor.shutdown(); rolloverFixture.remove() }
        var rolloverReasons: [WidgetReloadReason] = []
        rolloverMonitor.onSnapshotCommittedWithReason = { _, reason in rolloverReasons.append(reason) }
        rolloverFixture.date.addTimeInterval(120)
        rolloverMonitor.sample()
        #expect(rolloverReasons == [.localDayChanged])

        let zoneFixture = MonitorFixture()
        let zoneMonitor = zoneFixture.makeMonitor()
        defer { zoneMonitor.shutdown(); zoneFixture.remove() }
        var zoneReasons: [WidgetReloadReason] = []
        zoneMonitor.onSnapshotCommittedWithReason = { _, reason in zoneReasons.append(reason) }
        zoneFixture.calendar.timeZone = try #require(TimeZone(identifier: "Asia/Karachi"))
        zoneMonitor.sample()
        #expect(zoneReasons == [.timeZoneChanged])
    }

    @Test
    func ordinaryPublicationRequiresChangedProjectionRecords() {
        let fixture = MonitorFixture()
        let monitor = fixture.makeMonitor()
        defer { monitor.shutdown(); fixture.remove() }
        var reasons: [WidgetReloadReason] = []
        monitor.onSnapshotCommittedWithReason = { _, reason in reasons.append(reason) }

        monitor.flush()
        #expect(reasons.isEmpty)

        fixture.date.addTimeInterval(6)
        fixture.counters["en0"]!.downloaded += 10
        fixture.counters["en0"]!.uploaded += 5
        monitor.sample()

        #expect(reasons == [.ordinary])
    }
}
