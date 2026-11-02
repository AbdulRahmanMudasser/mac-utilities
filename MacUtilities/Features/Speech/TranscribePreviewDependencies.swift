#if DEBUG
import Foundation

@MainActor
final class PreviewTranscribeCapture: AudioCapturing {
    private var continuation: AudioCaptureStream.Continuation?
    private(set) var isCapturing = false

    func start() throws -> AudioCaptureStream {
        guard !isCapturing else { throw AudioCaptureFailure.alreadyCapturing }
        let (stream, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        isCapturing = true
        return stream
    }

    func stop() async {
        isCapturing = false
        continuation?.finish()
        continuation = nil
    }

    func cancel() async {
        isCapturing = false
        continuation?.finish(throwing: CancellationError())
        continuation = nil
    }
}

@MainActor
struct PreviewMicrophonePermission: MicrophonePermissionChecking {
    let state: MicrophonePermissionState

    init(state: MicrophonePermissionState = .notDetermined) {
        self.state = state
    }

    func request() async -> MicrophonePermissionState {
        state == .notDetermined ? .denied : state
    }
}

@MainActor
final class PreviewTranscribeSetup: TranscribeAssetSettingUp {
    func acquireAssets(for language: TranscriptionLanguage, progress: @escaping @Sendable (SpeechAssetAcquisitionProgress) -> Void) async throws {
    }
}

@MainActor
private final class PreviewTranscriptionRecognizer: TranscriptionRecognizing {
    func transcribe(
        audio: AudioCaptureStream,
        language: TranscriptionLanguage,
        generation: UUID,
        onEvent: @escaping @MainActor @Sendable (TranscriptionRecognitionEvent) -> Void
    ) async throws -> TranscriptionRecognitionResult {
        let text = switch language {
        case .english: "This is a simulated English transcription."
        case .urdu: "یہ ایک فرضی اردو نقل ہے۔"
        }
        onEvent(.provisional(generation: generation, text: text))
        for try await _ in audio {
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        onEvent(.finalized(generation: generation, text: text))
        return TranscriptionRecognitionResult(text: text)
    }

    func cancel(generation: UUID) async { }
}

@MainActor
final class PreviewTranscribeRecognizerFactory: TranscribeRecognizerLeaseFactory {
    func withPreparedRecognizer(
        for language: TranscriptionLanguage,
        operation: @escaping @MainActor @Sendable (any TranscriptionRecognizing) async -> Void
    ) async throws {
        await operation(PreviewTranscriptionRecognizer())
    }
}
#endif
