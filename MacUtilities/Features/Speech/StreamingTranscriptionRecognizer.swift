import Foundation

nonisolated protocol StreamingTranscriptionInferring: Sendable {
    func transcribe(
        samples: [Float],
        sampleRate: Double,
        language: WhisperInferenceLanguage
    ) async throws -> WhisperInferenceResult
}

extension WhisperInference: StreamingTranscriptionInferring {}

nonisolated enum StreamingTranscriptionLimits {
    static let maximumWindowSampleCount = WhisperInferenceLimits.maximumSampleCount
    static let maximumChunkSampleCount = WhisperInferenceLimits.sampleRate
    static let maximumPendingSampleCount = WhisperInferenceLimits.sampleRate * 10
    static let inferenceIntervalSampleCount = WhisperInferenceLimits.sampleRate * 2
    static let finalizationLookbackSampleCount = WhisperInferenceLimits.sampleRate * 2
    static let finalizationContextOverlapSampleCount = 0
    static let maximumTranscriptUTF8Bytes = WhisperInferenceLimits.maximumTranscriptUTF8Bytes
}

nonisolated enum StreamingTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case alreadyRecognizing
    case invalidWindowSampleCount(Int)
    case invalidStreamingConfiguration
    case unsupportedLanguage(String)
    case missingAudio
    case invalidAudioChunk
    case oversizedAudioChunk(Int)
    case audioBacklogExceeded(
        pendingSampleCount: Int,
        incomingSampleCount: Int,
        maximumSampleCount: Int
    )
    case windowLimitReached
    case discontinuousAudio(expectedSample: UInt64, actualSample: UInt64)
    case sampleIndexOverflow
    case invalidInferenceResult
    case tooManyInferenceSegments(Int)
    case invalidInferenceSegment(index: Int)
    case overlappingFinalizedAudio(
        existingRange: SpeechAudioSampleRange,
        incomingRange: SpeechAudioSampleRange
    )
    case transcriptTooLarge

    var errorDescription: String? {
        switch self {
        case .alreadyRecognizing:
            "A streaming transcription is already active."
        case .invalidWindowSampleCount(let count):
            "The transcription window size is invalid (\(count) samples)."
        case .invalidStreamingConfiguration:
            "The streaming transcription limits are invalid."
        case .unsupportedLanguage(let language):
            "The selected transcription language is not supported (\(language))."
        case .missingAudio:
            "No microphone audio was received."
        case .invalidAudioChunk:
            "The microphone stream supplied invalid audio."
        case .oversizedAudioChunk(let count):
            "An audio chunk contains \(count) samples, beyond the streaming limit."
        case .audioBacklogExceeded(let pending, let incoming, let maximum):
            "Speech inference could not keep up with microphone input (\(pending + incoming) pending samples; limit \(maximum))."
        case .windowLimitReached:
            "The inference window filled without a verified speech boundary; continuing would require discarding audio."
        case .discontinuousAudio(let expected, let actual):
            "Audio capture skipped samples (expected sample \(expected), received \(actual))."
        case .sampleIndexOverflow:
            "The microphone stream exceeded its supported sample timeline."
        case .invalidInferenceResult:
            "Speech inference returned text that could not be matched to timed segments."
        case .tooManyInferenceSegments(let count):
            "Speech inference returned too many timed segments (\(count))."
        case .invalidInferenceSegment(let index):
            "Speech inference returned invalid timing for segment \(index)."
        case .overlappingFinalizedAudio:
            "Speech inference returned overlapping finalized audio; the transcript was not stitched."
        case .transcriptTooLarge:
            "The transcription exceeded the configured text limit."
        }
    }
}

@MainActor
final class StreamingTranscriptionRecognizer: TranscriptionRecognizing {
    private struct ActiveSession {
        let generation: UUID
        let cancellation: StreamingTranscriptionCancellation
        let worker: Task<TranscriptionRecognitionResult, any Error>
    }

    private struct WindowOutput {
        let segments: [SpeechFinalizedSegment]
        let vadSpeechState: WhisperInferenceSpeechState
        let hasRawSegments: Bool
    }

