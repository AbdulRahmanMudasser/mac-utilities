import Foundation
import AppKit
import Testing
@testable import Mac_Utilities

@MainActor
private final class FakeKeepAwakePower: PowerAsserting {
    struct CreateRequest {
        let kind: PowerAssertionKind
        let timeout: TimeInterval?
    }

    private(set) var createRequests: [CreateRequest] = []
    private(set) var releaseAttempts: [PowerAssertionID] = []
    var failSystemCreate = false
    var failDisplayCreate = false
    var failedReleaseIDs: Set<UInt32> = []
    private var nextID: UInt32 = 1

    func create(_ kind: PowerAssertionKind, timeout: TimeInterval?) throws -> PowerAssertionID {
        createRequests.append(CreateRequest(kind: kind, timeout: timeout))
        switch kind {
        case .systemIdle where failSystemCreate:
            throw FakeKeepAwakePowerError.creation
        case .displayIdle where failDisplayCreate:
            throw FakeKeepAwakePowerError.creation
        default:
            let id = PowerAssertionID(rawValue: nextID)
            nextID &+= 1
            return id
        }
    }

    func release(_ id: PowerAssertionID) throws {
        releaseAttempts.append(id)
        if failedReleaseIDs.contains(id.rawValue) { throw FakeKeepAwakePowerError.release }
    }
}

private enum FakeKeepAwakePowerError: Error, LocalizedError {
    case creation
    case release

    var errorDescription: String? {
        switch self {
        case .creation: "Injected Assertion Creation Failure."
        case .release: "Injected Assertion Release Failure."
        }
    }
}

@MainActor
private final class FakeKeepAwakeClock {
    private struct Sleeper {
        let deadline: Double
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var uptime: Double = 0
    private(set) var wallDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var sleepers: [UUID: Sleeper] = [:]

    func makeClock() -> KeepAwakeClock {
        KeepAwakeClock(
            now: { [weak self] in self?.uptime ?? 0 },
            date: { [weak self] in self?.wallDate ?? .distantPast },
            sleepUntil: { [weak self] deadline in
                guard let self else { throw CancellationError() }
                try await self.sleepUntil(deadline)
            }
        )
    }

    var pendingDeadlines: [Double] { sleepers.values.map(\.deadline).sorted() }

    func setWallDate(_ date: Date) { wallDate = date }
    func setUptimeWithoutWaking(_ value: Double) { uptime = value }

    func advance(monotonic seconds: Double, wall secondsOnWallClock: Double = 0) {
        uptime += seconds
        wallDate = wallDate.addingTimeInterval(secondsOnWallClock)
        resumeSleepers(through: uptime)
    }

    func resumeAll() {
        let pending = sleepers.values
        sleepers.removeAll()
        for sleeper in pending { sleeper.continuation.resume() }
    }

    func waitForSleepers(_ count: Int) async {
        for _ in 0..<2_000 where sleepers.count < count { await Task.yield() }
    }

    private func sleepUntil(_ deadline: Double) async throws {
        if deadline <= uptime { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
        }
    }

    private func resumeSleepers(through time: Double) {
        let ready = sleepers.filter { $0.value.deadline <= time }
        for (id, sleeper) in ready {
            sleepers[id] = nil
            sleeper.continuation.resume()
        }
    }
}

@MainActor
private final class FakeTimerFinishedNotifier: KeepAwakeTimerFinishedNotifying {
    private(set) var events: [KeepAwakeTimerFinishedEvent] = []

    func notifyTimerFinished(_ event: KeepAwakeTimerFinishedEvent) {
        events.append(event)
    }
}

@MainActor
private final class KeepAwakeTestHarness {
    let suiteName = "MacUtilities.KeepAwakeTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let power: FakeKeepAwakePower
    let clock: FakeKeepAwakeClock
    let timerFinishedNotifier: FakeTimerFinishedNotifier
    let wakeNotificationCenter = NotificationCenter()
    let controller: KeepAwakeController

