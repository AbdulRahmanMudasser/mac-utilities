import AppKit
import Combine
import Foundation

@MainActor
protocol TranscribeAssetSettingUp: AnyObject {
    func acquireAssets(for language: TranscriptionLanguage, progress: @escaping @Sendable (SpeechAssetAcquisitionProgress) -> Void) async throws
}

@MainActor
final class SpeechAssetTranscribeSetup: TranscribeAssetSettingUp {
    private let acquisition: SpeechAssetAcquisition
    private let chooseUrduModel: @MainActor () async -> URL?

    init(acquisition: SpeechAssetAcquisition, chooseUrduModel: @escaping @MainActor () async -> URL? = {
        let panel = NSOpenPanel()
        panel.title = "Select Urdu Speech Model"
        panel.message = "Choose the downloaded Urdu Sukhan q5 model file."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                panel.begin { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
    }) {
        self.acquisition = acquisition
        self.chooseUrduModel = chooseUrduModel
    }

    func acquireAssets(for language: TranscriptionLanguage, progress: @escaping @Sendable (SpeechAssetAcquisitionProgress) -> Void) async throws {
        do {
            _ = try await acquisition.acquireAssets(forLanguageCode: language.rawValue, progress: progress)
        } catch SpeechAssetAcquisitionError.languageUnavailable("ur") where language == .urdu {
            guard let url = await chooseUrduModel() else { throw CancellationError() }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            try Task.checkCancellation()
            try await acquisition.importUrduModel(from: url)
            _ = try await acquisition.acquireAssets(forLanguageCode: language.rawValue, progress: progress)
        }
    }
}

@MainActor
protocol TranscribeRecognizerLeaseFactory: AnyObject {
    func withPreparedRecognizer(
        for language: TranscriptionLanguage,
        operation: @escaping @MainActor @Sendable (any TranscriptionRecognizing) async -> Void
    ) async throws
}

@MainActor
final class SpeechAssetTranscribeRecognizerFactory: TranscribeRecognizerLeaseFactory {
    private let inferenceFactory: SpeechAssetInferenceFactory

    init(inferenceFactory: SpeechAssetInferenceFactory) {
        self.inferenceFactory = inferenceFactory
    }

    func withPreparedRecognizer(
        for language: TranscriptionLanguage,
        operation: @escaping @MainActor @Sendable (any TranscriptionRecognizing) async -> Void
    ) async throws {
        try await inferenceFactory.withInference(forLanguageCode: language.rawValue) { inference in
            let recognizer = try await MainActor.run {
                try StreamingTranscriptionRecognizer(inference: inference)
            }
            await operation(recognizer)
        }
    }
}

@MainActor
final class TranscribeFeatureController: ObservableObject {
    private struct OperationFailure: Equatable {
        let title: String
        let detail: String
        var actions: [TranscribeCapabilityAction] = []
    }

    private enum SetupState {
        case required
        case running
        case ready
        case failed(String)
    }

    private let capture: any AudioCapturing
    private let permission: any MicrophonePermissionChecking
    private let history: any TranscriptionHistoryStoring
    private let assetSetup: any TranscribeAssetSettingUp
    private let recognizerFactory: any TranscribeRecognizerLeaseFactory
    private let runtimeMode: TranscribeRuntimeMode
    private let copyToPasteboard: @MainActor (String) -> Bool
    private let recognizerProxy = LeasedTranscriptionRecognizer()
    private let coordinator: TranscriptionSessionCoordinator
    private var coordinatorSubscription: AnyCancellable?

    @Published private var setupState: SetupState = .required
    @Published private var isPreparingInference = false
    @Published private var isStartingRecording = false
    @Published private var isStoppingRecording = false
    @Published private var operationFailure: OperationFailure?
    @Published private var setupProgressDetail: String?
    private var setupGeneration: UUID?

    private var setupTask: Task<Void, Never>?
    private var startActionTask: Task<Void, Never>?
    private var stopActionTask: Task<Void, Never>?
    private var leaseRun: LeaseRun?
    private var isShuttingDown = false

