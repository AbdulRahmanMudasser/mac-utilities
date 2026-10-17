import Foundation

@MainActor
struct StabilityClock {
    let now: () -> Double
    let date: () -> Date
    let sleepUntil: (Double) async throws -> Void
    var ticksProgress = true
    var waitForDeadline: ((Double) async throws -> Void)? = nil

    static func system() -> StabilityClock {
        let origin = ContinuousClock.now
        let now: () -> Double = {
            let parts = origin.duration(to: .now).components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
        let sleep: (Double) async throws -> Void = { deadline in
            try await Task.sleep(for: .seconds(max(0, deadline - now())), clock: .continuous)
        }
        return StabilityClock(now: now, date: Date.init, sleepUntil: sleep, waitForDeadline: sleep)
    }
}

@MainActor
final class StabilityCheckSession {
    typealias Probe = @MainActor (UUID, ProbeTarget, TimeInterval) async throws -> DiagnosticProcessOutput
    private let clock: StabilityClock
    private let events: any StabilityEventSource
    private let probe: Probe
    private let stopOperations: @MainActor (Set<UUID>) -> Void
    private let update: @MainActor (StabilitySnapshot) -> Void
    private let progress: @MainActor (Double, Double) -> Void
    private var snapshot: StabilitySnapshot?
    private var started = 0.0
    private var epoch = 0
    private var path: StabilityPathState = .pending
    private var sleeping = false
    private var cancelled = false
    private var active = false
    private var openGaps: [StabilityGapReason: Double] = [:]
    private var closedGaps: [StabilityGap] = []
    private var pair: Task<[StabilityOutcome], Never>?
    private var operationIDs: Set<UUID> = []
    private var progressTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var deadlineReached = false
    private var interruptionStarted: Double?
    private var interruptionGapReason: StabilityGapReason?
    private var coverageUpdatedAt = 0.0
    private var unobservedSeconds = 0.0
    private var schedulerWindowStart = 0.0
    private var schedulerWindowCovered = 0.0
    private var detailsLimited = false

    init(clock: StabilityClock? = nil, events: any StabilityEventSource,
         probe: @escaping Probe, stopOperations: @escaping @MainActor (Set<UUID>) -> Void,
         update: @escaping @MainActor (StabilitySnapshot) -> Void,
         progress: @escaping @MainActor (Double, Double) -> Void = { _, _ in }) {
        self.clock = clock ?? .system()
        self.events = events
        self.probe = probe
        self.stopOperations = stopOperations
        self.update = update
        self.progress = progress
    }

    var elapsed: Double { max(0, clock.now() - started) }

    func cancel() {
        guard active else { return }
        cancelled = true
        interrupt(reason: nil)
    }