    init(prepare: (UserDefaults) -> Void = { _ in }) {
        preferences = UserDefaults(suiteName: suiteName)!
        preferences.removePersistentDomain(forName: suiteName)
        prepare(preferences)
        power = FakeKeepAwakePower()
        clock = FakeKeepAwakeClock()
        timerFinishedNotifier = FakeTimerFinishedNotifier()
        controller = KeepAwakeController(
            power: power,
            preferences: preferences,
            clock: clock.makeClock(),
            wakeNotificationCenter: wakeNotificationCenter,
            timerFinishedNotifier: timerFinishedNotifier
        )
    }

    func cleanUp() async {
        controller.shutdown()
        clock.resumeAll()
        for _ in 0..<20 { await Task.yield() }
        preferences.removePersistentDomain(forName: suiteName)
    }
}

@Suite(.serialized)
@MainActor
struct KeepAwakeControllerTests {
    @Test func defaultsAndSavedPreferencesDoNotRestoreAnActiveSession() async {
        let harness = KeepAwakeTestHarness()
        #expect(harness.controller.presetConfiguration.presets.map(\.title) == ["30 Min", "1 Hour", "2 Hours", "Until Stopped"])
        #expect(harness.controller.selectedPresetID == .timedOne)
        #expect(!harness.controller.isActive)
        #expect(harness.controller.menuBarPrefix == "")
        #expect(harness.power.createRequests.isEmpty)

        try? harness.controller.setPresetEnabled(false, for: .timedThree)
        harness.controller.setKeepDisplayOn(true)
        harness.controller.setActive(true)
        #expect(harness.controller.isActive)
        #expect(harness.controller.menuBarPrefix == "☾ 30 Min\u{2003}")
        #expect(harness.power.createRequests.count == 2)

        let relaunchPower = FakeKeepAwakePower()
        let relaunchClock = FakeKeepAwakeClock()
        let relaunched = KeepAwakeController(
            power: relaunchPower,
            preferences: harness.preferences,
            clock: relaunchClock.makeClock()
        )
        #expect(!relaunched.isActive)
        #expect(relaunchPower.createRequests.isEmpty)
        #expect(relaunched.isKeepDisplayOn)
        #expect(relaunched.presetConfiguration.enabledPresets.map(\.id) == [.timedOne, .timedTwo, .untilStopped])
        #expect(relaunched.selectedPresetID == .timedOne)

        harness.controller.shutdown()
        relaunchClock.resumeAll()
        relaunched.shutdown()
        await harness.cleanUp()
    }

    @Test func invalidPreferenceFallsBackToTheCompleteDefaultConfiguration() async throws {
        let invalid = [
            KeepAwakePreset(id: .timedOne, duration: .timed(minutes: 0)),
            KeepAwakePreset(id: .timedTwo, duration: .timed(minutes: 60)),
            KeepAwakePreset(id: .timedThree, duration: .timed(minutes: 120)),
            KeepAwakePreset(id: .untilStopped, duration: .untilStopped),
        ]
        let encoded = try JSONEncoder().encode(invalid)
        let harness = KeepAwakeTestHarness { preferences in
            preferences.set(encoded, forKey: KeepAwakeController.presetsPreferenceKey)
            preferences.set(true, forKey: KeepAwakeController.keepDisplayOnPreferenceKey)
        }

        #expect(harness.controller.presetConfiguration == .defaults)
        #expect(harness.controller.preferenceError != nil)
        #expect(harness.controller.isKeepDisplayOn)
        #expect(harness.power.createRequests.isEmpty)
        await harness.cleanUp()
    }

    @Test func endedSessionOutcomeIsTransientAndDoesNotRestoreAfterRelaunch() async {
        let harness = KeepAwakeTestHarness()
        harness.controller.setActive(true)
        harness.controller.setActive(false)
        #expect(harness.controller.lastSession?.outcome == .cancelled(reason: .stopped))

        let relaunchClock = FakeKeepAwakeClock()
        let relaunched = KeepAwakeController(
            power: FakeKeepAwakePower(),
            preferences: harness.preferences,
            clock: relaunchClock.makeClock()
        )
        #expect(relaunched.lastSession == nil)
        relaunched.shutdown()
        await harness.cleanUp()
    }