    init(
        capture: any AudioCapturing,
        permission: any MicrophonePermissionChecking,
        history: any TranscriptionHistoryStoring,
        languagePreferences: TranscriptionLanguagePreferenceStore,
        assetSetup: any TranscribeAssetSettingUp,
        recognizerFactory: any TranscribeRecognizerLeaseFactory,
        runtimeMode: TranscribeRuntimeMode = .local,
        copyToPasteboard: @escaping @MainActor (String) -> Bool = { text in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
    ) {
        self.capture = capture
        self.permission = permission
        self.history = history
        self.assetSetup = assetSetup
        self.recognizerFactory = recognizerFactory
        self.runtimeMode = runtimeMode
        self.copyToPasteboard = copyToPasteboard
        coordinator = TranscriptionSessionCoordinator(
            capture: capture,
            recognizer: recognizerProxy,
            permission: permission,
            history: history,
            languagePreferences: languagePreferences
        )
        if runtimeMode == .interactivePreview { setupState = .ready }
        coordinatorSubscription = coordinator.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
    }

    var viewModel: TranscribeViewModel {
        let capability = capabilityPresentation
        return TranscribeViewModel(
            language: coordinator.selectedLanguage,
            isLanguageSelectionLocked: isSessionInProgress,
            canStopRecording: isPreparingInference || coordinator.phase == .requestingPermission || coordinator.phase == .recording,
            capability: capability,
            partialTranscript: coordinator.provisionalTranscript,
            finalTranscript: coordinator.finalizedTranscript,
            history: TranscribeHistoryPresentation(
                state: coordinator.historyError == nil
                    ? .loaded(entries: coordinator.historyEntries)
                    : .unavailable(entries: coordinator.historyEntries)
            )
        )
    }

    var actions: TranscribeViewActions {
        let canPerformCapabilityAction = !capabilityPresentation.actions.isEmpty
        return TranscribeViewActions(
            selectLanguage: { [weak self] in self?.selectLanguage($0) },
            startRecording: { [weak self] in self?.startRecording() },
            stopRecording: { [weak self] in self?.stopRecording() },
            performCapabilityAction: canPerformCapabilityAction
                ? { [weak self] in self?.performCapabilityAction($0) }
                : nil,
            copyHistoryEntry: { [weak self] in self?.copyHistoryEntry($0) ?? false },
            deleteHistoryEntry: { [weak self] in self?.deleteHistoryEntry(id: $0) },
            clearHistory: { [weak self] in self?.clearHistory() }
        )
    }

    private var isSessionInProgress: Bool {
        if case .running = setupState { return true }
        return isPreparingInference || isStartingRecording || isStoppingRecording || coordinator.isLanguageSelectionLocked
    }

    private var canStartRecording: Bool {
        guard !isShuttingDown,
              !isSessionInProgress,
              permission.state != .denied else { return false }
        return switch runtimeMode {
        case .local:
            setupIsReady
        case .interactivePreview:
            true
        }
    }

    private var setupIsReady: Bool {
        if case .ready = setupState { return true }
        return false
    }

    func refreshMicrophonePermission() {
        objectWillChange.send()
    }

    private var capabilityPresentation: TranscribeCapabilityPresentation {
        let base = baseCapabilityPresentation
        guard !isShuttingDown else { return base }

        var additionalDetails: [String] = []
        var additionalActions: [TranscribeCapabilityAction] = []

        if let operationFailure,
           base.message.title != operationFailure.title || base.message.detail != operationFailure.detail {
            additionalDetails.append("\(operationFailure.title): \(operationFailure.detail)")
            additionalActions.append(contentsOf: operationFailure.actions)
        }

        let deniedPermissionErrorIsAlreadyShown = permission.state == .denied &&
            coordinator.sessionErrorTitle == "Microphone Access Denied"
        if let sessionError = coordinator.sessionError,
           !deniedPermissionErrorIsAlreadyShown,
           (base.message.title != coordinator.sessionErrorTitle || base.message.detail != sessionError) {
            additionalDetails.append("\(coordinator.sessionErrorTitle ?? "Transcription Failed"): \(sessionError)")
        }

        if let historyError = coordinator.historyError {
            if !isShuttingDown {
                additionalActions.append(.retryHistory)
            }
            if base.message.title == "Speech Models Ready", additionalDetails.isEmpty {
                return .init(
                    message: UtilityCapabilityMessage(title: "Transcription History Unavailable", detail: historyError),
                    isActive: false,
                    actions: [.retryHistory],
                    canStartRecording: base.canStartRecording,
                    progressLabel: base.progressLabel
                )
            }
            additionalDetails.append("Transcription history is also unavailable: \(historyError)")
        }

        guard !additionalDetails.isEmpty else { return base }
        let detail = ([base.message.detail] + additionalDetails)
            .compactMap { $0 }
            .joined(separator: " ")
        var actions: [TranscribeCapabilityAction] = []
        for action in base.actions + additionalActions where !actions.contains(action) {
            actions.append(action)
        }
        return .init(
            message: UtilityCapabilityMessage(title: base.message.title, detail: detail),
            isActive: false,
            actions: actions,
            canStartRecording: base.canStartRecording,
            progressLabel: base.progressLabel
        )
    }

    private var baseCapabilityPresentation: TranscribeCapabilityPresentation {
        if isShuttingDown {
            return .init(
                message: UtilityCapabilityMessage(title: "Transcription Shutting Down", detail: nil),
                isActive: false,
                canStartRecording: false,
                progressLabel: "Shutting Down Transcription"
            )
        }
        if coordinator.phase == .recording {
            return .init(
                message: UtilityCapabilityMessage(
                    title: runtimeMode == .interactivePreview ? "Recording Preview" : "Recording",
                    detail: runtimeMode == .interactivePreview ? "Capture is simulated; no microphone is active." : nil
                ),
                isActive: true,
                canStartRecording: false
            )
        }
        if isPreparingInference || isStartingRecording {
            return .init(
                message: UtilityCapabilityMessage(
                    title: runtimeMode == .interactivePreview ? "Preparing Preview" : "Preparing Inference",
                    detail: runtimeMode == .interactivePreview
                        ? "Preparing simulated capture and transcript generation."
                        : "The selected local model is being prepared."
                ),
                isActive: false,
                canStartRecording: false,
                progressLabel: runtimeMode == .interactivePreview ? "Preparing Preview" : "Preparing Speech Model"
            )
        }
        if coordinator.phase == .requestingPermission {
            return .init(
                message: UtilityCapabilityMessage(
                    title: runtimeMode == .interactivePreview ? "Preparing Preview Recording" : "Waiting For Microphone Permission",
                    detail: runtimeMode == .interactivePreview ? "Microphone permission is simulated." : nil
                ),
                isActive: false,
                canStartRecording: false,
                progressLabel: runtimeMode == .interactivePreview ? "Preparing Preview Recording" : "Requesting Microphone Permission"
            )
        }
        if coordinator.phase == .processing {
            return .init(
                message: UtilityCapabilityMessage(
                    title: runtimeMode == .interactivePreview ? "Finalizing Preview Transcript" : "Finalizing Transcription",
                    detail: runtimeMode == .interactivePreview ? "Saving simulated transcript text." : nil
                ),
                isActive: false,
                canStartRecording: false,
                progressLabel: runtimeMode == .interactivePreview ? "Finalizing Preview Transcript" : "Finalizing Transcription"
            )
        }
        if coordinator.phase == .cancelling {
            return .init(
                message: UtilityCapabilityMessage(title: "Stopping Transcription", detail: nil),
                isActive: false,
                canStartRecording: false,
                progressLabel: "Stopping Transcription"
            )
        }
        if runtimeMode == .interactivePreview {
            return .init(
                message: UtilityCapabilityMessage(
                    title: "Interactive Preview Ready",
                    detail: "Microphone permission, capture and transcription are simulated; no microphone or speech model is used."
                ),
                isActive: true,
                canStartRecording: canStartRecording
            )
        }
        if permission.state == .denied {
            return microphoneDeniedPresentation
        }
        if let operationFailure {
            return .init(
                message: UtilityCapabilityMessage(title: operationFailure.title, detail: operationFailure.detail),
                isActive: false,
                actions: operationFailure.actions,
                canStartRecording: canStartRecording
            )
        }
        if let sessionError = coordinator.sessionError {
            return .init(
                message: UtilityCapabilityMessage(
                    title: coordinator.sessionErrorTitle ?? "Transcription Failed",
                    detail: sessionError
                ),
                isActive: false,
                canStartRecording: canStartRecording
            )
        }
        switch setupState {
        case .required:
            return .init(
                message: UtilityCapabilityMessage(
                    title: "Speech Models Not Ready",
                    detail: "Set up the \(coordinator.selectedLanguage.displayName) speech models before recording."
                ),
                isActive: false,
                actions: [.setUpModels],
                canStartRecording: false
            )
        case .running:
            return .init(
                message: UtilityCapabilityMessage(title: "Setting Up Speech Models", detail: setupProgressDetail),
                isActive: false,
                canStartRecording: false,
                progressLabel: "Setting Up Speech Models"
            )
        case .ready:
            return .init(
                message: UtilityCapabilityMessage(title: "Speech Models Ready", detail: nil),
                isActive: true,
                canStartRecording: canStartRecording
            )
        case .failed(let message):
            return .init(
                message: UtilityCapabilityMessage(title: "Speech Model Setup Failed", detail: message),
                isActive: false,
                actions: [.retrySetup],
                canStartRecording: false
            )
        }
    }

    private var microphoneDeniedPresentation: TranscribeCapabilityPresentation {
        switch setupState {
        case .required:
            return .init(
                message: UtilityCapabilityMessage(
                    title: "Transcription Not Ready",
                    detail: "Set up the \(coordinator.selectedLanguage.displayName) speech models and allow microphone access in System Settings before recording."
                ),
                isActive: false,
                actions: [.setUpModels, .openMicrophoneSettings],
                canStartRecording: false
            )
        case .running:
            let detail = [setupProgressDetail, "Microphone access is denied in System Settings."]
                .compactMap { $0 }
                .joined(separator: " ")
            return .init(
                message: UtilityCapabilityMessage(title: "Setting Up Speech Models", detail: detail),
                isActive: false,
                actions: [.openMicrophoneSettings],
                canStartRecording: false,
                progressLabel: "Setting Up Speech Models"
            )
        case .ready:
            return .init(
                message: UtilityCapabilityMessage(
                    title: "Microphone Access Denied",
                    detail: "Allow microphone access in System Settings to record."
                ),
                isActive: false,
                actions: [.openMicrophoneSettings],
                canStartRecording: false
            )
        case .failed(let message):
            return .init(
                message: UtilityCapabilityMessage(
                    title: "Speech Model Setup Failed",
                    detail: "\(message) Microphone access is also denied in System Settings."
                ),
                isActive: false,
                actions: [.retrySetup, .openMicrophoneSettings],
                canStartRecording: false
            )
        }
    }

    private func performCapabilityAction(_ action: TranscribeCapabilityAction) {
        switch action {
        case .retryHistory:
            coordinator.reloadHistory()
        case .openMicrophoneSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .setUpModels, .retrySetup:
            setUpModels()
        }
    }

    func selectLanguage(_ language: TranscriptionLanguage) {
        guard !isShuttingDown else { return }
        guard !isSessionInProgress else {
            operationFailure = OperationFailure(
                title: "Language Could Not Be Changed",
                detail: TranscriptionSessionCoordinatorError.languageChangeWhileSessionActive.localizedDescription
            )
            return
        }
        do {
            let changed = coordinator.selectedLanguage != language
            try coordinator.selectLanguage(language)
            if changed, runtimeMode == .local { setUpModels() }
            operationFailure = nil
        } catch {
            operationFailure = OperationFailure(title: "Language Could Not Be Changed", detail: Self.message(for: error))
        }
    }

    func setUpModels() {
        guard runtimeMode == .local,
              !isShuttingDown,
              setupTask == nil,
              !isSessionInProgress else { return }

        setupState = .running
        setupProgressDetail = "Checking speech models."
        operationFailure = nil
        let generation = UUID()
        setupGeneration = generation
        let setup = assetSetup
        let selectedLanguage = coordinator.selectedLanguage
        setupTask = Task { @MainActor [weak self] in
            do {
                try await setup.acquireAssets(for: selectedLanguage) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isShuttingDown, self.setupGeneration == generation else { return }
                        switch progress {
                        case .downloading(let asset, let received, let expected):
                            let label = asset == .vad ? "Speech detector" : "\(selectedLanguage.displayName) model"
                            let percent = expected > 0 ? min(100, Int(Double(received) * 100 / Double(expected))) : 0
                            self.setupProgressDetail = "Downloading \(label): \(percent)%."
                        case .verifying:
                            self.setupProgressDetail = "Verifying downloaded files."
                        default:
                            break
                        }
                    }
                }
                guard let self, !self.isShuttingDown, self.setupGeneration == generation else { return }
                guard !Task.isCancelled else {
                    self.finishSetup(generation: generation, state: .required)
                    return
                }
                self.finishSetup(generation: generation, state: .ready)
            } catch {
                guard let self, !self.isShuttingDown, self.setupGeneration == generation else { return }
                let state: SetupState = Task.isCancelled || error is CancellationError
                    ? .required
                    : .failed(Self.message(for: error))
                self.finishSetup(generation: generation, state: state)
            }
        }
    }

