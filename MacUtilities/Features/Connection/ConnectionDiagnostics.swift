import Combine
import Foundation

@MainActor
final class ConnectionDiagnostics: ObservableObject {
    enum Activity: Equatable { case idle, latency, load, stability }
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var lastStartedActivity: Activity = .idle
    #if DEBUG
    @Published private(set) var isStabilityPreview = false
    #endif
    @Published private(set) var isStopping = false
    @Published private(set) var message = "Choose A Check To Start"
    @Published private(set) var probes: [ProbeResult] = []
    @Published private(set) var quality: QualityResult?
    @Published private(set) var qualityNetworkName = "Not Reported"
    @Published private(set) var qualityError: String?
    @Published private(set) var latencyCompletedAt: Date?
    @Published private(set) var qualityCompletedAt: Date?
    @Published private(set) var stabilitySnapshot: StabilitySnapshot?
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private let runner = DiagnosticProcessRunner()
    private let processOperation: ((String, [String], TimeInterval) async throws -> DiagnosticProcessOutput)?
    private let httpsOperation: ((URL) async throws -> HTTPSResult)?
    private let stabilityClock: StabilityClock
    private let stabilityEvents: @MainActor () -> any StabilityEventSource
    private var stabilitySession: StabilityCheckSession?
    private var hasShutDown = false

    init(
        processOperation: ((String, [String], TimeInterval) async throws -> DiagnosticProcessOutput)? = nil,
        httpsOperation: ((URL) async throws -> HTTPSResult)? = nil,
        stabilityClock: StabilityClock? = nil,
        stabilityEvents: @escaping @MainActor () -> any StabilityEventSource = { ConnectionObservationEvents() }
    ) {
        self.processOperation = processOperation
        self.httpsOperation = httpsOperation
        self.stabilityClock = stabilityClock ?? .system()
        self.stabilityEvents = stabilityEvents
    }

    private func runProcess(executable: String, arguments: [String], timeout: TimeInterval) async throws -> DiagnosticProcessOutput {
        if let processOperation { return try await processOperation(executable, arguments, timeout) }
        return try await runner.run(executable: executable, arguments: arguments, timeout: timeout)
    }
    var isRunning: Bool { activity != .idle }
    var activeProcessIDs: [Int32] { runner.activeProcessIDs }