    @Test func incompletePreferencesFallBackAndRestoreDefaultsPersistsTheCompleteConfiguration() async throws {
        let incomplete = [
            KeepAwakePreset(id: .timedOne, duration: .timed(minutes: 15)),
            KeepAwakePreset(id: .untilStopped, duration: .untilStopped),
        ]
        let encoded = try JSONEncoder().encode(incomplete)
        let harness = KeepAwakeTestHarness { preferences in
            preferences.set(encoded, forKey: KeepAwakeController.presetsPreferenceKey)
        }

        #expect(harness.controller.presetConfiguration == .defaults)
        #expect(harness.controller.preferenceError != nil)

        try harness.controller.setPresetDuration(.timed(minutes: 45), for: .timedOne)
        harness.controller.restoreDefaultPresets()
        #expect(harness.controller.presetConfiguration == .defaults)
        #expect(harness.controller.preferenceError == nil)
        let saved = try #require(harness.preferences.data(forKey: KeepAwakeController.presetsPreferenceKey))
        let decoded = try JSONDecoder().decode([KeepAwakePreset].self, from: saved)
        #expect(try KeepAwakePresetConfiguration(validating: decoded) == .defaults)
        await harness.cleanUp()
    }

    @Test func presetEditsEnforceEnabledCountUniqueDurationsAndBounds() async {
        let harness = KeepAwakeTestHarness()
        let controller = harness.controller

        try? controller.setPresetDuration(.timed(minutes: 1), for: .timedOne)
        try? controller.setPresetDuration(.timed(minutes: 1_440), for: .timedThree)
        #expect(controller.presetConfiguration.presets.first?.duration == .timed(minutes: 1))
        #expect(controller.presetConfiguration.presets.first(where: { $0.id == .timedThree })?.duration == .timed(minutes: 1_440))
        #expect(validationError { try controller.setPresetDuration(.timed(minutes: 1_441), for: .timedThree) } == .durationOutOfRange(for: .timedThree))

        try? controller.setPresetEnabled(false, for: .timedOne)
        try? controller.setPresetEnabled(false, for: .timedTwo)
        #expect(controller.presetConfiguration.enabledPresets.map(\.id) == [.timedThree, .untilStopped])
        #expect(validationError { try controller.setPresetEnabled(false, for: .timedThree) } == .enabledCountOutOfRange)
        #expect(validationError { try controller.setPresetDuration(.timed(minutes: 1), for: .timedThree) } == .duplicateDuration)
        #expect(validationError { try controller.setPresetDuration(.timed(minutes: 0), for: .timedThree) } == .durationOutOfRange(for: .timedThree))
        #expect(controller.presetConfiguration.enabledPresets.map(\.id) == [.timedThree, .untilStopped])
        #expect(controller.preferenceError == nil)
        await harness.cleanUp()
    }

    @Test func editingPresetsLeavesTheRunningSessionSnapshotAndDeadlineUnchanged() async {
        let harness = KeepAwakeTestHarness()
        harness.controller.setActive(true)
        let original = harness.controller.activeSession
        #expect(original?.duration == .timed(minutes: 30))
        let oldEndDate = original?.endsAt

        try? harness.controller.setPresetDuration(.timed(minutes: 90), for: .timedOne)

        #expect(harness.controller.activeSession == original)
        #expect(harness.controller.activeSession?.endsAt == oldEndDate)
        #expect(harness.controller.presetConfiguration.presets.first?.duration == .timed(minutes: 90))
        await harness.cleanUp()
    }