    private func finishSetup(generation: UUID, state: SetupState) {
        guard setupGeneration == generation else { return }
        setupTask = nil
        setupGeneration = nil
        setupState = state
    }

    func startRecording() {
        guard canStartRecording, startActionTask == nil else { return }
        isStartingRecording = true
        startActionTask = Task { @MainActor [weak self] in
            await self?.performStartRecording()
            guard let self else { return }
            self.startActionTask = nil
            self.isStartingRecording = false
        }
    }

    private func performStartRecording() async {
        guard !isShuttingDown else { return }
        guard setupIsReady else { return }

        operationFailure = nil
        isPreparingInference = true
        let language = coordinator.selectedLanguage
        let run = LeaseRun()
        leaseRun = run
        let factory = recognizerFactory
        let proxy = recognizerProxy
        run.task = Task { @MainActor in
            do {
                try await factory.withPreparedRecognizer(for: language) { recognizer in
                    proxy.install(recognizer, lifetime: run.lifetime)
                    await run.preparation.resolve(.ready)
                    await run.lifetime.waitUntilFinished()
                    proxy.clear()
                }
                await run.preparation.resolve(.failed("The selected speech model could not be prepared."))
            } catch {
                run.error = error
                await run.preparation.resolve(.failed(Self.message(for: error)))
            }
        }

        let preparation = await run.preparation.wait()
        isPreparingInference = false
        guard case .ready = preparation else {
            if case .failed(let message) = preparation {
                let needsSetup = Self.requiresModelSetup(for: run.error)
                if needsSetup { setupState = .required }
                operationFailure = OperationFailure(
                    title: "Speech Model Preparation Failed",
                    detail: message,
                    actions: needsSetup ? [.setUpModels] : []
                )
            }
            await release(run)
            return
        }
        guard !isShuttingDown, !Task.isCancelled else {
            await release(run)
            return
        }

        do {
            try await coordinator.start()
        } catch {
            let title = error is AudioCaptureFailure ? "Audio Capture Failed" : "Recording Could Not Start"
            operationFailure = OperationFailure(title: title, detail: Self.message(for: error))
            await release(run)
            return
        }
        if coordinator.phase == .recording {
            await coordinator.waitForRecognition()
        }
        await release(run)
    }

