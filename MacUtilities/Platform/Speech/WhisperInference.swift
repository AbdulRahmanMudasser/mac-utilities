import Darwin
import Dispatch
import Foundation
import Synchronization
import whisper

nonisolated enum WhisperInferenceLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case urdu = "ur"
}

nonisolated enum WhisperInferenceSpeechState: Equatable, Sendable {
    case unknown
    case speechDetected
    case noSpeechDetected
}

nonisolated struct WhisperInferenceSegment: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

nonisolated struct WhisperInferenceResult: Equatable, Sendable {
    let text: String
    let segments: [WhisperInferenceSegment]
    let vadSpeechState: WhisperInferenceSpeechState

    init(
        text: String,
        segments: [WhisperInferenceSegment],
        vadSpeechState: WhisperInferenceSpeechState = .unknown
    ) {
        self.text = text
        self.segments = segments
        self.vadSpeechState = vadSpeechState
    }
}

nonisolated enum WhisperInferenceFileRole: Equatable, Sendable {
    case model
    case vad
}

nonisolated enum WhisperInferenceError: Error, Equatable, LocalizedError, Sendable {
    case invalidFileURL(role: WhisperInferenceFileRole)
    case fileUnavailable(role: WhisperInferenceFileRole, systemErrorCode: Int32)
    case notRegularFile(role: WhisperInferenceFileRole)
    case modelLoadFailed
    case vadModelLoadFailed
    case unsupportedSampleRate(Double)
    case emptyAudio
    case audioTooLong(actualSamples: Int, maximumSamples: Int)
    case nonFiniteAudioSample(index: Int)
    case cancelled
    case vadDetectionFailed
    case invalidVADSegmentCount(Int32)
    case vadSegmentLimitExceeded(Int32)
    case nativeTranscriptionFailed(status: Int32)
    case invalidSegmentCount(Int32)
    case segmentLimitExceeded(Int32)
    case invalidSegment(index: Int)
    case invalidSegmentText(index: Int)
    case transcriptTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidFileURL(let role):
            "The supplied \(role.description) must be a local file URL."
        case .fileUnavailable(let role, let code):
            "The supplied \(role.description) could not be read (system error \(code))."
        case .notRegularFile(let role):
            "The supplied \(role.description) must be a regular file, not a symbolic link or directory."
        case .modelLoadFailed:
            "The specified speech model could not be opened by the pinned whisper runtime."
        case .vadModelLoadFailed:
            "The specified VAD model could not be opened by the pinned whisper runtime."
        case .unsupportedSampleRate(let sampleRate):
            "Whisper inference requires 16 kHz mono audio; received a sample rate of \(sampleRate)."
        case .emptyAudio:
            "Whisper inference requires at least one audio sample."
        case .audioTooLong(let actualSamples, let maximumSamples):
            "The audio contains \(actualSamples) samples; this inference window is limited to \(maximumSamples)."
        case .nonFiniteAudioSample(let index):
            "The audio contains a non-finite sample at index \(index)."
        case .cancelled:
            "Speech inference was cancelled."
        case .vadDetectionFailed:
            "The pinned whisper runtime could not complete VAD for the audio."
        case .invalidVADSegmentCount(let count):
            "The pinned whisper runtime returned an invalid VAD segment count (\(count))."
        case .vadSegmentLimitExceeded(let count):
            "The pinned whisper runtime returned too many VAD segments (\(count))."
        case .nativeTranscriptionFailed(let status):
            "The pinned whisper runtime failed to transcribe the audio (status \(status))."
        case .invalidSegmentCount(let count):
            "The pinned whisper runtime returned an invalid segment count (\(count))."
        case .segmentLimitExceeded(let count):
            "The pinned whisper runtime returned too many segments (\(count))."
        case .invalidSegment(let index):
            "The pinned whisper runtime returned invalid timing for segment \(index)."
        case .invalidSegmentText(let index):
            "The pinned whisper runtime returned invalid UTF-8 for segment \(index)."
        case .transcriptTooLarge:
            "The pinned whisper runtime returned text beyond the configured result limit."
        }
    }
}

private extension WhisperInferenceFileRole {
    nonisolated var description: String {
        switch self {
        case .model: "verified speech model"
        case .vad: "VAD model"
        }
    }
}

nonisolated enum WhisperInferenceLimits {
    static let sampleRate = 16_000
    static let maximumDurationSeconds = 30
    static let maximumSampleCount = sampleRate * maximumDurationSeconds
    static let maximumSegmentCount = 4_096
    static let maximumVADSegmentCount = 4_096
    static let maximumTranscriptUTF8Bytes = 512 * 1_024
}

