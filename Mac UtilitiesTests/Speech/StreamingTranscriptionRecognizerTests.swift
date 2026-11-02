import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct StreamingTranscriptionRecognizerTests {
    @MainActor
    private final class EventRecorder {
        private(set) var events: [TranscriptionRecognitionEvent] = []
        private var eventWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        func record(_ event: TranscriptionRecognitionEvent) {
            events.append(event)
            guard let eventWaiter, events.count >= eventWaiter.count else { return }
            self.eventWaiter = nil
            eventWaiter.continuation.resume()
        }

        func waitForEventCount(_ count: Int) async {
            guard events.count < count else { return }
            await withCheckedContinuation { continuation in
                eventWaiter = (count, continuation)
            }
        }
    }

    private struct InferenceCall: Equatable, Sendable {
        let samples: [Float]
        let language: WhisperInferenceLanguage
    }

    private actor FakeInference: StreamingTranscriptionInferring {
        private let results: [WhisperInferenceResult]
        private let blocksUntilCancelled: Bool
        private let holdsFirstResponse: Bool
        private let failureAtCall: Int?
        private var calls: [InferenceCall] = []
        private var nextResult = 0
        private var cancellationCount = 0
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var heldResponse: CheckedContinuation<WhisperInferenceResult, any Error>?
        private var heldResponseWaiter: CheckedContinuation<Void, Never>?

        init(
            results: [WhisperInferenceResult],
            blocksUntilCancelled: Bool = false,
            holdsFirstResponse: Bool = false,
            failureAtCall: Int? = nil
        ) {
            self.results = results
            self.blocksUntilCancelled = blocksUntilCancelled
            self.holdsFirstResponse = holdsFirstResponse
            self.failureAtCall = failureAtCall
        }

        func transcribe(
            samples: [Float],
            sampleRate: Double,
            language: WhisperInferenceLanguage
        ) async throws -> WhisperInferenceResult {
            #expect(sampleRate == 16_000)
            calls.append(InferenceCall(samples: samples, language: language))
            startWaiter?.resume()
            startWaiter = nil

            if calls.count == failureAtCall { throw TestFailure.inferenceFailed }

            if blocksUntilCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    cancellationCount += 1
                    throw error
                }
            }

            guard nextResult < results.count else {
                throw TestFailure.unexpectedInference
            }
            let result = results[nextResult]
            nextResult += 1

            if holdsFirstResponse, calls.count == 1 {
                return try await withCheckedThrowingContinuation { continuation in
                    heldResponse = continuation
                    heldResponseWaiter?.resume()
                    heldResponseWaiter = nil
                }
            }
            return result
        }

        func recordedCalls() -> [InferenceCall] { calls }
        func observedCancellationCount() -> Int { cancellationCount }

        func waitForFirstCall() async {
            guard calls.isEmpty else { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func waitForHeldResponse() async {
            guard heldResponse == nil else { return }
            await withCheckedContinuation { heldResponseWaiter = $0 }
        }

        func releaseHeldResponse() {
            heldResponse?.resume(returning: results[0])
            heldResponse = nil
        }
    }

    private enum TestFailure: Error {
        case unexpectedInference
        case inferenceFailed
    }

    private func timedResult(_ text: String, durationSamples: Int) -> WhisperInferenceResult {
        result([(0, durationSamples, text)])
    }

    private func result(
        _ segments: [(start: Int, end: Int, text: String)],
        vadSpeechState: WhisperInferenceSpeechState = .unknown
    ) -> WhisperInferenceResult {
        WhisperInferenceResult(
            text: segments.map(\.text).joined(),
            segments: segments.map {
                WhisperInferenceSegment(
                    startTime: Double($0.start) / 16_000,
                    endTime: Double($0.end) / 16_000,
                    text: $0.text
                )
            },
            vadSpeechState: vadSpeechState
        )
    }

    private func finishedStream(_ chunks: [AudioCaptureChunk]) -> AudioCaptureStream {
        let (stream, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .unbounded)
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
        return stream
    }

    private func chunk(_ start: UInt64, _ samples: [Float]) -> AudioCaptureChunk {
        AudioCaptureChunk(startingSampleIndex: start, sampleRate: 16_000, samples: samples)
    }

    private func testRecognizer(
        inference: FakeInference,
        windowSampleCount: Int = 8,
        inferenceIntervalSampleCount: Int = 4,
        finalizationLookbackSampleCount: Int = 0,
        finalizationContextOverlapSampleCount: Int = 0,
        maximumPendingSampleCount: Int = 16
    ) throws -> StreamingTranscriptionRecognizer {
        try StreamingTranscriptionRecognizer(
            inference: inference,
            windowSampleCount: windowSampleCount,
            inferenceIntervalSampleCount: inferenceIntervalSampleCount,
            finalizationLookbackSampleCount: finalizationLookbackSampleCount,
            finalizationContextOverlapSampleCount: finalizationContextOverlapSampleCount,
            maximumPendingSampleCount: maximumPendingSampleCount
        )
    }

    @Test
    func vadTimestampSlightlyBeyondAudioIsClippedToTheCapturedWindow() async throws {
        let inference = FakeInference(results: [WhisperInferenceResult(
            text: "hello",
            segments: [WhisperInferenceSegment(startTime: 1.99, endTime: 2.09, text: "hello")]
        )])
        let recognizer = try StreamingTranscriptionRecognizer(
            inference: inference, windowSampleCount: 32_001,
            inferenceIntervalSampleCount: 32_001, finalizationLookbackSampleCount: 0,
            finalizationContextOverlapSampleCount: 0, maximumPendingSampleCount: 32_001
        )
        let samples = [Float](repeating: 0, count: 16_000)
        let output = try await recognizer.transcribe(
            audio: finishedStream([chunk(0, samples), chunk(16_000, samples)]),
            language: .english, generation: UUID(), onEvent: { _ in }
        )
        #expect(output.text == "hello")
    }

    @Test
    func timestampBeyondVadMinimumDurationIsRejected() async throws {
        let inference = FakeInference(results: [WhisperInferenceResult(
            text: "hello",
            segments: [WhisperInferenceSegment(startTime: 1.99, endTime: 2.11, text: "hello")]
        )])
        let recognizer = try StreamingTranscriptionRecognizer(
            inference: inference, windowSampleCount: 32_001,
            inferenceIntervalSampleCount: 32_001, finalizationLookbackSampleCount: 0,
            finalizationContextOverlapSampleCount: 0, maximumPendingSampleCount: 32_001
        )
        let samples = [Float](repeating: 0, count: 16_000)
        do {
            _ = try await recognizer.transcribe(
                audio: finishedStream([chunk(0, samples), chunk(16_000, samples)]),
                language: .english, generation: UUID(), onEvent: { _ in }
            )
            Issue.record("A timestamp exceeding the native VAD limit must fail.")
        } catch let error as StreamingTranscriptionError {
            #expect(error == .invalidInferenceSegment(index: 0))
        }
    }

    @Test
    func normalStreamEndFlushesShortUrduAudio() async throws {
        let inference = FakeInference(results: [timedResult("اردو", durationSamples: 2)])
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 8,
            inferenceIntervalSampleCount: 4,
            finalizationLookbackSampleCount: 1,
            finalizationContextOverlapSampleCount: 1
        )
        let generation = UUID()
        let recorder = EventRecorder()

        let result = try await recognizer.transcribe(
            audio: finishedStream([chunk(0, [0.25, -0.25])]),
            language: .urdu,
            generation: generation,
            onEvent: { recorder.record($0) }
        )

        #expect(result.text == "اردو")
        #expect(recorder.events == [.finalized(generation: generation, text: "اردو")])
        #expect(await inference.recordedCalls() == [
            InferenceCall(samples: [0.25, -0.25], language: .urdu)
        ])
    }

    @Test
    func emitsProvisionalTextBeforeTheAudioStreamFinishes() async throws {
        let inference = FakeInference(results: [
            timedResult("hello", durationSamples: 4),
            timedResult("hello", durationSamples: 4)
        ])
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 8,
            inferenceIntervalSampleCount: 4,
            finalizationLookbackSampleCount: 1,
            finalizationContextOverlapSampleCount: 1
        )
        let generation = UUID()
        let recorder = EventRecorder()
        let (audio, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .unbounded)

        let recognition = Task { @MainActor in
            try await recognizer.transcribe(
                audio: audio,
                language: .english,
                generation: generation,
                onEvent: { recorder.record($0) }
            )
        }
        continuation.yield(chunk(0, [0, 1, 2, 3]))

        await inference.waitForFirstCall()
        await recorder.waitForEventCount(1)
        #expect(recorder.events == [.provisional(generation: generation, text: "hello")])

        continuation.finish()
        let final = try await recognition.value
        #expect(final.text == "hello")
        #expect(recorder.events == [
            .provisional(generation: generation, text: "hello"),
            .finalized(generation: generation, text: "hello")
        ])
    }

    @Test
    func repeatedSegmentsAcrossRollingWindowsAreFinalizedOnlyOnce() async throws {
        let inference = FakeInference(results: [
            result([(0, 2, "one"), (2, 4, " two")]),
            result([(0, 2, " two"), (2, 4, " three"), (4, 6, " four")]),
            result([(0, 2, " four")])
        ])
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 8,
            inferenceIntervalSampleCount: 4,
            finalizationLookbackSampleCount: 0,
            finalizationContextOverlapSampleCount: 2
        )
        let generation = UUID()
        let recorder = EventRecorder()

        let transcript = try await recognizer.transcribe(
            audio: finishedStream([
                chunk(0, [0, 1, 2, 3]),
                chunk(4, [4, 5, 6, 7])
            ]),
            language: .english,
            generation: generation,
            onEvent: { recorder.record($0) }
        )

        #expect(transcript.text == "one two three four")
        #expect(recorder.events == [
            .finalized(generation: generation, text: "one two"),
            .finalized(generation: generation, text: "one two three four")
        ])
        #expect(await inference.recordedCalls().map(\.samples) == [
            [0, 1, 2, 3],
            [2, 3, 4, 5, 6, 7],
            [6, 7]
        ])
    }

    @Test
    func ordinaryPauseAfterFinalizedSpeechAllowsLaterSpeechToFinish() async throws {
        let silence = WhisperInferenceResult(text: "", segments: [], vadSpeechState: .noSpeechDetected)
        let inference = FakeInference(results: [
            result([(0, 2, "first")], vadSpeechState: .speechDetected),
            silence,
            silence,
            result([(1, 3, " second")], vadSpeechState: .speechDetected)
        ])
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 8,
            inferenceIntervalSampleCount: 4,
            finalizationLookbackSampleCount: 0,
            finalizationContextOverlapSampleCount: 0
        )
        let generation = UUID()
        let recorder = EventRecorder()

        let transcript = try await recognizer.transcribe(
            audio: finishedStream([
                chunk(0, [0, 1, 2, 3]),
                chunk(4, [4, 5, 6, 7]),
                chunk(8, [8, 9, 10, 11])
            ]),
            language: .english,
            generation: generation,
            onEvent: { recorder.record($0) }
        )

        #expect(transcript.text == "first second")
        #expect(recorder.events == [
            .finalized(generation: generation, text: "first"),
            .finalized(generation: generation, text: "first second")
        ])
        #expect(await inference.recordedCalls().map(\.samples) == [
            [0, 1, 2, 3],
            [2, 3, 4, 5, 6, 7],
            [2, 3, 4, 5, 6, 7, 8, 9],
            [9, 10, 11]
        ])
    }

    @Test
    func pauseAfterRollingTimestampDriftDoesNotKeepStaleUnfinalizedMarker() async throws {
        let inference = FakeInference(results: [
            result([(0, 14_400, "speech")], vadSpeechState: .speechDetected),
            result([(0, 14_240, "speech")], vadSpeechState: .speechDetected),
            WhisperInferenceResult(text: "", segments: [], vadSpeechState: .noSpeechDetected)
        ])
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 32_000,
            inferenceIntervalSampleCount: 16_000,
            finalizationLookbackSampleCount: 4_000,
            finalizationContextOverlapSampleCount: 0,
            maximumPendingSampleCount: 32_000
        )
        let generation = UUID()
        let recorder = EventRecorder()
        let halfSecond = [Float](repeating: 0.1, count: 16_000)

        let transcript = try await recognizer.transcribe(
            audio: finishedStream([
                chunk(0, halfSecond),
                chunk(16_000, halfSecond)
            ]),
            language: .english,
            generation: generation,
            onEvent: { recorder.record($0) }
        )

        #expect(transcript.text == "speech")
        #expect(recorder.events == [
            .provisional(generation: generation, text: "speech"),
            .finalized(generation: generation, text: "speech")
        ])
        #expect(await inference.recordedCalls().map(\.samples.count) == [16_000, 32_000, 17_760])
    }

    @Test
    func stopFlushesTheUnfinalizedTail() async throws {
        let inference = FakeInference(results: [
            timedResult("tail", durationSamples: 3),
            timedResult("tail", durationSamples: 3)
        ])
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 8,
            inferenceIntervalSampleCount: 3,
            finalizationLookbackSampleCount: 2,
            finalizationContextOverlapSampleCount: 1
        )
        let generation = UUID()
        let recorder = EventRecorder()
        let (audio, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .unbounded)
        let recognition = Task { @MainActor in
            try await recognizer.transcribe(
                audio: audio,
                language: .english,
                generation: generation,
                onEvent: { recorder.record($0) }
            )
        }

        continuation.yield(chunk(0, [0.1, 0.2, 0.3]))
        await inference.waitForFirstCall()
        await recorder.waitForEventCount(1)
        #expect(recorder.events == [.provisional(generation: generation, text: "tail")])

        // Finishing the capture stream models a normal user Stop: drain, re-infer and finalize the tail.
        continuation.finish()
        let completed = try await recognition.value
        #expect(completed.text == "tail")
        #expect(recorder.events.last == .finalized(generation: generation, text: "tail"))
    }

    @Test
    func boundedBacklogReportsOverloadWhileInferenceIsHeld() async throws {
        let inference = FakeInference(
            results: [
                timedResult("first", durationSamples: 4),
                timedResult("queued", durationSamples: 4)
            ],
            holdsFirstResponse: true
        )
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 8,
            inferenceIntervalSampleCount: 4,
            finalizationLookbackSampleCount: 0,
            finalizationContextOverlapSampleCount: 0,
            maximumPendingSampleCount: 4
        )
        let generation = UUID()
        let (audio, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .unbounded)
        let recognition = Task { @MainActor in
            try await recognizer.transcribe(
                audio: audio,
                language: .english,
                generation: generation,
                onEvent: { _ in }
            )
        }

        continuation.yield(chunk(0, [0, 1, 2, 3]))
        await inference.waitForHeldResponse()
        continuation.yield(chunk(4, [4, 5, 6, 7]))
        continuation.yield(chunk(8, [8]))
        continuation.finish()
        // Let the independent reader enqueue and reject the over-limit chunk while inference remains held.
        try await Task.sleep(for: .milliseconds(100))
        await inference.releaseHeldResponse()

        do {
            _ = try await recognition.value
            Issue.record("Backlog overflow must not return a partial transcript as success.")
        } catch let error as StreamingTranscriptionError {
            #expect(error == .audioBacklogExceeded(
                pendingSampleCount: 4,
                incomingSampleCount: 1,
                maximumSampleCount: 4
            ))
        }
    }

    @Test
    func overlappingTimedSegmentsCoalesceTheirRangesWithoutLosingText() async throws {
        let inference = FakeInference(results: [
            result([(0, 3, "one"), (2, 4, " two")])
        ])
        let recognizer = try testRecognizer(inference: inference, windowSampleCount: 4)
        let generation = UUID()
        let recorder = EventRecorder()

        let transcript = try await recognizer.transcribe(
            audio: finishedStream([chunk(0, [0, 1, 2, 3])]),
            language: .english,
            generation: generation,
            onEvent: { recorder.record($0) }
        )

        #expect(transcript.text == "one two")
        #expect(recorder.events == [.finalized(generation: generation, text: "one two")])
    }

    @Test
    func partialOverlapWithPreviouslyFinalizedAudioStillFailsClosed() async throws {
        let inference = FakeInference(results: [
            result([(0, 3, "one")]),
            result([(1, 4, " two")])
        ])
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 8,
            inferenceIntervalSampleCount: 4,
            finalizationLookbackSampleCount: 0,
            finalizationContextOverlapSampleCount: 2
        )
        let generation = UUID()
        let recorder = EventRecorder()

        do {
            _ = try await recognizer.transcribe(
                audio: finishedStream([
                    chunk(0, [0, 1, 2, 3]),
                    chunk(4, [4, 5, 6, 7])
                ]),
                language: .english,
                generation: generation,
                onEvent: { recorder.record($0) }
            )
            Issue.record("Ambiguous text crossing an already finalized boundary must not be dropped.")
        } catch let error as StreamingTranscriptionError {
            guard case let .overlappingFinalizedAudio(existingRange, incomingRange) = error else {
                Issue.record("Unexpected streaming error: \(error)")
                return
            }
            #expect(existingRange.startSample == 0)
            #expect(existingRange.endSample == 3)
            #expect(incomingRange.startSample == 2)
            #expect(incomingRange.endSample == 5)
        }
        #expect(recorder.events == [.finalized(generation: generation, text: "one")])
    }

    @Test
    func discontinuousCaptureTimelineFailsBeforeInference() async throws {
        let inference = FakeInference(results: [])
        let recognizer = try testRecognizer(inference: inference, windowSampleCount: 4)

        do {
            _ = try await recognizer.transcribe(
                audio: finishedStream([chunk(1, [0.1, 0.2])]),
                language: .english,
                generation: UUID(),
                onEvent: { _ in }
            )
            Issue.record("A skipped sample range must fail.")
        } catch let error as StreamingTranscriptionError {
            #expect(error == .discontinuousAudio(expectedSample: 0, actualSample: 1))
        }
        #expect(await inference.recordedCalls().isEmpty)
    }

    @Test
    func reportedCaptureOverflowNeverReturnsPartialAudioAsSuccess() async throws {
        let (audio, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .bufferingOldest(1))
        let firstYield = continuation.yield(chunk(0, [0.1]))
        let overflowYield = continuation.yield(chunk(1, [0.2]))
        if case .enqueued = firstYield {} else { Issue.record("First test chunk should fit in the bounded stream.") }
        if case .dropped = overflowYield {} else { Issue.record("The full bounded stream should report a dropped yield.") }
        continuation.finish(throwing: AudioCaptureFailure.consumerTooSlow)

        let inference = FakeInference(results: [])
        let recognizer = try testRecognizer(inference: inference, windowSampleCount: 4)
        do {
            _ = try await recognizer.transcribe(
                audio: audio,
                language: .english,
                generation: UUID(),
                onEvent: { _ in }
            )
            Issue.record("Capture overflow must not be reported as a successful transcript.")
        } catch let error as AudioCaptureFailure {
            #expect(error == .consumerTooSlow)
        }
        #expect(await inference.recordedCalls().isEmpty)
    }

    @Test
    func cancelAbortsAndJoinsInferenceWithoutFinalEvents() async throws {
        let inference = FakeInference(results: [], blocksUntilCancelled: true)
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 1,
            inferenceIntervalSampleCount: 1
        )
        let generation = UUID()
        let recorder = EventRecorder()
        let audio = finishedStream([chunk(0, [0.1])])
        let recognition = Task { @MainActor in
            try await recognizer.transcribe(
                audio: audio,
                language: .urdu,
                generation: generation,
                onEvent: { recorder.record($0) }
            )
        }

        await inference.waitForFirstCall()
        await recognizer.cancel(generation: generation)
        do {
            _ = try await recognition.value
            Issue.record("Cancelled inference must not return a transcript.")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await inference.observedCancellationCount() == 1)
        #expect(recorder.events.isEmpty)
    }

    @Test
    func invalidProductionWindowSizeIsRejected() {
        let inference = FakeInference(results: [])
        #expect(throws: StreamingTranscriptionError.self) {
            try StreamingTranscriptionRecognizer(inference: inference, windowSampleCount: 0)
        }
        #expect(throws: StreamingTranscriptionError.self) {
            try StreamingTranscriptionRecognizer(
                inference: inference,
                windowSampleCount: StreamingTranscriptionLimits.maximumWindowSampleCount + 1
            )
        }
    }

    @Test
    func oversizedInputChunkIsRejectedBeforeBuffering() async throws {
        let inference = FakeInference(results: [])
        let recognizer = try testRecognizer(inference: inference, windowSampleCount: 4)
        let oversized = chunk(
            0,
            Array(repeating: Float.zero, count: StreamingTranscriptionLimits.maximumChunkSampleCount + 1)
        )

        do {
            _ = try await recognizer.transcribe(
                audio: finishedStream([oversized]),
                language: .english,
                generation: UUID(),
                onEvent: { _ in }
            )
            Issue.record("An oversized audio chunk must fail before it is accumulated.")
        } catch let error as StreamingTranscriptionError {
            #expect(error == .oversizedAudioChunk(StreamingTranscriptionLimits.maximumChunkSampleCount + 1))
        }
        #expect(await inference.recordedCalls().isEmpty)
    }

    @Test
    func emptyInferenceResultRemainsAnEmptyTranscript() async throws {
        let inference = FakeInference(results: [timedResult("", durationSamples: 3)])
        let recognizer = try testRecognizer(inference: inference, windowSampleCount: 4)
        let recorder = EventRecorder()

        let result = try await recognizer.transcribe(
            audio: finishedStream([chunk(0, [0, 0, 0])]),
            language: .english,
            generation: UUID(),
            onEvent: { recorder.record($0) }
        )

        #expect(result.text.isEmpty)
        #expect(recorder.events.isEmpty)
    }

    @Test(arguments: [WhisperInferenceSpeechState.unknown, .speechDetected])
    func fullWindowWithoutVerifiedSilenceFailsWithoutReinferringOrDiscardingAudio(
        speechState: WhisperInferenceSpeechState
    ) async throws {
        let noOutput = WhisperInferenceResult(text: "", segments: [], vadSpeechState: speechState)
        let inference = FakeInference(results: [noOutput])
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 4,
            inferenceIntervalSampleCount: 4,
            finalizationLookbackSampleCount: 0,
            finalizationContextOverlapSampleCount: 0,
            maximumPendingSampleCount: 8
        )
        let recorder = EventRecorder()

        do {
            _ = try await recognizer.transcribe(
                audio: finishedStream([chunk(0, [0, 0, 0, 0, 0])]),
                language: .english,
                generation: UUID(),
                onEvent: { recorder.record($0) }
            )
            Issue.record("No-output inference is not verified evidence that buffered audio is silence.")
        } catch let error as StreamingTranscriptionError {
            #expect(error == .windowLimitReached)
        }

        #expect(await inference.recordedCalls().map(\.samples) == [[0, 0, 0, 0]])
        #expect(recorder.events.isEmpty)
    }

    @Test(arguments: [WhisperInferenceSpeechState.unknown, .speechDetected])
    func stoppingAtFullWindowWithoutVerifiedSilenceDoesNotReturnEmptySuccess(
        speechState: WhisperInferenceSpeechState
    ) async throws {
        let noOutput = WhisperInferenceResult(text: "", segments: [], vadSpeechState: speechState)
        let inference = FakeInference(results: [noOutput, noOutput])
        let recognizer = try testRecognizer(inference: inference, windowSampleCount: 4)

        do {
            _ = try await recognizer.transcribe(
                audio: finishedStream([chunk(0, [0, 0, 0, 0])]),
                language: .english, generation: UUID(), onEvent: { _ in }
            )
            Issue.record("Unverified no-output audio must not become an empty success at the window limit.")
        } catch let error as StreamingTranscriptionError {
            #expect(error == .invalidInferenceResult)
        }
    }

    @Test
    func confirmedSilenceBeyondOneWindowCanFinishEmpty() async throws {
        let silence = WhisperInferenceResult(text: "", segments: [], vadSpeechState: .noSpeechDetected)
        let inference = FakeInference(results: [silence, silence, silence, silence])
        let recognizer = try testRecognizer(
            inference: inference, windowSampleCount: 4, inferenceIntervalSampleCount: 4,
            maximumPendingSampleCount: 16
        )

        let result = try await recognizer.transcribe(
            audio: finishedStream([chunk(0, Array(repeating: 0, count: 10))]),
            language: .english, generation: UUID(), onEvent: { _ in }
        )

        #expect(result.text.isEmpty)
        #expect(await inference.recordedCalls().map(\.samples.count) == [4, 4, 4, 1])
    }

    @Test
    func confirmedSilenceAdvancesAcrossWindowsAndRetainsOnsetForLaterSpeech() async throws {
        let silence = WhisperInferenceResult(text: "", segments: [], vadSpeechState: .noSpeechDetected)
        let speech = result([(0, 8, "speech")], vadSpeechState: .speechDetected)
        let inference = FakeInference(results: [silence, silence, silence, silence, silence, speech, speech])
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 8,
            inferenceIntervalSampleCount: 4,
            finalizationLookbackSampleCount: 2,
            finalizationContextOverlapSampleCount: 2,
            maximumPendingSampleCount: 32
        )
        let samples = (0..<20).map { Float($0) }
        let generation = UUID()
        let recorder = EventRecorder()

        let transcript = try await recognizer.transcribe(
            audio: finishedStream([chunk(0, samples)]),
            language: .english,
            generation: generation,
            onEvent: { recorder.record($0) }
        )

        #expect(transcript.text == "speech")
        #expect(recorder.events == [
            .provisional(generation: generation, text: "speech"),
            .finalized(generation: generation, text: "speech")
        ])
        #expect(await inference.recordedCalls().map(\.samples) == [
            Array(samples[0..<4]), Array(samples[0..<8]),
            Array(samples[6..<12]), Array(samples[6..<14]),
            Array(samples[12..<18]), Array(samples[12..<20]), Array(samples[12..<20])
        ])
    }

    @Test
    func inferenceFailurePropagatesWithoutAdvancingSilence() async throws {
        let silence = WhisperInferenceResult(text: "", segments: [], vadSpeechState: .noSpeechDetected)
        let inference = FakeInference(results: [silence], failureAtCall: 2)
        let recognizer = try testRecognizer(
            inference: inference, windowSampleCount: 4, inferenceIntervalSampleCount: 2,
            maximumPendingSampleCount: 8
        )
        let recorder = EventRecorder()

        do {
            _ = try await recognizer.transcribe(
                audio: finishedStream([chunk(0, [0, 1, 2, 3, 4])]),
                language: .english, generation: UUID(), onEvent: { recorder.record($0) }
            )
            Issue.record("A VAD or inference error must not be treated as silence.")
        } catch TestFailure.inferenceFailed {
            // The failure is preserved instead of advancing the audio window.
        }
        #expect(await inference.recordedCalls().map(\.samples) == [[0, 1], [0, 1, 2, 3]])
        #expect(recorder.events.isEmpty)
    }

    @Test
    func laterNoSpeechResultDoesNotDiscardEarlierDetectedSpeechWithoutOutput() async throws {
        let detected = WhisperInferenceResult(text: "", segments: [], vadSpeechState: .speechDetected)
        let silence = WhisperInferenceResult(text: "", segments: [], vadSpeechState: .noSpeechDetected)
        let inference = FakeInference(results: [detected, silence])
        let recognizer = try testRecognizer(
            inference: inference, windowSampleCount: 4, inferenceIntervalSampleCount: 2,
            maximumPendingSampleCount: 8
        )
        let recorder = EventRecorder()

        do {
            _ = try await recognizer.transcribe(
                audio: finishedStream([chunk(0, [0, 1, 2, 3, 4])]),
                language: .english, generation: UUID(), onEvent: { recorder.record($0) }
            )
            Issue.record("A later no-speech result must not discard earlier detected speech.")
        } catch let error as StreamingTranscriptionError {
            #expect(error == .windowLimitReached)
        }
        #expect(await inference.recordedCalls().map(\.samples) == [[0, 1], [0, 1, 2, 3]])
        #expect(recorder.events.isEmpty)
    }

    @Test
    func laterNoSpeechResultDoesNotDiscardAnEarlierProvisionalSegment() async throws {
        let provisional = result([(0, 2, "possible speech")])
        let silence = WhisperInferenceResult(text: "", segments: [], vadSpeechState: .noSpeechDetected)
        let inference = FakeInference(results: [provisional, silence])
        let recognizer = try testRecognizer(
            inference: inference, windowSampleCount: 4, inferenceIntervalSampleCount: 2,
            finalizationLookbackSampleCount: 2, maximumPendingSampleCount: 8
        )
        let recorder = EventRecorder()
        let generation = UUID()

        do {
            _ = try await recognizer.transcribe(
                audio: finishedStream([chunk(0, [0, 1, 2, 3, 4])]),
                language: .english, generation: generation, onEvent: { recorder.record($0) }
            )
            Issue.record("A no-speech result must not discard an earlier provisional segment.")
        } catch let error as StreamingTranscriptionError {
            #expect(error == .windowLimitReached)
        }
        #expect(recorder.events == [.provisional(generation: generation, text: "possible speech")])
        #expect(await inference.recordedCalls().map(\.samples) == [[0, 1], [0, 1, 2, 3]])
    }

    @Test
    func stoppingAfterContradictoryNoSpeechDoesNotReturnAnEmptySuccess() async throws {
        let detected = WhisperInferenceResult(text: "", segments: [], vadSpeechState: .speechDetected)
        let silence = WhisperInferenceResult(text: "", segments: [], vadSpeechState: .noSpeechDetected)
        let inference = FakeInference(results: [detected, silence, silence])
        let recognizer = try testRecognizer(
            inference: inference, windowSampleCount: 4, inferenceIntervalSampleCount: 2,
            maximumPendingSampleCount: 8
        )

        do {
            _ = try await recognizer.transcribe(
                audio: finishedStream([chunk(0, [0, 1, 2, 3])]),
                language: .english, generation: UUID(), onEvent: { _ in }
            )
            Issue.record("A contradictory no-speech result must not become an empty success.")
        } catch let error as StreamingTranscriptionError {
            #expect(error == .invalidInferenceResult)
        }
    }

    @Test(arguments: ["speech", ""])
    func contradictoryNoSpeechResultCannotDiscardTranscriptSegments(text: String) async throws {
        let inference = FakeInference(results: [result([(0, 4, text)], vadSpeechState: .noSpeechDetected)])
        let recognizer = try testRecognizer(inference: inference, windowSampleCount: 4)
        let recorder = EventRecorder()

        do {
            _ = try await recognizer.transcribe(
                audio: finishedStream([chunk(0, [0, 1, 2, 3, 4])]),
                language: .english, generation: UUID(), onEvent: { recorder.record($0) }
            )
            Issue.record("Contradictory VAD and transcript output must fail.")
        } catch let error as StreamingTranscriptionError {
            #expect(error == .invalidInferenceResult)
        }
        #expect(recorder.events.isEmpty)
    }

    @Test
    func exactWindowEndReinfersTailSoEarlierNoOutputCannotDiscardSpeech() async throws {
        let inference = FakeInference(results: [
            WhisperInferenceResult(text: "", segments: []),
            timedResult("speech", durationSamples: 4)
        ])
        let recognizer = try testRecognizer(
            inference: inference,
            windowSampleCount: 4,
            inferenceIntervalSampleCount: 4,
            finalizationLookbackSampleCount: 0,
            finalizationContextOverlapSampleCount: 0,
            maximumPendingSampleCount: 8
        )
        let generation = UUID()
        let recorder = EventRecorder()

        let result = try await recognizer.transcribe(
            audio: finishedStream([chunk(0, [0.1, 0.2, 0.3, 0.4])]),
            language: .english,
            generation: generation,
            onEvent: { recorder.record($0) }
        )

        #expect(result.text == "speech")
        #expect(recorder.events == [.finalized(generation: generation, text: "speech")])
        #expect(await inference.recordedCalls().map(\.samples) == [
            [0.1, 0.2, 0.3, 0.4],
            [0.1, 0.2, 0.3, 0.4]
        ])
    }
}
