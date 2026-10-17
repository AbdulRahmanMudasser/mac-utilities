import AppKit
import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
final class StabilityTestClock {
    private(set) var uptime = 0.0
    private(set) var wallDate = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var sleepDeadlines: [Double] = []
    var advancesAutomatically = true
    var onAutomaticSleep: ((Double) -> Void)?

    private struct Waiter {
        let id: UUID
        let deadline: Double
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    var waitingDeadlines: [Double] { waiters.map(\.deadline) }

    func makeClock() -> StabilityClock {
        StabilityClock(now: { [weak self] in self?.uptime ?? 0 },
                       date: { [weak self] in self?.wallDate ?? .distantPast },
                       sleepUntil: { [weak self] deadline in
                           guard let self else { throw CancellationError() }
                           try await self.sleepUntil(deadline)
                       },
                       ticksProgress: false,
                       waitForDeadline: { [weak self] deadline in
                           guard let self else { throw CancellationError() }
                           try await self.waitForDeadline(deadline)
                       })
    }

    func setWallDate(_ date: Date) { wallDate = date }

    func jump(to value: Double) {
        uptime = value
        let ready = waiters.filter { $0.deadline <= uptime }
        waiters.removeAll { $0.deadline <= uptime }
        for waiter in ready { waiter.continuation.resume() }
    }

