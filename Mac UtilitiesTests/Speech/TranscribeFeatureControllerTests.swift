import Combine
import Foundation
import Testing
@testable import Mac_Utilities

@MainActor
struct TranscribeFeatureControllerTests {
    @MainActor
    private final class Fixture {
        let directory: URL
        let historyURL: URL
        let preferences: UserDefaults
        let capture = FakeCapture()
        let permission = FakePermission()
        let setup = FakeSetup()
        let recognizer = FakeRecognizer()
        let factory: FakeRecognizerFactory
        private let suiteName: String
        private(set) var copiedText: [String] = []
        var copySucceeds = true

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcribe-controller-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            historyURL = directory.appendingPathComponent("history.json")
            suiteName = "MacUtilities.TranscribeControllerTests.\(UUID().uuidString)"
            preferences = try #require(UserDefaults(suiteName: suiteName))
            factory = FakeRecognizerFactory(recognizer: recognizer)
        }

        func makeHistory() -> TranscriptionHistoryStore {
            TranscriptionHistoryStore(
                historyURL: historyURL,
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            )
        }

        func makeController(
            history: (any TranscriptionHistoryStoring)? = nil,
            runtimeMode: TranscribeRuntimeMode = .local
        ) -> TranscribeFeatureController {
            TranscribeFeatureController(
                capture: capture,
                permission: permission,
                history: history ?? makeHistory(),
                languagePreferences: TranscriptionLanguagePreferenceStore(preferences: preferences),
                assetSetup: setup,
                recognizerFactory: factory,
                runtimeMode: runtimeMode,
                copyToPasteboard: { [weak self] text in
                    guard let self, self.copySucceeds else { return false }
                    self.copiedText.append(text)
                    return true
                }
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
            preferences.removePersistentDomain(forName: suiteName)
        }
    }

    @MainActor
    private final class FakeSetup: TranscribeAssetSettingUp {
        private(set) var callCount = 0
        private(set) var languages: [TranscriptionLanguage] = []
        var failure: (any Error)?

        func acquireAssets(for language: TranscriptionLanguage,
            progress: @escaping @Sendable (SpeechAssetAcquisitionProgress) -> Void
        ) async throws {
            callCount += 1
            languages.append(language)
            if let failure { throw failure }
        }
    }

    @MainActor
    private final class FakeRecognizerFactory: TranscribeRecognizerLeaseFactory {
        let recognizer: any TranscriptionRecognizing
        private(set) var languages: [TranscriptionLanguage] = []
        private(set) var isLeaseActive = false
        var failure: (any Error)?

        init(recognizer: any TranscriptionRecognizing) {
            self.recognizer = recognizer
        }

        func withPreparedRecognizer(
            for language: TranscriptionLanguage,
            operation: @escaping @MainActor @Sendable (any TranscriptionRecognizing) async -> Void
        ) async throws {
            languages.append(language)
            if let failure { throw failure }
            isLeaseActive = true
            defer { isLeaseActive = false }
            await operation(recognizer)
        }
    }

    @MainActor
    private final class FakeCapture: AudioCapturing {
        private var continuation: AudioCaptureStream.Continuation?
        private var startWaiter: CheckedContinuation<Void, Never>?
        private(set) var isCapturing = false
        private(set) var startCount = 0

