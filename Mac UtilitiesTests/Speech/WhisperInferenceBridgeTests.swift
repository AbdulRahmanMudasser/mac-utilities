import Dispatch
import Foundation
import Testing
@testable import Mac_Utilities

struct WhisperInferenceBridgeTests {
    @Test
    func languageIsExplicitlyLimitedToEnglishAndUrdu() {
        #expect(WhisperInferenceLanguage.allCases.map(\.rawValue) == ["en", "ur"])
    }

    @Test
    func fakeInferenceResultsDefaultVADSpeechStateToUnknown() {
        let result = WhisperInferenceResult(text: "fixture", segments: [])

        #expect(result.vadSpeechState == .unknown)
    }

    @Test
    func successfulVADSegmentCountsDistinguishSilenceFromSpeech() throws {
        let cancellation = WhisperInferenceCancellationState()

        let silenceState = try WhisperInferenceSpeechStateResolver.resolve(cancellation: cancellation) {
            0
        }
        let speechState = try WhisperInferenceSpeechStateResolver.resolve(cancellation: cancellation) {
            1
        }

        #expect(silenceState == .noSpeechDetected)
        #expect(speechState == .speechDetected)
    }

    @Test
    func vadDetectionFailureIsNotReportedAsSilence() {
        let cancellation = WhisperInferenceCancellationState()

        #expect(throws: WhisperInferenceError.vadDetectionFailed) {
            try WhisperInferenceSpeechStateResolver.resolve(cancellation: cancellation) {
                nil
            }
        }
    }

    @Test
    func rejectsInvalidVADSegmentCounts() {
        let cancellation = WhisperInferenceCancellationState()

        #expect(throws: WhisperInferenceError.invalidVADSegmentCount(-1)) {
            try WhisperInferenceSpeechStateResolver.resolve(cancellation: cancellation) {
                -1
            }
        }
        #expect(throws: WhisperInferenceError.vadSegmentLimitExceeded(
            Int32(WhisperInferenceLimits.maximumVADSegmentCount + 1)
        )) {
            try WhisperInferenceSpeechStateResolver.resolve(cancellation: cancellation) {
                Int32(WhisperInferenceLimits.maximumVADSegmentCount + 1)
            }
        }
    }

    @Test
    func cancellationPreventsOrInvalidatesVADDetection() {
        let alreadyCancelled = WhisperInferenceCancellationState()
        alreadyCancelled.cancel()
        var attemptedDetection = false

        #expect(throws: WhisperInferenceError.cancelled) {
            try WhisperInferenceSpeechStateResolver.resolve(cancellation: alreadyCancelled) {
                attemptedDetection = true
                return 0
            }
        }
        #expect(!attemptedDetection)

        let cancelledDuringDetection = WhisperInferenceCancellationState()
        #expect(throws: WhisperInferenceError.cancelled) {
            try WhisperInferenceSpeechStateResolver.resolve(cancellation: cancelledDuringDetection) {
                cancelledDuringDetection.cancel()
                return 0
            }
        }
    }

    @Test
    func acceptsBoundedSixteenKilohertzInput() throws {
        try WhisperInference.validateInput(samples: [0, 0.25, -0.25], sampleRate: 16_000)
        try WhisperInference.validateInput(
            samples: Array(repeating: 0, count: WhisperInferenceLimits.maximumSampleCount),
            sampleRate: 16_000
        )
    }

    @Test
    func rejectsOtherSampleRates() {
        #expect(throws: WhisperInferenceError.self) {
            try WhisperInference.validateInput(samples: [0], sampleRate: 44_100)
        }
        #expect(throws: WhisperInferenceError.self) {
            try WhisperInference.validateInput(samples: [0], sampleRate: .nan)
        }
    }

    @Test
    func rejectsEmptyOversizedAndNonFiniteAudio() {
        #expect(throws: WhisperInferenceError.self) {
            try WhisperInference.validateInput(samples: [], sampleRate: 16_000)
        }
        #expect(throws: WhisperInferenceError.self) {
            try WhisperInference.validateInput(
                samples: Array(repeating: 0, count: WhisperInferenceLimits.maximumSampleCount + 1),
                sampleRate: 16_000
            )
        }
        #expect(throws: WhisperInferenceError.self) {
            try WhisperInference.validateInput(samples: [0, .nan], sampleRate: 16_000)
        }
        #expect(throws: WhisperInferenceError.self) {
            try WhisperInference.validateInput(samples: [.infinity], sampleRate: 16_000)
        }
    }

    @Test
    func cancellationStateIsVisibleToTheNativeCallback() {
        let state = WhisperInferenceCancellationState()
        let userData = Unmanaged.passUnretained(state).toOpaque()

        #expect(!WhisperInferenceCancellationState.abortCallback(userData))
        DispatchQueue.global().sync {
            state.cancel()
        }
        #expect(WhisperInferenceCancellationState.abortCallback(userData))
        #expect(WhisperInferenceCancellationState.abortCallback(nil))
    }

    @Test
    func rejectsMissingModelBeforeCallingWhisper() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try WhisperInference(
                verifiedModelURL: directory.appendingPathComponent("missing-model.bin"),
                vadModelURL: directory.appendingPathComponent("missing-vad.bin")
            )
            Issue.record("A missing model must be rejected before native model loading.")
        } catch let error as WhisperInferenceError {
            guard case .fileUnavailable(role: .model, systemErrorCode: _) = error else {
                Issue.record("Expected the selected model file to be reported unavailable; received \(error).")
                return
            }
        }
    }

    @Test
    func validatesTheSpecifiedVADFileBeforeLoadingTheModel() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelURL = directory.appendingPathComponent("caller-selected-model.bin")
        try Data([0x01]).write(to: modelURL)

        do {
            _ = try WhisperInference(
                verifiedModelURL: modelURL,
                vadModelURL: directory.appendingPathComponent("missing-selected-vad.bin")
            )
            Issue.record("A missing VAD file must be rejected before native model loading.")
        } catch let error as WhisperInferenceError {
            guard case .fileUnavailable(role: .vad, systemErrorCode: _) = error else {
                Issue.record("Expected the selected VAD file to be reported unavailable; received \(error).")
                return
            }
        }
    }

    @Test
    func rejectsSymbolicLinkModelPaths() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let actualModelURL = directory.appendingPathComponent("actual-model.bin")
        let linkedModelURL = directory.appendingPathComponent("linked-model.bin")
        let vadURL = directory.appendingPathComponent("vad.bin")
        try Data([0x01]).write(to: actualModelURL)
        try Data([0x02]).write(to: vadURL)
        try FileManager.default.createSymbolicLink(at: linkedModelURL, withDestinationURL: actualModelURL)

        do {
            _ = try WhisperInference(verifiedModelURL: linkedModelURL, vadModelURL: vadURL)
            Issue.record("A symbolic-link model path must be rejected before native model loading.")
        } catch let error as WhisperInferenceError {
            #expect(error == .notRegularFile(role: .model))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-inference-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