nonisolated enum WhisperInferenceSpeechStateResolver {
    static func resolve(
        cancellation: WhisperInferenceCancellationState,
        detectSegmentCount: () -> Int32?
    ) throws -> WhisperInferenceSpeechState {
        guard !cancellation.isCancelled else { throw WhisperInferenceError.cancelled }

        let segmentCount = detectSegmentCount()

        guard !cancellation.isCancelled else { throw WhisperInferenceError.cancelled }
        guard let segmentCount else { throw WhisperInferenceError.vadDetectionFailed }
        guard segmentCount >= 0 else {
            throw WhisperInferenceError.invalidVADSegmentCount(segmentCount)
        }
        guard segmentCount <= Int32(WhisperInferenceLimits.maximumVADSegmentCount) else {
            throw WhisperInferenceError.vadSegmentLimitExceeded(segmentCount)
        }

        return segmentCount == 0 ? .noSpeechDetected : .speechDetected
    }
}

nonisolated final class WhisperInferenceCancellationState: @unchecked Sendable {
    private let cancelled = Atomic<Bool>(false)

    var isCancelled: Bool {
        cancelled.load(ordering: .acquiring)
    }

    func cancel() {
        cancelled.store(true, ordering: .releasing)
    }

    static let abortCallback: ggml_abort_callback = { userData in
        guard let userData else { return true }
        let state = Unmanaged<WhisperInferenceCancellationState>
            .fromOpaque(userData)
            .takeUnretainedValue()
        return state.isCancelled
    }
}

nonisolated private final class WhisperInferenceNativeContext: @unchecked Sendable {
    private let context: OpaquePointer
    private let vadContext: OpaquePointer

    init(context: OpaquePointer, vadContext: OpaquePointer) {
        self.context = context
        self.vadContext = vadContext
    }

    deinit {
        whisper_vad_free(vadContext)
        whisper_free(context)
    }

    func transcribe(
        samples: [Float],
        language: WhisperInferenceLanguage,
        vadModelPath: String,
        cancellation: WhisperInferenceCancellationState
    ) throws -> WhisperInferenceResult {
        guard !cancellation.isCancelled else { throw WhisperInferenceError.cancelled }

        let speechState = try detectSpeech(
            samples: samples,
            cancellation: cancellation
        )
        guard !cancellation.isCancelled else { throw WhisperInferenceError.cancelled }
        if speechState == .noSpeechDetected {
            return WhisperInferenceResult(text: "", segments: [], vadSpeechState: speechState)
        }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        parameters.translate = false
        parameters.no_timestamps = false
        parameters.print_special = false
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        parameters.language = nil
        parameters.detect_language = false
        parameters.vad = true
        parameters.vad_model_path = nil
        parameters.abort_callback = WhisperInferenceCancellationState.abortCallback
        parameters.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()

        let status = language.rawValue.withCString { languageCString in
            parameters.language = languageCString
            return vadModelPath.withCString { vadModelCString in
                parameters.vad_model_path = vadModelCString
                return samples.withUnsafeBufferPointer { sampleBuffer in
                    whisper_full(
                        context,
                        parameters,
                        sampleBuffer.baseAddress!,
                        Int32(sampleBuffer.count)
                    )
                }
            }
        }

        guard !cancellation.isCancelled else { throw WhisperInferenceError.cancelled }
        if status == -1 {
            throw WhisperInferenceError.vadDetectionFailed
        }
        guard status == 0 else {
            throw WhisperInferenceError.nativeTranscriptionFailed(status: status)
        }

        return try readResult(vadSpeechState: speechState)
    }

    private func detectSpeech(
        samples: [Float],
        cancellation: WhisperInferenceCancellationState
    ) throws -> WhisperInferenceSpeechState {
        return try WhisperInferenceSpeechStateResolver.resolve(cancellation: cancellation) {
            samples.withUnsafeBufferPointer { sampleBuffer in
                guard let samplesBaseAddress = sampleBuffer.baseAddress else { return nil }
                guard let vadSegments = whisper_vad_segments_from_samples(
                    vadContext,
                    whisper_vad_default_params(),
                    samplesBaseAddress,
                    Int32(sampleBuffer.count)
                ) else {
                    return nil
                }
                defer { whisper_vad_free_segments(vadSegments) }
                return whisper_vad_segments_n_segments(vadSegments)
            }
        }
    }

    private func readResult(
        vadSpeechState: WhisperInferenceSpeechState
    ) throws -> WhisperInferenceResult {
        let segmentCount = whisper_full_n_segments(context)
        guard segmentCount >= 0 else {
            throw WhisperInferenceError.invalidSegmentCount(segmentCount)
        }
        guard segmentCount <= Int32(WhisperInferenceLimits.maximumSegmentCount) else {
            throw WhisperInferenceError.segmentLimitExceeded(segmentCount)
        }

        var segments: [WhisperInferenceSegment] = []
        segments.reserveCapacity(Int(segmentCount))
        var fullText = ""
        var transcriptByteCount = 0
        var previousStart: Int64 = -1
        var previousEnd: Int64 = -1

        for index in 0..<Int(segmentCount) {
            let nativeIndex = Int32(index)
            let start = whisper_full_get_segment_t0(context, nativeIndex)
            let end = whisper_full_get_segment_t1(context, nativeIndex)
            guard start >= 0,
                  end > start,
                  start >= previousStart,
                  end >= previousEnd else {
                throw WhisperInferenceError.invalidSegment(index: index)
            }

            guard let textPointer = whisper_full_get_segment_text(context, nativeIndex) else {
                throw WhisperInferenceError.invalidSegmentText(index: index)
            }
            let remainingByteLimit = WhisperInferenceLimits.maximumTranscriptUTF8Bytes - transcriptByteCount
            let byteCount = strnlen(textPointer, remainingByteLimit + 1)
            guard byteCount <= remainingByteLimit else {
                throw WhisperInferenceError.transcriptTooLarge
            }
            guard let text = String(validatingCString: textPointer) else {
                throw WhisperInferenceError.invalidSegmentText(index: index)
            }

            transcriptByteCount += byteCount
            fullText.append(text)
            segments.append(
                WhisperInferenceSegment(
                    startTime: Double(start) / 100,
                    endTime: Double(end) / 100,
                    text: text
                )
            )
            previousStart = start
            previousEnd = end
        }

        return WhisperInferenceResult(
            text: fullText,
            segments: segments,
            vadSpeechState: vadSpeechState
        )
    }
}

