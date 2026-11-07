import Combine
import Foundation

nonisolated enum TranscriptionSessionPhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording
    case processing
    case cancelling
    case shutdown
}

@MainActor
protocol TranscriptionHistoryStoring: AnyObject {
    func load() throws -> [TranscriptionHistoryEntry]
    func append(_ text: String) throws -> TranscriptionHistoryEntry
    func delete(id: UUID) throws
    func clear() throws
}

extension TranscriptionHistoryStore: TranscriptionHistoryStoring {}

nonisolated enum TranscriptionSessionCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case sessionAlreadyActive
    case languageChangeWhileSessionActive
    case shutdown

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            "A transcription session is already active."
        case .languageChangeWhileSessionActive:
            "The transcription language cannot change during an active session."
        case .shutdown:
            "The transcription coordinator has shut down."
        }
    }
}

@MainActor
final class TranscriptionSessionCoordinator: ObservableObject {
    private let capture: any AudioCapturing
    private let recognizer: any TranscriptionRecognizing
    private let permission: any MicrophonePermissionChecking
    private let history: any TranscriptionHistoryStoring
    private let languagePreferences: TranscriptionLanguagePreferenceStore

    private var activeGeneration: UUID?
    private var recognitionTask: Task<Void, Never>?
    private var captureCleanupTask: Task<Void, Never>?
    private var recognizerCleanupTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var pendingPermissionGeneration: UUID?
    private var permissionContinuation: CheckedContinuation<MicrophonePermissionState?, Never>?
    private var isShutdown = false

    @Published private(set) var phase: TranscriptionSessionPhase = .idle
    @Published private(set) var selectedLanguage: TranscriptionLanguage
    @Published private(set) var provisionalTranscript = ""
    @Published private(set) var finalizedTranscript = ""
    @Published private(set) var sessionError: String?
    @Published private(set) var sessionErrorTitle: String?
    @Published private(set) var historyEntries: [TranscriptionHistoryEntry] = []
    @Published private(set) var historyError: String?

    var isLanguageSelectionLocked: Bool {
        activeGeneration != nil || phase == .cancelling || phase == .shutdown
    }

    init(
        capture: any AudioCapturing,
        recognizer: any TranscriptionRecognizing,
        permission: any MicrophonePermissionChecking,
        history: any TranscriptionHistoryStoring,
        languagePreferences: TranscriptionLanguagePreferenceStore
    ) {
        self.capture = capture
        self.recognizer = recognizer
        self.permission = permission
        self.history = history
        self.languagePreferences = languagePreferences
        selectedLanguage = languagePreferences.selectedLanguage

        do {
            historyEntries = try history.load()
        } catch {
            historyError = Self.message(for: error)
        }
    }

    func selectLanguage(_ language: TranscriptionLanguage) throws {
        guard !isShutdown else { throw TranscriptionSessionCoordinatorError.shutdown }
        guard !isLanguageSelectionLocked else {
            throw TranscriptionSessionCoordinatorError.languageChangeWhileSessionActive
        }
        let didChange = selectedLanguage != language
        selectedLanguage = language
        languagePreferences.selectedLanguage = language
        if didChange {
            sessionError = nil
            sessionErrorTitle = nil
        }
    }

    func start() async throws {
        guard !isShutdown else { throw TranscriptionSessionCoordinatorError.shutdown }
        guard activeGeneration == nil, phase == .idle else {
            throw TranscriptionSessionCoordinatorError.sessionAlreadyActive
        }

        let generation = UUID()
        let language = selectedLanguage
        activeGeneration = generation
        phase = .requestingPermission
        provisionalTranscript = ""
        finalizedTranscript = ""
        sessionError = nil
        sessionErrorTitle = nil

        let permissionRequest = Task { @MainActor [permission] in
            await permission.request()
        }
        let permissionState: MicrophonePermissionState? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingPermissionGeneration = generation
                permissionContinuation = continuation
                Task { @MainActor [weak self] in
                    let result = await permissionRequest.value
                    self?.resolvePermissionRequest(generation: generation, result: result)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in await self?.cancel() }
        }
        guard !isShutdown else { return }
        guard let permissionState else { return }
        guard activeGeneration == generation else {
            if activeGeneration == nil,
               phase == .cancelling,
               pendingPermissionGeneration == nil {
                phase = .idle
            }
            return
        }
        guard !Task.isCancelled else {
            finish(generation: generation)
            return
        }
        guard permissionState == .granted else {
            finish(generation: generation)
            setSessionError(
                permissionState == .denied
                    ? "Microphone access is denied."
                    : "Microphone access has not been granted.",
                title: permissionState == .denied ? "Microphone Access Denied" : "Microphone Permission Required"
            )
            return
        }

