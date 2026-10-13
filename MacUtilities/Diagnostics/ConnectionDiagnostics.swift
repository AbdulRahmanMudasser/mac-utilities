import Combine
import CoreFoundation
import Darwin
import Foundation
import SystemConfiguration

enum NetworkInterfaceLabel {
    static func displayName(_ identifier: String?, names: [String: String]) -> String {
        guard let identifier, !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Not Reported"
        }
        if let name = names[identifier], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return "Network Interface (\(identifier))"
    }

    static func currentDisplayName(_ identifier: String?) -> String {
        var names: [String: String] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            if let identifier = SCNetworkInterfaceGetBSDName(interface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[identifier] = name
            }
        }
        return displayName(identifier, names: names)
    }
}

struct ProbeTarget: Identifiable, Sendable {
    let name: String
    let address: String
    let httpsURL: URL
    var id: String { address }

    static let defaults = [
        ProbeTarget(name: "Google", address: "8.8.8.8", httpsURL: URL(string: "https://dns.google/")!),
        ProbeTarget(name: "Cloudflare", address: "1.1.1.1", httpsURL: URL(string: "https://one.one.one.one/")!)
    ]
}

struct ProbeStatistics: Equatable, Sendable {
    let sent: Int
    let received: Int
    let samples: [Double]
    var lost: Int { sent - received }
    var lossPercent: Double { sent > 0 ? Double(lost) / Double(sent) * 100 : 0 }
    var minimum: Double? { samples.min() }
    var maximum: Double? { samples.max() }
    var median: Double? {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    var jitter: Double? {
        guard samples.count > 1 else { return nil }
        return zip(samples, samples.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / Double(samples.count - 1)
    }

    static func parse(_ output: String, exitCode: Int32 = 0) throws -> ProbeStatistics {
        guard exitCode == 0 || exitCode == 2 else {
            throw DiagnosticError.toolFailed("The reply check could not finish. Error code \(exitCode).")
        }
        let summary = try NSRegularExpression(pattern: "(\\d+) packets transmitted, (\\d+) packets received")
        let ns = output as NSString
        guard let match = summary.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)),
              let sent = Int(ns.substring(with: match.range(at: 1))),
              let received = Int(ns.substring(with: match.range(at: 2))),
              sent > 0, sent <= 10, received >= 0, received <= sent else {
            throw DiagnosticError.invalidOutput("The reply check returned results we could not read. Please try again.")
        }
        guard exitCode != 2 || received == 0 else {
            throw DiagnosticError.invalidOutput("The reply check returned results that do not match. Please try again.")
        }
        let replies = try NSRegularExpression(pattern: "icmp_seq=(\\d+).*?time[=<]([0-9.]+)")
        var seen = Set<Int>()
        let samples = replies.matches(in: output, range: NSRange(location: 0, length: ns.length)).compactMap { reply -> Double? in
            guard let sequence = Int(ns.substring(with: reply.range(at: 1))),
                  !seen.contains(sequence),
                  let value = Double(ns.substring(with: reply.range(at: 2))), value.isFinite, value >= 0 else { return nil }
            seen.insert(sequence)
            return value
        }
        guard samples.count == received else { throw DiagnosticError.invalidOutput("The reply counts do not match. Please try again.") }
        return ProbeStatistics(sent: sent, received: received, samples: samples)
    }
}

struct HTTPSResult: Sendable {
    let elapsedMilliseconds: Double
    let statusCode: Int
}

struct ProbeResult: Identifiable, Sendable {
    let target: ProbeTarget
    let statistics: ProbeStatistics?
    let error: String?
    let https: HTTPSResult?
    let httpsError: String?
    var id: String { target.id }
}

struct QualityResult: Equatable, Sendable {
    let baseline: Double?
    let downloadLatency: Double?
    let uploadLatency: Double?
    let downloadLatencySampleCount: Int?
    let uploadLatencySampleCount: Int?
    let downloadCapacity: Double?
    let uploadCapacity: Double?
    let downloadRPM: Double?
    let uploadRPM: Double?
    let interfaceName: String?

