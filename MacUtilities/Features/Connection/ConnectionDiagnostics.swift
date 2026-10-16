import Combine
import Foundation

@MainActor
final class ConnectionDiagnostics: ObservableObject {
    enum Activity: Equatable { case idle, latency, load }
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var message = "Choose A Check To Start."
    @Published private(set) var probes: [ProbeResult] = []
    @Published private(set) var quality: QualityResult?
    @Published private(set) var qualityNetworkName = "Not Reported"
    @Published private(set) var qualityError: String?
    @Published private(set) var latencyCompletedAt: Date?
    @Published private(set) var qualityCompletedAt: Date?
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private let runner = DiagnosticProcessRunner()
    private let processOperation: ((String, [String], TimeInterval) async throws -> DiagnosticProcessOutput)?
    private let httpsOperation: ((URL) async throws -> HTTPSResult)?

    init(
        processOperation: ((String, [String], TimeInterval) async throws -> DiagnosticProcessOutput)? = nil,
        httpsOperation: ((URL) async throws -> HTTPSResult)? = nil
    ) {
        self.processOperation = processOperation
        self.httpsOperation = httpsOperation
    }

    private func runProcess(executable: String, arguments: [String], timeout: TimeInterval) async throws -> DiagnosticProcessOutput {
        if let processOperation { return try await processOperation(executable, arguments, timeout) }
        return try await runner.run(executable: executable, arguments: arguments, timeout: timeout)
    }
    var isRunning: Bool { activity != .idle }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        runner.stopAll()
        message = "Stopping The Check…"
    }

    func shutdown() {
        task?.cancel()
        runner.stopAll()
    }

    func startLatency() {
        guard !isRunning else { return }
        runID = UUID()
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
                        statistics = try ProbeStatistics.parse(String(decoding: output.stdout, as: UTF8.self), exitCode: output.exitCode)
                    } catch {
                        let detail = String(decoding: output.stderr, as: UTF8.self).split(separator: "\n").first.map(String.init)
                        throw DiagnosticError.toolFailed(error.localizedDescription + (detail.map { " \($0)" } ?? ""))
                    }
                } catch is CancellationError { break }
                catch {
                    errorMessage = error.localizedDescription + (runner.lastFailureDetail.flatMap { $0.isEmpty ? nil : " \($0)" } ?? "")
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
        guard !isRunning else { return }
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

    private func finish(id: UUID) {
        guard id == runID else { return }
        if Task.isCancelled {
            message = "Check Cancelled."
        } else if activity == .load {
            message = qualityError == nil ? "Check Done." : "The Check Could Not Finish."
            qualityCompletedAt = Date()
        } else {
            message = probes.contains(where: { $0.error != nil }) ? "Some Results Are Not Available." : "Check Done."
            latencyCompletedAt = Date()
        }
        activity = .idle
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
