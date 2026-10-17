import Darwin
import Foundation

struct DiagnosticProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

@MainActor
final class DiagnosticProcessRunner {
    private struct RunningProcess {
        let operationID: UUID
        let process: Process
    }

    private var processes: [UUID: RunningProcess] = [:]
    private let outputLimit = 1_048_576
    var activeProcessIDs: [Int32] {
        processes.values.map(\.process).filter(\.isRunning).map(\.processIdentifier)
    }

    func stopAll() {
        for running in processes.values where running.process.isRunning {
            kill(running.process.processIdentifier, SIGKILL)
        }
    }

    func stop(operationIDs: Set<UUID>) {
        guard !operationIDs.isEmpty else { return }
        for running in processes.values where operationIDs.contains(running.operationID) && running.process.isRunning {
            kill(running.process.processIdentifier, SIGKILL)
        }
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        operationID: UUID = UUID()
    ) async throws -> DiagnosticProcessOutput {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        var process: Process?
        var processIdentifier: UUID?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
                  FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            defer { try? stdout.close() }
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer { try? stderr.close() }
            let child = Process()
            process = child
            let identifier = UUID()
            processIdentifier = identifier
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            child.environment = environment
            child.standardOutput = stdout
            child.standardError = stderr
            try child.run()
            processes[identifier] = RunningProcess(operationID: operationID, process: child)
            let started = ProcessInfo.processInfo.systemUptime
            while child.isRunning {
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
            processes.removeValue(forKey: identifier)
            return DiagnosticProcessOutput(stdout: output, stderr: errors, exitCode: child.terminationStatus)
        } catch {
            if let child = process, child.isRunning {
                kill(child.processIdentifier, SIGKILL)
            }
            if let child = process {
                // Wait asynchronously for the killed child to be reaped before exposing an idle state.
                while child.isRunning {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
                    }
                }
            }
            if let processIdentifier {
                processes.removeValue(forKey: processIdentifier)
            }
            let detail = Self.failureDetail(at: stderrURL)
            if error is CancellationError {
                throw error
            }
            if let failure = error as? DiagnosticProcessFailure {
                throw failure
            }
            throw DiagnosticProcessFailure(message: error.localizedDescription, stderrDetail: detail)
        }
    }

    private static func failureDetail(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 2048)) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
    }
}

struct DiagnosticProcessFailure: LocalizedError {
    let message: String
    let stderrDetail: String?

    var errorDescription: String? {
        message + (stderrDetail.flatMap { $0.isEmpty ? nil : " \($0)" } ?? "")
    }
}