    static func parse(_ data: Data, exitCode: Int32) throws -> QualityResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiagnosticError.invalidOutput("The speed test returned results we could not read. Please try again.")
        }
        if exitCode != 0 || json["error_domain"] != nil || json["error_code"] != nil {
            let code = json["error_code"].map { String(describing: $0) } ?? String(exitCode)
            throw DiagnosticError.toolFailed("The speed test could not finish. Error code \(code). Please try again.")
        }
        func value(_ key: String) throws -> Double? {
            guard let raw = json[key] else { return nil }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else {
                throw DiagnosticError.invalidOutput("Some speed test results could not be read. Please try again.")
            }
            return number.doubleValue
        }
        func latency(_ key: String) throws -> (median: Double?, count: Int?) {
            guard let raw = json[key] else { return (nil, nil) }
            guard let entries = raw as? [Any] else { return (try value(key), nil) }
            let samples = try entries.map { entry -> Double in
                guard let number = entry as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue >= 0 else {
                    throw DiagnosticError.invalidOutput("Some speed test readings could not be read. Please try again.")
                }
                return number.doubleValue
            }.sorted()
            guard !samples.isEmpty else { return (nil, nil) }
            let middle = samples.count / 2
            let median = samples.count.isMultiple(of: 2) ? (samples[middle - 1] + samples[middle]) / 2 : samples[middle]
            return (median, samples.count)
        }
        let download = try latency("lud_foreign_dl_h2_req_resp")
        let upload = try latency("lud_foreign_ul_h2_req_resp")
        let result = try QualityResult(
            baseline: value("base_rtt"),
            downloadLatency: download.median,
            uploadLatency: upload.median,
            downloadLatencySampleCount: download.count,
            uploadLatencySampleCount: upload.count,
            downloadCapacity: value("dl_throughput"), uploadCapacity: value("ul_throughput"),
            downloadRPM: value("dl_responsiveness"), uploadRPM: value("ul_responsiveness"),
            interfaceName: json["interface_name"] as? String
        )
        guard [result.baseline, result.downloadLatency, result.uploadLatency, result.downloadCapacity,
               result.uploadCapacity, result.downloadRPM, result.uploadRPM].contains(where: { $0 != nil }) else {
            throw DiagnosticError.invalidOutput("The speed test did not return any results. Please try again.")
        }
        return result
    }
}

enum DiagnosticError: LocalizedError {
    case invalidOutput(String)
    case toolFailed(String)
    case timeout
    case outputLimit
    var errorDescription: String? {
        switch self {
        case .invalidOutput(let message), .toolFailed(let message): message
        case .timeout: "The test took too long, so we stopped it. Please try again."
        case .outputLimit: "The test returned too much data, so we stopped it. Please try again."
        }
    }
}

struct DiagnosticProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

@MainActor
final class DiagnosticProcessRunner {
    private var processes: [UUID: Process] = [:]
    private let outputLimit = 1_048_576
    private(set) var lastFailureDetail: String?
    var activeProcessIDs: [Int32] { processes.values.filter(\.isRunning).map(\.processIdentifier) }

    func stopAll() {
        for process in processes.values where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> DiagnosticProcessOutput {
        try Task.checkCancellation()
        lastFailureDetail = nil
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }
        let process = Process()
        let identifier = UUID()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            processes.removeValue(forKey: identifier)
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        processes[identifier] = process
        let started = ProcessInfo.processInfo.systemUptime
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime - started < timeout else { throw DiagnosticError.timeout }
                for url in [stdoutURL, stderrURL] {
                    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                    guard size <= outputLimit else { throw DiagnosticError.outputLimit }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            try stdout.close()
            try stderr.close()
            func boundedRead(_ url: URL) throws -> Data {
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= outputLimit else { throw DiagnosticError.outputLimit }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try handle.read(upToCount: outputLimit + 1) ?? Data()
            }
            let output = try boundedRead(stdoutURL)
            let errors = try boundedRead(stderrURL)
            guard output.count <= outputLimit, errors.count <= outputLimit else { throw DiagnosticError.outputLimit }
            return DiagnosticProcessOutput(stdout: output, stderr: errors, exitCode: process.terminationStatus)
        } catch {
            if let handle = try? FileHandle(forReadingFrom: stderrURL) {
                let data = (try? handle.read(upToCount: 2048)) ?? Data()
                lastFailureDetail = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
                try? handle.close()
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            // Wait asynchronously for the killed child to be reaped before exposing an idle state.
            while process.isRunning {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
                }
            }
            throw error
        }
    }
}

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