nonisolated final class WhisperInference: @unchecked Sendable {
    private let context: WhisperInferenceNativeContext
    private let vadModelPath: String
    private let inferenceQueue: DispatchQueue

    init(verifiedModelURL: URL, vadModelURL: URL) throws {
        let modelPath = try Self.readableRegularFilePath(verifiedModelURL, role: .model)
        let vadPath = try Self.readableRegularFilePath(vadModelURL, role: .vad)

        var contextParameters = whisper_context_default_params()
        contextParameters.use_gpu = true
        contextParameters.flash_attn = true

        guard let nativeContext = modelPath.withCString({
            whisper_init_from_file_with_params($0, contextParameters)
        }) else {
            throw WhisperInferenceError.modelLoadFailed
        }

        var vadContextParameters = whisper_vad_default_context_params()
        vadContextParameters.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        guard let nativeVADContext = vadPath.withCString({
            whisper_vad_init_from_file_with_params($0, vadContextParameters)
        }) else {
            whisper_free(nativeContext)
            throw WhisperInferenceError.vadModelLoadFailed
        }

        context = WhisperInferenceNativeContext(
            context: nativeContext,
            vadContext: nativeVADContext
        )
        vadModelPath = vadPath
        inferenceQueue = DispatchQueue(
            label: "com.abdulrahman.mac-utilities.whisper-inference.\(UUID().uuidString)",
            qos: .userInitiated
        )
    }

    func transcribe(
        samples: [Float],
        sampleRate: Double,
        language: WhisperInferenceLanguage
    ) async throws -> WhisperInferenceResult {
        try Self.validateInput(samples: samples, sampleRate: sampleRate)

        let cancellation = WhisperInferenceCancellationState()
        let context = self.context
        let vadModelPath = self.vadModelPath
        let inferenceQueue = self.inferenceQueue

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                inferenceQueue.async {
                    do {
                        guard !cancellation.isCancelled else {
                            throw WhisperInferenceError.cancelled
                        }
                        let result = try context.transcribe(
                            samples: samples,
                            language: language,
                            vadModelPath: vadModelPath,
                            cancellation: cancellation
                        )
                        guard !cancellation.isCancelled else {
                            throw WhisperInferenceError.cancelled
                        }
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func validateInput(samples: [Float], sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate == Double(WhisperInferenceLimits.sampleRate) else {
            throw WhisperInferenceError.unsupportedSampleRate(sampleRate)
        }
        guard !samples.isEmpty else { throw WhisperInferenceError.emptyAudio }
        guard samples.count <= WhisperInferenceLimits.maximumSampleCount else {
            throw WhisperInferenceError.audioTooLong(
                actualSamples: samples.count,
                maximumSamples: WhisperInferenceLimits.maximumSampleCount
            )
        }
        if let index = samples.firstIndex(where: { !$0.isFinite }) {
            throw WhisperInferenceError.nonFiniteAudioSample(index: index)
        }
    }

    private static func readableRegularFilePath(
        _ url: URL,
        role: WhisperInferenceFileRole
    ) throws -> String {
        guard url.isFileURL else { throw WhisperInferenceError.invalidFileURL(role: role) }

        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw WhisperInferenceError.invalidFileURL(role: role)
        }

        var fileInfo = stat()
        guard path.withCString({ lstat($0, &fileInfo) }) == 0 else {
            throw WhisperInferenceError.fileUnavailable(role: role, systemErrorCode: errno)
        }
        guard (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw WhisperInferenceError.notRegularFile(role: role)
        }
        guard path.withCString({ access($0, R_OK) }) == 0 else {
            throw WhisperInferenceError.fileUnavailable(role: role, systemErrorCode: errno)
        }
        return path
    }
}