    private struct WindowInferenceOutcome {
        let vadSpeechState: WhisperInferenceSpeechState
        let unresolvedSpeechThrough: UInt64?
        let hasSegments: Bool
    }

    private let inference: any StreamingTranscriptionInferring
    private let windowSampleCount: Int
    private let inferenceIntervalSampleCount: Int
    private let finalizationLookbackSampleCount: Int
    private let finalizationContextOverlapSampleCount: Int
    private let maximumPendingSampleCount: Int
    private var activeSession: ActiveSession?

    init(
        inference: any StreamingTranscriptionInferring,
        windowSampleCount: Int = StreamingTranscriptionLimits.maximumWindowSampleCount,
        inferenceIntervalSampleCount: Int? = nil,
        finalizationLookbackSampleCount: Int? = nil,
        finalizationContextOverlapSampleCount: Int? = nil,
        maximumPendingSampleCount: Int = StreamingTranscriptionLimits.maximumPendingSampleCount
    ) throws {
        guard (1...StreamingTranscriptionLimits.maximumWindowSampleCount).contains(windowSampleCount) else {
            throw StreamingTranscriptionError.invalidWindowSampleCount(windowSampleCount)
        }

        let inferenceInterval = inferenceIntervalSampleCount
            ?? min(StreamingTranscriptionLimits.inferenceIntervalSampleCount, windowSampleCount)
        let finalizationLookback = finalizationLookbackSampleCount
            ?? min(StreamingTranscriptionLimits.finalizationLookbackSampleCount, windowSampleCount - 1)
        let contextOverlap = finalizationContextOverlapSampleCount
            ?? min(StreamingTranscriptionLimits.finalizationContextOverlapSampleCount, windowSampleCount - 1)
        guard (1...windowSampleCount).contains(inferenceInterval),
              (0..<windowSampleCount).contains(finalizationLookback),
              (0..<windowSampleCount).contains(contextOverlap),
              (1...StreamingTranscriptionLimits.maximumWindowSampleCount).contains(maximumPendingSampleCount) else {
            throw StreamingTranscriptionError.invalidStreamingConfiguration
        }

        self.inference = inference
        self.windowSampleCount = windowSampleCount
        self.inferenceIntervalSampleCount = inferenceInterval
        self.finalizationLookbackSampleCount = finalizationLookback
        self.finalizationContextOverlapSampleCount = contextOverlap
        self.maximumPendingSampleCount = maximumPendingSampleCount
    }