    private func sleepUntil(_ deadline: Double) async throws {
        sleepDeadlines.append(deadline)
        try Task.checkCancellation()
        guard deadline > uptime else { return }

        if advancesAutomatically {
            jump(to: deadline)
            onAutomaticSleep?(deadline)
        } else {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelWaiter(id) }
            }
        }
        try Task.checkCancellation()
    }

    private func waitForDeadline(_ deadline: Double) async throws {
        guard deadline > uptime else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
final class FakeStabilityEventSource: StabilityEventSource {
    var initialPath: StabilityPathState?
    private var receive: (@MainActor (StabilityEnvironmentEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(initialPath: StabilityPathState? = .satisfied("test-interface-a")) {
        self.initialPath = initialPath
    }

    func start(_ receive: @escaping @MainActor (StabilityEnvironmentEvent) -> Void) {
        startCount += 1
        self.receive = receive
        if let initialPath { receive(.path(initialPath)) }
    }

    func emit(_ event: StabilityEnvironmentEvent) { receive?(event) }

    func stop() {
        stopCount += 1
        receive = nil
    }
}

@MainActor
final class CancellableProbePairGate {
    private(set) var started: [UUID] = []
    private(set) var cancelled: [UUID] = []
    private(set) var completedFirstPair: [UUID] = []
    private var probes: [UUID: CheckedContinuation<DiagnosticProcessOutput, Error>] = [:]
    private var cleanup: [CheckedContinuation<Void, Never>] = []

    func probe(_ operationID: UUID) async throws -> DiagnosticProcessOutput {
        started.append(operationID)
        guard started.count <= 2 else { return stabilityReplyOutput(40) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                probes[operationID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in await self?.finishCancelledProbe(operationID) }
        }
    }

    func releaseCleanup() {
        let pending = cleanup
        cleanup = []
        for continuation in pending { continuation.resume() }
    }

    private func finishCancelledProbe(_ operationID: UUID) async {
        cancelled.append(operationID)
        await withCheckedContinuation { continuation in cleanup.append(continuation) }
        completedFirstPair.append(operationID)
        probes.removeValue(forKey: operationID)?.resume(returning: stabilityReplyOutput(40))
    }
}

func stabilityReplyOutput(_ milliseconds: Double = 8) -> DiagnosticProcessOutput {
    DiagnosticProcessOutput(
        stdout: Data("64 bytes from 8.8.8.8: icmp_seq=0 ttl=52 time=\(milliseconds) ms\n1 packets transmitted, 1 packets received, 0.0% packet loss".utf8),
        stderr: Data(),
        exitCode: 0
    )
}

@Suite(.serialized)
@MainActor
struct StabilityCheckTests {
    @Test func summaryPresentationKeepsMissingAndStoppedChecksSeparateFromMissedReplies() {
        let target = ProbeTarget.defaults[0].id
        var snapshot = StabilitySnapshot(id: UUID(), startedAt: .now, elapsed: 10,
            status: .cancelled, observations: [
                observation(target, 0, .unavailable("Mac Asleep")),
                observation(target, 1, .interrupted("Check Cancelled")),
                observation(target, 2, .unavailable("Mac Asleep"))
            ], gaps: [], transitions: [])
        #expect(!snapshot.hasCompletedChecks)
        #expect(snapshot.reasons(for: target) == ["Check Cancelled", "Mac Asleep"])
        #expect(snapshot.summary(for: target).missed == 0)
        snapshot.observations.append(observation(target, 3, .noReply))
        #expect(snapshot.hasCompletedChecks)
        #expect(snapshot.summary(for: target).missed == 1)
        #expect(snapshot.summary(for: target).unobserved == 2)
        #expect(snapshot.summary(for: target).interrupted == 1)
    }

    @Test func deadlineCancelsAnInFlightPairAndRejectsItsLateReplies() async {
        let clock = StabilityTestClock()
        clock.advancesAutomatically = false
        let events = FakeStabilityEventSource()
        let gate = CancellableProbePairGate()
        let subject = session(clock: clock, events: events,
            probe: { operationID, _, _ in try await gate.probe(operationID) })
        let run = Task { await subject.run() }
        for _ in 0..<10_000 where gate.started.count < 2 { await Task.yield() }
        clock.jump(to: 300)
        for _ in 0..<10_000 where gate.cancelled.count < 2 { await Task.yield() }
        #expect(gate.cancelled.count == 2)
        #expect(gate.started.count == 2)
        gate.releaseCleanup()
        let result = await run.value
        #expect(result.status == .completed)
        #expect(result.elapsed == 300)
        #expect(result.observations.count == 120)
        #expect(result.observations.filter { $0.slot == 0 }.allSatisfy {
            $0.outcome == .interrupted("Time Limit Reached")
        })
        #expect(result.summary(for: ProbeTarget.defaults[0].id).completed == 0)
        #expect(gate.completedFirstPair.count == 2)
        #expect(events.stopCount == 1)
    }

    @Test func workspaceNotificationsCompleteTheirMainActorHandoffBeforeReturning() async {
        let events = ConnectionObservationEvents()
        var sleepCount = 0
        var wakeCount = 0
        events.start { event in
            switch event {
            case .sleep: sleepCount += 1
            case .wake: wakeCount += 1
            case .path: break
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(sleepCount == 1)
        await Task.detached {
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
        }.value
        #expect(wakeCount == 1)
        events.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(sleepCount == 1)
        #expect(!events.isObserving)
    }

    @Test func shutdownPermanentlyRejectsNewDiagnosticStarts() async {
        let diagnostics = ConnectionDiagnostics()
        diagnostics.shutdown()
        await diagnostics.waitUntilStopped()
        diagnostics.startLatency()
        diagnostics.startLoad()
        diagnostics.startStability()
        #expect(!diagnostics.isRunning)
        #expect(diagnostics.stabilitySnapshot == nil)
        #expect(diagnostics.probes.isEmpty)
        #expect(diagnostics.quality == nil)
    }

    private func session(clock: StabilityTestClock,
                         events: FakeStabilityEventSource,
                         probe: @escaping StabilityCheckSession.Probe,
                         stopOperations: @escaping @MainActor (Set<UUID>) -> Void = { _ in }) -> StabilityCheckSession {
        StabilityCheckSession(clock: clock.makeClock(), events: events, probe: probe,
                              stopOperations: stopOperations, update: { _ in })
    }

    private func observation(_ target: String, _ slot: Int, _ outcome: StabilityOutcome,
                             epoch: Int = 0) -> StabilityObservation {
        StabilityObservation(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                             targetID: target, slot: slot, elapsed: Double(slot * 5),
                             timestamp: Date(timeIntervalSince1970: Double(slot)), epoch: epoch, outcome: outcome)
    }

    private func waitForSamples(_ diagnostics: ConnectionDiagnostics, count: Int = 2) async {
        for _ in 0..<10_000 {
            if (diagnostics.stabilitySnapshot?.observations.count ?? 0) >= count { return }
            await Task.yield()
        }
        Issue.record("Stability observations did not arrive")
    }

    @Test(arguments: [false, true])
    func terminalTimestampUsesTheActualWallClock(cancelled: Bool) async {
        let clock = StabilityTestClock()
        let startedAt = clock.wallDate
        let finishedAt = startedAt.addingTimeInterval(-3_600)
        var subject: StabilityCheckSession?
        clock.onAutomaticSleep = { deadline in
            if deadline >= 5 {
                clock.setWallDate(finishedAt)
                if cancelled { subject?.cancel() }
            }
        }
        let check = session(clock: clock, events: FakeStabilityEventSource(),
                            probe: { _, _, _ in stabilityReplyOutput() })
        subject = check
        let result = await check.run()

        #expect(result.status == (cancelled ? .cancelled : .completed))
        #expect(result.startedAt == startedAt)
        #expect(result.finishedAt == finishedAt)
        #expect(result.finishedAt != result.startedAt.addingTimeInterval(result.elapsed))
    }

    @Test
    func fiveMinuteCheckRespectsItsProbeCapAndMonotonicDeadline() async {
        let clock = StabilityTestClock()
        let events = FakeStabilityEventSource()
        clock.onAutomaticSleep = { deadline in
            if deadline == 295 { clock.jump(to: 299) }
        }
        var probes: [(time: Double, timeout: Double)] = []
        let subject = session(clock: clock, events: events, probe: { _, _, timeout in
            probes.append((clock.uptime, timeout))
            return stabilityReplyOutput()
        })

        let result = await subject.run()

        #expect(result.status == .completed)
        #expect(result.elapsed == 300)
        #expect(result.observations.count == 60 * ProbeTarget.defaults.count)
        #expect(probes.count == 60 * ProbeTarget.defaults.count)
        #expect(result.observations.map(\.slot).max() == 60 - 1)
        #expect(result.observations.allSatisfy { $0.elapsed < 300 })
        #expect(clock.sleepDeadlines.contains(300))
        #expect(Set(result.observations.map(\.slot)).count == 60)
        #expect(probes.filter { $0.time == 299 }.count == ProbeTarget.defaults.count)
        #expect(probes.filter { $0.time == 299 }.allSatisfy { $0.timeout == 1 })
        #expect(probes.allSatisfy { $0.time < 300 && $0.time + $0.timeout <= 300 })
        #expect(events.startCount == 1)
        #expect(events.stopCount == 1)
    }

    @Test func schedulerDelaySkipsExpiredSlotsWithoutCatchingUp() async {
        let clock = StabilityTestClock()
        let events = FakeStabilityEventSource()
        clock.onAutomaticSleep = { deadline in
            if deadline == 5 { clock.jump(to: 22) }
        }
        var probeTimes: [Double] = []
        let subject = session(clock: clock, events: events, probe: { _, _, _ in
            probeTimes.append(clock.uptime)
            return stabilityReplyOutput()
        })

        let result = await subject.run()

        #expect(probeTimes.filter { $0 == 5 || $0 == 10 || $0 == 15 || $0 == 20 }.isEmpty)
        #expect(probeTimes.filter { $0 == 22 }.count == ProbeTarget.defaults.count)
        #expect(result.observations.filter { (1...3).contains($0.slot) }.allSatisfy {
            if case .unavailable(let reason) = $0.outcome { reason == StabilityGapReason.schedulerDelay.rawValue } else { false }
        })
        #expect(result.observations.filter { $0.slot == 4 }.allSatisfy { $0.elapsed == 22 })
        #expect(result.gaps.contains(StabilityGap(start: 5, end: 22, reason: .schedulerDelay)))
        #expect(probeTimes.count == 114)
    }

    @Test func shortSchedulerStallIsIncludedInCoverage() async {
        let clock = StabilityTestClock()
        let events = FakeStabilityEventSource()
        clock.onAutomaticSleep = { due in if due == 5 { clock.jump(to: 5.5) } }
        let subject = session(clock: clock, events: events, probe: { _, _, _ in stabilityReplyOutput() })
        let result = await subject.run()
        #expect(result.gaps.contains(StabilityGap(start: 5, end: 5.5, reason: .schedulerDelay)))
        #expect(result.unobservedDuration == 0.5)
        #expect(result.observations.filter { $0.slot == 1 }.allSatisfy { $0.elapsed == 5.5 })
    }

    @Test func ordinaryDispatchJitterDoesNotBreakReplyContinuity() async {
        let clock = StabilityTestClock()
        let events = FakeStabilityEventSource()
        clock.onAutomaticSleep = { due in if due == 5 { clock.jump(to: 5.05) } }
        let subject = session(clock: clock, events: events, probe: { _, _, _ in stabilityReplyOutput(20) })
        let result = await subject.run()
        #expect(result.gaps.isEmpty)
        #expect(result.summary(for: ProbeTarget.defaults[0].id).replyTimeChanges == 0)
    }

    @Test func rapidEventsHaveBoundedDetailsAndPreserveCompleteCoverageTotals() async {
        let clock = StabilityTestClock()
        let events = FakeStabilityEventSource()
        clock.onAutomaticSleep = { due in
            guard due == 5 else { return }
            for index in 0..<1000 {
                clock.jump(to: 5 + Double(index) * 0.002)
                events.emit(.path(.unavailable))
                clock.jump(to: 5.001 + Double(index) * 0.002)
                events.emit(.path(.satisfied("a-\(index)")))
                events.emit(.path(.satisfied("b-\(index)")))
            }
        }
        let subject = session(clock: clock, events: events, probe: { _, _, _ in stabilityReplyOutput() })
        let result = await subject.run()
        #expect(result.detailsLimited)
        #expect(result.gaps.count <= 60 * 4)
        #expect(result.transitions.count <= 60 * 2)
        #expect(abs(result.unobservedDuration - 1.999) < 0.001)
        #expect(result.unobservedDuration > StabilityGap.unionDuration(result.gaps))
    }

    @Test func summariesUseCompletedProbeDenominatorsAndBreakReplyChangeContinuity() {
        let target = ProbeTarget.defaults[0].id
        let summary = StabilitySummary(observations: [
            observation(target, 0, .reply(10)),
            observation(target, 1, .noReply),
            observation(target, 2, .reply(50)),
            observation(target, 3, .unavailable("Network Unavailable")),
            observation(target, 4, .reply(100)),
            observation(target, 5, .reply(70), epoch: 1),
            observation(target, 6, .reply(60), epoch: 1),
            observation(target, 7, .interrupted("Mac Asleep"), epoch: 1),
        ])

        #expect(summary.received == 5)
        #expect(summary.missed == 1)
        #expect(summary.completed == 6)
        #expect(abs((summary.missedPercent ?? 0) - (100.0 / 6.0)) < 0.0001)
        #expect(summary.unobserved == 1)
        #expect(summary.interrupted == 1)
        #expect(summary.minimum == 10)
        #expect(summary.maximum == 100)
        #expect(summary.median == 60)
        #expect(summary.replyTimeChanges == 10)
    }

    @Test func quickCheckJitterKeepsItsExistingAdjacentReplyDefinition() throws {
        let output = """
        64 bytes from 8.8.8.8: icmp_seq=0 ttl=52 time=10.000 ms
        64 bytes from 8.8.8.8: icmp_seq=1 ttl=52 time=30.000 ms
        64 bytes from 8.8.8.8: icmp_seq=1 ttl=52 time=30.000 ms (DUP!)
        64 bytes from 8.8.8.8: icmp_seq=3 ttl=52 time=20.000 ms
        4 packets transmitted, 3 packets received, 25.0% packet loss
        """

        #expect(try ProbeStatistics.parse(output).jitter == 15)
    }

    @Test func overlappingGapsAreCountedAsOneUnobservedUnion() {
        let gaps = [
            StabilityGap(start: 0, end: 10, reason: .sleep),
            StabilityGap(start: 5, end: 15, reason: .pathUnavailable),
            StabilityGap(start: 20, end: 25, reason: .schedulerDelay),
            StabilityGap(start: 24, end: 24, reason: .networkChange),
        ]
        #expect(StabilityGap.unionDuration(gaps) == 20)
    }

    @Test func pendingAndUnavailableInitialPathsNeverCreateLossOrZeroLatency() async {
        for initialPath in [Optional<StabilityPathState>.none, .some(.unavailable)] {
            let clock = StabilityTestClock()
            let events = FakeStabilityEventSource(initialPath: initialPath)
            var probeCount = 0
            let subject = session(clock: clock, events: events, probe: { _, _, _ in
                probeCount += 1
                return stabilityReplyOutput(0)
            })

            let result = await subject.run()

            #expect(probeCount == 0)
            #expect(result.observations.count == 120)
            for target in ProbeTarget.defaults {
                let summary = result.summary(for: target.id)
                #expect(summary.completed == 0)
                #expect(summary.missed == 0)
                #expect(summary.missedPercent == nil)
                #expect(summary.median == nil)
                #expect(summary.minimum == nil)
                #expect(summary.maximum == nil)
                #expect(summary.replyTimeChanges == nil)
                #expect(result.observations.filter { $0.targetID == target.id }.allSatisfy {
                    if case .unavailable = $0.outcome { true } else { false }
                })
            }
            #expect(result.gaps.contains { $0.start == 0 && $0.end == 300 })
            #expect(events.stopCount == 1)
        }
    }

    @Test func wallClockJumpsDoNotChangeMonotonicOrderingOrDeadline() async {
        let clock = StabilityTestClock()
        let events = FakeStabilityEventSource()
        clock.onAutomaticSleep = { deadline in
            if deadline == 5 { clock.setWallDate(Date(timeIntervalSince1970: 10)) }
            if deadline == 10 { clock.setWallDate(Date(timeIntervalSince1970: 2_000_000_000)) }
        }
        let subject = session(clock: clock, events: events, probe: { _, _, _ in stabilityReplyOutput() })

        let result = await subject.run()

        #expect(result.status == .completed)
        #expect(result.elapsed == 300)
        #expect(result.observations.count == 120)
        #expect(result.observations.map(\.elapsed) == result.observations.map(\.elapsed).sorted())
        #expect(result.observations[0].timestamp > result.observations[2].timestamp)
    }

    @Test func sleepPastDeadlineClosesCoverageAtDeadlineWithoutInventingReplies() async {
        let clock = StabilityTestClock()
        let events = FakeStabilityEventSource()
        var probeTimes: [Double] = []
        clock.onAutomaticSleep = { deadline in
            guard deadline == 100 else { return }
            events.emit(.sleep)
            clock.jump(to: 420)
            events.emit(.wake)
        }
        let subject = session(clock: clock, events: events, probe: { _, _, _ in
            probeTimes.append(clock.uptime)
            return stabilityReplyOutput(12)
        })

        let result = await subject.run()

        #expect(result.status == .completed)
        #expect(result.elapsed == 300)
        #expect(probeTimes.count == 40)
        #expect(probeTimes.allSatisfy { $0 < 100 })
        #expect(result.gaps.contains(StabilityGap(start: 100, end: 300, reason: .sleep)))
        #expect(result.unobservedDuration == 200)
        #expect(result.observations.filter { $0.slot >= 20 }.allSatisfy {
            if case .unavailable = $0.outcome { true } else { false }
        })
        #expect(result.observations.allSatisfy {
            if case .reply(let milliseconds) = $0.outcome { milliseconds > 0 } else { true }
        })
    }

    @Test func pathRecoveryResumesAtNextSlotWithoutCatchUpBurst() async {
        let clock = StabilityTestClock()
        let events = FakeStabilityEventSource()
        clock.onAutomaticSleep = { deadline in
            if deadline == 5 { events.emit(.path(.unavailable)) }
            if deadline == 10 { events.emit(.path(.satisfied("test-interface-b"))) }
        }
        var starts: [(time: Double, address: String)] = []
        let subject = session(clock: clock, events: events, probe: { _, target, _ in
            starts.append((clock.uptime, target.address))
            return stabilityReplyOutput()
        })

        let result = await subject.run()

        #expect(starts.filter { $0.time == 5 }.isEmpty)
        #expect(starts.filter { $0.time == 10 }.count == 2)
        #expect(starts.filter { $0.time == 10 }.map { $0.address }.sorted() == ProbeTarget.defaults.map(\.address).sorted())
        #expect(result.gaps.contains(StabilityGap(start: 5, end: 10, reason: .pathUnavailable)))
        #expect(result.observations.filter { $0.slot == 1 }.allSatisfy {
            if case .unavailable(let reason) = $0.outcome { reason == StabilityGapReason.pathUnavailable.rawValue } else { false }
        })
        #expect(result.observations.filter { $0.slot == 2 }.allSatisfy { $0.elapsed == 10 })
        #expect(result.summary(for: ProbeTarget.defaults[0].id).replyTimeChanges == 0)
        let aroundGap = result.observations.filter { $0.targetID == ProbeTarget.defaults[0].id && $0.slot <= 2 }
        #expect(StabilitySummary(observations: aroundGap).replyTimeChanges == nil)
    }

    @Test func satisfiedInterfaceSignatureChangeStartsAnEpochWithoutAnOutage() async {
        let clock = StabilityTestClock()
        let events = FakeStabilityEventSource(initialPath: .satisfied("test-interface-a"))
        clock.onAutomaticSleep = { deadline in
            if deadline == 5 { events.emit(.path(.satisfied("test-interface-b"))) }
        }
        let subject = session(clock: clock, events: events, probe: { _, _, _ in stabilityReplyOutput(10) })

        let result = await subject.run()

        #expect(result.transitions.count == 1)
        #expect(result.transitions[0].elapsed == 5)
        #expect(result.transitions[0].epoch == result.observations.first(where: { $0.slot == 1 })?.epoch)
        #expect(result.gaps.isEmpty)
        #expect(result.observations.filter { $0.slot == 1 }.allSatisfy { $0.epoch != result.observations.first?.epoch })
    }

    @Test func controllerPreservesDistinctFailureDetailsAndPartialResultsUnderExclusion() async {
        let clock = StabilityTestClock()
        clock.advancesAutomatically = false
        let events = FakeStabilityEventSource()
        let diagnostics = ConnectionDiagnostics(processOperation: { _, arguments, _ in
            let address = arguments.last ?? "unknown target"
            throw DiagnosticProcessFailure(message: "Probe failed", stderrDetail: "detail for \(address)")
        }, stabilityClock: clock.makeClock(), stabilityEvents: { events })

        diagnostics.startStability()
        await waitForSamples(diagnostics)
        let initialID = diagnostics.stabilitySnapshot?.id
        diagnostics.startLatency()
        diagnostics.startLoad()

        #expect(diagnostics.activity == .stability)
        #expect(diagnostics.stabilitySnapshot?.id == initialID)
        #expect(Set(diagnostics.stabilitySnapshot?.observations.compactMap { observation -> String? in
            guard case .unavailable(let reason) = observation.outcome else { return nil }
            return reason
        } ?? []) == Set([
            "Probe failed detail for 8.8.8.8",
            "Probe failed detail for 1.1.1.1",
        ]))
        #expect(diagnostics.stabilitySnapshot?.summary(for: ProbeTarget.defaults[0].id).completed == 0)
        #expect(diagnostics.stabilitySnapshot?.summary(for: ProbeTarget.defaults[1].id).completed == 0)

        diagnostics.cancel()
        await diagnostics.waitUntilStopped()

        #expect(!diagnostics.isRunning)
        #expect(diagnostics.stabilitySnapshot?.status == .cancelled)
        #expect(diagnostics.stabilitySnapshot?.observations.count == 2)
        #expect(events.stopCount == 1)
    }

    @Test func interruptedTargetPairIsJoinedBeforeResumedSlotsAndLateRepliesAreIgnored() async {
        let clock = StabilityTestClock()
        clock.advancesAutomatically = false
        let events = FakeStabilityEventSource()
        let gate = CancellableProbePairGate()
        var stoppedOperationSets: [Set<UUID>] = []

        let subject = session(clock: clock, events: events,
                              probe: { operationID, _, _ in try await gate.probe(operationID) },
                              stopOperations: { stoppedOperationSets.append($0) })

        let run = Task { await subject.run() }
        for _ in 0..<10_000 where gate.started.count < 2 { await Task.yield() }
        #expect(gate.started.count == 2)

        events.emit(.path(.satisfied("test-interface-b")))
        for _ in 0..<10_000 where gate.cancelled.count < 2 { await Task.yield() }
        #expect(gate.cancelled.count == 2)
        #expect(gate.started.count == 2)
        #expect(stoppedOperationSets == [Set(gate.started)])

        gate.releaseCleanup()
        clock.jump(to: 5)
        for _ in 0..<10_000 where gate.started.count < 4 { await Task.yield() }

        #expect(gate.started.count == 4)
        #expect(Set(gate.completedFirstPair) == Set(gate.started.prefix(2)))

        events.emit(.path(.unavailable))
        subject.cancel()
        clock.jump(to: 10)
        let result = await run.value

        #expect(result.status == .cancelled)
        #expect(result.observations.filter { $0.slot == 0 }.allSatisfy {
            if case .interrupted = $0.outcome { true } else { false }
        })
        #expect(result.observations.filter { $0.slot == 1 }.allSatisfy {
            if case .interrupted = $0.outcome { true } else { false }
        })
        #expect(events.stopCount == 1)
    }

    @Test func sleepDuringAnActivePairDoesNotCreateANetworkChangeGap() async {
        let clock = StabilityTestClock()
        clock.advancesAutomatically = false
        let events = FakeStabilityEventSource()
        let gate = CancellableProbePairGate()
        let subject = session(clock: clock, events: events,
                              probe: { operationID, _, _ in try await gate.probe(operationID) })

        let run = Task { await subject.run() }
        for _ in 0..<10_000 where gate.started.count < 2 { await Task.yield() }
        #expect(gate.started.count == 2)

        events.emit(.sleep)
        for _ in 0..<10_000 where gate.cancelled.count < 2 { await Task.yield() }
        #expect(gate.cancelled.count == 2)
        clock.jump(to: 5)
        events.emit(.wake)
        gate.releaseCleanup()
        for _ in 0..<10_000 where gate.started.count < 4 { await Task.yield() }
        #expect(gate.started.count == 4)

        subject.cancel()
        clock.jump(to: 10)
        let result = await run.value

        #expect(result.gaps.contains(StabilityGap(start: 0, end: 5, reason: .sleep)))
        #expect(!result.gaps.contains { $0.reason == .networkChange })
    }

    @Test func cancellingAnActivePairDoesNotCreateAnOutageGap() async {
        let clock = StabilityTestClock()
        clock.advancesAutomatically = false
        let events = FakeStabilityEventSource()
        let gate = CancellableProbePairGate()
        let subject = session(clock: clock, events: events,
                              probe: { operationID, _, _ in try await gate.probe(operationID) })

        let run = Task { await subject.run() }
        for _ in 0..<10_000 where gate.started.count < 2 { await Task.yield() }
        #expect(gate.started.count == 2)

        subject.cancel()
        for _ in 0..<10_000 where gate.cancelled.count < 2 { await Task.yield() }
        #expect(gate.cancelled.count == 2)
        clock.jump(to: 5)
        gate.releaseCleanup()
        let result = await run.value

        #expect(result.status == .cancelled)
        #expect(!result.gaps.contains { $0.reason == .networkChange })
        #expect(result.gaps.isEmpty)
        #expect(result.observations.allSatisfy {
            if case .interrupted = $0.outcome { true } else { false }
        })
    }
}