        func start() throws -> AudioCaptureStream {
            let (stream, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .unbounded)
            self.continuation = continuation
            isCapturing = true
            startCount += 1
            startWaiter?.resume()
            startWaiter = nil
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

        func waitForStart() async {
            guard startCount == 0 else { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
    }

    @MainActor
    private final class FakePermission: MicrophonePermissionChecking {
        var state: MicrophonePermissionState = .notDetermined
        var requestedState: MicrophonePermissionState = .granted
        var holdsRequest = false
        private(set) var requestCount = 0
        private var startedWaiter: CheckedContinuation<Void, Never>?
        private var requestContinuation: CheckedContinuation<MicrophonePermissionState, Never>?

        func request() async -> MicrophonePermissionState {
            requestCount += 1
            startedWaiter?.resume()
            startedWaiter = nil
            if holdsRequest {
                return await withCheckedContinuation { requestContinuation = $0 }
            }
            state = requestedState
            return requestedState
        }

        func waitForRequest() async {
            guard requestCount == 0 else { return }
            await withCheckedContinuation { startedWaiter = $0 }
        }

        func resolveHeldRequest() {
            state = requestedState
            requestContinuation?.resume(returning: requestedState)
            requestContinuation = nil
        }
    }

    @MainActor
    private final class FakeRecognizer: TranscriptionRecognizing {
        var result = TranscriptionRecognitionResult(text: "local transcript")
        var failure: (any Error)?
        private(set) var languages: [TranscriptionLanguage] = []

        func transcribe(
            audio: AudioCaptureStream,
            language: TranscriptionLanguage,
            generation: UUID,
            onEvent: @escaping @MainActor @Sendable (TranscriptionRecognitionEvent) -> Void
        ) async throws -> TranscriptionRecognitionResult {
            languages.append(language)
            if let failure { throw failure }
            for try await _ in audio { }
            return result
        }

        func cancel(generation: UUID) async { }
    }

    @MainActor
    private final class PreviewRecognitionRecorder {
        var result: TranscriptionRecognitionResult?
        var events: [TranscriptionRecognitionEvent] = []
    }

    private func historyEntries(_ presentation: TranscribeHistoryPresentation) -> [TranscriptionHistoryEntry] {
        switch presentation.state {
        case .loaded(let entries), .unavailable(let entries):
            entries
        }
    }

    @Test
    func setupIsExplicitAndPreparesSelectedModelBeforeMicrophoneCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()

        #expect(controller.viewModel.language == .english)
        #expect(controller.viewModel.capability.message.title == "Speech Models Not Ready")
        #expect(controller.viewModel.capability.message.detail == "Set up the English speech models before recording.")
        #expect(controller.viewModel.capability.actions == [.setUpModels])
        #expect(controller.viewModel.capability.accessibilityValue == controller.viewModel.capability.message.combinedText)
        #expect(!controller.viewModel.capability.canStartRecording)
        #expect(fixture.permission.requestCount == 0)
        #expect(fixture.capture.startCount == 0)

        controller.actions.performCapabilityAction?(.setUpModels)
        await controller.waitForCurrentActions()
        #expect(fixture.setup.callCount == 1)
        #expect(controller.viewModel.capability.isActive)
        #expect(controller.viewModel.capability.canStartRecording)
        #expect(controller.viewModel.capability.message.detail == nil)
        #expect(controller.viewModel.capability.accessibilityValue == "Speech Models Ready")
        #expect(fixture.permission.requestCount == 0)

        controller.actions.startRecording()
        await fixture.capture.waitForStart()
        #expect(fixture.factory.languages == [.english])
        #expect(fixture.factory.isLeaseActive)
        #expect(fixture.permission.requestCount == 1)
        #expect(fixture.capture.isCapturing)

        controller.actions.stopRecording()
        await controller.waitForCurrentActions()
        #expect(!fixture.factory.isLeaseActive)
        #expect(!fixture.capture.isCapturing)
        #expect(fixture.recognizer.languages == [.english])
        #expect(historyEntries(controller.viewModel.history).count == 1)
        await controller.shutdown()
    }

    @Test
    func selectingUrduAutomaticallySetsUpItsModelWithoutFallbackOrMicrophoneRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()

        controller.actions.selectLanguage(.urdu)
        await controller.waitForCurrentActions()
        #expect(controller.viewModel.language == .urdu)
        #expect(controller.viewModel.capability.canStartRecording)
        #expect(controller.viewModel.capability.message.title == "Speech Models Ready")
        #expect(controller.viewModel.capability.message.detail == nil)
        #expect(fixture.setup.callCount == 1)
        #expect(fixture.setup.languages == [.urdu])

        #expect(fixture.permission.requestCount == 0)
        #expect(fixture.capture.startCount == 0)
        #expect(TranscriptionLanguagePreferenceStore(preferences: fixture.preferences).selectedLanguage == .urdu)
        await controller.shutdown()
    }

    @Test
    func interactivePreviewKeepsRecordingAvailableAcrossLanguageChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController(runtimeMode: .interactivePreview)