    func transcribe(
        audio: AudioCaptureStream,
        language: TranscriptionLanguage,
        generation: UUID,
        onEvent: @escaping @MainActor @Sendable (TranscriptionRecognitionEvent) -> Void
    ) async throws -> TranscriptionRecognitionResult {
        guard activeSession == nil else {
            throw StreamingTranscriptionError.alreadyRecognizing
        }
        guard let inferenceLanguage = WhisperInferenceLanguage(rawValue: language.rawValue) else {
            throw StreamingTranscriptionError.unsupportedLanguage(language.rawValue)
        }

        let cancellation = StreamingTranscriptionCancellation()
        let backlog = StreamingAudioBacklog(maximumSampleCount: maximumPendingSampleCount)
        let reader = Task { @MainActor [weak self, cancellation, backlog] in
            defer { cancellation.clearReader() }
            guard let self else {
                await backlog.finish(throwing: CancellationError())
                return
            }

            var expectedSample: UInt64 = 0
            do {
                for try await chunk in audio {
                    try Task.checkCancellation()
                    try self.validate(chunk, expectedSample: expectedSample)
                    let (nextSample, overflow) = chunk.startingSampleIndex.addingReportingOverflow(
                        UInt64(chunk.samples.count)
                    )
                    guard !overflow else { throw StreamingTranscriptionError.sampleIndexOverflow }
                    expectedSample = nextSample
                    try await backlog.enqueue(chunk)
                }
                await backlog.finish()
            } catch {
                cancellation.fail(error)
                await backlog.finish(throwing: error)
            }
        }
        cancellation.install(reader: reader)

        let worker = Task { @MainActor [weak self, cancellation, backlog, reader] in
            defer { cancellation.clearWorker() }
            guard let self else { throw CancellationError() }
            return try await self.consume(
                backlog: backlog,
                reader: reader,
                language: inferenceLanguage,
                generation: generation,
                cancellation: cancellation,
                onEvent: onEvent
            )
        }
        cancellation.install(worker: worker)
        activeSession = ActiveSession(
            generation: generation,
            cancellation: cancellation,
            worker: worker
        )
        defer {
            if activeSession?.generation == generation {
                activeSession = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    func cancel(generation: UUID) async {
        guard let session = activeSession, session.generation == generation else { return }
        session.cancellation.cancel()
        _ = try? await session.worker.value
    }

    private func consume(
        backlog: StreamingAudioBacklog,
        reader: Task<Void, Never>,
        language: WhisperInferenceLanguage,
        generation: UUID,
        cancellation: StreamingTranscriptionCancellation,
        onEvent: @escaping @MainActor @Sendable (TranscriptionRecognitionEvent) -> Void
    ) async throws -> TranscriptionRecognitionResult {
        var window: [Float] = []
        window.reserveCapacity(windowSampleCount)
        var windowStartSample: UInt64 = 0
        var receivedAudio = false
        var transcript = ""
        var lastFinalizedSegment: SpeechFinalizedSegment?
        var lastProvisionalText = ""
        var samplesSinceInference = 0
        var unfinalizedSpeechThrough: UInt64?

        do {
            while let chunk = try await backlog.next() {
                try Task.checkCancellation()
                receivedAudio = true
                var offset = 0

                while offset < chunk.samples.count {
                    try Task.checkCancellation()

                    if window.count == windowSampleCount {
                        throw StreamingTranscriptionError.windowLimitReached
                    }

                    if window.isEmpty {
                        let (start, overflow) = chunk.startingSampleIndex.addingReportingOverflow(UInt64(offset))
                        guard !overflow else { throw StreamingTranscriptionError.sampleIndexOverflow }
                        windowStartSample = start
                    }

                    let space = windowSampleCount - window.count
                    let untilInference = inferenceIntervalSampleCount - samplesSinceInference
                    let count = min(space, untilInference, chunk.samples.count - offset)
                    window.append(contentsOf: chunk.samples[offset..<(offset + count)])
                    offset += count
                    samplesSinceInference += count

                    if samplesSinceInference >= inferenceIntervalSampleCount || window.count == windowSampleCount {
                        let outcome = try await inferAndPublish(
                            window: window,
                            startingSample: windowStartSample,
                            isFinal: false,
                            language: language,
                            generation: generation,
                            cancellation: cancellation,
                            transcript: &transcript,
                            lastFinalizedSegment: &lastFinalizedSegment,
                            lastProvisionalText: &lastProvisionalText,
                            hasUnfinalizedSpeech: unfinalizedSpeechThrough != nil || !lastProvisionalText.isEmpty,
                            onEvent: onEvent
                        )
                        if let unresolvedThrough = outcome.unresolvedSpeechThrough {
                            unfinalizedSpeechThrough = max(unfinalizedSpeechThrough ?? 0, unresolvedThrough)
                        }
                        if let protectedEnd = unfinalizedSpeechThrough,
                           let finalizedEnd = lastFinalizedSegment?.audioRange.endSample,
                           UInt64(finalizedEnd) >= protectedEnd {
                            unfinalizedSpeechThrough = nil
                        }
                        compactWindow(
                            &window,
                            startingSample: &windowStartSample,
                            lastFinalizedSegment: lastFinalizedSegment
                        )
                        if outcome.vadSpeechState == .noSpeechDetected,
                           unfinalizedSpeechThrough == nil,
                           lastProvisionalText.isEmpty,
                           window.count == windowSampleCount {
                            compactConfirmedSilence(&window, startingSample: &windowStartSample)
                        }
                        samplesSinceInference = 0
                    }
                }
            }

            try Task.checkCancellation()
            guard receivedAudio else { throw StreamingTranscriptionError.missingAudio }

            if !window.isEmpty {
                let finalOutcome = try await inferAndPublish(
                    window: window,
                    startingSample: windowStartSample,
                    isFinal: true,
                    language: language,
                    generation: generation,
                    cancellation: cancellation,
                    transcript: &transcript,
                    lastFinalizedSegment: &lastFinalizedSegment,
                    lastProvisionalText: &lastProvisionalText,
                    hasUnfinalizedSpeech: unfinalizedSpeechThrough != nil || !lastProvisionalText.isEmpty,
                    onEvent: onEvent
                )
                if !finalOutcome.hasSegments &&
                    (finalOutcome.vadSpeechState == .speechDetected ||
                     (finalOutcome.vadSpeechState == .unknown &&
                      (window.count == windowSampleCount || unfinalizedSpeechThrough != nil))) {
                    throw StreamingTranscriptionError.invalidInferenceResult
                }
            }
            try Task.checkCancellation()
            await reader.value
            return TranscriptionRecognitionResult(text: transcript)
        } catch {
            cancellation.fail(error)
            reader.cancel()
            await reader.value
            throw cancellation.failure() ?? error
        }
    }

    private func validate(_ chunk: AudioCaptureChunk, expectedSample: UInt64) throws {
        guard chunk.sampleRate == Double(WhisperInferenceLimits.sampleRate),
              chunk.channelCount == 1,
              !chunk.samples.isEmpty else {
            throw StreamingTranscriptionError.invalidAudioChunk
        }
        guard chunk.samples.count <= StreamingTranscriptionLimits.maximumChunkSampleCount else {
            throw StreamingTranscriptionError.oversizedAudioChunk(chunk.samples.count)
        }
        if let index = chunk.samples.firstIndex(where: { !$0.isFinite }) {
            throw WhisperInferenceError.nonFiniteAudioSample(index: index)
        }
        guard chunk.startingSampleIndex == expectedSample else {
            throw StreamingTranscriptionError.discontinuousAudio(
                expectedSample: expectedSample,
                actualSample: chunk.startingSampleIndex
            )
        }
    }

    private func inferAndPublish(
        window: [Float],
        startingSample: UInt64,
        isFinal: Bool,
        language: WhisperInferenceLanguage,
        generation: UUID,
        cancellation: StreamingTranscriptionCancellation,
        transcript: inout String,
        lastFinalizedSegment: inout SpeechFinalizedSegment?,
        lastProvisionalText: inout String,
        hasUnfinalizedSpeech: Bool,
        onEvent: @escaping @MainActor @Sendable (TranscriptionRecognitionEvent) -> Void
    ) async throws -> WindowInferenceOutcome {
        let output = try await recognizeWindow(
            samples: window,
            startingSample: startingSample,
            language: language,
            previousSegment: lastFinalizedSegment,
            cancellation: cancellation
        )
        try Task.checkCancellation()

        let (windowEnd, endOverflow) = startingSample.addingReportingOverflow(UInt64(window.count))
        guard !endOverflow, windowEnd <= UInt64(Int64.max) else {
            throw StreamingTranscriptionError.sampleIndexOverflow
        }
        if output.vadSpeechState == .noSpeechDetected, hasUnfinalizedSpeech {
            guard !isFinal else { throw StreamingTranscriptionError.invalidInferenceResult }
            return WindowInferenceOutcome(
                vadSpeechState: .noSpeechDetected, unresolvedSpeechThrough: nil, hasSegments: false
            )
        }
        let lookback = isFinal ? 0 : finalizationLookbackSampleCount
        let safeThrough = windowEnd >= UInt64(lookback) ? windowEnd - UInt64(lookback) : 0

        var pendingSegments: [SpeechFinalizedSegment] = []
        var finalizedAny = false
        for segment in output.segments {
            if isFinal || UInt64(segment.audioRange.endSample) <= safeThrough {
                try append(segment.text, to: &transcript)
                lastFinalizedSegment = segment
                finalizedAny = finalizedAny || !segment.text.isEmpty
            } else {
                pendingSegments.append(segment)
            }
        }

        if finalizedAny {
            onEvent(.finalized(generation: generation, text: transcript))
            lastProvisionalText = ""
        }

        let provisionalText = pendingSegments.map(\.text).joined()
        try validateCombinedTextSize(finalized: transcript, provisional: provisionalText)
        if provisionalText != lastProvisionalText {
            onEvent(.provisional(generation: generation, text: provisionalText))
            lastProvisionalText = provisionalText
        }
        let speechWithoutTimedSegments = output.vadSpeechState == .speechDetected && !output.hasRawSegments
            ? windowEnd
            : nil

        return WindowInferenceOutcome(
            vadSpeechState: output.vadSpeechState,
            unresolvedSpeechThrough: speechWithoutTimedSegments,
            hasSegments: output.hasRawSegments
        )
    }

    private func recognizeWindow(
        samples: [Float],
        startingSample: UInt64,
        language: WhisperInferenceLanguage,
        previousSegment: SpeechFinalizedSegment?,
        cancellation: StreamingTranscriptionCancellation
    ) async throws -> WindowOutput {
        guard !samples.isEmpty,
              samples.count <= StreamingTranscriptionLimits.maximumWindowSampleCount else {
            throw StreamingTranscriptionError.invalidInferenceResult
        }
        guard startingSample <= UInt64(Int64.max) else {
            throw StreamingTranscriptionError.sampleIndexOverflow
        }
        try Task.checkCancellation()

        let inferenceTask = Task.detached(priority: .userInitiated) { [inference] in
            try await inference.transcribe(
                samples: samples,
                sampleRate: Double(WhisperInferenceLimits.sampleRate),
                language: language
            )
        }
        cancellation.install(inference: inferenceTask)
        defer { cancellation.clearInference() }

        let result = try await inferenceTask.value
        try Task.checkCancellation()
        guard result.text.utf8.count <= StreamingTranscriptionLimits.maximumTranscriptUTF8Bytes else {
            throw StreamingTranscriptionError.transcriptTooLarge
        }
        guard result.segments.count <= WhisperInferenceLimits.maximumSegmentCount else {
            throw StreamingTranscriptionError.tooManyInferenceSegments(result.segments.count)
        }
        guard result.vadSpeechState != .noSpeechDetected || (result.text.isEmpty && result.segments.isEmpty) else {
            throw StreamingTranscriptionError.invalidInferenceResult
        }

        var rawByteCount = 0
        var rawTextPieces: [String] = []
        rawTextPieces.reserveCapacity(result.segments.count)
        var candidates: [SpeechFinalizedSegment] = []
        candidates.reserveCapacity(result.segments.count)
        var priorStartTime: TimeInterval = -1
        var priorEndTime: TimeInterval = -1
        let sampleRate = Double(WhisperInferenceLimits.sampleRate)
        let windowDuration = Double(samples.count) / sampleRate
        let windowStart = Int64(startingSample)

        for (index, segment) in result.segments.enumerated() {
            let byteCount = segment.text.utf8.count
            let (nextByteCount, byteOverflow) = rawByteCount.addingReportingOverflow(byteCount)
            guard !byteOverflow,
                  nextByteCount <= StreamingTranscriptionLimits.maximumTranscriptUTF8Bytes else {
                throw StreamingTranscriptionError.transcriptTooLarge
            }
            rawByteCount = nextByteCount
            rawTextPieces.append(segment.text)

            guard segment.startTime.isFinite,
                  segment.endTime.isFinite,
                  segment.startTime >= 0,
                  segment.endTime > segment.startTime,
                  segment.startTime < windowDuration,
                  segment.endTime <= windowDuration + 0.10 + 1e-9,
                  segment.startTime >= priorStartTime,
                  segment.endTime >= priorEndTime else {
                throw StreamingTranscriptionError.invalidInferenceSegment(index: index)
            }

            let localStart = Int64((segment.startTime * sampleRate).rounded(.down))
            let localEnd = min(Int64(samples.count), Int64((segment.endTime * sampleRate).rounded(.up)))
            let (absoluteStart, startOverflow) = windowStart.addingReportingOverflow(localStart)
            let (absoluteEnd, endOverflow) = windowStart.addingReportingOverflow(localEnd)
            guard !startOverflow, !endOverflow else {
                throw StreamingTranscriptionError.sampleIndexOverflow
            }
            do {
                let range = try SpeechAudioSampleRange(
                    startSample: absoluteStart,
                    endSample: absoluteEnd,
                    sampleRate: WhisperInferenceLimits.sampleRate
                )
                candidates.append(SpeechFinalizedSegment(audioRange: range, text: segment.text))
            } catch {
                throw StreamingTranscriptionError.invalidInferenceSegment(index: index)
            }
            priorStartTime = segment.startTime
            priorEndTime = segment.endTime
        }

        guard rawTextPieces.joined().utf8.elementsEqual(result.text.utf8) else {
            throw StreamingTranscriptionError.invalidInferenceResult
        }
        guard result.text.isEmpty || !result.segments.isEmpty else {
            throw StreamingTranscriptionError.invalidInferenceResult
        }

        var normalizedCandidates: [SpeechFinalizedSegment] = []
        normalizedCandidates.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            guard let previous = normalizedCandidates.last,
                  candidate.audioRange.startSample < previous.audioRange.endSample else {
                normalizedCandidates.append(candidate)
                continue
            }

            do {
                let combinedRange = try SpeechAudioSampleRange(
                    startSample: previous.audioRange.startSample,
                    endSample: max(previous.audioRange.endSample, candidate.audioRange.endSample),
                    sampleRate: WhisperInferenceLimits.sampleRate
                )
                normalizedCandidates[normalizedCandidates.count - 1] = SpeechFinalizedSegment(
                    audioRange: combinedRange,
                    text: previous.text + candidate.text
                )
            } catch {
                throw StreamingTranscriptionError.invalidInferenceSegment(index: index)
            }
        }

        var accepted: [SpeechFinalizedSegment] = []
        accepted.reserveCapacity(normalizedCandidates.count)
        var lastSegment = previousSegment
        for candidate in normalizedCandidates {
            if let previous = lastSegment {
                if candidate.audioRange.endSample <= previous.audioRange.endSample { continue }
                guard candidate.audioRange.startSample >= previous.audioRange.endSample else {
                    throw StreamingTranscriptionError.overlappingFinalizedAudio(
                        existingRange: previous.audioRange,
                        incomingRange: candidate.audioRange
                    )
                }
            }
            accepted.append(candidate)
            lastSegment = candidate
        }

        return WindowOutput(
            segments: accepted,
            vadSpeechState: result.vadSpeechState,
            hasRawSegments: !result.segments.isEmpty
        )
    }

    private func compactConfirmedSilence(_ window: inout [Float], startingSample: inout UInt64) {
        guard window.count > 1 else { return }
        let lookback = max(1, max(finalizationLookbackSampleCount, finalizationContextOverlapSampleCount))
        let retained = min(window.count - 1, lookback)
        let removable = window.count - retained
        window.removeFirst(removable)
        startingSample += UInt64(removable)
    }

    private func compactWindow(
        _ window: inout [Float],
        startingSample: inout UInt64,
        lastFinalizedSegment: SpeechFinalizedSegment?
    ) {
        guard let lastFinalizedSegment else { return }
        let finalizedEnd = UInt64(lastFinalizedSegment.audioRange.endSample)
        let desiredStart = finalizedEnd > UInt64(finalizationContextOverlapSampleCount)
            ? finalizedEnd - UInt64(finalizationContextOverlapSampleCount)
            : 0
        guard desiredStart > startingSample else { return }
        let removable = min(window.count, Int(desiredStart - startingSample))
        guard removable > 0 else { return }
        window.removeFirst(removable)
        startingSample += UInt64(removable)
    }

    private func append(_ text: String, to transcript: inout String) throws {
        let (newByteCount, overflow) = transcript.utf8.count.addingReportingOverflow(text.utf8.count)
        guard !overflow, newByteCount <= StreamingTranscriptionLimits.maximumTranscriptUTF8Bytes else {
            throw StreamingTranscriptionError.transcriptTooLarge
        }
        transcript.append(contentsOf: text)
    }

    private func validateCombinedTextSize(finalized: String, provisional: String) throws {
        let (combined, overflow) = finalized.utf8.count.addingReportingOverflow(provisional.utf8.count)
        guard !overflow, combined <= StreamingTranscriptionLimits.maximumTranscriptUTF8Bytes else {
            throw StreamingTranscriptionError.transcriptTooLarge
        }
    }
}

private actor StreamingAudioBacklog {
    private let maximumSampleCount: Int
    private var chunks: [AudioCaptureChunk] = []
    private var pendingSampleCount = 0
    private var isFinished = false
    private var terminalError: (any Error)?
    private var waiter: CheckedContinuation<AudioCaptureChunk?, any Error>?

    init(maximumSampleCount: Int) {
        self.maximumSampleCount = maximumSampleCount
    }

    func enqueue(_ chunk: AudioCaptureChunk) throws {
        guard !isFinished else { throw CancellationError() }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: chunk)
            return
        }

        let (nextCount, overflow) = pendingSampleCount.addingReportingOverflow(chunk.samples.count)
        guard !overflow, nextCount <= maximumSampleCount else {
            throw StreamingTranscriptionError.audioBacklogExceeded(
                pendingSampleCount: pendingSampleCount,
                incomingSampleCount: chunk.samples.count,
                maximumSampleCount: maximumSampleCount
            )
        }
        chunks.append(chunk)
        pendingSampleCount = nextCount
    }

