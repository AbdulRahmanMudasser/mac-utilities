import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Synchronization

private enum BenchmarkFailure: Error {
    case invalidArguments
    case invalidPath
    case repositoryPath
    case invalidManifest
    case inputHashMismatch
    case invalidPinnedAsset
    case durationLimitExceeded
    case runtimeUnavailable
    case outputExists
    case outputUnavailable
    case outputWriteFailed

    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .invalidPath: "invalid_path"
        case .repositoryPath: "repository_private_path_refused"
        case .invalidManifest: "manifest_invalid"
        case .inputHashMismatch: "input_hash_mismatch"
        case .invalidPinnedAsset: "pinned_asset_mismatch"
        case .durationLimitExceeded: "benchmark_duration_limit_exceeded"
        case .runtimeUnavailable: "runtime_unavailable"
        case .outputExists: "output_exists"
        case .outputUnavailable: "output_unavailable"
        case .outputWriteFailed: "output_write_failed"
        }
    }
}

private enum SelfTestFailure: Error {
    case manifestSchema
    case resultSchema
    case runSchema
    case audioFile
    case audioRecognizer(String)
    case audioProducer(String)
    case audioResult
    case audioSampleCount
    case audioSampleRate
    case audioSignal
    case audioTiming
    case workloadLimit

    var code: String {
        switch self {
        case .manifestSchema: "self_test_manifest_schema_failed"
        case .resultSchema: "self_test_result_schema_failed"
        case .runSchema: "self_test_run_schema_failed"
        case .audioFile: "self_test_audio_file_failed"
        case .audioRecognizer(let code): "self_test_audio_recognizer_\(code)"
        case .audioProducer(let code): "self_test_audio_producer_\(code)"
        case .audioResult: "self_test_audio_result_failed"
        case .audioSampleCount: "self_test_audio_sample_count_failed"
        case .audioSampleRate: "self_test_audio_sample_rate_failed"
        case .audioSignal: "self_test_audio_signal_failed"
        case .audioTiming: "self_test_audio_timing_failed"
        case .workloadLimit: "self_test_workload_limit_failed"
        }
    }
}

private struct CLIOptions {
    let manifestURL: URL
    let outputURL: URL
    let modelURL: URL
    let vadURL: URL
    let language: TranscriptionLanguage
    let limit: Int?
}

private struct ManifestEntry: Decodable {
    let schemaVersion: Int
    let id: String
    let language: String
    let slice: String
    let audioPath: String
    let reference: String
    let speakerId: String?
    let speechEndSeconds: Double?
    let source: String
    let sourceRevision: String
    let audioSha256: String
}

private struct PreparedEntry {
    let manifest: ManifestEntry
    let audioURL: URL
    let expectedDurationSeconds: Double?
    let preflightErrorCode: String?
}

private struct ResultRow: Encodable {
    let schemaVersion = 1
    let id: String
    let language: String
    let slice: String
    let status: String
    let hypothesis: String
    let durationSeconds: Double
    let firstPartialSeconds: Double?
    let stopToFinalSeconds: Double?
    let speechEndToFinalSeconds: Double?
    let inferenceSeconds: Double
    let inferenceCalls: Int
    let errorCode: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case language
        case slice
        case status
        case hypothesis
        case durationSeconds
        case firstPartialSeconds
        case stopToFinalSeconds
        case speechEndToFinalSeconds
        case inferenceSeconds
        case inferenceCalls
        case errorCode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(language, forKey: .language)
        try container.encode(slice, forKey: .slice)
        try container.encode(status, forKey: .status)
        try container.encode(hypothesis, forKey: .hypothesis)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(firstPartialSeconds, forKey: .firstPartialSeconds)
        try container.encode(stopToFinalSeconds, forKey: .stopToFinalSeconds)
        try container.encode(speechEndToFinalSeconds, forKey: .speechEndToFinalSeconds)
        try container.encode(inferenceSeconds, forKey: .inferenceSeconds)
        try container.encode(inferenceCalls, forKey: .inferenceCalls)
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
    }
}

private struct AssetRecord: Encodable {
    let name: String
    let source: String
    let revision: String
    let fileName: String
    let expectedByteCount: Int64
    let sha256: String
}

private struct DataSourceRecord: Encodable, Hashable {
    let source: String
    let sourceRevision: String
}

private struct RuntimeRecord: Encodable {
    let revision: String
    let sha256: String
}

private struct SourceRecord: Encodable {
    let revision: String
    let sha256: String
    let dirty: Bool
}

private struct RunEnvironmentRecord: Encodable {
    let macOSVersion: String
    let appVersionCandidate: String
    let appBuildCandidate: String
    let appVersionSource: String
    let appVersionScope: String
    let thermalStateStart: Int
    let thermalStateEnd: Int
    let lowPowerMode: Bool
    let powerSource: String
    let displayState: String
    let backgroundWorkload: String
}

private struct RunEnvironmentSnapshot {
    let macOSVersion: String
    let appVersionCandidate: String
    let appBuildCandidate: String
    let thermalStateStart: Int
    let lowPowerMode: Bool

    static func capture() throws -> RunEnvironmentSnapshot {
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        guard let appVersion = ProcessInfo.processInfo.environment["MACUTILITIES_SPEECH_BENCHMARK_APP_VERSION_CANDIDATE"],
              let appBuild = ProcessInfo.processInfo.environment["MACUTILITIES_SPEECH_BENCHMARK_APP_BUILD_CANDIDATE"] else {
            throw BenchmarkFailure.runtimeUnavailable
        }
        return RunEnvironmentSnapshot(
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            appVersionCandidate: appVersion,
            appBuildCandidate: appBuild,
            thermalStateStart: process.thermalState.rawValue,
            lowPowerMode: process.isLowPowerModeEnabled
        )
    }

    func finish() -> RunEnvironmentRecord {
        RunEnvironmentRecord(
            macOSVersion: macOSVersion,
            appVersionCandidate: appVersionCandidate,
            appBuildCandidate: appBuildCandidate,
            appVersionSource: "Configuration/Version.xcconfig",
            appVersionScope: "candidate_not_installed",
            thermalStateStart: thermalStateStart,
            thermalStateEnd: ProcessInfo.processInfo.thermalState.rawValue,
            lowPowerMode: lowPowerMode,
            powerSource: "unknown",
            displayState: "unknown",
            backgroundWorkload: "unknown"
        )
    }
}

private struct RunnerSettings: Encodable {
    let language: String
    let sampleRateHz: Int
    let channelCount: Int
    let sourceDecodeBufferSeconds: Double
    let replayInRealTime: Bool
    let maximumChunkSamples: Int
    let streamBufferCapacity: Int
    let maximumPendingSamples: Int
    let windowSamples: Int
    let inferenceIntervalSamples: Int
    let finalizationLookbackSamples: Int
    let finalizationContextOverlapSamples: Int
    let whisperSampling: String
    let threadCount: Int
    let vadThreadCount: Int
    let translate: Bool
    let noTimestamps: Bool
    let detectLanguage: Bool
    let vad: Bool
    let useGPU: Bool
    let flashAttention: Bool
}

