import AppKit
import SwiftUI
import Testing
@testable import Mac_Utilities

@Suite(.serialized)
@MainActor
struct TranscribeWindowLifecycleTests {
    @MainActor
    private final class Fixture {
        let directory: URL
        let historyURL: URL
        let history: TranscriptionHistoryStore
        let preferences: UserDefaults
        let capture = FakeCapture()
        let permission = FakePermission()
        let setup = FakeSetup()
        let recognizer = FakeRecognizer()
        let recognizerFactory: FakeRecognizerFactory
        private let suiteName: String

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcribe-window-lifecycle-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            historyURL = directory.appendingPathComponent("history.json")
            history = TranscriptionHistoryStore(historyURL: historyURL)

            suiteName = "MacUtilities.TranscribeWindowLifecycleTests.\(UUID().uuidString)"
            preferences = try #require(UserDefaults(suiteName: suiteName))
            recognizerFactory = FakeRecognizerFactory(recognizer: recognizer)
        }

        func makeController() -> TranscribeFeatureController {
            TranscribeFeatureController(
                capture: capture,
                permission: permission,
                history: history,
                languagePreferences: TranscriptionLanguagePreferenceStore(preferences: preferences),
                assetSetup: setup,
                recognizerFactory: recognizerFactory,
                copyToPasteboard: { _ in true }
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
            preferences.removePersistentDomain(forName: suiteName)
        }
    }

    @MainActor
    private final class AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var isWaiting = false