    func next() async throws -> AudioCaptureChunk? {
        if !chunks.isEmpty {
            let chunk = chunks.removeFirst()
            pendingSampleCount -= chunk.samples.count
            return chunk
        }
        if let terminalError { throw terminalError }
        if isFinished { return nil }
        return try await withCheckedThrowingContinuation { waiter in
            self.waiter = waiter
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        guard !isFinished else { return }
        isFinished = true
        terminalError = error
        if error != nil {
            chunks.removeAll(keepingCapacity: false)
            pendingSampleCount = 0
        }
        guard chunks.isEmpty, let waiter else { return }
        self.waiter = nil
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume(returning: nil)
        }
    }
}

nonisolated private final class StreamingTranscriptionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var terminalError: (any Error)?
    private var worker: Task<TranscriptionRecognitionResult, any Error>?
    private var reader: Task<Void, Never>?
    private var inference: Task<WhisperInferenceResult, any Error>?

    func install(worker: Task<TranscriptionRecognitionResult, any Error>) {
        lock.lock()
        let shouldCancel = cancelled
        self.worker = worker
        lock.unlock()
        if shouldCancel { worker.cancel() }
    }

    func install(reader: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = cancelled
        self.reader = reader
        lock.unlock()
        if shouldCancel { reader.cancel() }
    }

    func install(inference: Task<WhisperInferenceResult, any Error>) {
        lock.lock()
        let shouldCancel = cancelled
        self.inference = inference
        lock.unlock()
        if shouldCancel { inference.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let worker = self.worker
        let reader = self.reader
        let inference = self.inference
        lock.unlock()
        worker?.cancel()
        reader?.cancel()
        inference?.cancel()
    }

    func fail(_ error: any Error) {
        lock.lock()
        if terminalError == nil { terminalError = error }
        lock.unlock()
        cancel()
    }

    func failure() -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return terminalError
    }

    func clearWorker() {
        lock.lock()
        worker = nil
        lock.unlock()
    }

    func clearReader() {
        lock.lock()
        reader = nil
        lock.unlock()
    }

    func clearInference() {
        lock.lock()
        inference = nil
        lock.unlock()
    }
}