private struct RunRecord: Encodable {
    let schemaVersion = 1
    let status: String
    let errorCode: String?
    let language: String
    let selectedCount: Int
    let totalCount: Int
    let completedCount: Int
    let failedCount: Int
    let selectedIds: [String]?
    let manifestSHA256: String
    let modelSHA256: String
    let vadSHA256: String
    let runtimeRevision: String
    let runtimeSHA256: String
    let sourceRevision: String
    let sourceSHA256: String
    let sourceDirty: Bool
    let dataSources: [DataSourceRecord]
    let model: AssetRecord
    let vad: AssetRecord
    let modelLoadKind: String
    let modelLoadSeconds: Double?
    let streamSettings: RunnerSettings
    let environment: RunEnvironmentRecord

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case status
        case errorCode
        case language
        case selectedCount
        case totalCount
        case completedCount
        case failedCount
        case selectedIds
        case manifestSHA256
        case modelSHA256
        case vadSHA256
        case runtimeRevision
        case runtimeSHA256
        case sourceRevision
        case sourceSHA256
        case sourceDirty
        case dataSources
        case model
        case vad
        case modelLoadKind
        case modelLoadSeconds
        case streamSettings
        case environment
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
        try container.encode(language, forKey: .language)
        try container.encode(selectedCount, forKey: .selectedCount)
        try container.encode(totalCount, forKey: .totalCount)
        try container.encode(completedCount, forKey: .completedCount)
        try container.encode(failedCount, forKey: .failedCount)
        try container.encodeIfPresent(selectedIds, forKey: .selectedIds)
        try container.encode(manifestSHA256, forKey: .manifestSHA256)
        try container.encode(modelSHA256, forKey: .modelSHA256)
        try container.encode(vadSHA256, forKey: .vadSHA256)
        try container.encode(runtimeRevision, forKey: .runtimeRevision)
        try container.encode(runtimeSHA256, forKey: .runtimeSHA256)
        try container.encode(sourceRevision, forKey: .sourceRevision)
        try container.encode(sourceSHA256, forKey: .sourceSHA256)
        try container.encode(sourceDirty, forKey: .sourceDirty)
        try container.encode(dataSources, forKey: .dataSources)
        try container.encode(model, forKey: .model)
        try container.encode(vad, forKey: .vad)
        try container.encode(modelLoadKind, forKey: .modelLoadKind)
        try container.encode(modelLoadSeconds, forKey: .modelLoadSeconds)
        try container.encode(streamSettings, forKey: .streamSettings)
        try container.encode(environment, forKey: .environment)
    }
}

private struct NativeRunSummary {
    let modelLoadSeconds: Double
    let modelLoadFailed: Bool
    let completedCount: Int
    let failedCount: Int
}

nonisolated private struct InferenceStatistics: Sendable {
    var seconds = 0.0
    var calls = 0
}

nonisolated private final class TimedInference: StreamingTranscriptionInferring, @unchecked Sendable {
    private let base: any StreamingTranscriptionInferring
    private let statistics = Mutex(InferenceStatistics())

    init(base: any StreamingTranscriptionInferring) {
        self.base = base
    }

    func transcribe(
        samples: [Float],
        sampleRate: Double,
        language: WhisperInferenceLanguage
    ) async throws -> WhisperInferenceResult {
        let clock = ContinuousClock()
        let started = clock.now
        let awakeClock = SuspendingClock()
        let awakeStarted = awakeClock.now
        let call = statistics.withLock {
            $0.calls += 1
            return $0.calls
        }
        defer {
            let elapsed = SpeechBenchmark.seconds(from: started, to: clock.now) ?? 0
            let awakeElapsed = SpeechBenchmark.seconds(awakeStarted.duration(to: awakeClock.now)) ?? 0
            statistics.withLock { $0.seconds += elapsed }
            let diagnostic = "inference_call=\(call) input_samples=\(samples.count) elapsed_seconds=\(elapsed) awake_seconds=\(awakeElapsed)\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
        return try await base.transcribe(samples: samples, sampleRate: sampleRate, language: language)
    }

    func snapshot() -> InferenceStatistics {
        statistics.withLock { $0 }
    }
}

private enum AudioReplayFailure: Error {
    case openFailed
    case unsupportedFormat
    case conversionFailed
    case streamOverflow
    case timingInterrupted
    case sampleIndexOverflow
}

private enum ReplayTiming {
    static let maximumLateness: Duration = .milliseconds(250)

    static func validate(deadline: ContinuousClock.Instant, now: ContinuousClock.Instant) throws {
        guard deadline.duration(to: now) <= maximumLateness else {
            throw AudioReplayFailure.timingInterrupted
        }
    }
}

@MainActor
private final class ReplayState {
    var playbackStart: ContinuousClock.Instant?
    var endOfFile: ContinuousClock.Instant?
    var firstPartialAt: ContinuousClock.Instant?
    var sampleCount: UInt64 = 0
}

@MainActor
private final class PrivateOutput {
    let directoryURL: URL
    private let resultsHandle: FileHandle

    init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        let path = directoryURL.path
        guard path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else {
            throw BenchmarkFailure.outputExists
        }
        guard chmod(path, mode_t(0o700)) == 0 else {
            throw BenchmarkFailure.outputUnavailable
        }
        let resultsURL = directoryURL.appendingPathComponent("results.jsonl", isDirectory: false)
        let descriptor = try Self.createPrivateFile(at: resultsURL)
        resultsHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    var diagnosticsURL: URL {
        directoryURL.appendingPathComponent("diagnostics.log", isDirectory: false)
    }

    func write(_ row: ResultRow) throws {
        do {
            var data = try Self.encoder().encode(row)
            data.append(0x0A)
            try resultsHandle.write(contentsOf: data)
        } catch {
            throw BenchmarkFailure.outputWriteFailed
        }
    }

    func write(_ record: RunRecord) throws {
        let url = directoryURL.appendingPathComponent("run.json", isDirectory: false)
        do {
            let descriptor = try Self.createPrivateFile(at: url)
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var data = try Self.encoder().encode(record)
            data.append(0x0A)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            throw BenchmarkFailure.outputWriteFailed
        }
    }

    func finishResults() throws {
        do {
            try resultsHandle.synchronize()
        } catch {
            throw BenchmarkFailure.outputWriteFailed
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func createPrivateFile(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw BenchmarkFailure.outputUnavailable }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            close(descriptor)
            throw BenchmarkFailure.outputUnavailable
        }
        return descriptor
    }
}

@MainActor
private final class NativeDiagnosticsCapture {
    private let savedStderr: Int32
    private var isRestored = false

    init(logURL: URL) throws {
        let descriptor = logURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw BenchmarkFailure.outputUnavailable }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            close(descriptor)
            throw BenchmarkFailure.outputUnavailable
        }
        let original = dup(STDERR_FILENO)
        guard original >= 0, dup2(descriptor, STDERR_FILENO) >= 0 else {
            if original >= 0 { close(original) }
            close(descriptor)
            throw BenchmarkFailure.outputUnavailable
        }
        close(descriptor)
        savedStderr = original
    }

    func restore() {
        guard !isRestored else { return }
        fflush(stderr)
        _ = dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)
        isRestored = true
    }

}