        do {
            let stream = try capture.start()
            phase = .recording
            recognitionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runRecognition(
                    audio: stream,
                    language: language,
                    generation: generation
                )
            }
        } catch {
            finish(generation: generation)
            setSessionError(Self.message(for: error), title: "Audio Capture Failed")
        }
    }

    func stop() async {
        if let cancellationTask {
            await cancellationTask.value
            return
        }
        guard let generation = activeGeneration else { return }
        guard !isShutdown else { return }

        if phase == .requestingPermission {
            await cancel()
            return
        }

        if phase == .recording {
            phase = .processing
            await finishCapture(cancel: false)
        }
        if let cancellationTask {
            await cancellationTask.value
            return
        }
        guard activeGeneration == generation else { return }
        if let recognitionTask {
            await recognitionTask.value
        }
        if let cancellationTask {
            await cancellationTask.value
        }
    }

    func cancel() async {
        if let cancellationTask {
            await cancellationTask.value
            return
        }
        guard !isShutdown else {
            await joinCleanupTasks()
            return
        }
        guard let generation = activeGeneration else { return }

        let wasRequestingPermission = phase == .requestingPermission
        activeGeneration = nil
        phase = .cancelling
        provisionalTranscript = ""
        finalizedTranscript = ""
        sessionError = nil
        sessionErrorTitle = nil

        if wasRequestingPermission {
            let continuation = permissionContinuation
            permissionContinuation = nil
            continuation?.resume(returning: nil)
            return
        }

        let task = recognitionTask
        task?.cancel()
        let cleanup = beginCancellation(generation: generation, recognitionTask: task)
        await cleanup.value
    }

    func shutdown() async {
        if isShutdown {
            await joinCleanupTasks()
            return
        }
        isShutdown = true
        let generation = activeGeneration
        activeGeneration = nil
        phase = .shutdown
        provisionalTranscript = ""
        finalizedTranscript = ""
        sessionError = nil
        sessionErrorTitle = nil
        let permissionContinuation = self.permissionContinuation
        self.permissionContinuation = nil
        permissionContinuation?.resume(returning: nil)

        let task = recognitionTask
        task?.cancel()
        if let cancellationTask {
            await cancellationTask.value
        } else if let generation {
            let cleanup = beginCancellation(generation: generation, recognitionTask: task)
            await cleanup.value
        } else {
            await joinCleanupTasks()
        }
        recognitionTask = nil
        phase = .shutdown
    }

    func join() async {
        await joinCleanupTasks()
    }

    func waitForRecognition() async {
        if let recognitionTask { await recognitionTask.value }
    }

    func reloadHistory() {
        do {
            historyEntries = try history.load()
            historyError = nil
        } catch {
            historyError = Self.message(for: error)
        }
    }

    func deleteHistoryEntry(id: UUID) {
        do {
            try history.delete(id: id)
            historyEntries.removeAll { $0.id == id }
            historyError = nil
        } catch {
            historyError = Self.message(for: error)
        }
    }

    func clearHistory() {
        do {
            try history.clear()
            historyEntries.removeAll()
            historyError = nil
        } catch {
            historyError = Self.message(for: error)
        }
    }

    private func runRecognition(
        audio: AudioCaptureStream,
        language: TranscriptionLanguage,
        generation: UUID
    ) async {
        do {
            let result = try await recognizer.transcribe(
                audio: audio,
                language: language,
                generation: generation,
                onEvent: { [weak self] event in
                    self?.receive(event, expectedGeneration: generation)
                }
            )
            guard activeGeneration == generation, !isShutdown else { return }
            guard !capture.isCapturing else {
                await finishCapture(cancel: true)
                guard activeGeneration == generation, !isShutdown else { return }
                setSessionError(
                    "Recognition ended before microphone capture stopped.",
                    title: "Audio Capture Failed"
                )
                finish(generation: generation)
                return
            }

            finalizedTranscript = result.text
            if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let entry = try history.append(result.text)
                    historyEntries.append(entry)
                    historyError = nil
                } catch {
                    historyError = Self.message(for: error)
                }
            }
            finish(generation: generation)
        } catch {
            guard activeGeneration == generation, !isShutdown else { return }
            if capture.isCapturing {
                await finishCapture(cancel: true)
                guard activeGeneration == generation, !isShutdown else { return }
            }
            setSessionError(
                Self.message(for: error),
                title: error is AudioCaptureFailure ? "Audio Capture Failed" : "Speech Inference Failed"
            )
            finish(generation: generation)
        }
    }

    private func receive(
        _ event: TranscriptionRecognitionEvent,
        expectedGeneration: UUID
    ) {
        guard activeGeneration == expectedGeneration, !isShutdown else { return }
        switch event {
        case .provisional(let generation, let text):
            guard generation == expectedGeneration else { return }
            provisionalTranscript = text
        case .finalized(let generation, let text):
            guard generation == expectedGeneration else { return }
            finalizedTranscript = text
            provisionalTranscript = ""
        }
    }

    private func finish(generation: UUID) {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        recognitionTask = nil
        phase = isShutdown ? .shutdown : .idle
    }

    private func finishCapture(cancel: Bool) async {
        if let captureCleanupTask {
            await captureCleanupTask.value
            return
        }
        let task = Task { @MainActor [capture] in
            if cancel { await capture.cancel() } else { await capture.stop() }
        }
        captureCleanupTask = task
        await task.value
        captureCleanupTask = nil
    }

    private func finishRecognizer(generation: UUID) async {
        if let recognizerCleanupTask {
            await recognizerCleanupTask.value
            return
        }
        let task = Task { @MainActor [recognizer] in
            await recognizer.cancel(generation: generation)
        }
        recognizerCleanupTask = task
        await task.value
        recognizerCleanupTask = nil
    }

    private func beginCancellation(
        generation: UUID,
        recognitionTask: Task<Void, Never>?
    ) -> Task<Void, Never> {
        if let cancellationTask { return cancellationTask }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishCapture(cancel: true)
            await self.finishRecognizer(generation: generation)
            if let recognitionTask { await recognitionTask.value }
            self.recognitionTask = nil
            self.phase = self.isShutdown ? .shutdown : .idle
            if !self.isShutdown { self.cancellationTask = nil }
        }
        cancellationTask = task
        return task
    }

    private func joinCleanupTasks() async {
        if let cancellationTask { await cancellationTask.value }
        if let captureCleanupTask { await captureCleanupTask.value }
        if let recognizerCleanupTask { await recognizerCleanupTask.value }
        if let recognitionTask { await recognitionTask.value }
    }

    private func resolvePermissionRequest(
        generation: UUID,
        result: MicrophonePermissionState
    ) {
        guard pendingPermissionGeneration == generation else { return }
        pendingPermissionGeneration = nil
        let continuation = permissionContinuation
        permissionContinuation = nil

        guard !isShutdown,
              activeGeneration == generation,
              phase == .requestingPermission else {
            if !isShutdown, phase == .cancelling { phase = .idle }
            continuation?.resume(returning: nil)
            return
        }
        continuation?.resume(returning: result)
    }

    private static func message(for error: any Error) -> String {
        let description = error.localizedDescription
        return description.isEmpty ? "Transcription could not be completed." : description
    }

    private func setSessionError(_ message: String, title: String) {
        sessionErrorTitle = title
        sessionError = message
    }
}