    func stopRecording() {
        guard !isShuttingDown, stopActionTask == nil else { return }
        isStoppingRecording = true
        stopActionTask = Task { @MainActor [weak self] in
            await self?.performStopRecording()
            guard let self else { return }
            self.stopActionTask = nil
            self.isStoppingRecording = false
        }
    }

    private func performStopRecording() async {
        guard let run = leaseRun else {
            await coordinator.stop()
            await coordinator.join()
            return
        }

        if coordinator.phase == .recording || coordinator.phase == .processing {
            await coordinator.stop()
        } else {
            startActionTask?.cancel()
            run.task?.cancel()
            await coordinator.cancel()
            await coordinator.join()
            await run.lifetime.finish()
            if let startActionTask { await startActionTask.value }
        }
        await release(run)
    }

    @discardableResult
    func copyHistoryEntry(_ entry: TranscriptionHistoryEntry) -> Bool {
        operationFailure = nil
        guard let current = coordinator.historyEntries.first(where: { $0.id == entry.id }) else { return false }
        guard copyToPasteboard(current.text) else {
            operationFailure = OperationFailure(
                title: "Copy Failed",
                detail: "The transcription could not be copied. Please try again."
            )
            return false
        }
        return true
    }

    func deleteHistoryEntry(id: UUID) {
        operationFailure = nil
        coordinator.deleteHistoryEntry(id: id)
    }