        #expect(controller.viewModel.capability.message.title == "Interactive Preview Ready")
        #expect(controller.viewModel.capability.isActive)
        #expect(controller.viewModel.capability.canStartRecording)
        #expect(controller.viewModel.capability.message.detail?.contains("Microphone permission") == true)

        controller.actions.selectLanguage(.urdu)

        #expect(controller.viewModel.language == .urdu)
        #expect(controller.viewModel.capability.message.title == "Interactive Preview Ready")
        #expect(controller.viewModel.capability.canStartRecording)
        #expect(fixture.setup.callCount == 0)
        #expect(TranscriptionLanguagePreferenceStore(preferences: fixture.preferences).selectedLanguage == .urdu)

        controller.actions.startRecording()
        await fixture.capture.waitForStart()
        #expect(controller.viewModel.capability.message.title == "Recording Preview")
        #expect(fixture.factory.languages == [.urdu])
        #expect(fixture.permission.requestCount == 1)

        controller.actions.stopRecording()
        await controller.waitForCurrentActions()
        #expect(controller.viewModel.capability.canStartRecording)
        #expect(historyEntries(controller.viewModel.history).map(\.text) == ["local transcript"])
        await controller.shutdown()
    }

    @Test
    func previewDependenciesGenerateSyntheticTextForTheSelectedLanguage() async throws {
        let capture = PreviewTranscribeCapture()
        let stream = try capture.start()
        let recorder = PreviewRecognitionRecorder()
        let generation = UUID()

        try await PreviewTranscribeRecognizerFactory().withPreparedRecognizer(for: .urdu) { recognizer in
            await capture.stop()
            recorder.result = try? await recognizer.transcribe(
                audio: stream,
                language: .urdu,
                generation: generation,
                onEvent: { recorder.events.append($0) }
            )
        }

        let transcript = "یہ ایک فرضی اردو نقل ہے۔"
        #expect(!capture.isCapturing)
        #expect(recorder.result?.text == transcript)
        #expect(recorder.events == [
            .provisional(generation: generation, text: transcript),
            .finalized(generation: generation, text: transcript)
        ])
    }

    @Test
    func preparationFailureAppearsBeforePermissionOrCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        fixture.factory.failure = SpeechModelStoreError.modelNotInstalled

        controller.setUpModels()
        await controller.waitForCurrentActions()
        controller.startRecording()
        await controller.waitForCurrentActions()

        #expect(fixture.factory.languages == [.english])
        #expect(fixture.permission.requestCount == 0)
        #expect(fixture.capture.startCount == 0)
        #expect(controller.viewModel.capability.actions == [.setUpModels])
        #expect(controller.viewModel.capability.message.detail?.contains("not been imported") == true)
        await controller.shutdown()
    }

    @Test
    func permissionDenialReleasesModelLeaseWithoutStartingCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        fixture.permission.requestedState = .denied

        controller.setUpModels()
        await controller.waitForCurrentActions()
        controller.startRecording()
        await controller.waitForCurrentActions()

        #expect(fixture.permission.requestCount == 1)
        #expect(fixture.capture.startCount == 0)
        #expect(!fixture.factory.isLeaseActive)
        #expect(controller.viewModel.capability.message.title == "Microphone Access Denied")
        #expect(controller.viewModel.capability.actions == [.openMicrophoneSettings])
        await controller.shutdown()
    }

    @Test
    func permissionRefreshReflectsExternalSettingsChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.permission.state = .denied
        let controller = fixture.makeController()
        #expect(controller.viewModel.capability.message.title == "Transcription Not Ready")
        #expect(controller.viewModel.capability.message.detail == "Set up the English speech models and allow microphone access in System Settings before recording.")
        #expect(controller.viewModel.capability.actions == [.setUpModels, .openMicrophoneSettings])
        #expect(!controller.viewModel.capability.canStartRecording)
        var notifications = 0
        let subscription = controller.objectWillChange.sink { notifications += 1 }
        fixture.permission.state = .granted
        controller.refreshMicrophonePermission()
        #expect(notifications == 1)
        #expect(controller.viewModel.capability.message.title == "Speech Models Not Ready")
        #expect(controller.viewModel.capability.message.detail == "Set up the English speech models before recording.")
        #expect(controller.viewModel.capability.actions == [.setUpModels])
        #expect(!controller.viewModel.capability.accessibilityValue.contains("Microphone"))
        withExtendedLifetime(subscription) {}
        await controller.shutdown()
    }

    @Test
    func modelSetupProgressKeepsDeniedPermissionRecoveryInTheSameCard() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.permission.state = .denied
        let controller = fixture.makeController()

        controller.setUpModels()
        let presentation = controller.viewModel.capability

        #expect(presentation.message.title == "Setting Up Speech Models")
        #expect(presentation.message.detail?.contains("Microphone access is denied in System Settings.") == true)
        #expect(presentation.actions == [.openMicrophoneSettings])
        #expect(presentation.progressLabel == "Setting Up Speech Models")
        #expect(!presentation.canStartRecording)
        await controller.waitForCurrentActions()
        await controller.shutdown()
    }

    @Test
    func combinedBlockersExposeSetupActionAndThenRevealRemainingPermissionAction() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.permission.state = .denied
        let controller = fixture.makeController()

        #expect(controller.viewModel.capability.actions == [.setUpModels, .openMicrophoneSettings])
        controller.actions.performCapabilityAction?(.setUpModels)
        await controller.waitForCurrentActions()

        #expect(fixture.setup.callCount == 1)
        #expect(controller.viewModel.capability.message.title == "Microphone Access Denied")
        #expect(controller.viewModel.capability.actions == [.openMicrophoneSettings])
        #expect(!controller.viewModel.capability.canStartRecording)
        await controller.shutdown()
    }

    @Test
    func readyModelsDoNotRepeatGrantedMicrophonePermission() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.permission.state = .granted
        let controller = fixture.makeController()

        controller.setUpModels()
        await controller.waitForCurrentActions()

        #expect(controller.viewModel.capability.message.title == "Speech Models Ready")
        #expect(controller.viewModel.capability.message.detail == nil)
        #expect(controller.viewModel.capability.accessibilityValue == "Speech Models Ready")
        #expect(controller.viewModel.capability.canStartRecording)
        #expect(controller.viewModel.capability.actions.isEmpty)
        await controller.shutdown()
    }

    @Test
    func setupFailureRemainsVisibleAndRecordingStaysDisabled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.setup.failure = SpeechModelStoreError.fileSystem(operation: "write model", code: 28)
        let controller = fixture.makeController()
        controller.setUpModels()
        await controller.waitForCurrentActions()
        #expect(controller.viewModel.capability.message.title == "Speech Model Setup Failed")
        #expect(controller.viewModel.capability.actions == [.retrySetup])
        #expect(!controller.viewModel.capability.canStartRecording)
        #expect(fixture.capture.startCount == 0)
        await controller.shutdown()
    }

    @Test
    func setupFailureAndDeniedPermissionShareOneCardWithBothRecoveryActions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.setup.failure = SpeechModelStoreError.fileSystem(operation: "write model", code: 28)
        fixture.permission.state = .denied
        let controller = fixture.makeController()

        controller.setUpModels()
        await controller.waitForCurrentActions()

        #expect(controller.viewModel.capability.message.title == "Speech Model Setup Failed")
        #expect(controller.viewModel.capability.message.detail?.contains("Microphone access is also denied in System Settings.") == true)
        #expect(controller.viewModel.capability.actions == [.retrySetup, .openMicrophoneSettings])
        #expect(!controller.viewModel.capability.canStartRecording)
        await controller.shutdown()
    }

    @Test
    func historyLoadFailureUsesTheCapabilityCardAndKeepsTheFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let corrupt = Data("{".utf8)
        try corrupt.write(to: fixture.historyURL)
        let controller = fixture.makeController()
        #expect(controller.viewModel.capability.message.title == "Speech Models Not Ready")
        #expect(controller.viewModel.capability.message.detail?.contains("Transcription history is also unavailable") == true)
        #expect(controller.viewModel.capability.actions == [.setUpModels, .retryHistory])
        #expect(try Data(contentsOf: fixture.historyURL) == corrupt)
        await controller.shutdown()
    }

    @Test
    func languageRemainsLockedDuringRecordingAndStopSavesHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()

        controller.setUpModels()
        await controller.waitForCurrentActions()
        controller.startRecording()
        await fixture.capture.waitForStart()

        controller.actions.selectLanguage(.urdu)
        #expect(controller.viewModel.language == .english)
        #expect(controller.viewModel.capability.message.title == "Recording")
        #expect(fixture.factory.isLeaseActive)

        controller.stopRecording()
        await controller.waitForCurrentActions()
        #expect(!fixture.factory.isLeaseActive)
        #expect(historyEntries(controller.viewModel.history).first?.text == "local transcript")
        await controller.shutdown()
    }

    @Test
    func copyAndDeleteTargetStableHistoryIdentityImmediately() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = fixture.makeHistory()
        _ = try history.load()
        let first = try history.append("same text")
        let second = try history.append("same text")
        let controller = fixture.makeController(history: history)

        #expect(controller.actions.copyHistoryEntry(second))
        #expect(fixture.copiedText == ["same text"])
        controller.actions.deleteHistoryEntry(first.id)
        #expect(try history.load() == [second])
        await controller.shutdown()
    }

    @Test
    func clearHistoryRemovesAllSavedEntriesAndPersistsTheEmptyState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = fixture.makeHistory()
        _ = try history.load()
        _ = try history.append("first transcript")
        _ = try history.append("second transcript")
        let controller = fixture.makeController(history: history)

        controller.actions.clearHistory()

        #expect(historyEntries(controller.viewModel.history).isEmpty)
        #expect(try history.load().isEmpty)
        await controller.shutdown()
    }

    @Test
    func clearHistoryFailurePreservesEntriesAndShowsTheStorageError() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = fixture.makeHistory()
        _ = try history.load()
        let saved = try history.append("preserve this transcript")
        let controller = fixture.makeController(history: history)
        controller.setUpModels()
        await controller.waitForCurrentActions()

        try FileManager.default.removeItem(at: fixture.historyURL)
        try FileManager.default.createDirectory(at: fixture.historyURL, withIntermediateDirectories: false)
        let sentinelURL = fixture.historyURL.appendingPathComponent("sentinel")
        let sentinel = Data("preserve the blocked history path".utf8)
        try sentinel.write(to: sentinelURL)

        controller.actions.clearHistory()

        #expect(historyEntries(controller.viewModel.history) == [saved])
        #expect(controller.viewModel.capability.message.title == "Transcription History Unavailable")
        #expect(controller.viewModel.capability.canStartRecording)
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        await controller.shutdown()
    }

    @Test
    func historyLoadFailureCanBeRetriedAfterTheFileIsRepaired() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("invalid".utf8).write(to: fixture.historyURL)
        let controller = fixture.makeController()
        #expect(controller.viewModel.capability.message.title == "Speech Models Not Ready")
        #expect(controller.viewModel.capability.actions == [.setUpModels, .retryHistory])

        try Data("{\"schemaVersion\":1,\"entries\":[]}".utf8).write(to: fixture.historyURL)
        controller.actions.performCapabilityAction?(.retryHistory)
        #expect(controller.viewModel.capability.message.title == "Speech Models Not Ready")
        #expect(controller.viewModel.capability.actions == [.setUpModels])
        await controller.shutdown()
    }

    @Test
    func activeRecordingIsVisibleWhenHistoryIsUnavailable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("invalid".utf8).write(to: fixture.historyURL)
        let controller = fixture.makeController()
        controller.setUpModels()
        await controller.waitForCurrentActions()
        controller.startRecording()
        await fixture.capture.waitForStart()
        #expect(controller.viewModel.capability.message.title == "Recording")
        #expect(controller.viewModel.capability.actions == [.retryHistory])
        #expect(controller.viewModel.capability.message.detail?.contains("Transcription history is also unavailable") == true)
        controller.stopRecording()
        await controller.waitForCurrentActions()
        #expect(controller.viewModel.capability.message.title == "Transcription History Unavailable")
        await controller.shutdown()
    }

    @Test
    func failedCopyReportsAnErrorInsteadOfClaimingSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = fixture.makeHistory()
        _ = try history.load()
        let entry = try history.append("text")
        fixture.copySucceeds = false
        let controller = fixture.makeController(history: history)

        #expect(!controller.actions.copyHistoryEntry(entry))
        #expect(controller.viewModel.capability.message.title == "Copy Failed")
        #expect(controller.viewModel.capability.message.detail?.contains("could not be copied") == true)
        #expect(fixture.copiedText.isEmpty)

        fixture.copySucceeds = true
        #expect(controller.actions.copyHistoryEntry(entry))
        #expect(controller.viewModel.capability.message.title == "Speech Models Not Ready")

        fixture.copySucceeds = false
        #expect(!controller.actions.copyHistoryEntry(entry))
        controller.actions.deleteHistoryEntry(entry.id)
        #expect(controller.viewModel.capability.message.title == "Speech Models Not Ready")
        await controller.shutdown()
    }

    @Test
    func shutdownStopsCaptureAndJoinsModelLease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()

        controller.setUpModels()
        await controller.waitForCurrentActions()
        controller.startRecording()
        await fixture.capture.waitForStart()
        #expect(fixture.factory.isLeaseActive)

        await controller.shutdown()
        #expect(!fixture.capture.isCapturing)
        #expect(!fixture.factory.isLeaseActive)
        #expect(controller.viewModel.capability.message.title == "Transcription Shutting Down")
    }

    @Test
    func recognitionFailureReleasesTheModelBeforeAnotherRecording() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.recognizer.failure = AudioCaptureFailure.inputUnavailable
        let controller = fixture.makeController()
        controller.setUpModels()
        await controller.waitForCurrentActions()
        controller.startRecording()
        await controller.waitForCurrentActions()

        #expect(!fixture.capture.isCapturing)
        #expect(!fixture.factory.isLeaseActive)
        #expect(controller.viewModel.capability.canStartRecording)
        #expect(controller.viewModel.capability.message.title == "Audio Capture Failed")
        #expect(historyEntries(controller.viewModel.history).isEmpty)
        await controller.shutdown()
    }

    @Test
    func speechInferenceFailureKeepsConcurrentHistoryFailureAndRecoveryVisible() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("invalid".utf8).write(to: fixture.historyURL)
        fixture.recognizer.failure = StreamingTranscriptionError.invalidInferenceResult
        let controller = fixture.makeController()

        controller.setUpModels()
        await controller.waitForCurrentActions()
        controller.startRecording()
        await controller.waitForCurrentActions()

        let capability = controller.viewModel.capability
        #expect(capability.message.title == "Speech Inference Failed")
        #expect(capability.message.detail?.contains("Speech inference returned text that could not be matched to timed segments.") == true)
        #expect(capability.message.detail?.contains("Transcription history is also unavailable") == true)
        #expect(capability.actions == [.retryHistory])
        #expect(capability.canStartRecording)
        #expect(historyEntries(controller.viewModel.history).isEmpty)
        await controller.shutdown()
    }

    @Test
    func deniedMicrophoneDoesNotHideAnIndependentSpeechFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.recognizer.failure = StreamingTranscriptionError.invalidInferenceResult
        let controller = fixture.makeController()

        controller.setUpModels()
        await controller.waitForCurrentActions()
        controller.startRecording()
        await controller.waitForCurrentActions()
        #expect(controller.viewModel.capability.message.title == "Speech Inference Failed")

        fixture.permission.state = .denied
        controller.refreshMicrophonePermission()

        let capability = controller.viewModel.capability
        #expect(capability.message.title == "Microphone Access Denied")
        #expect(capability.message.detail?.contains("Speech Inference Failed:") == true)
        #expect(capability.message.detail?.contains("could not be matched to timed segments") == true)
        #expect(capability.actions == [.openMicrophoneSettings])
        #expect(!capability.canStartRecording)
        await controller.shutdown()
    }

    @Test
    func shutdownDoesNotWaitForPendingPermissionOrStartLateCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.permission.holdsRequest = true
        let controller = fixture.makeController()
        controller.setUpModels()
        await controller.waitForCurrentActions()
        controller.startRecording()
        await fixture.permission.waitForRequest()

        await controller.shutdown()
        #expect(fixture.capture.startCount == 0)
        #expect(!fixture.factory.isLeaseActive)
        fixture.permission.resolveHeldRequest()
        await Task.yield()
        #expect(fixture.capture.startCount == 0)
    }
}
