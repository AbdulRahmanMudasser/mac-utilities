import Foundation

nonisolated enum StabilityCheckLimits {
    static let duration: Double = 300
    static let slotCount = 60
}

nonisolated enum StabilityPathState: Equatable, Sendable {
    case pending, unavailable, satisfied(String)
}

nonisolated enum StabilityEnvironmentEvent: Sendable {
    case path(StabilityPathState), sleep, wake
}

@MainActor
protocol StabilityEventSource: AnyObject {
    func start(_ receive: @escaping @MainActor (StabilityEnvironmentEvent) -> Void)
    func stop()
}

nonisolated enum StabilityOutcome: Equatable, Sendable {
    case reply(Double), noReply, unavailable(String), interrupted(String)

    var description: String {
        switch self {
        case .reply(let value): "\(value.formatted(.number.precision(.fractionLength(1)))) ms"
        case .noReply: "Missed Test Reply"
        case .unavailable(let reason): "No Result · \(reason)"
        case .interrupted(let reason): "Stopped · \(reason)"
        }
    }
    var milliseconds: Double? { if case .reply(let value) = self { value } else { nil } }
}

nonisolated struct StabilityObservation: Identifiable, Equatable, Sendable {
    let sessionID: UUID
    let targetID: String
    let slot: Int
    let elapsed: Double
    let timestamp: Date
    let epoch: Int
    let outcome: StabilityOutcome
    var id: String { "\(sessionID)-\(targetID)-\(slot)" }
}

nonisolated enum StabilityGapReason: String, CaseIterable, Sendable {
    case pendingPath = "Waiting For Network", pathUnavailable = "Network Unavailable"
    case sleep = "Mac Asleep", schedulerDelay = "Sampling Delayed", networkChange = "Network Changed"
}

nonisolated struct StabilityGap: Identifiable, Equatable, Sendable {
    let start: Double
    let end: Double
    let reason: StabilityGapReason
    var id: String { "\(start)-\(end)-\(reason.rawValue)" }

    static func unionDuration(_ gaps: [StabilityGap]) -> Double {
        let ordered = gaps.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var total = 0.0
        var end = 0.0
        for gap in ordered {
            total += max(0, gap.end - max(end, gap.start))
            end = max(end, gap.end)
        }
        return total
    }
}

nonisolated struct StabilityTransition: Identifiable, Equatable, Sendable {
    let elapsed: Double
    let epoch: Int
    var id: Int { epoch }
}

nonisolated struct StabilitySummary: Equatable, Sendable {
    let received: Int
    let missed: Int
    let unobserved: Int
    let interrupted: Int
    let median: Double?
    let minimum: Double?
    let maximum: Double?
    let replyTimeChanges: Double?
    var completed: Int { received + missed }
    var missedPercent: Double? { completed == 0 ? nil : Double(missed) / Double(completed) * 100 }

    init(observations: [StabilityObservation]) {
        let ordered = observations.sorted { $0.slot < $1.slot }
        let samples = ordered.compactMap(\.outcome.milliseconds).sorted()
        received = samples.count
        missed = ordered.filter { $0.outcome == .noReply }.count
        interrupted = ordered.filter { if case .interrupted = $0.outcome { true } else { false } }.count
        unobserved = ordered.count - received - missed - interrupted
        minimum = samples.first
        maximum = samples.last
        let middle = samples.count / 2
        median = samples.isEmpty ? nil : samples.count.isMultiple(of: 2)
            ? (samples[middle - 1] + samples[middle]) / 2 : samples[middle]
        let differences = zip(ordered, ordered.dropFirst()).compactMap { previous, next -> Double? in
            guard next.slot == previous.slot + 1, next.epoch == previous.epoch,
                  let a = previous.outcome.milliseconds, let b = next.outcome.milliseconds else { return nil }
            return abs(b - a)
        }
        replyTimeChanges = differences.isEmpty ? nil : differences.reduce(0, +) / Double(differences.count)
    }
}

nonisolated struct StabilitySnapshot: Equatable, Sendable {
    enum Status: String, Sendable { case running = "Running", completed = "Completed", cancelled = "Cancelled" }
    let id: UUID
    let startedAt: Date
    var elapsed: Double
    var status: Status
    var observations: [StabilityObservation]
    var gaps: [StabilityGap]
    var transitions: [StabilityTransition]
    var unobservedSeconds: Double? = nil
    var detailsLimited = false
    var finishedAt: Date? = nil
    var remaining: Double { max(0, StabilityCheckLimits.duration - elapsed) }
    var unobservedDuration: Double { min(elapsed, unobservedSeconds ?? StabilityGap.unionDuration(gaps)) }
    var availableDuration: Double { max(0, elapsed - unobservedDuration) }
    var hasCompletedChecks: Bool {
        observations.contains { observation in
            switch observation.outcome {
            case .reply, .noReply: true
            case .unavailable, .interrupted: false
            }
        }
    }

    func reasons(for targetID: String) -> [String] {
        Array(Set(observations.compactMap { observation -> String? in
            guard observation.targetID == targetID else { return nil }
            switch observation.outcome {
            case .unavailable(let reason), .interrupted(let reason): return reason
            case .reply, .noReply: return nil
            }
        })).sorted()
    }

    func summary(for targetID: String) -> StabilitySummary {
        StabilitySummary(observations: observations.filter { $0.targetID == targetID })
    }
}
