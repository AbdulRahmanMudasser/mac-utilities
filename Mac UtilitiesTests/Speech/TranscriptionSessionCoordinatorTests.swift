import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct TranscriptionSessionCoordinatorTests {
    @MainActor
    private final class Fixture {
        let directory: URL
        let preferences: UserDefaults
        let historyURL: URL
        private let suiteName: String

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcription-session-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            historyURL = directory.appendingPathComponent("transcription-history.json")
            suiteName = "MacUtilities.TranscriptionSessionTests.\(UUID().uuidString)"
            preferences = try #require(UserDefaults(suiteName: suiteName))
        }

        func makeHistory() -> TranscriptionHistoryStore {
            TranscriptionHistoryStore(
                historyURL: historyURL,
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            )
        }

        func makeCoordinator(
            capture: FakeCapture? = nil,
            recognizer: FakeRecognizer? = nil,
            permission: FakePermission? = nil,
            history: (any TranscriptionHistoryStoring)? = nil
        ) -> TranscriptionSessionCoordinator {
            let selectedCapture = capture ?? FakeCapture()
            let selectedRecognizer = recognizer ?? FakeRecognizer()
            let selectedPermission = permission ?? FakePermission()
            let selectedHistory: any TranscriptionHistoryStoring = history ?? makeHistory()
            return TranscriptionSessionCoordinator(
                capture: selectedCapture,
                recognizer: selectedRecognizer,
                permission: selectedPermission,
                history: selectedHistory,
                languagePreferences: TranscriptionLanguagePreferenceStore(preferences: preferences)
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
            preferences.removePersistentDomain(forName: suiteName)
        }
    }

    @MainActor
    private final class FakeCapture: AudioCapturing {
        private var continuation: AudioCaptureStream.Continuation?
        private(set) var isCapturing = false
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var cancelCount = 0
        var startFailure: (any Error)?
        var holdStopUntilReleased = false
        var holdCancelUntilReleased = false
        private var stopStartedWaiter: CheckedContinuation<Void, Never>?
        private var stopRelease: CheckedContinuation<Void, Never>?
        private var cancelStartedWaiter: CheckedContinuation<Void, Never>?
        private var cancelRelease: CheckedContinuation<Void, Never>?

        func start() throws -> AudioCaptureStream {
            startCount += 1
            if let startFailure { throw startFailure }
            let (stream, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .unbounded)
            self.continuation = continuation
            isCapturing = true
            return stream
        }

        func yield(_ chunk: AudioCaptureChunk) {
            continuation?.yield(chunk)
        }

        func stop() async {
            stopCount += 1
            stopStartedWaiter?.resume()
            stopStartedWaiter = nil
            if holdStopUntilReleased {
                await withCheckedContinuation { stopRelease = $0 }
            }
            isCapturing = false
            continuation?.finish()
            continuation = nil
        }

        func cancel() async {
            cancelCount += 1
            cancelStartedWaiter?.resume()
            cancelStartedWaiter = nil
            if holdCancelUntilReleased {
                await withCheckedContinuation { cancelRelease = $0 }
            }
            isCapturing = false
            continuation?.finish(throwing: CancellationError())
            continuation = nil
        }

        func waitForStopStart() async {
            guard stopCount == 0 else { return }
            await withCheckedContinuation { stopStartedWaiter = $0 }
        }

        func releaseStop() {
            stopRelease?.resume()
            stopRelease = nil
        }

        func waitForCancelStart() async {
            guard cancelCount == 0 else { return }
            await withCheckedContinuation { cancelStartedWaiter = $0 }
        }

        func releaseCancel() {
            cancelRelease?.resume()
            cancelRelease = nil
        }
    }

    @MainActor
    private final class FakePermission: MicrophonePermissionChecking {
        var state: MicrophonePermissionState
        var requestedState: MicrophonePermissionState
        private(set) var requestCount = 0

        init(
            state: MicrophonePermissionState = .granted,
            requestedState: MicrophonePermissionState = .granted
        ) {
            self.state = state
            self.requestedState = requestedState
        }

        func request() async -> MicrophonePermissionState {
            requestCount += 1
            state = requestedState
            return requestedState
        }
    }

    @MainActor
    private final class FakeRecognizer: TranscriptionRecognizing {
        var result = TranscriptionRecognitionResult(text: "recognized speech")
        var failure: (any Error)?
        var provisionalText: String?
        var finalizedText: String?
        var holdsResult = false
        var respondsPromptlyToTaskCancellation = false
        var holdCancelUntilReleased = false

        private(set) var invocationCount = 0
        private(set) var observedChunkCount = 0
        private(set) var languages: [TranscriptionLanguage] = []
        private(set) var generations: [UUID] = []
        private(set) var cancelCount = 0
        private(set) var completedInvocationCount = 0
        private var eventHandlers: [UUID: @MainActor @Sendable (TranscriptionRecognitionEvent) -> Void] = [:]
        private var invocationWaiter: CheckedContinuation<Void, Never>?
        private var heldResult: CheckedContinuation<TranscriptionRecognitionResult, any Error>?
        private var heldResultWaiter: CheckedContinuation<Void, Never>?
        private var cancelStartedWaiter: CheckedContinuation<Void, Never>?
        private var cancelRelease: CheckedContinuation<Void, Never>?

        func transcribe(
            audio: AudioCaptureStream,
            language: TranscriptionLanguage,
            generation: UUID,
            onEvent: @escaping @MainActor @Sendable (TranscriptionRecognitionEvent) -> Void
        ) async throws -> TranscriptionRecognitionResult {
            invocationCount += 1
            languages.append(language)
            generations.append(generation)
            eventHandlers[generation] = onEvent
            if let provisionalText {
                onEvent(.provisional(generation: generation, text: provisionalText))
            }
            if let finalizedText {
                onEvent(.finalized(generation: generation, text: finalizedText))
            }
            invocationWaiter?.resume()
            invocationWaiter = nil

            if holdsResult {
                let held = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<TranscriptionRecognitionResult, any Error>) in
                    heldResult = continuation
                    heldResultWaiter?.resume()
                    heldResultWaiter = nil
                }
                completedInvocationCount += 1
                return held
            }

            if respondsPromptlyToTaskCancellation {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    completedInvocationCount += 1
                    return result
                } catch {
                    completedInvocationCount += 1
                    throw error
                }
            }

            for try await _ in audio {
                observedChunkCount += 1
            }
            if let failure {
                completedInvocationCount += 1
                throw failure
            }
            completedInvocationCount += 1
            return result
        }

        func cancel(generation: UUID) async {
            cancelCount += 1
            cancelStartedWaiter?.resume()
            cancelStartedWaiter = nil
            if holdCancelUntilReleased {
                await withCheckedContinuation { cancelRelease = $0 }
            }
        }

        func waitForInvocation(_ targetCount: Int = 1) async {
            guard invocationCount < targetCount else { return }
            await withCheckedContinuation { invocationWaiter = $0 }
        }

        func waitForHeldResult() async {
            guard heldResult == nil else { return }
            await withCheckedContinuation { heldResultWaiter = $0 }
        }

        func releaseHeldResult(_ result: TranscriptionRecognitionResult? = nil) {
            heldResult?.resume(returning: result ?? self.result)
            heldResult = nil
        }

        func send(_ event: TranscriptionRecognitionEvent, from generation: UUID) {
            eventHandlers[generation]?(event)
        }

        func waitForCancelStart() async {
            guard cancelCount == 0 else { return }
            await withCheckedContinuation { cancelStartedWaiter = $0 }
        }

        func releaseCancel() {
            cancelRelease?.resume()
            cancelRelease = nil
        }
    }

    @MainActor
    private final class FailingAppendHistory: TranscriptionHistoryStoring {
        let store: TranscriptionHistoryStore

        init(store: TranscriptionHistoryStore) {
            self.store = store
        }

        func load() throws -> [TranscriptionHistoryEntry] {
            try store.load()
        }

        func append(_ text: String) throws -> TranscriptionHistoryEntry {
            throw TestFailure.historyWrite
        }

        func delete(id: UUID) throws {
            try store.delete(id: id)
        }

        func clear() throws {
            try store.clear()
        }
    }

    private enum TestFailure: Error, LocalizedError {
        case recognition
        case historyWrite

        var errorDescription: String? {
            switch self {
            case .recognition: "Recognition failed after partial output."
            case .historyWrite: "History could not be updated."
            }
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test
    func stopDrainsCapturedAudioAndSavesOnlySuccessfulNonEmptyResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = FakeCapture()
        let recognizer = FakeRecognizer()
        recognizer.provisionalText = "recogniz"
        recognizer.finalizedText = "recognized speech"
        let permission = FakePermission()
        let store = fixture.makeHistory()
        let coordinator = fixture.makeCoordinator(
            capture: capture,
            recognizer: recognizer,
            permission: permission,
            history: store
        )

        #expect(coordinator.selectedLanguage == .english)
        try await coordinator.start()
        await recognizer.waitForInvocation()
        capture.yield(AudioCaptureChunk(startingSampleIndex: 0, sampleRate: 16_000, samples: [0.1, 0.2]))
        await coordinator.stop()

        #expect(permission.requestCount == 1)
        #expect(capture.stopCount == 1)
        #expect(capture.cancelCount == 0)
        #expect(recognizer.observedChunkCount == 1)
        #expect(recognizer.languages == [.english])
        #expect(coordinator.phase == .idle)
        #expect(coordinator.finalizedTranscript == "recognized speech")
        #expect(coordinator.provisionalTranscript.isEmpty)
        #expect(coordinator.historyEntries.map(\.text) == ["recognized speech"])
        #expect(try store.load() == coordinator.historyEntries)
    }

    @Test
    func selectedUrduIsPassedExplicitlyAndCannotChangeDuringSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = FakeCapture()
        let recognizer = FakeRecognizer()
        let coordinator = fixture.makeCoordinator(capture: capture, recognizer: recognizer)

        try coordinator.selectLanguage(.urdu)
        #expect(coordinator.selectedLanguage == .urdu)
        #expect(TranscriptionLanguagePreferenceStore(preferences: fixture.preferences).selectedLanguage == .urdu)

        try await coordinator.start()
        await recognizer.waitForInvocation()
        #expect(coordinator.phase == .recording)
        #expect(coordinator.isLanguageSelectionLocked)
        #expect(throws: TranscriptionSessionCoordinatorError.self) {
            try coordinator.selectLanguage(.english)
        }
        await coordinator.stop()

        #expect(recognizer.languages == [.urdu])
        #expect(coordinator.selectedLanguage == .urdu)
    }

    @Test
    func deniedPermissionDoesNotStartCaptureAndRemainsVisible() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = FakeCapture()
        let permission = FakePermission(state: .denied, requestedState: .denied)
        let coordinator = fixture.makeCoordinator(capture: capture, permission: permission)

        try await coordinator.start()

        #expect(permission.requestCount == 1)
        #expect(capture.startCount == 0)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.sessionError == "Microphone access is denied.")
    }

    @Test
    func emptyAndFailedRecognitionNeverPersistPartialOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = FakeCapture()
        let recognizer = FakeRecognizer()
        let store = fixture.makeHistory()
        let coordinator = fixture.makeCoordinator(
            capture: capture,
            recognizer: recognizer,
            history: store
        )

        recognizer.result = TranscriptionRecognitionResult(text: " \n ")
        recognizer.finalizedText = "provisional final text"
        try await coordinator.start()
        await recognizer.waitForInvocation()
        await coordinator.stop()
        #expect(coordinator.historyEntries.isEmpty)
        #expect(try store.load().isEmpty)

        recognizer.result = TranscriptionRecognitionResult(text: "must not be saved")
        recognizer.finalizedText = "partial result"
        recognizer.failure = TestFailure.recognition
        try await coordinator.start()
        await recognizer.waitForInvocation(2)
        await coordinator.stop()

        #expect(coordinator.historyEntries.isEmpty)
        #expect(try store.load().isEmpty)
        #expect(coordinator.finalizedTranscript == "partial result")
        #expect(coordinator.sessionError == "Recognition failed after partial output.")
    }

    @Test
    func cancellationRejectsLateResultAndJoinsRecognitionBeforeReturning() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = FakeCapture()
        let recognizer = FakeRecognizer()
        recognizer.holdsResult = true
        let store = fixture.makeHistory()
        let coordinator = fixture.makeCoordinator(
            capture: capture,
            recognizer: recognizer,
            history: store
        )

        try await coordinator.start()
        await recognizer.waitForInvocation()
        let cancellation = Task { @MainActor in await coordinator.cancel() }
        await recognizer.waitForHeldResult()
        await recognizer.waitForCancelStart()
        #expect(coordinator.phase == .cancelling)
        #expect(recognizer.cancelCount == 1)
        recognizer.releaseHeldResult(TranscriptionRecognitionResult(text: "stale result"))
        await cancellation.value

        #expect(recognizer.completedInvocationCount == 1)
        #expect(capture.cancelCount == 1)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.historyEntries.isEmpty)
        #expect(try store.load().isEmpty)
    }

    @Test
    func shutdownJoinsCancellationBeforeRecognizerCleanupIsRegistered() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = FakeCapture()
        capture.holdCancelUntilReleased = true
        let recognizer = FakeRecognizer()
        recognizer.respondsPromptlyToTaskCancellation = true
        recognizer.holdCancelUntilReleased = true
        let store = fixture.makeHistory()
        let coordinator = fixture.makeCoordinator(
            capture: capture,
            recognizer: recognizer,
            history: store
        )

        try await coordinator.start()
        await recognizer.waitForInvocation()
        var cancelReturned = false
        let cancellation = Task { @MainActor in
            await coordinator.cancel()
            cancelReturned = true
        }
        await capture.waitForCancelStart()

        #expect(coordinator.phase == .cancelling)
        #expect(recognizer.cancelCount == 0)
        var shutdownReturned = false
        let shutdown = Task(priority: .high) { @MainActor in
            await coordinator.shutdown()
            shutdownReturned = true
        }
        await waitUntil { coordinator.phase == .shutdown }
        #expect(coordinator.phase == .shutdown)
        #expect(!shutdownReturned)

        capture.releaseCancel()
        await recognizer.waitForCancelStart()
        #expect(!shutdownReturned)
        #expect(!cancelReturned)

        recognizer.releaseCancel()
        await cancellation.value
        await shutdown.value

        #expect(cancelReturned)
        #expect(shutdownReturned)
        #expect(recognizer.completedInvocationCount == 1)
        #expect(capture.cancelCount == 1)
        #expect(recognizer.cancelCount == 1)
        #expect(coordinator.phase == .shutdown)
        #expect(coordinator.historyEntries.isEmpty)
        #expect(try store.load().isEmpty)
    }

    @Test
    func concurrentStopCancelAndShutdownJoinTheSameCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = FakeCapture()
        capture.holdStopUntilReleased = true
        let recognizer = FakeRecognizer()
        recognizer.respondsPromptlyToTaskCancellation = true
        recognizer.holdCancelUntilReleased = true
        let coordinator = fixture.makeCoordinator(capture: capture, recognizer: recognizer)

        try await coordinator.start()
        await recognizer.waitForInvocation()
        var stopReturned = false
        let stop = Task { @MainActor in
            await coordinator.stop()
            stopReturned = true
        }
        await capture.waitForStopStart()

        var cancelReturned = false
        let cancellation = Task { @MainActor in
            await coordinator.cancel()
            cancelReturned = true
        }
        await waitUntil { coordinator.phase == .cancelling }
        #expect(coordinator.phase == .cancelling)

        var shutdownReturned = false
        let shutdown = Task { @MainActor in
            await coordinator.shutdown()
            shutdownReturned = true
        }
        await waitUntil { coordinator.phase == .shutdown }
        #expect(!stopReturned)
        #expect(!cancelReturned)
        #expect(!shutdownReturned)

        capture.releaseStop()
        await recognizer.waitForCancelStart()
        #expect(!stopReturned)
        #expect(!cancelReturned)
        #expect(!shutdownReturned)

        recognizer.releaseCancel()
        await stop.value
        await cancellation.value
        await shutdown.value

        #expect(stopReturned)
        #expect(cancelReturned)
        #expect(shutdownReturned)
        #expect(capture.stopCount == 1)
        #expect(capture.cancelCount == 0)
        #expect(recognizer.cancelCount == 1)
        #expect(coordinator.phase == .shutdown)
        #expect(coordinator.historyEntries.isEmpty)
    }

    @Test
    func eventsFromAnEarlierGenerationCannotChangeTheCurrentTranscript() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let recognizer = FakeRecognizer()
        let coordinator = fixture.makeCoordinator(recognizer: recognizer)

        try await coordinator.start()
        await recognizer.waitForInvocation()
        let oldGeneration = try #require(recognizer.generations.first)
        await coordinator.stop()

        recognizer.result = TranscriptionRecognitionResult(text: "current result")
        recognizer.finalizedText = nil
        try await coordinator.start()
        await recognizer.waitForInvocation(2)
        recognizer.send(.provisional(generation: oldGeneration, text: "stale provisional"), from: oldGeneration)
        #expect(coordinator.provisionalTranscript.isEmpty)
        #expect(coordinator.finalizedTranscript.isEmpty)
        await coordinator.stop()

        #expect(coordinator.historyEntries.map(\.text) == ["recognized speech", "current result"])
    }

    @Test
    func shutdownInvalidatesLateResultAndRejectsFutureStarts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = FakeCapture()
        let recognizer = FakeRecognizer()
        recognizer.holdsResult = true
        let store = fixture.makeHistory()
        let coordinator = fixture.makeCoordinator(
            capture: capture,
            recognizer: recognizer,
            history: store
        )

        try await coordinator.start()
        await recognizer.waitForInvocation()
        let shutdown = Task { @MainActor in await coordinator.shutdown() }
        await recognizer.waitForHeldResult()
        recognizer.releaseHeldResult(TranscriptionRecognitionResult(text: "stale result"))
        await shutdown.value

        #expect(recognizer.completedInvocationCount == 1)
        #expect(capture.cancelCount == 1)
        #expect(coordinator.phase == .shutdown)
        #expect(coordinator.historyEntries.isEmpty)
        #expect(try store.load().isEmpty)
        await #expect(throws: TranscriptionSessionCoordinatorError.self) {
            try await coordinator.start()
        }
    }

    @Test
    func historyLoadAndWriteFailuresRemainVisible() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("{invalid".utf8).write(to: fixture.historyURL)
        let brokenStore = fixture.makeHistory()
        let coordinator = fixture.makeCoordinator(history: brokenStore)

        #expect(coordinator.historyError != nil)
        try await coordinator.start()
        await coordinator.stop()
        #expect(coordinator.historyError != nil)
        #expect(coordinator.historyEntries.isEmpty)

        let writeFixture = try Fixture()
        defer { writeFixture.remove() }
        let capture = FakeCapture()
        let recognizer = FakeRecognizer()
        let backingStore = writeFixture.makeHistory()
        let failingHistory = FailingAppendHistory(store: backingStore)
        let writeCoordinator = writeFixture.makeCoordinator(
            capture: capture,
            recognizer: recognizer,
            history: failingHistory
        )
        try await writeCoordinator.start()
        await recognizer.waitForInvocation()
        await writeCoordinator.stop()

        #expect(writeCoordinator.finalizedTranscript == "recognized speech")
        #expect(writeCoordinator.historyEntries.isEmpty)
        #expect(writeCoordinator.historyError == "History could not be updated.")
        #expect(try backingStore.load().isEmpty)
    }

    @Test
    func historyDeleteUpdatesOnlyRequestedEntry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeHistory()
        #expect(try store.load().isEmpty)
        let first = try store.append("duplicate")
        let second = try store.append("duplicate")
        let coordinator = fixture.makeCoordinator(history: store)

        coordinator.deleteHistoryEntry(id: first.id)

        #expect(coordinator.historyEntries == [second])
        #expect(coordinator.historyError == nil)
        #expect(try store.load() == [second])
    }
}