    func cancel() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        task?.cancel()
        stabilitySession?.cancel()
        runner.stopAll()
        message = "Stopping The Check…"
    }

    func shutdown() {
        hasShutDown = true
        if isRunning { isStopping = true }
        task?.cancel()
        stabilitySession?.cancel()
        runner.stopAll()
    }

    func startLatency() {
        guard !hasShutDown, !isRunning else { return }
        lastStartedActivity = .latency
        runID = UUID()
        isStopping = false
        let id = runID
        probes = []
        latencyCompletedAt = nil
        activity = .latency
        message = "Waiting For Replies…"
        task = Task {
            for target in ProbeTarget.defaults {
                guard !Task.isCancelled else { break }
                var statistics: ProbeStatistics?
                var errorMessage: String?
                do {
                    let output = try await runProcess(executable: "/sbin/ping", arguments: ["-n", "-c", "10", "-i", "1", "-W", "1500", "-t", "15", target.address], timeout: 18)
                    do {
                        statistics = try ProbeStatistics.parse(String(decoding: output.stdout, as: UTF8.self), exitCode: output.exitCode, expectedCount: 10)
                    } catch {
                        let detail = String(decoding: output.stderr, as: UTF8.self).split(separator: "\n").first.map(String.init)
                        throw DiagnosticError.toolFailed(error.localizedDescription + (detail.map { " \($0)" } ?? ""))
                    }
                } catch is CancellationError { break }
                catch {
                    errorMessage = error.localizedDescription
                }
                var https: HTTPSResult?
                var httpsError: String?
                if statistics?.received ?? 0 == 0 && !Task.isCancelled {
                    do { https = try await checkHTTPS(target.httpsURL) }
                    catch { httpsError = error.localizedDescription }
                }
                guard id == runID, !Task.isCancelled else { break }
                probes.append(ProbeResult(target: target, statistics: statistics, error: errorMessage, https: https, httpsError: httpsError))
            }
            finish(id: id)
        }
    }

    func startLoad() {
        guard !hasShutDown, !isRunning else { return }
        lastStartedActivity = .load
        isStopping = false
        runID = UUID()
        let id = runID
        quality = nil
        qualityNetworkName = "Not Reported"
        qualityError = nil
        qualityCompletedAt = nil
        activity = .load
        message = "Checking Your Internet While Busy…"
        task = Task {
            do {
                let output = try await runProcess(executable: "/usr/bin/networkQuality", arguments: ["-s", "-c", "-M", "45"], timeout: 60)
                let result = try QualityResult.parse(output.stdout, exitCode: output.exitCode)
                guard id == runID, !Task.isCancelled else { finish(id: id); return }
                quality = result
                qualityNetworkName = NetworkInterfaceLabel.currentDisplayName(result.interfaceName)
            } catch is CancellationError { }
            catch { if id == runID && !Task.isCancelled { qualityError = error.localizedDescription } }
            finish(id: id)
        }
    }

    func startStability() {
        guard !hasShutDown, !isRunning else { return }
        lastStartedActivity = .stability
        #if DEBUG
        isStabilityPreview = false
        #endif
        isStopping = false
        runID = UUID()
        let id = runID
        stabilitySnapshot = nil
        activity = .stability
        message = "Starting The Check…"
        let session = StabilityCheckSession(clock: stabilityClock, events: stabilityEvents(),
            probe: { [self] operationID, target, timeout in
                let arguments = ["-n", "-c", "1", "-i", "1", "-W", "1500", "-t", "2", target.address]
                if let processOperation { return try await processOperation("/sbin/ping", arguments, timeout) }
                return try await runner.run(executable: "/sbin/ping", arguments: arguments, timeout: timeout, operationID: operationID)
            }, stopOperations: { [weak self] ids in self?.runner.stop(operationIDs: ids) },
            update: { [weak self] value in
                guard let self, self.runID == id else { return }
                self.stabilitySnapshot = value
            }, progress: { [weak self] elapsed, remaining in
                guard let self, self.runID == id, self.activity == .stability, !self.isStopping,
                      self.stabilitySnapshot?.status == .running else { return }
                self.message = "\(Self.elapsedText(elapsed)) Elapsed · \(Self.elapsedText(remaining)) Remaining"
            })
        stabilitySession = session
        task = Task { [self] in
            let result = await session.run()
            guard runID == id else { return }
            stabilitySnapshot = result
            stabilitySession = nil
            message = result.status == .cancelled ? "Check Cancelled" : "Check Done"
            activity = .idle
            isStopping = false
            task = nil
        }
    }

    func waitUntilStopped() async {
        if let task { await task.value }
    }

    private static func elapsedText(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    #if DEBUG
    func showStabilityPreview(unobserved: Bool = false,
                              sparse: Bool = false,
                              cancelled: Bool = false,
                              running: Bool = false) {
        guard !hasShutDown, !isRunning else { return }
        lastStartedActivity = .stability
        let id = UUID()
        let finishedAt = Date()
        let elapsed = running || cancelled ? 120.0 : StabilityCheckLimits.duration
        let date = finishedAt.addingTimeInterval(-elapsed)
        probes = ProbeTarget.defaults.enumerated().map { index, target in
            let samples = (0..<10).map { Double(20 + ($0 * 3 + index * 5) % 15) }
            return ProbeResult(target: target,
                statistics: ProbeStatistics(sent: 10, received: 10, samples: samples),
                error: nil, https: nil, httpsError: nil)
        }
        latencyCompletedAt = date
        var readings: [StabilityObservation] = []
        let slotCount = running || cancelled ? 24 : StabilityCheckLimits.slotCount
        for slot in 0..<slotCount {
            for (index, target) in ProbeTarget.defaults.enumerated() {
                let outcome: StabilityOutcome
                if cancelled && slot >= 20 { outcome = .interrupted("User Cancelled") }
                else if unobserved { outcome = .unavailable("Mac Asleep") }
                else if (10..<14).contains(slot) { outcome = .unavailable("Mac Asleep") }
                else if sparse && slot != 2 && slot != 57 { outcome = .unavailable("Sampling Delayed") }
                else if slot == 25 || slot == 26 { outcome = .noReply }
                else { outcome = .reply(Double(18 + (slot * 7 + index * 11) % 34)) }
                readings.append(StabilityObservation(sessionID: id, targetID: target.id, slot: slot,
                    elapsed: Double(slot * 5), timestamp: date.addingTimeInterval(Double(slot * 5)),
                    epoch: slot < 14 ? 0 : slot < 36 ? 1 : 2, outcome: outcome))
            }
        }
        stabilitySnapshot = StabilitySnapshot(id: id, startedAt: date, elapsed: elapsed,
            status: running ? .running : cancelled ? .cancelled : .completed, observations: readings,
            gaps: unobserved ? [StabilityGap(start: 0, end: elapsed, reason: .sleep)]
                : [StabilityGap(start: 50, end: min(70, elapsed), reason: .sleep)],
            transitions: unobserved || running ? [] : [StabilityTransition(elapsed: min(180, elapsed), epoch: 2)])
        isStabilityPreview = true
        message = running ? "Check In Progress…" : cancelled ? "Check Cancelled" : "Check Done"
        stabilitySnapshot?.finishedAt = running ? nil : finishedAt
    }
    #endif

    private func finish(id: UUID) {
        guard id == runID else { return }
        if Task.isCancelled {
            message = "Check Cancelled"
        } else if activity == .load {
            message = qualityError == nil ? "Check Done" : "The Check Could Not Finish"
            qualityCompletedAt = Date()
        } else {
            message = probes.contains(where: { $0.error != nil }) ? "Some Results Are Not Available" : "Check Done"
            latencyCompletedAt = Date()
        }
        activity = .idle
        isStopping = false
        task = nil
    }

    private func checkHTTPS(_ url: URL) async throws -> HTTPSResult {
        if let httpsOperation { return try await httpsOperation(url) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let started = ProcessInfo.processInfo.systemUptime
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DiagnosticError.invalidOutput("The web server did not reply.") }
        return HTTPSResult(elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, statusCode: response.statusCode)
    }
}