    @Test func selectingTheFallbackPresetReplacesAHiddenActivePreset() async {
        let harness = KeepAwakeTestHarness()
        let controller = harness.controller
        controller.setActive(true)
        let original = controller.activeSession

        try? controller.setPresetEnabled(false, for: .timedOne)
        #expect(controller.selectedPresetID == .timedTwo)
        #expect(controller.activeSession == original)
        #expect(harness.power.createRequests.count == 1)

        controller.selectPreset(.timedTwo)
        #expect(controller.activeSession?.presetID == .timedTwo)
        #expect(controller.activeSession?.duration == .timed(minutes: 60))
        #expect(harness.power.createRequests.count == 2)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [1])
        await harness.cleanUp()
    }

    @Test func selectingAnotherPresetReplacesAndRepeatedStopReleasesEachIDOnce() async {
        let harness = KeepAwakeTestHarness()
        let controller = harness.controller
        controller.setActive(true)
        #expect(harness.power.createRequests.count == 1)

        controller.selectPreset(.untilStopped)
        #expect(controller.isActive)
        #expect(controller.activeSession?.duration == .untilStopped)
        #expect(controller.menuBarPrefix == "☾ ∞\u{2003}")
        #expect(controller.lastSession?.outcome == .cancelled(reason: .replaced))
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [1])
        #expect(harness.power.createRequests.count == 2)
        #expect(harness.power.createRequests[1].timeout == nil)

        controller.setActive(false)
        #expect(controller.lastSession?.outcome == .cancelled(reason: .stopped))
        controller.setActive(false)
        controller.shutdown()
        #expect(!controller.isActive)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [1, 2])
        await harness.cleanUp()
    }

    @Test func monotonicTimeExpiresSessionDespiteWallClockChangesAndDelayedWake() async {
        let harness = KeepAwakeTestHarness()
        let controller = harness.controller
        let initialDate = harness.clock.wallDate
        controller.setActive(true)
        let endDate = controller.activeSession?.endsAt
        await harness.clock.waitForSleepers(1)

        harness.clock.setWallDate(initialDate.addingTimeInterval(-86_400))
        controller.reconcileAfterWake()
        #expect(controller.isActive)
        #expect(controller.remainingMinutes == 30)
        #expect(controller.activeSession?.endsAt == endDate)

        harness.clock.advance(monotonic: 1_740)
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.isActive)
        #expect(controller.remainingMinutes == 1)
        harness.clock.setWallDate(initialDate.addingTimeInterval(86_400))
        controller.reconcileAfterWake()
        #expect(controller.isActive)
        #expect(controller.remainingMinutes == 1)