@MainActor
@main
private struct SpeechBenchmark {
    private static let sampleRate = 16_000
    private static let maximumSourceRate = 384_000.0
    private static let minimumSourceRate = 8_000.0
    private static let sourceReadDuration = 0.25
    private static let streamBufferCapacity = 8
    private static let maximumManifestBytes = 64 * 1_024 * 1_024
    private static let maximumManifestRows = 100_000
    private static let maximumManifestLineBytes = 4 * 1_024 * 1_024
    private static let maximumReferenceBytes = 1 * 1_024 * 1_024
    private static let maximumAudioDurationSeconds = 90.0 * 60.0

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--self-test"] {
                try await selfTest()
                print("self_test=passed")
                return
            }

            let options = try parse(arguments)
            try await run(options)
        } catch let failure as BenchmarkFailure {
            reportError(failure.code)
        } catch let failure as SelfTestFailure {
            reportError(failure.code)
        } catch {
            reportError("benchmark_failed")
        }
    }

    private static func parse(_ arguments: [String]) throws -> CLIOptions {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard ["--manifest", "--output", "--model", "--vad", "--language", "--limit"].contains(key),
                  index + 1 < arguments.count,
                  values[key] == nil else {
                throw BenchmarkFailure.invalidArguments
            }
            values[key] = arguments[index + 1]
            index += 2
        }

        guard let manifest = values["--manifest"],
              let output = values["--output"],
              let model = values["--model"],
              let vad = values["--vad"],
              let languageRaw = values["--language"],
              let language = TranscriptionLanguage(rawValue: languageRaw) else {
            throw BenchmarkFailure.invalidArguments
        }
        let limit: Int?
        if let rawLimit = values["--limit"] {
            guard let parsedLimit = Int(rawLimit), parsedLimit > 0 else {
                throw BenchmarkFailure.invalidArguments
            }
            limit = parsedLimit
        } else {
            limit = nil
        }

        return CLIOptions(
            manifestURL: try existingExternalFileURL(manifest),
            outputURL: try canonicalNewDirectoryURL(
                newExternalDirectoryURL(output).path,
                repositoryRoot: environmentPath("MACUTILITIES_SPEECH_BENCHMARK_REPOSITORY_ROOT")
            ),
            modelURL: try existingExternalFileURL(model),
            vadURL: try existingExternalFileURL(vad),
            language: language,
            limit: limit
        )
    }

    private static func run(_ options: CLIOptions) async throws {
        let manifestData = try readBoundedManifest(at: options.manifestURL)
        let manifestHash = sha256(manifestData)
        let allEntries = try decodeManifest(manifestData, language: options.language)
        let validatedEntries = try allEntries.map { entry in
            (entry, try existingExternalFileURL(entry.audioPath, requireAudioExtension: true, requirePrivate: true))
        }
        let selectedEntries = Array(validatedEntries.prefix(options.limit ?? validatedEntries.count))
        let selectedManifests = selectedEntries.map(\.0)
        guard !selectedManifests.isEmpty else { throw BenchmarkFailure.invalidManifest }

        let modelMetadata = options.language == .english ? SpeechModelMetadata.pinnedEnglish : .pinnedUrdu
        let vadMetadata = SpeechModelMetadata.pinnedVAD
        try verifyPinnedFile(options.modelURL, metadata: modelMetadata)
        try verifyPinnedFile(options.vadURL, metadata: vadMetadata)
        let repositoryRoot = try environmentPath("MACUTILITIES_SPEECH_BENCHMARK_REPOSITORY_ROOT")
        let outputURL = try canonicalNewDirectoryURL(options.outputURL.path, repositoryRoot: repositoryRoot)
        let runtime = try runtimeRecord()
        let source = try sourceRecord()

        var prepared: [PreparedEntry] = []
        prepared.reserveCapacity(selectedManifests.count)
        for (manifest, audioURL) in selectedEntries {
            do {
                prepared.append(try prepare(manifest, audioURL: audioURL))
            } catch {
                prepared.append(PreparedEntry(
                    manifest: manifest,
                    audioURL: audioURL,
                    expectedDurationSeconds: nil,
                    preflightErrorCode: failureCode(error)
                ))
            }
        }
        let selectedAudioDuration = prepared.compactMap(\.expectedDurationSeconds).reduce(0.0, +)
        try validateRunDuration(selectedAudioDuration)

        let output = try PrivateOutput(directoryURL: outputURL)
        let diagnostics = try NativeDiagnosticsCapture(logURL: output.diagnosticsURL)
        defer { diagnostics.restore() }

        let settings = runnerSettings(language: options.language)
        let dataSources = Array(Set(prepared.map {
            DataSourceRecord(source: $0.manifest.source, sourceRevision: $0.manifest.sourceRevision)
        })).sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.sourceRevision < $1.sourceRevision
        }

        let environmentStart = try RunEnvironmentSnapshot.capture()
        let summary = try await executeNativeRun(prepared, options: options, output: output)
        let environment = environmentStart.finish()
        diagnostics.restore()
        try output.finishResults()
        try output.write(runRecord(
            status: summary.modelLoadFailed ? "failed" : (summary.failedCount == 0 ? "ok" : "completed_with_failures"),
            errorCode: summary.modelLoadFailed ? "model_load_failed" : nil,
            prepared: prepared,
            totalCount: allEntries.count,
            completedCount: summary.completedCount,
            failedCount: summary.failedCount,
            options: options,
            manifestHash: manifestHash,
            model: modelMetadata,
            vad: vadMetadata,
            source: source,
            runtime: runtime,
            dataSources: dataSources,
            loadSeconds: summary.modelLoadSeconds,
            settings: settings,
            environment: environment
        ))
        if summary.modelLoadFailed {
            reportError("model_load_failed")
        }
        print("completed selected=\(prepared.count) failed=\(summary.failedCount)")
    }

    private static func executeNativeRun(
        _ prepared: [PreparedEntry],
        options: CLIOptions,
        output: PrivateOutput
    ) async throws -> NativeRunSummary {
        let clock = ContinuousClock()
        let loadStart = clock.now
        let inference: WhisperInference
        do {
            inference = try WhisperInference(verifiedModelURL: options.modelURL, vadModelURL: options.vadURL)
        } catch {
            let loadSeconds = seconds(from: loadStart, to: clock.now) ?? 0
            for entry in prepared {
                try output.write(failedRow(
                    entry,
                    duration: entry.expectedDurationSeconds ?? 0,
                    code: entry.preflightErrorCode ?? "model_load_failed"
                ))
            }
            return NativeRunSummary(
                modelLoadSeconds: loadSeconds,
                modelLoadFailed: true,
                completedCount: 0,
                failedCount: prepared.count
            )
        }

        let loadSeconds = seconds(from: loadStart, to: clock.now) ?? 0
        let timedInference = TimedInference(base: inference)
        let recognizer = try StreamingTranscriptionRecognizer(inference: timedInference)
        var failedCount = 0
        for entry in prepared {
            let row = await runEntry(entry, language: options.language, recognizer: recognizer, inference: timedInference)
            if row.status != "ok" { failedCount += 1 }
            try output.write(row)
        }

        return NativeRunSummary(
            modelLoadSeconds: loadSeconds,
            modelLoadFailed: false,
            completedCount: prepared.count - failedCount,
            failedCount: failedCount
        )
    }

    private static func runEntry(
        _ entry: PreparedEntry,
        language: TranscriptionLanguage,
        recognizer: StreamingTranscriptionRecognizer,
        inference: TimedInference
    ) async -> ResultRow {
        let before = inference.snapshot()
        if let code = entry.preflightErrorCode {
            return failedRow(entry, duration: entry.expectedDurationSeconds ?? 0, code: code, statistics: difference(inference.snapshot(), before))
        }

        let generation = UUID()
        let (stream, continuation) = AudioCaptureStream.makeStream(
            bufferingPolicy: .bufferingOldest(streamBufferCapacity)
        )
        let replayState = ReplayState()
        let clock = ContinuousClock()
        let producer = Task { @MainActor in
            do {
                try await replay(entry.audioURL, continuation: continuation, state: replayState)
                continuation.finish()
                replayState.endOfFile = clock.now
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }

        let (completionStream, completionContinuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let producerMonitor = Task { @MainActor in
            _ = await producer.result
            _ = completionContinuation.yield(0)
        }
        let recognition = Task { @MainActor in
            try await recognizer.transcribe(
                audio: stream,
                language: language,
                generation: generation
            ) { event in
                if case .provisional = event, replayState.firstPartialAt == nil {
                    replayState.firstPartialAt = clock.now
                }
            }
        }
        let recognitionMonitor = Task { @MainActor in
            _ = await recognition.result
            _ = completionContinuation.yield(1)
        }

        var firstCompletion: Int?
        for await completion in completionStream {
            firstCompletion = completion
            break
        }

        if firstCompletion == 0, case .failure(let producerError) = await producer.result {
            await recognizer.cancel(generation: generation)
            recognition.cancel()
            _ = await recognition.result
            await producerMonitor.value
            await recognitionMonitor.value
            completionContinuation.finish()
            let statistics = difference(inference.snapshot(), before)
            return failedRow(
                entry,
                duration: entry.expectedDurationSeconds ?? Double(replayState.sampleCount) / Double(sampleRate),
                code: failureCode(producerError),
                statistics: statistics
            )
        }

        do {
            let result = try await recognition.value
            let finalAt = clock.now
            try await producer.value
            await producerMonitor.value
            await recognitionMonitor.value
            completionContinuation.finish()
            let statistics = difference(inference.snapshot(), before)
            let stopLatency = replayState.endOfFile.flatMap { seconds(from: $0, to: finalAt) }
            let endpointLatency = speechEndLatency(
                playbackStart: replayState.playbackStart,
                speechEndSeconds: entry.manifest.speechEndSeconds,
                finalAt: finalAt
            )
            return ResultRow(
                id: entry.manifest.id,
                language: entry.manifest.language,
                slice: entry.manifest.slice,
                status: "ok",
                hypothesis: result.text,
                durationSeconds: Double(replayState.sampleCount) / Double(sampleRate),
                firstPartialSeconds: replayState.firstPartialAt.flatMap { partialAt in
                    replayState.playbackStart.flatMap { seconds(from: $0, to: partialAt) }
                },
                stopToFinalSeconds: stopLatency,
                speechEndToFinalSeconds: endpointLatency,
                inferenceSeconds: statistics.seconds,
                inferenceCalls: statistics.calls,
                errorCode: nil
            )
        } catch {
            producer.cancel()
            continuation.finish(throwing: CancellationError())
            await recognizer.cancel(generation: generation)
            recognition.cancel()
            _ = await recognition.result
            _ = try? await producer.value
            await producerMonitor.value
            await recognitionMonitor.value
            completionContinuation.finish()
            let statistics = difference(inference.snapshot(), before)
            return failedRow(
                entry,
                duration: entry.expectedDurationSeconds ?? Double(replayState.sampleCount) / Double(sampleRate),
                code: failureCode(error),
                statistics: statistics
            )
        }
    }

    private static func replay(
        _ url: URL,
        continuation: AudioCaptureStream.Continuation,
        state: ReplayState
    ) async throws {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw AudioReplayFailure.openFailed
        }
        let inputFormat = audioFile.processingFormat
        guard inputFormat.sampleRate.isFinite,
              (minimumSourceRate...maximumSourceRate).contains(inputFormat.sampleRate),
              inputFormat.channelCount > 0,
              inputFormat.channelCount <= 8,
              inputFormat.commonFormat != .otherFormat,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioReplayFailure.unsupportedFormat
        }
        converter.downmix = true

        let inputFrameCount = AVAudioFrameCount(max(1, floor(inputFormat.sampleRate * sourceReadDuration)))
        let totalSourceFrames = audioFile.length
        guard totalSourceFrames > 0 else { throw AudioReplayFailure.unsupportedFormat }
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputFrameCount) * Double(sampleRate) / inputFormat.sampleRate) + 2_048)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw AudioReplayFailure.conversionFailed
        }

        let clock = ContinuousClock()
        state.playbackStart = clock.now
        var readSourceFrames: Int64 = 0
        while readSourceFrames < totalSourceFrames {
            try Task.checkCancellation()
            let remainingFrames = totalSourceFrames - readSourceFrames
            let requestFrameCount = AVAudioFrameCount(min(Int64(inputFrameCount), remainingFrames))
            do {
                try audioFile.read(into: inputBuffer, frameCount: requestFrameCount)
            } catch {
                throw AudioReplayFailure.openFailed
            }
            guard inputBuffer.frameLength > 0 else { throw AudioReplayFailure.openFailed }
            readSourceFrames += Int64(inputBuffer.frameLength)
            try convert(inputBuffer, with: converter, into: outputBuffer)
            if outputBuffer.frameLength > 0 {
                try await enqueue(outputBuffer, continuation: continuation, state: state, clock: clock)
            }
        }

        try Task.checkCancellation()
        while true {
            try Task.checkCancellation()
            let status = try flush(converter, into: outputBuffer)
            if outputBuffer.frameLength > 0 {
                try await enqueue(outputBuffer, continuation: continuation, state: state, clock: clock)
            }
            if status == .endOfStream { break }
            guard status == .haveData, outputBuffer.frameLength > 0 else {
                throw AudioReplayFailure.conversionFailed
            }
        }
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        into output: AVAudioPCMBuffer
    ) throws {
        output.frameLength = 0
        var offeredInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !offeredInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            offeredInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil, status == .haveData || status == .inputRanDry else {
            throw AudioReplayFailure.conversionFailed
        }
    }

    private static func flush(
        _ converter: AVAudioConverter,
        into output: AVAudioPCMBuffer
    ) throws -> AVAudioConverterOutputStatus {
        output.frameLength = 0
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard conversionError == nil, status != .error else { throw AudioReplayFailure.conversionFailed }
        return status
    }

    private static func enqueue(
        _ buffer: AVAudioPCMBuffer,
        continuation: AudioCaptureStream.Continuation,
        state: ReplayState,
        clock: ContinuousClock
    ) async throws {
        guard let samples = buffer.floatChannelData?.pointee else {
            throw AudioReplayFailure.conversionFailed
        }
        var offset = 0
        let total = Int(buffer.frameLength)
        while offset < total {
            try Task.checkCancellation()
            let count = min(StreamingTranscriptionLimits.maximumChunkSampleCount, total - offset)
            let (endSample, overflow) = state.sampleCount.addingReportingOverflow(UInt64(count))
            guard !overflow else { throw AudioReplayFailure.sampleIndexOverflow }
            guard let playbackStart = state.playbackStart else { throw AudioReplayFailure.conversionFailed }
            let offsetSeconds = Double(endSample) / Double(sampleRate)
            let deadline = playbackStart.advanced(by: .nanoseconds(Int64(offsetSeconds * 1_000_000_000)))
            try await clock.sleep(until: deadline, tolerance: .milliseconds(3))
            try Task.checkCancellation()
            try ReplayTiming.validate(deadline: deadline, now: clock.now)

            let chunk = AudioCaptureChunk(
                startingSampleIndex: state.sampleCount,
                sampleRate: Double(sampleRate),
                samples: Array(UnsafeBufferPointer(start: samples + offset, count: count))
            )
            switch continuation.yield(chunk) {
            case .enqueued:
                state.sampleCount = endSample
            case .dropped:
                throw AudioReplayFailure.streamOverflow
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw AudioReplayFailure.streamOverflow
            }
            offset += count
        }
    }

    private static func prepare(_ entry: ManifestEntry, audioURL: URL) throws -> PreparedEntry {
        let expectedHash = entry.audioSha256
        let actualHash = try? hashFile(at: audioURL)
        let hashFailure = actualHash != expectedHash ? "audio_hash_mismatch" : nil

        let duration: Double?
        do {
            let audioFile = try AVAudioFile(forReading: audioURL)
            let format = audioFile.processingFormat
            guard format.sampleRate.isFinite,
                  (minimumSourceRate...maximumSourceRate).contains(format.sampleRate),
                  format.channelCount > 0,
                  format.channelCount <= 8,
                  audioFile.length > 0 else {
                return PreparedEntry(
                    manifest: entry,
                    audioURL: audioURL,
                    expectedDurationSeconds: nil,
                    preflightErrorCode: hashFailure ?? "audio_decode_failed"
                )
            }
            let seconds = Double(audioFile.length) / format.sampleRate
            guard seconds.isFinite, seconds > 0 else {
                return PreparedEntry(
                    manifest: entry,
                    audioURL: audioURL,
                    expectedDurationSeconds: nil,
                    preflightErrorCode: hashFailure ?? "audio_decode_failed"
                )
            }
            if let speechEnd = entry.speechEndSeconds, speechEnd > seconds + 1.0 / Double(sampleRate) {
                return PreparedEntry(
                    manifest: entry,
                    audioURL: audioURL,
                    expectedDurationSeconds: seconds,
                    preflightErrorCode: hashFailure ?? "manifest_invalid"
                )
            }
            duration = seconds
        } catch let failure as BenchmarkFailure {
            throw failure
        } catch {
            return PreparedEntry(
                manifest: entry,
                audioURL: audioURL,
                expectedDurationSeconds: nil,
                preflightErrorCode: hashFailure ?? "audio_decode_failed"
            )
        }

        return PreparedEntry(
            manifest: entry,
            audioURL: audioURL,
            expectedDurationSeconds: duration,
            preflightErrorCode: hashFailure
        )
    }

    private static func decodeManifest(_ data: Data, language: TranscriptionLanguage) throws -> [ManifestEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw BenchmarkFailure.invalidManifest }
        var entries: [ManifestEntry] = []
        var identifiers = Set<String>()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for (index, lineSlice) in lines.enumerated() {
            var line = String(lineSlice)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty {
                if index == lines.count - 1 { continue }
                throw BenchmarkFailure.invalidManifest
            }
            guard line.utf8.count <= maximumManifestLineBytes,
                  entries.count < maximumManifestRows,
                  let entry = try? decoder.decode(ManifestEntry.self, from: Data(line.utf8)),
                  entry.schemaVersion == 1,
                  !entry.id.isEmpty,
                  entry.id.utf8.count <= 256,
                  identifiers.insert(entry.id).inserted,
                  entry.language == language.rawValue,
                  !entry.slice.isEmpty,
                  entry.slice.utf8.count <= 256,
                  !entry.source.isEmpty,
                  !entry.sourceRevision.isEmpty,
                  entry.reference.utf8.count <= maximumReferenceBytes,
                  entry.audioSha256.utf8.count == 64,
                  entry.audioSha256.utf8.allSatisfy(isLowerHex),
                  entry.audioPath.hasPrefix("/"),
                  !entry.audioPath.utf8.contains(0),
                  entry.speechEndSeconds.map({ $0.isFinite && $0 > 0 && $0 < Double(Int64.max) / 1_000_000_000 }) ?? true,
                  entry.speakerId.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else {
                throw BenchmarkFailure.invalidManifest
            }
            entries.append(entry)
        }
        guard !entries.isEmpty else { throw BenchmarkFailure.invalidManifest }
        return entries
    }

    private static func readBoundedManifest(at url: URL) throws -> Data {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o077) == 0,
              info.st_size > 0,
              info.st_size <= maximumManifestBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= maximumManifestBytes else {
            throw BenchmarkFailure.invalidManifest
        }
        return data
    }

    private static func verifyPinnedFile(_ url: URL, metadata: SpeechModelMetadata) throws {
        var info = stat()
        guard metadata.isWellFormed,
              url.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == metadata.expectedByteCount,
              (try? hashFile(at: url)) == metadata.sha256 else {
            throw BenchmarkFailure.inputHashMismatch
        }
    }

    private static func existingExternalFileURL(
        _ path: String,
        requireAudioExtension: Bool = false,
        requirePrivate: Bool = false
    ) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw BenchmarkFailure.invalidPath }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        var info = stat()
        guard standardizedPath.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (!requirePrivate || (info.st_mode & 0o077) == 0),
              let canonicalPath = resolvedPath(standardizedPath) else {
            throw BenchmarkFailure.invalidPath
        }
        let root = try environmentPath("MACUTILITIES_SPEECH_BENCHMARK_REPOSITORY_ROOT")
        guard !isWithin(canonicalPath, root: root) else { throw BenchmarkFailure.repositoryPath }
        let url = URL(fileURLWithPath: canonicalPath, isDirectory: false)
        if requireAudioExtension && !["wav", "flac"].contains(url.pathExtension.lowercased()) {
            throw BenchmarkFailure.invalidManifest
        }
        return url
    }

    private static func newExternalDirectoryURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw BenchmarkFailure.invalidPath }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        guard standardized.path != "/", standardized.lastPathComponent != ".", standardized.lastPathComponent != ".." else {
            throw BenchmarkFailure.invalidPath
        }
        return standardized
    }

    private static func canonicalNewDirectoryURL(_ path: String, repositoryRoot: String) throws -> URL {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        let parentPath = standardized.deletingLastPathComponent().path
        var parentInfo = stat()
        guard parentPath.withCString({ stat($0, &parentInfo) }) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              let canonicalParent = resolvedPath(parentPath) else {
            throw BenchmarkFailure.outputUnavailable
        }
        let destination = URL(fileURLWithPath: canonicalParent, isDirectory: true)
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
        guard !isWithin(destination.path, root: repositoryRoot) else { throw BenchmarkFailure.repositoryPath }
        var existingInfo = stat()
        guard destination.path.withCString({ lstat($0, &existingInfo) }) != 0, errno == ENOENT else {
            throw BenchmarkFailure.outputExists
        }
        return destination
    }

    private static func runtimeRecord() throws -> RuntimeRecord {
        guard let frameworkPath = ProcessInfo.processInfo.environment["MACUTILITIES_SPEECH_BENCHMARK_FRAMEWORK"],
              let bundle = Bundle(path: frameworkPath),
              let revision = bundle.object(forInfoDictionaryKey: "WhisperSourceRevision") as? String,
              !revision.isEmpty,
              let executableURL = bundle.executableURL else {
            throw BenchmarkFailure.runtimeUnavailable
        }
        return RuntimeRecord(revision: revision, sha256: try hashFile(at: executableURL))
    }

    private static func sourceRecord() throws -> SourceRecord {
        guard let revision = ProcessInfo.processInfo.environment["MACUTILITIES_SPEECH_BENCHMARK_SOURCE_REVISION"],
              let digest = ProcessInfo.processInfo.environment["MACUTILITIES_SPEECH_BENCHMARK_SOURCE_SHA256"],
              let dirtyRaw = ProcessInfo.processInfo.environment["MACUTILITIES_SPEECH_BENCHMARK_SOURCE_DIRTY"],
              let dirty = Bool(dirtyRaw),
              digest.utf8.count == 64,
              digest.utf8.allSatisfy(isLowerHex) else {
            throw BenchmarkFailure.runtimeUnavailable
        }
        return SourceRecord(revision: revision, sha256: digest, dirty: dirty)
    }

    private static func runnerSettings(language: TranscriptionLanguage) -> RunnerSettings {
        let threads = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
        return RunnerSettings(
            language: language.rawValue,
            sampleRateHz: sampleRate,
            channelCount: 1,
            sourceDecodeBufferSeconds: sourceReadDuration,
            replayInRealTime: true,
            maximumChunkSamples: StreamingTranscriptionLimits.maximumChunkSampleCount,
            streamBufferCapacity: streamBufferCapacity,
            maximumPendingSamples: StreamingTranscriptionLimits.maximumPendingSampleCount,
            windowSamples: StreamingTranscriptionLimits.maximumWindowSampleCount,
            inferenceIntervalSamples: StreamingTranscriptionLimits.inferenceIntervalSampleCount,
            finalizationLookbackSamples: StreamingTranscriptionLimits.finalizationLookbackSampleCount,
            finalizationContextOverlapSamples: StreamingTranscriptionLimits.finalizationContextOverlapSampleCount,
            whisperSampling: "greedy",
            threadCount: threads,
            vadThreadCount: threads,
            translate: false,
            noTimestamps: false,
            detectLanguage: false,
            vad: true,
            useGPU: true,
            flashAttention: true
        )
    }

    private static func runRecord(
        status: String,
        errorCode: String?,
        prepared: [PreparedEntry],
        totalCount: Int,
        completedCount: Int,
        failedCount: Int,
        options: CLIOptions,
        manifestHash: String,
        model: SpeechModelMetadata,
        vad: SpeechModelMetadata,
        source: SourceRecord,
        runtime: RuntimeRecord,
        dataSources: [DataSourceRecord],
        loadSeconds: Double?,
        settings: RunnerSettings,
        environment: RunEnvironmentRecord
    ) -> RunRecord {
        RunRecord(
            status: status,
            errorCode: errorCode,
            language: options.language.rawValue,
            selectedCount: prepared.count,
            totalCount: totalCount,
            completedCount: completedCount,
            failedCount: failedCount,
            selectedIds: options.limit == nil ? nil : prepared.map { $0.manifest.id },
            manifestSHA256: manifestHash,
            modelSHA256: model.sha256,
            vadSHA256: vad.sha256,
            runtimeRevision: runtime.revision,
            runtimeSHA256: runtime.sha256,
            sourceRevision: source.revision,
            sourceSHA256: source.sha256,
            sourceDirty: source.dirty,
            dataSources: dataSources,
            model: assetRecord(model),
            vad: assetRecord(vad),
            modelLoadKind: "process_initial",
            modelLoadSeconds: loadSeconds,
            streamSettings: settings,
            environment: environment
        )
    }

    private static func assetRecord(_ metadata: SpeechModelMetadata) -> AssetRecord {
        AssetRecord(
            name: metadata.modelName,
            source: metadata.sourceRepository.absoluteString,
            revision: metadata.revision,
            fileName: metadata.fileName,
            expectedByteCount: metadata.expectedByteCount,
            sha256: metadata.sha256
        )
    }

    private static func failedRow(
        _ entry: PreparedEntry,
        duration: Double,
        code: String,
        statistics: InferenceStatistics = InferenceStatistics()
    ) -> ResultRow {
        ResultRow(
            id: entry.manifest.id,
            language: entry.manifest.language,
            slice: entry.manifest.slice,
            status: "failed",
            hypothesis: "",
            durationSeconds: duration,
            firstPartialSeconds: nil,
            stopToFinalSeconds: nil,
            speechEndToFinalSeconds: nil,
            inferenceSeconds: statistics.seconds,
            inferenceCalls: statistics.calls,
            errorCode: code
        )
    }

    private static func difference(_ after: InferenceStatistics, _ before: InferenceStatistics) -> InferenceStatistics {
        InferenceStatistics(
            seconds: max(0, after.seconds - before.seconds),
            calls: max(0, after.calls - before.calls)
        )
    }

    private static func failureCode(_ error: any Error) -> String {
        if let failure = error as? BenchmarkFailure {
            switch failure {
            case .invalidManifest: "manifest_invalid"
            default: "inference_failed"
            }
        } else if let failure = error as? AudioReplayFailure {
            switch failure {
            case .openFailed: "audio_decode_failed"
            case .unsupportedFormat: "audio_format_unsupported"
            case .conversionFailed: "audio_conversion_failed"
            case .streamOverflow: "audio_stream_overflow"
            case .timingInterrupted: "audio_replay_interrupted"
            case .sampleIndexOverflow: "audio_timeline_overflow"
            }
        } else if let failure = error as? StreamingTranscriptionError {
            switch failure {
            case .audioBacklogExceeded: "inference_backlog_exceeded"
            case .discontinuousAudio: "audio_discontinuity"
            case .windowLimitReached: "inference_window_limit"
            case .invalidAudioChunk, .oversizedAudioChunk: "audio_chunk_invalid"
            case .missingAudio: "audio_missing"
            case .transcriptTooLarge: "transcript_limit_exceeded"
            default: "inference_failed"
            }
        } else if error is CancellationError {
            "inference_cancelled"
        } else {
            "inference_failed"
        }
    }

    private static func speechEndLatency(
        playbackStart: ContinuousClock.Instant?,
        speechEndSeconds: Double?,
        finalAt: ContinuousClock.Instant?
    ) -> Double? {
        guard let playbackStart, let speechEndSeconds, let finalAt else { return nil }
        let endpoint = playbackStart.advanced(by: .nanoseconds(Int64(speechEndSeconds * 1_000_000_000)))
        return seconds(from: endpoint, to: finalAt)
    }

    nonisolated fileprivate static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double? {
        seconds(start.duration(to: end))
    }

    nonisolated fileprivate static func seconds(_ duration: Duration) -> Double? {
        let components = duration.components
        let value = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return value.isFinite && value >= 0 ? value : nil
    }

    private static func sha256(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func environmentPath(_ key: String) throws -> String {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let resolved = resolvedPath(raw) else {
            throw BenchmarkFailure.runtimeUnavailable
        }
        return resolved
    }

    private static func resolvedPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return path.withCString { source in
            buffer.withUnsafeMutableBufferPointer { target in
                guard let result = realpath(source, target.baseAddress) else { return nil }
                return String(cString: result)
            }
        }
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func validateRunDuration(_ seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0, seconds <= maximumAudioDurationSeconds else {
            throw BenchmarkFailure.durationLimitExceeded
        }
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    private static func reportError(_ code: String) {
        FileHandle.standardError.write(Data("error_code=\(code)\n".utf8))
        Darwin.exit(2)
    }

    private static func selfTest() async throws {
        try selfTestPinnedFileValidation()
        try validateRunDuration(maximumAudioDurationSeconds)
        do {
            try validateRunDuration(maximumAudioDurationSeconds + 0.001)
            throw SelfTestFailure.workloadLimit
        } catch BenchmarkFailure.durationLimitExceeded {
        }
        let fake = SelfTestInference()
        let timed = TimedInference(base: fake)
        let recognizer = try StreamingTranscriptionRecognizer(
            inference: timed,
            windowSampleCount: 32_000,
            inferenceIntervalSampleCount: 16_000,
            finalizationLookbackSampleCount: 8_000,
            finalizationContextOverlapSampleCount: 0,
            maximumPendingSampleCount: 32_000
        )
        let (stream, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .bufferingOldest(4))
        _ = continuation.yield(AudioCaptureChunk(
            startingSampleIndex: 0,
            sampleRate: Double(sampleRate),
            samples: [Float](repeating: 0.01, count: 16_000)
        ))
        _ = continuation.yield(AudioCaptureChunk(
            startingSampleIndex: 16_000,
            sampleRate: Double(sampleRate),
            samples: [Float](repeating: 0.01, count: 8_000)
        ))
        continuation.finish()

        var sawPartial = false
        var sawFinal = false
        let generation = UUID()
        let result = try await recognizer.transcribe(audio: stream, language: .english, generation: generation) { event in
            switch event {
            case .provisional(let eventGeneration, let text):
                sawPartial = eventGeneration == generation && text == "hello"
            case .finalized(let eventGeneration, let text):
                sawFinal = eventGeneration == generation && text == "hello world"
            }
        }
        guard result.text == "hello world", sawPartial, sawFinal, timed.snapshot().calls == 2 else {
            throw BenchmarkFailure.runtimeUnavailable
        }

        let discontinuity = try await selfTestRecognitionError(
            AudioCaptureChunk(startingSampleIndex: 1, sampleRate: Double(sampleRate), samples: [0.1]),
            inference: SelfTestInference()
        )
        guard case .discontinuousAudio(expectedSample: 0, actualSample: 1) = discontinuity else {
            throw BenchmarkFailure.runtimeUnavailable
        }
        let invalidInput = try await selfTestRecognitionError(
            AudioCaptureChunk(startingSampleIndex: 0, sampleRate: 8_000, samples: [0.1]),
            inference: SelfTestInference()
        )
        guard case .invalidAudioChunk = invalidInput else { throw BenchmarkFailure.runtimeUnavailable }
        guard speechEndLatency(playbackStart: nil, speechEndSeconds: nil, finalAt: nil) == nil else {
            throw BenchmarkFailure.runtimeUnavailable
        }
        guard failureCode(BenchmarkFailure.invalidManifest) == "manifest_invalid" else {
            throw SelfTestFailure.resultSchema
        }
        try await selfTestAudioReplay()
        try selfTestReplayTiming()
        try selfTestSerializedSchema()
    }

    private static func selfTestPinnedFileValidation() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mac-utilities-speech-benchmark-file-self-test-\(UUID().uuidString)", isDirectory: true)
        guard directory.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else {
            throw SelfTestFailure.audioFile
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let data = Data("pinned asset verification fixture".utf8)
        let file = directory.appendingPathComponent("fixture.bin", isDirectory: false)
        do {
            try data.write(to: file, options: .atomic)
            guard chmod(file.path, mode_t(0o600)) == 0 else { throw SelfTestFailure.audioFile }
        } catch {
            throw SelfTestFailure.audioFile
        }
        let metadata = SpeechModelMetadata(
            languageCode: "en",
            modelName: "fixture",
            sourceRepository: URL(string: "https://huggingface.co/example/fixture")!,
            revision: String(repeating: "a", count: 40),
            fileName: "fixture.bin",
            expectedByteCount: Int64(data.count),
            sha256: sha256(data),
            licenseIdentifier: "MIT"
        )
        try verifyPinnedFile(file, metadata: metadata)

        let symlink = directory.appendingPathComponent("fixture-link.bin", isDirectory: false)
        do {
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
            try verifyPinnedFile(symlink, metadata: metadata)
            throw SelfTestFailure.resultSchema
        } catch BenchmarkFailure.inputHashMismatch {
            return
        }
    }

    private static func selfTestReplayTiming() throws {
        let deadline = ContinuousClock().now
        for offset: Duration in [.milliseconds(-1), .zero, .milliseconds(3), .milliseconds(250)] {
            try ReplayTiming.validate(deadline: deadline, now: deadline.advanced(by: offset))
        }
        for offset: Duration in [.milliseconds(251), .seconds(2), .seconds(330)] {
            do {
                try ReplayTiming.validate(deadline: deadline, now: deadline.advanced(by: offset))
                throw SelfTestFailure.resultSchema
            } catch AudioReplayFailure.timingInterrupted {
                guard failureCode(AudioReplayFailure.timingInterrupted) == "audio_replay_interrupted" else {
                    throw SelfTestFailure.resultSchema
                }
            }
        }
    }

    private static func selfTestAudioReplay() async throws {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mac-utilities-speech-benchmark-self-test-\(UUID().uuidString)", isDirectory: true)
        guard directoryURL.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else {
            throw SelfTestFailure.audioFile
        }
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let diagnostics = try NativeDiagnosticsCapture(
            logURL: directoryURL.appendingPathComponent("diagnostics.log", isDirectory: false)
        )
        defer { diagnostics.restore() }

        let audioURL = directoryURL.appendingPathComponent("fixture.wav", isDirectory: false)
        let sourceSampleRate = 48_000.0
        let sourceFrames = 24_000
        let expectedOutputSamples = sourceFrames / 3
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 2,
            interleaved: false
        ),
        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(sourceFrames)),
        let sourceChannels = sourceBuffer.floatChannelData else {
            throw SelfTestFailure.audioFile
        }
        sourceBuffer.frameLength = AVAudioFrameCount(sourceFrames)
        for frame in 0..<sourceFrames {
            let sample = Float(sin(Double(frame) * 2 * .pi * 440 / sourceSampleRate) * 0.2)
            sourceChannels[0][frame] = sample
            sourceChannels[1][frame] = sample * 0.5
        }
        let (interruptedStream, interruptedContinuation) = AudioCaptureStream.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let interruptedState = ReplayState()
        let interruptedClock = ContinuousClock()
        interruptedState.playbackStart = interruptedClock.now.advanced(by: .seconds(-330))
        do {
            try await enqueue(
                sourceBuffer,
                continuation: interruptedContinuation,
                state: interruptedState,
                clock: interruptedClock
            )
            throw SelfTestFailure.resultSchema
        } catch AudioReplayFailure.timingInterrupted {
            guard interruptedState.sampleCount == 0 else { throw SelfTestFailure.resultSchema }
        }
        interruptedContinuation.finish()
        var interruptedIterator = interruptedStream.makeAsyncIterator()
        guard try await interruptedIterator.next() == nil else { throw SelfTestFailure.resultSchema }
        do {
            var writer: AVAudioFile? = try AVAudioFile(
                forWriting: audioURL,
                settings: sourceFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try writer?.write(from: sourceBuffer)
            writer = nil
        } catch {
            throw SelfTestFailure.audioFile
        }
        guard chmod(audioURL.path, mode_t(0o600)) == 0 else { throw SelfTestFailure.audioFile }

        let fakeInference = ReplaySelfTestInference()
        let timedInference = TimedInference(base: fakeInference)
        let recognizer = try StreamingTranscriptionRecognizer(inference: timedInference)
        let (stream, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .bufferingOldest(streamBufferCapacity))
        let replayState = ReplayState()
        let generation = UUID()
        let replayClock = ContinuousClock()
        let producer = Task { @MainActor in
            do {
                try await replay(audioURL, continuation: continuation, state: replayState)
                continuation.finish()
                replayState.endOfFile = replayClock.now
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }
        let recognition = Task { @MainActor in
            try await recognizer.transcribe(audio: stream, language: .english, generation: generation) { _ in }
        }

        let result: TranscriptionRecognitionResult
        do {
            result = try await recognition.value
        } catch {
            let producerResult = await producer.result
            producer.cancel()
            continuation.finish(throwing: CancellationError())
            await recognizer.cancel(generation: generation)
            recognition.cancel()
            _ = await recognition.result
            _ = try? await producer.value
            if case .failure(let producerError) = producerResult {
                throw SelfTestFailure.audioProducer(failureCode(producerError))
            }
            throw SelfTestFailure.audioRecognizer(failureCode(error))
        }
        do {
            try await producer.value
        } catch {
            await recognizer.cancel(generation: generation)
            throw SelfTestFailure.audioProducer(failureCode(error))
        }
        guard result.text.isEmpty else { throw SelfTestFailure.audioResult }

        guard replayState.sampleCount == UInt64(expectedOutputSamples),
              fakeInference.observedSampleCount == expectedOutputSamples else { throw SelfTestFailure.audioSampleCount }
        guard fakeInference.observedSampleRate == Double(sampleRate) else { throw SelfTestFailure.audioSampleRate }
        guard fakeInference.observedNonzeroSample else { throw SelfTestFailure.audioSignal }
        guard let playbackStart = replayState.playbackStart,
              let endOfFile = replayState.endOfFile,
              let elapsed = seconds(from: playbackStart, to: endOfFile),
              elapsed >= Double(expectedOutputSamples) / Double(sampleRate) - 0.02 else {
            throw SelfTestFailure.audioTiming
        }
    }

    private static func selfTestSerializedSchema() throws {
        let measuredEnvironment = try RunEnvironmentSnapshot.capture().finish()
        guard measuredEnvironment.macOSVersion.split(separator: ".").allSatisfy({ Int($0) != nil }),
              !measuredEnvironment.appVersionCandidate.isEmpty,
              !measuredEnvironment.appBuildCandidate.isEmpty,
              measuredEnvironment.appVersionSource == "Configuration/Version.xcconfig",
              measuredEnvironment.appVersionScope == "candidate_not_installed",
              measuredEnvironment.powerSource == "unknown",
              measuredEnvironment.displayState == "unknown",
              measuredEnvironment.backgroundWorkload == "unknown" else {
            throw SelfTestFailure.runSchema
        }

        let digest = String(repeating: "a", count: 64)
        let manifestLine = """
        {"schema_version":1,"id":"fixture","language":"en","slice":"short","audio_path":"/private/fixture.wav","reference":"","speaker_id":"speaker-1","speech_end_seconds":0.5,"source":"fixture-corpus","source_revision":"fixture-revision","audio_sha256":"\(digest)"}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let parsed: ManifestEntry
        do {
            parsed = try decoder.decode(ManifestEntry.self, from: Data(manifestLine.utf8))
        } catch {
            throw SelfTestFailure.manifestSchema
        }
        guard parsed.audioSha256 == digest, parsed.speakerId == "speaker-1" else {
            throw SelfTestFailure.manifestSchema
        }

        let prepared = PreparedEntry(manifest: parsed, audioURL: URL(fileURLWithPath: parsed.audioPath), expectedDurationSeconds: 1, preflightErrorCode: nil)
        let rowEncoder = JSONEncoder()
        rowEncoder.keyEncodingStrategy = .convertToSnakeCase
        let rowData = try rowEncoder.encode(failedRow(prepared, duration: 1, code: "inference_failed"))
        let row = try JSONSerialization.jsonObject(with: rowData) as? [String: Any]
        guard row?["status"] as? String == "failed",
              row?["hypothesis"] as? String == "",
              row?["first_partial_seconds"] is NSNull,
              row?["stop_to_final_seconds"] is NSNull,
              row?["speech_end_to_final_seconds"] is NSNull else {
            throw SelfTestFailure.resultSchema
        }

        let run = RunRecord(
            status: "ok",
            errorCode: nil,
            language: "en",
            selectedCount: 1,
            totalCount: 2,
            completedCount: 1,
            failedCount: 0,
            selectedIds: ["fixture"],
            manifestSHA256: digest,
            modelSHA256: SpeechModelMetadata.pinnedEnglish.sha256,
            vadSHA256: SpeechModelMetadata.pinnedVAD.sha256,
            runtimeRevision: "fixture-runtime",
            runtimeSHA256: digest,
            sourceRevision: "fixture-source",
            sourceSHA256: digest,
            sourceDirty: true,
            dataSources: [],
            model: assetRecord(.pinnedEnglish),
            vad: assetRecord(.pinnedVAD),
            modelLoadKind: "process_initial",
            modelLoadSeconds: 0.1,
            streamSettings: runnerSettings(language: .english),
            environment: RunEnvironmentRecord(
                macOSVersion: "26.6.0",
                appVersionCandidate: "4.0.4",
                appBuildCandidate: "33",
                appVersionSource: "Configuration/Version.xcconfig",
                appVersionScope: "candidate_not_installed",
                thermalStateStart: 0,
                thermalStateEnd: 0,
                lowPowerMode: false,
                powerSource: "unknown",
                displayState: "unknown",
                backgroundWorkload: "unknown"
            )
        )
        let runData = try rowEncoder.encode(run)
        let runObject = try JSONSerialization.jsonObject(with: runData) as? [String: Any]
        let requiredKeys = [
            "schema_version", "language", "manifest_sha256", "model_sha256", "vad_sha256",
            "runtime_revision", "runtime_sha256", "source_revision", "source_sha256", "source_dirty", "model_load_seconds",
            "selected_count", "total_count", "completed_count", "failed_count", "stream_settings",
            "selected_ids", "environment"
        ]
        guard requiredKeys.allSatisfy({ runObject?[$0] != nil }) else {
            throw SelfTestFailure.runSchema
        }
        let environment = runObject?["environment"] as? [String: Any]
        let environmentKeys = [
            "mac_os_version", "app_version_candidate", "app_build_candidate", "app_version_source",
            "app_version_scope", "thermal_state_start", "thermal_state_end", "low_power_mode",
            "power_source", "display_state", "background_workload"
        ]
        guard environmentKeys.allSatisfy({ environment?[$0] != nil }),
              environment?["power_source"] as? String == "unknown",
              environment?["display_state"] as? String == "unknown",
              environment?["background_workload"] as? String == "unknown" else {
            throw SelfTestFailure.runSchema
        }
    }

    private static func selfTestRecognitionError(
        _ chunk: AudioCaptureChunk,
        inference: SelfTestInference
    ) async throws -> StreamingTranscriptionError {
        let recognizer = try StreamingTranscriptionRecognizer(inference: inference)
        let (stream, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .bufferingOldest(2))
        _ = continuation.yield(chunk)
        continuation.finish()
        do {
            _ = try await recognizer.transcribe(audio: stream, language: .english, generation: UUID()) { _ in }
            throw BenchmarkFailure.runtimeUnavailable
        } catch let error as StreamingTranscriptionError {
            return error
        }
    }
}

nonisolated private final class SelfTestInference: StreamingTranscriptionInferring, @unchecked Sendable {
    private let callCount = Mutex(0)

    func transcribe(
        samples: [Float],
        sampleRate: Double,
        language: WhisperInferenceLanguage
    ) async throws -> WhisperInferenceResult {
        let call = callCount.withLock { count -> Int in
            let current = count
            count += 1
            return current
        }
        if call == 0 {
            return WhisperInferenceResult(
                text: "hello",
                segments: [WhisperInferenceSegment(startTime: 0, endTime: 0.8, text: "hello")],
                vadSpeechState: .speechDetected
            )
        }
        return WhisperInferenceResult(
            text: "hello world",
            segments: [
                WhisperInferenceSegment(startTime: 0, endTime: 0.8, text: "hello"),
                WhisperInferenceSegment(startTime: 0.8, endTime: 1.2, text: " world")
            ],
            vadSpeechState: .speechDetected
        )
    }
}

nonisolated private final class ReplaySelfTestInference: StreamingTranscriptionInferring, @unchecked Sendable {
    private struct ObservedAudio: Sendable {
        var sampleCount = 0
        var sampleRate = 0.0
        var nonzeroSample = false
    }

    private let observed = Mutex(ObservedAudio())

    var observedSampleCount: Int { observed.withLock { $0.sampleCount } }
    var observedSampleRate: Double { observed.withLock { $0.sampleRate } }
    var observedNonzeroSample: Bool { observed.withLock { $0.nonzeroSample } }

    func transcribe(
        samples: [Float],
        sampleRate: Double,
        language: WhisperInferenceLanguage
    ) async throws -> WhisperInferenceResult {
        observed.withLock {
            $0.sampleCount = samples.count
            $0.sampleRate = sampleRate
            $0.nonzeroSample = samples.contains { $0 != 0 }
        }
        return WhisperInferenceResult(text: "", segments: [], vadSpeechState: .noSpeechDetected)
    }
}