        func wait() async {
            guard !released else { return }
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class FakeCapture: AudioCapturing {
        private var continuation: AudioCaptureStream.Continuation?
        let cancellationGate = AsyncGate()
        private(set) var isCapturing = false
        private(set) var cancellationCompleted = false

        func start() throws -> AudioCaptureStream {
            let (stream, continuation) = AudioCaptureStream.makeStream(bufferingPolicy: .unbounded)
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
            await cancellationGate.wait()
            isCapturing = false
            continuation?.finish(throwing: CancellationError())
            continuation = nil
            cancellationCompleted = true
        }
    }

    @MainActor
    private final class FakePermission: MicrophonePermissionChecking {
        let state: MicrophonePermissionState = .granted

        func request() async -> MicrophonePermissionState { .granted }
    }

    @MainActor
    private final class FakeSetup: TranscribeAssetSettingUp {
        func acquireAssets(for language: TranscriptionLanguage,
            progress: @escaping @Sendable (SpeechAssetAcquisitionProgress) -> Void
        ) async throws { }
    }

    @MainActor
    private final class FakeRecognizerFactory: TranscribeRecognizerLeaseFactory {
        let recognizer: any TranscriptionRecognizing
        private(set) var isLeaseActive = false
        private(set) var didReleaseLease = false

        init(recognizer: any TranscriptionRecognizing) {
            self.recognizer = recognizer
        }

        func withPreparedRecognizer(
            for language: TranscriptionLanguage,
            operation: @escaping @MainActor @Sendable (any TranscriptionRecognizing) async -> Void
        ) async throws {
            isLeaseActive = true
            didReleaseLease = false
            defer {
                isLeaseActive = false
                didReleaseLease = true
            }
            await operation(recognizer)
        }
    }

    @MainActor
    private final class FakeRecognizer: TranscriptionRecognizing {
        let inferenceGate = AsyncGate()
        let cancellationGate = AsyncGate()
        private var completionContinuation: CheckedContinuation<Void, Never>?
        private(set) var isInferenceActive = false
        private(set) var didCompleteInference = false
        private(set) var cancellationCompleted = false

        func transcribe(
            audio: AudioCaptureStream,
            language: TranscriptionLanguage,
            generation: UUID,
            onEvent: @escaping @MainActor @Sendable (TranscriptionRecognitionEvent) -> Void
        ) async throws -> TranscriptionRecognitionResult {
            isInferenceActive = true
            await inferenceGate.wait()
            isInferenceActive = false
            didCompleteInference = true
            completionContinuation?.resume()
            completionContinuation = nil
            try Task.checkCancellation()
            return TranscriptionRecognitionResult(text: "synthetic transcript")
        }

        func cancel(generation: UUID) async {
            await cancellationGate.wait()
            inferenceGate.release()
            if isInferenceActive {
                await withCheckedContinuation { completionContinuation = $0 }
            }
            cancellationCompleted = true
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func prepareRecording(
        controller: TranscribeFeatureController,
        fixture: Fixture
    ) async -> Bool {
        controller.setUpModels()
        await controller.waitForCurrentActions()
        controller.startRecording()
        return await waitUntil {
            fixture.capture.isCapturing &&
            controller.viewModel.canStopRecording &&
            fixture.recognizer.isInferenceActive &&
            fixture.recognizerFactory.isLeaseActive
        }
    }

    private func makeWindow(
        diagnostics: ConnectionDiagnostics,
        controller: TranscribeFeatureController
    ) -> UtilityWindowCoordinator {
        UtilityWindowCoordinator(
            diagnostics: diagnostics,
            setActivationPolicy: { _ in },
            activateApplication: {}
        ) { coordinator in
            AnyView(
                UtilityWindowView()
                    .environmentObject(coordinator)
                    .environmentObject(diagnostics)
                    .environmentObject(controller)
            )
        }
    }

    @Test
    func closingTranscribeWindowLeavesActiveRecordingAndModelLeaseRunning() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        let diagnostics = ConnectionDiagnostics()
        let window = makeWindow(diagnostics: diagnostics, controller: controller)
        let delegate = AppDelegate()
        delegate.utilityWindow = window
        delegate.transcribeController = controller
        defer { window.shutdown() }

        let recordingPrepared = await prepareRecording(controller: controller, fixture: fixture)
        #expect(recordingPrepared)
        #expect(!FileManager.default.fileExists(atPath: fixture.historyURL.path))

        window.present(.transcribe)
        window.window?.close()

        #expect(controller.viewModel.canStopRecording)
        #expect(fixture.capture.isCapturing)
        #expect(fixture.recognizer.isInferenceActive)
        #expect(fixture.recognizerFactory.isLeaseActive)
        #expect(!FileManager.default.fileExists(atPath: fixture.historyURL.path))

        fixture.capture.cancellationGate.release()
        fixture.recognizer.cancellationGate.release()
        await controller.shutdown()
        #expect(!fixture.capture.isCapturing)
        #expect(!fixture.recognizerFactory.isLeaseActive)
        #expect(!FileManager.default.fileExists(atPath: fixture.historyURL.path))
    }

    @Test
    func applicationTerminationWaitsForCaptureInferenceAndModelLeaseShutdown() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        let delegate = AppDelegate()
        delegate.transcribeController = controller
        var replies: [Bool] = []
        var cleanupAtReply: (captureStopped: Bool, inferenceStopped: Bool, leaseReleased: Bool)?
        delegate.replyToTermination = { shouldTerminate in
            replies.append(shouldTerminate)
            cleanupAtReply = (
                captureStopped: fixture.capture.cancellationCompleted && !fixture.capture.isCapturing,
                inferenceStopped: fixture.recognizer.cancellationCompleted && fixture.recognizer.didCompleteInference,
                leaseReleased: fixture.recognizerFactory.didReleaseLease && !fixture.recognizerFactory.isLeaseActive
            )
        }

        let recordingPrepared = await prepareRecording(controller: controller, fixture: fixture)
        #expect(recordingPrepared)
        #expect(!FileManager.default.fileExists(atPath: fixture.historyURL.path))

        let reply = delegate.applicationShouldTerminate(NSApp)
        #expect(reply == .terminateLater)
        #expect(replies.isEmpty)

        let captureShutdownStarted = await waitUntil { fixture.capture.cancellationGate.isWaiting }
        #expect(captureShutdownStarted)
        #expect(replies.isEmpty)
        #expect(fixture.capture.isCapturing)
        #expect(fixture.recognizer.isInferenceActive)
        #expect(fixture.recognizerFactory.isLeaseActive)

        fixture.capture.cancellationGate.release()
        let inferenceShutdownStarted = await waitUntil { fixture.recognizer.cancellationGate.isWaiting }
        #expect(inferenceShutdownStarted)
        #expect(replies.isEmpty)
        #expect(!fixture.capture.isCapturing)
        #expect(fixture.recognizer.isInferenceActive)
        #expect(fixture.recognizerFactory.isLeaseActive)

        fixture.recognizer.cancellationGate.release()
        let terminationReplied = await waitUntil { !replies.isEmpty }
        #expect(terminationReplied)
        #expect(replies == [true])
        #expect(cleanupAtReply?.captureStopped == true)
        #expect(cleanupAtReply?.inferenceStopped == true)
        #expect(cleanupAtReply?.leaseReleased == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.historyURL.path))

        await controller.shutdown()
    }
}