        harness.clock.advance(monotonic: 60)
        for _ in 0..<20 { await Task.yield() }
        #expect(!controller.isActive)
        #expect(controller.remainingMinutes == nil)
        #expect(controller.lastSession?.outcome == .completed)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [1])
        await harness.cleanUp()
    }

    @Test func naturalFiniteExpirationNotifiesExactlyOnceAfterAssertionsRelease() async {
        let harness = KeepAwakeTestHarness()
        harness.controller.setActive(true)
        await harness.clock.waitForSleepers(1)

        harness.clock.advance(monotonic: 1_800)
        for _ in 0..<20 { await Task.yield() }

        #expect(!harness.controller.isActive)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [1])
        #expect(harness.timerFinishedNotifier.events.count == 1)
        #expect(harness.timerFinishedNotifier.events.first?.duration == .timed(minutes: 30))
        #expect(harness.timerFinishedNotifier.events.first?.sessionGeneration == 1)
        await harness.cleanUp()
    }

    @Test func cancellationReplacementUntilStoppedAndReleaseFailureDoNotNotify() async {
        let harness = KeepAwakeTestHarness()
        harness.controller.setActive(true)
        harness.controller.setActive(false)
        harness.controller.setActive(true)
        harness.controller.selectPreset(.untilStopped)
        harness.controller.setActive(false)

        let failed = KeepAwakeTestHarness()
        failed.controller.setActive(true)
        failed.power.failedReleaseIDs = [1]
        failed.controller.setActive(false)

        #expect(harness.timerFinishedNotifier.events.isEmpty)
        #expect(failed.timerFinishedNotifier.events.isEmpty)
        await harness.cleanUp()
        await failed.cleanUp()
    }

    @Test func untilStoppedHasNoDeadlineAndDisplayPreferenceAppliesLive() async {
        let harness = KeepAwakeTestHarness()
        let controller = harness.controller
        controller.selectPreset(.untilStopped)
        controller.setActive(true)
        #expect(controller.isActive)
        #expect(controller.isUntilStopped)
        #expect(controller.remainingMinutes == nil)
        #expect(controller.activeSession?.endsAt == nil)
        #expect(harness.power.createRequests.map(\.kind) == [.systemIdle])

        controller.setKeepDisplayOn(true)
        #expect(harness.power.createRequests.map(\.kind) == [.systemIdle, .displayIdle])
        #expect(harness.power.createRequests.allSatisfy { $0.timeout == nil })

        controller.setKeepDisplayOn(false)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [2])
        #expect(controller.isActive)
        controller.setActive(false)
        #expect(controller.lastSession?.outcome == .cancelled(reason: .stopped))
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [2, 1])
        await harness.cleanUp()
    }

    @Test func displayCreationFailureKeepsBaseSessionActiveAndBaseCreationFailureStaysOff() async {
        let displayHarness = KeepAwakeTestHarness()
        displayHarness.power.failDisplayCreate = true
        displayHarness.controller.setKeepDisplayOn(true)
        displayHarness.controller.setActive(true)
        #expect(displayHarness.controller.isActive)
        #expect(displayHarness.controller.warningMessage?.contains("Keep Display On") == true)
        #expect(displayHarness.power.createRequests.count == 2)
        await displayHarness.clock.waitForSleepers(1)
        displayHarness.clock.advance(monotonic: 1_800)
        for _ in 0..<20 { await Task.yield() }
        #expect(displayHarness.timerFinishedNotifier.events.isEmpty)
        displayHarness.controller.setActive(false)
        #expect(displayHarness.power.releaseAttempts.map(\.rawValue) == [1])
        await displayHarness.cleanUp()

        let baseHarness = KeepAwakeTestHarness()
        baseHarness.power.failSystemCreate = true
        baseHarness.controller.setActive(true)
        #expect(!baseHarness.controller.isActive)
        #expect(baseHarness.controller.errorMessage?.contains("could not start") == true)
        #expect(baseHarness.controller.lastSession == nil)
        #expect(baseHarness.power.releaseAttempts.isEmpty)
        await baseHarness.cleanUp()
    }

    @Test func liveDisplayCreationFailureSuppressesFiniteCompletionNotification() async {
        let harness = KeepAwakeTestHarness()
        harness.controller.setActive(true)
        harness.power.failDisplayCreate = true

        harness.controller.setKeepDisplayOn(true)
        #expect(harness.controller.isActive)
        #expect(harness.controller.warningMessage?.contains("Keep Display On") == true)

        await harness.clock.waitForSleepers(1)
        harness.clock.advance(monotonic: 1_800)
        for _ in 0..<20 { await Task.yield() }

        #expect(!harness.controller.isActive)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [1])
        #expect(harness.timerFinishedNotifier.events.isEmpty)
        await harness.cleanUp()
    }

    @Test func liveDisplayReleaseFailureSuppressesFiniteCompletionNotification() async {
        let harness = KeepAwakeTestHarness()
        harness.controller.setKeepDisplayOn(true)
        harness.controller.setActive(true)
        harness.power.failedReleaseIDs = [2]

        harness.controller.setKeepDisplayOn(false)
        #expect(harness.controller.isStartBlocked)

        await harness.clock.waitForSleepers(1)
        harness.clock.advance(monotonic: 1_800)
        for _ in 0..<20 { await Task.yield() }

        #expect(!harness.controller.isActive)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [2, 1])
        #expect(harness.timerFinishedNotifier.events.isEmpty)
        await harness.cleanUp()
    }

    @Test func failedReleaseBlocksStartsAndIsNeverRetriedDuringShutdown() async {
        let harness = KeepAwakeTestHarness()
        let controller = harness.controller
        controller.selectPreset(.untilStopped)
        controller.setKeepDisplayOn(true)
        controller.setActive(true)
        harness.power.failedReleaseIDs = [2]

        controller.setKeepDisplayOn(false)
        #expect(controller.isActive)
        #expect(controller.isStartBlocked)
        #expect(controller.errorMessage?.contains("Restart Mac Utilities") == true)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [2])

        controller.setActive(false)
        controller.setActive(true)
        controller.shutdown()
        #expect(!controller.isActive)
        #expect(harness.power.createRequests.count == 2)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [2, 1])

        let afterRelaunchPower = FakeKeepAwakePower()
        let afterRelaunchClock = FakeKeepAwakeClock()
        let afterRelaunch = KeepAwakeController(
            power: afterRelaunchPower,
            preferences: harness.preferences,
            clock: afterRelaunchClock.makeClock()
        )
        afterRelaunch.selectPreset(.untilStopped)
        afterRelaunch.setActive(true)
        #expect(afterRelaunch.isActive)
        afterRelaunch.shutdown()
        afterRelaunchClock.resumeAll()
        await harness.cleanUp()
    }

    @Test func failedBaseReleaseBlocksStartsAndIsNeverRetriedDuringShutdown() async {
        let harness = KeepAwakeTestHarness()
        let controller = harness.controller
        controller.setActive(true)
        harness.power.failedReleaseIDs = [1]

        controller.setActive(false)
        #expect(!controller.isActive)
        #expect(controller.isStartBlocked)
        #expect(controller.errorMessage?.contains("Restart Mac Utilities") == true)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [1])

        controller.setActive(true)
        controller.shutdown()
        #expect(!controller.isActive)
        #expect(harness.power.createRequests.count == 1)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [1])
        await harness.cleanUp()
    }

    @Test func staleCancelledTimerCannotExpireReplacementUntilStoppedSession() async {
        let harness = KeepAwakeTestHarness()
        let controller = harness.controller
        controller.setActive(true)
        await harness.clock.waitForSleepers(1)

        controller.selectPreset(.untilStopped)
        #expect(controller.isUntilStopped)
        harness.clock.advance(monotonic: 60)
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.isActive)
        #expect(controller.isUntilStopped)
        #expect(controller.remainingMinutes == nil)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [1])
        controller.shutdown()
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [1, 2])
        await harness.cleanUp()
    }

    @Test func shutdownIsIdempotentAndReleasesEverySuccessfulAssertionOnce() async {
        let harness = KeepAwakeTestHarness()
        harness.controller.selectPreset(.untilStopped)
        harness.controller.setKeepDisplayOn(true)
        harness.controller.setActive(true)

        harness.controller.shutdown()
        harness.controller.shutdown()
        harness.controller.setActive(true)

        #expect(!harness.controller.isActive)
        #expect(harness.controller.lastSession?.outcome == .cancelled(reason: .applicationQuit))
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [2, 1])
        #expect(harness.power.createRequests.count == 2)
        await harness.cleanUp()
    }

    @Test func workspaceWakeNotificationExpiresADeadlinePassedDuringSleep() async {
        let harness = KeepAwakeTestHarness()
        harness.controller.setActive(true)
        await harness.clock.waitForSleepers(1)
        harness.clock.setUptimeWithoutWaking(1_801)

        harness.wakeNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }

        #expect(!harness.controller.isActive)
        #expect(harness.power.releaseAttempts.map(\.rawValue) == [1])
        #expect(harness.controller.menuBarPrefix == "")
        #expect(harness.timerFinishedNotifier.events.count == 1)
        await harness.cleanUp()
    }
}

@MainActor
private func validationError(_ body: () throws -> Void) -> KeepAwakePresetValidationError? {
    do {
        try body()
        return nil
    } catch {
        return error as? KeepAwakePresetValidationError
    }
}