    func run() async -> StabilitySnapshot {
        precondition(!active && snapshot == nil, "A stability session can only run once")
        active = true
        started = clock.now()
        let deadline = started + StabilityCheckLimits.duration
        snapshot = StabilitySnapshot(id: UUID(), startedAt: clock.date(), elapsed: 0,
            status: .running, observations: [], gaps: [], transitions: [])
        openGaps[.pendingPath] = 0
        events.start { [weak self] event in self?.receive(event) }
        publish()
        if let waitForDeadline = clock.waitForDeadline {
            deadlineTask = Task { [weak self] in
                do { try await waitForDeadline(deadline) } catch { return }
                guard let self, self.active else { return }
                self.deadlineReached = true
                self.interrupt(reason: nil)
            }
        }
        if clock.ticksProgress { progressTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && active {
                progress(min(elapsed, StabilityCheckLimits.duration), max(0, deadline - clock.now()))
                do { try await clock.sleepUntil(clock.now() + 1) } catch { break }
            }
        } }
        var slot = 0
        while slot < StabilityCheckLimits.slotCount && !cancelled && !Task.isCancelled {
            let due = started + Double(slot * 5)
            do { try await clock.sleepUntil(due) } catch { cancelled = true; break }
            guard !cancelled, !Task.isCancelled else { break }
            let now = clock.now()
            advanceCoverage(to: elapsed)
            guard now < deadline else {
                recordSkippedSlots(from: slot, to: StabilityCheckLimits.slotCount, reason: currentUnavailableReason ?? "Sampling Delayed")
                recordSchedulerGap(start: Double(slot * 5), end: StabilityCheckLimits.duration)
                slot = StabilityCheckLimits.slotCount
                break
            }
            // Skip complete missed slots. Never send catch-up bursts after a stall.
            let currentSlot = min(StabilityCheckLimits.slotCount - 1, Int(max(0, now - started) / 5))
            if currentSlot > slot {
                recordSkippedSlots(from: slot, to: currentSlot, reason: currentUnavailableReason ?? "Sampling Delayed")
                recordSchedulerGap(start: Double(slot * 5), end: elapsed)
                epoch += 1
                slot = currentSlot
            } else if now - due >= 0.1 {
                // Ignore ordinary dispatch jitter below the runner's 100 ms
                // observation resolution; genuine sub-slot stalls break continuity.
                recordSchedulerGap(start: Double(slot * 5), end: elapsed)
                epoch += 1
            }
            if let reason = currentUnavailableReason {
                recordSkippedSlots(from: slot, to: slot + 1, reason: reason)
                publish()
                slot += 1
                schedulerWindowStart = Double(slot * 5)
                schedulerWindowCovered = 0
                continue
            }
            let slotEpoch = epoch
            let offset = elapsed
            let timestamp = clock.date()
            let ids = [UUID(), UUID()]
            operationIDs = Set(ids)
            let timeout = min(3, max(0, deadline - now))
            let task = Task { [self] in
                async let first = observe(operationID: ids[0], target: ProbeTarget.defaults[0], timeout: timeout)
                async let second = observe(operationID: ids[1], target: ProbeTarget.defaults[1], timeout: timeout)
                return await [first, second]
            }
            pair = task
            let outcomes = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel() }
            }
            pair = nil
            operationIDs = []
            if clock.now() >= deadline { deadlineReached = true }
            if interruptionStarted != nil {
                advanceCoverage(to: elapsed)
                if let interruptionGapReason {
                    closeGap(interruptionGapReason, at: min(elapsed, StabilityCheckLimits.duration))
                }
                self.interruptionStarted = nil
                interruptionGapReason = nil
            }
            for (index, target) in ProbeTarget.defaults.enumerated() {
                let reason = deadlineReached ? "Time Limit Reached" : cancelled || Task.isCancelled ? "Check Cancelled" : "Network Or Sleep Changed"
                let outcome: StabilityOutcome = slotEpoch == epoch && !cancelled && !Task.isCancelled && !deadlineReached
                    ? outcomes[index] : .interrupted(reason)
                append(target: target.id, slot: slot, offset: offset, timestamp: timestamp, epoch: slotEpoch, outcome: outcome)
            }
            publish()
            slot += 1
            schedulerWindowStart = Double(slot * 5)
            schedulerWindowCovered = 0
        }
        if !cancelled && !Task.isCancelled && clock.now() < deadline {
            do { try await clock.sleepUntil(deadline) } catch { cancelled = true }
        }
        // stop() prevents new events, then join the progress task and any child pair
        // before the controller may make another diagnostic available.
        active = false
        events.stop()
        deadlineTask?.cancel()
        if let deadlineTask { await deadlineTask.value }
        deadlineTask = nil
        progressTask?.cancel()
        if let progressTask { await progressTask.value }
        progressTask = nil
        if let pair {
            pair.cancel()
            stopOperations(operationIDs)
            _ = await pair.value
            self.pair = nil
        }
        operationIDs = []
        snapshot?.status = cancelled || Task.isCancelled ? .cancelled : .completed
        snapshot?.finishedAt = clock.date()
        publish()
        return snapshot!
    }

    private var currentUnavailableReason: String? {
        if sleeping { return StabilityGapReason.sleep.rawValue }
        switch path {
        case .pending: return StabilityGapReason.pendingPath.rawValue
        case .unavailable: return StabilityGapReason.pathUnavailable.rawValue
        case .satisfied: return nil
        }
    }

    private func receive(_ event: StabilityEnvironmentEvent) {
        guard active, let snapshot else { return }
        let offset = min(elapsed, StabilityCheckLimits.duration)
        advanceCoverage(to: offset)
        switch event {
        case .sleep:
            guard !sleeping else { return }
            sleeping = true
            openGaps[.sleep] = offset
            interrupt(reason: .sleep)
        case .wake:
            guard sleeping else { return }
            sleeping = false
            closeGap(.sleep, at: offset)
            if interruptionStarted != nil, interruptionGapReason == nil {
                interruptionGapReason = .schedulerDelay
                openGaps[.schedulerDelay] = offset
            }
            epoch += 1
        case .path(let next):
            guard next != path else { return }
            let previous = path
            path = next
            closeGap(.pendingPath, at: offset)
            closeGap(.pathUnavailable, at: offset)
            switch next {
            case .pending: openGaps[.pendingPath] = offset
            case .unavailable: openGaps[.pathUnavailable] = offset
            case .satisfied:
                if case .satisfied = previous {
                    if snapshot.transitions.count < StabilityCheckLimits.slotCount * 2 {
                        self.snapshot?.transitions.append(StabilityTransition(elapsed: offset, epoch: epoch + 1))
                    } else { detailsLimited = true }
                }
            }
            interrupt(reason: .networkChange)
        }
        publish()
    }

    private func interrupt(reason: StabilityGapReason?) {
        epoch += 1
        if pair != nil, interruptionStarted == nil, let reason {
            let offset = min(elapsed, StabilityCheckLimits.duration)
            advanceCoverage(to: offset)
            interruptionStarted = offset
            if reason != .sleep {
                interruptionGapReason = reason
                openGaps[reason] = offset
            }
        }
        pair?.cancel()
        if !operationIDs.isEmpty { stopOperations(operationIDs) }
    }

    private func observe(operationID: UUID, target: ProbeTarget, timeout: Double) async -> StabilityOutcome {
        do {
            try Task.checkCancellation()
            let output = try await probe(operationID, target, timeout)
            try Task.checkCancellation()
            let result: ProbeStatistics
            do {
                result = try ProbeStatistics.parse(String(decoding: output.stdout, as: UTF8.self),
                    exitCode: output.exitCode, expectedCount: 1)
            } catch {
                let detail = String(decoding: output.stderr, as: UTF8.self).split(separator: "\n").first.map(String.init)
                return .unavailable(error.localizedDescription + (detail.map { " \($0)" } ?? ""))
            }
            if result.received == 0 { return .noReply }
            guard let value = result.samples.first else { return .unavailable("Reply Time Not Reported") }
            return .reply(value)
        } catch is CancellationError {
            return .interrupted("Check Stopped")
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func append(target: String, slot: Int, offset: Double, timestamp: Date, epoch: Int, outcome: StabilityOutcome) {
        guard let snapshot, snapshot.observations.count < StabilityCheckLimits.slotCount * ProbeTarget.defaults.count else { return }
        self.snapshot?.observations.append(StabilityObservation(sessionID: snapshot.id, targetID: target,
            slot: slot, elapsed: offset, timestamp: timestamp, epoch: epoch, outcome: outcome))
    }

    private func recordSkippedSlots(from first: Int, to end: Int, reason: String) {
        guard first < end else { return }
        for slot in first..<end {
            for target in ProbeTarget.defaults {
                append(target: target.id, slot: slot, offset: Double(slot * 5), timestamp: clock.date(), epoch: epoch,
                    outcome: .unavailable(reason))
            }
        }
    }

    private func appendGap(start: Double, end: Double, reason: StabilityGapReason) {
        guard end > start else { return }
        if let last = closedGaps.last, last.reason == reason, start <= last.end {
            closedGaps[closedGaps.count - 1] = StabilityGap(start: last.start, end: max(end, last.end), reason: reason)
        } else {
            if closedGaps.count < StabilityCheckLimits.slotCount * 4 {
                closedGaps.append(StabilityGap(start: start, end: end, reason: reason))
            } else { detailsLimited = true }
        }
    }

    private func advanceCoverage(to offset: Double) {
        let end = min(max(coverageUpdatedAt, offset), StabilityCheckLimits.duration)
        if !openGaps.isEmpty {
            unobservedSeconds += end - coverageUpdatedAt
            schedulerWindowCovered += max(0, end - max(coverageUpdatedAt, schedulerWindowStart))
        }
        coverageUpdatedAt = end
    }

    private func recordSchedulerGap(start: Double, end: Double) {
        // Coverage events have already accounted for any sleep/path overlap.
        unobservedSeconds += max(0, end - start - schedulerWindowCovered)
        appendGap(start: start, end: end, reason: .schedulerDelay)
    }

    private func closeGap(_ reason: StabilityGapReason, at end: Double) {
        if let start = openGaps.removeValue(forKey: reason) { appendGap(start: start, end: end, reason: reason) }
    }

    private func publish() {
        guard var value = snapshot else { return }
        advanceCoverage(to: elapsed)
        value.elapsed = min(elapsed, StabilityCheckLimits.duration)
        value.unobservedSeconds = min(value.elapsed, unobservedSeconds)
        value.detailsLimited = detailsLimited
        value.gaps = closedGaps + openGaps.map { StabilityGap(start: $0.value, end: value.elapsed, reason: $0.key) }
        value.gaps = value.gaps.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        snapshot = value
        update(value)
        progress(value.elapsed, value.remaining)
    }
}
