import CoreFoundation
import Foundation

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

    static func parse(_ output: String, exitCode: Int32 = 0, expectedCount: Int? = nil) throws -> ProbeStatistics {
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
        if let expectedCount, sent != expectedCount {
            throw DiagnosticError.invalidOutput("The reply counts do not match. Please try again.")
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
