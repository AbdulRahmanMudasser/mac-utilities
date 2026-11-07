import Foundation

nonisolated enum TranscriptionRecognitionEvent: Equatable, Sendable {
    case provisional(generation: UUID, text: String)
    case finalized(generation: UUID, text: String)
}

nonisolated struct TranscriptionRecognitionResult: Equatable, Sendable {
    let text: String

    init(text: String) {
        self.text = text
    }
}

@MainActor
protocol TranscriptionRecognizing: AnyObject {
    func transcribe(
        audio: AudioCaptureStream,
        language: TranscriptionLanguage,
        generation: UUID,
        onEvent: @escaping @MainActor @Sendable (TranscriptionRecognitionEvent) -> Void
    ) async throws -> TranscriptionRecognitionResult

    func cancel(generation: UUID) async
}