    func clearHistory() {
        operationFailure = nil
        coordinator.clearHistory()
    }

    func shutdown() async {
        guard !isShuttingDown else {
            await coordinator.join()
            if let leaseRun { await leaseRun.task?.value }
            return
        }
        isShuttingDown = true
        setupTask?.cancel()
        startActionTask?.cancel()
        leaseRun?.task?.cancel()
        await coordinator.shutdown()
        if let leaseRun { await leaseRun.lifetime.finish() }
        if let setupTask { await setupTask.value }
        if let startActionTask { await startActionTask.value }
        if let stopActionTask { await stopActionTask.value }
        if let leaseRun { await release(leaseRun) }
        coordinatorSubscription = nil
    }

    func waitForCurrentActions() async {
        if let setupTask { await setupTask.value }
        if let startActionTask { await startActionTask.value }
        if let stopActionTask { await stopActionTask.value }
    }

    private func release(_ run: LeaseRun) async {
        await run.lifetime.finish()
        if let task = run.task { await task.value }
        if leaseRun === run {
            recognizerProxy.clear()
            leaseRun = nil
        }
    }

    private static func requiresModelSetup(for error: (any Error)?) -> Bool {
        guard let error = error as? SpeechModelStoreError else { return false }
        switch error {
        case .modelUnavailable, .assetUnavailable, .modelNotInstalled, .installedModelInvalid:
            return true
        case .invalidFileURL, .unsafeStorageDirectory, .unsafeSourceFile, .unsafeDestination,
             .sourceByteCountMismatch, .checksumMismatch, .stagedModelInvalid, .assetInUse,
             .fileSystem:
            return false
        }
    }

