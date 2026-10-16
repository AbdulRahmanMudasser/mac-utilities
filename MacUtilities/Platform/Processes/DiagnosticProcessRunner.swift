import Darwin
import Foundation

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