    private static func message(for error: any Error) -> String {
        let description = error.localizedDescription
        return description.isEmpty ? "Transcription could not be completed." : description
    }
}

@MainActor
private final class LeaseRun {
    let lifetime = TranscriptionLeaseLifetime()
    let preparation = TranscriptionPreparationSignal()
    var task: Task<Void, Never>?
    var error: (any Error)?
}

private actor TranscriptionPreparationSignal {
    enum Outcome {
        case ready
        case failed(String)
    }

    private var result: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func resolve(_ result: Outcome) {
        guard self.result == nil else { return }
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
    }
}

private actor TranscriptionLeaseLifetime {
    private var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilFinished() async {
        guard !isFinished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class LeasedTranscriptionRecognizer: TranscriptionRecognizing {
    private struct ActiveRecognizer {
        let recognizer: any TranscriptionRecognizing
        let lifetime: TranscriptionLeaseLifetime
    }

    private var active: ActiveRecognizer?

    func install(_ recognizer: any TranscriptionRecognizing, lifetime: TranscriptionLeaseLifetime) {
        active = ActiveRecognizer(recognizer: recognizer, lifetime: lifetime)
    }

    func clear() {
        active = nil
    }

    func transcribe(
        audio: AudioCaptureStream,
        language: TranscriptionLanguage,
        generation: UUID,
        onEvent: @escaping @MainActor @Sendable (TranscriptionRecognitionEvent) -> Void
    ) async throws -> TranscriptionRecognitionResult {
        guard let active else { throw TranscriptionSessionCoordinatorError.shutdown }
        do {
            let result = try await active.recognizer.transcribe(
                audio: audio,
                language: language,
                generation: generation,
                onEvent: onEvent
            )
            await active.lifetime.finish()
            return result
        } catch {
            await active.lifetime.finish()
            throw error
        }
    }

    func cancel(generation: UUID) async {
        guard let active else { return }
        await active.recognizer.cancel(generation: generation)
        await active.lifetime.finish()
    }
}
