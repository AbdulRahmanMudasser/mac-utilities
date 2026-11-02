import Foundation
import SwiftUI

enum TranscribeRuntimeMode: Equatable {
    case local
    case interactivePreview
}

enum TranscribeCapabilityAction: Hashable, Identifiable {
    case setUpModels
    case retrySetup
    case openMicrophoneSettings
    case retryHistory

    var id: Self { self }

    var title: String {
        switch self {
        case .setUpModels: "Set Up Models"
        case .retrySetup: "Retry Setup"
        case .openMicrophoneSettings: "Open Settings"
        case .retryHistory: "Retry History"
        }
    }
}

struct TranscribeCapabilityPresentation {
    let message: UtilityCapabilityMessage
    let isActive: Bool
    let canStartRecording: Bool
    let actions: [TranscribeCapabilityAction]
    let progressLabel: String?

    init(
        message: UtilityCapabilityMessage,
        isActive: Bool,
        actions: [TranscribeCapabilityAction] = [],
        canStartRecording: Bool,
        progressLabel: String? = nil
    ) {
        self.message = message
        self.isActive = isActive
        self.canStartRecording = canStartRecording
        self.actions = actions
        self.progressLabel = progressLabel
    }

    var accessibilityValue: String {
        message.combinedText
    }
}

struct TranscribeHistoryPresentation {
    enum State {
        case loaded(entries: [TranscriptionHistoryEntry])
        case unavailable(entries: [TranscriptionHistoryEntry])
    }

    let state: State
}

struct TranscribeViewModel {
    let language: TranscriptionLanguage
    let isLanguageSelectionLocked: Bool
    let canStopRecording: Bool
    let capability: TranscribeCapabilityPresentation
    let partialTranscript: String?
    let finalTranscript: String?
    let history: TranscribeHistoryPresentation
}

struct TranscribeViewActions {
    let selectLanguage: (TranscriptionLanguage) -> Void
    let startRecording: () -> Void
    let stopRecording: () -> Void
    let performCapabilityAction: ((TranscribeCapabilityAction) -> Void)?
    let copyHistoryEntry: (TranscriptionHistoryEntry) -> Bool
    let deleteHistoryEntry: (UUID) -> Void
    let clearHistory: () -> Void
}

struct TranscribeView: View {
    let model: TranscribeViewModel
    let actions: TranscribeViewActions
    @State private var confirmClearHistory = false

    private var languageBinding: Binding<TranscriptionLanguage> {
        Binding(
            get: { model.language },
            set: { actions.selectLanguage($0) }
        )
    }

    private var capabilityAction: AnyView? {
        guard model.capability.progressLabel != nil ||
                (!model.capability.actions.isEmpty && actions.performCapabilityAction != nil) else {
            return nil
        }

        return AnyView(
            HStack(spacing: UtilityStyle.contentSpacing) {
                if let progressLabel = model.capability.progressLabel {
                    ProgressView()
                        .controlSize(UtilityStyle.progressControlSize)
                        .accessibilityLabel(progressLabel)
                }
                if let perform = actions.performCapabilityAction {
                    ForEach(model.capability.actions) { capabilityAction in
                        Button(capabilityAction.title) {
                            perform(capabilityAction)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(capabilityAction.title)
                        .help(capabilityAction.title)
                        .handPointer()
                    }
                }
            }
        )
    }

    private var recordingAction: some View {
        Button {
            if model.canStopRecording {
                actions.stopRecording()
            } else {
                actions.startRecording()
            }
        } label: {
            Label(
                model.canStopRecording ? "Stop Recording" : "Start Recording",
                systemImage: model.canStopRecording ? "stop.fill" : "record.circle"
            )
        }
        .buttonStyle(.bordered)
        .disabled(!model.canStopRecording && !model.capability.canStartRecording)
        .handPointer()
    }

    private var finalTranscriptText: String? {
        nonempty(model.finalTranscript)
    }

    private var partialTranscriptText: String? {
        nonempty(model.partialTranscript)
    }

    var body: some View {
        UtilityScrollContent {
            capabilityCard

            UtilityPanel(
                "Transcribe",
                action: AnyView(recordingAction),
                showsContent: false
            ) {
                EmptyView()
            }

            UtilityPanel("Configuration") {
                HStack(spacing: UtilityStyle.contentSpacing) {
                    Text("Language")
                    Spacer(minLength: UtilityStyle.contentSpacing)
                    Picker("Language", selection: languageBinding) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .disabled(model.isLanguageSelectionLocked)
                    .accessibilityLabel("Transcription Language")
                    .accessibilityValue(model.language.displayName)
                    .handPointer()
                }

            }

            if finalTranscriptText != nil || partialTranscriptText != nil {
                UtilityPanel("Transcript") {
                    VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                        if let finalTranscriptText {
                            Text(finalTranscriptText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityLabel("Confirmed Transcript")
                                .accessibilityValue(finalTranscriptText)
                        }
                        if let partialTranscriptText {
                            liveTranscriptSection(partialTranscriptText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            UtilityPanel(
                "History",
                action: AnyView(clearHistoryButton),
                showsContent: historyShowsContent
            ) {
                historyContent
            }
        }
        .font(UtilityStyle.bodyFont)
        .controlSize(UtilityStyle.controlSize)
        .sheet(isPresented: $confirmClearHistory) { clearHistoryConfirmation }
    }

    private var capabilityCard: some View {
        UtilityCapabilityCard(
            message: model.capability.message,
            isActive: model.capability.isActive,
            action: capabilityAction
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcription Capability")
        .accessibilityValue(model.capability.accessibilityValue)
    }

    @ViewBuilder
    private var historyContent: some View {
        switch model.history.state {
        case let .loaded(entries):
            if entries.isEmpty {
                historyEmptyState
            } else {
                historyRows(entries)
            }

        case let .unavailable(entries):
            if !entries.isEmpty {
                historyRows(entries)
            }
        }
    }

    private var historyShowsContent: Bool {
        if case .unavailable(let entries) = model.history.state { return !entries.isEmpty }
        return true
    }

    private var canClearHistory: Bool {
        guard case .loaded(let entries) = model.history.state else { return false }
        return !entries.isEmpty
    }

    private var clearHistoryButton: some View {
        Button("Clear History", role: .destructive) {
            confirmClearHistory = true
        }
        .buttonStyle(.bordered)
        .handPointer()
        .disabled(!canClearHistory)
    }

    private var clearHistoryConfirmation: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            Text("Clear Transcription History?").font(UtilityStyle.headingFont)
            Text("This permanently removes all saved transcriptions. A recording in progress may add a new entry when it finishes.")
            HStack(spacing: UtilityStyle.contentSpacing) {
                Spacer()
                Button("Cancel", role: .cancel) { confirmClearHistory = false }
                    .keyboardShortcut(.defaultAction)
                Button("Clear History", role: .destructive) {
                    actions.clearHistory()
                    confirmClearHistory = false
                }
                .disabled(!canClearHistory)
            }
            .buttonStyle(.bordered)
            .handPointer()
        }
        .font(UtilityStyle.bodyFont)
        .padding(UtilityStyle.pagePadding)
        .frame(width: UtilityStyle.confirmationWidth)
        .onExitCommand { confirmClearHistory = false }
    }

    private var historyEmptyState: some View {
        VStack(spacing: UtilityStyle.contentSpacing) {
            Image(systemName: "waveform")
                .font(.title2)
                .accessibilityHidden(true)
            Text("No Transcriptions Yet")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: UtilityStyle.History.placeholderHeight)
        .padding(.vertical, UtilityStyle.cardPadding)
    }

    private func historyRows(_ entries: [TranscriptionHistoryEntry]) -> some View {
        let newestFirst = entries.reversed()
        return VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            ForEach(newestFirst) { entry in
                TranscribeHistoryRow(
                    entry: entry,
                    copy: { actions.copyHistoryEntry(entry) },
                    delete: { actions.deleteHistoryEntry(entry.id) }
                )
            }
        }
    }

    private func liveTranscriptSection(_ text: String) -> some View {
        HStack(alignment: .center, spacing: UtilityStyle.contentSpacing) {
            Image(systemName: "waveform")
                .font(UtilityStyle.metadataFont)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .baselineOffset(model.language == .urdu ? UtilityStyle.Transcribe.urduLiveTextBaselineOffset : 0)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Live Transcript")
                .accessibilityValue(text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nonempty(_ text: String?) -> String? {
        guard let text else { return nil }
        let displayText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty else {
            return nil
        }
        return displayText
    }
}

private struct TranscribeHistoryRow: View {
    let entry: TranscriptionHistoryEntry
    let copy: () -> Bool
    let delete: () -> Void
    @State private var copyGeneration = 0
    @State private var isCopied = false

    private var savedTimestamp: String {
        UtilityTimestampRow.timestampText(for: entry.savedAt, detail: nil)
    }

    private var displayText: String {
        entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            Text(displayText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: UtilityStyle.contentSpacing) {
                Text(savedTimestamp)
                    .font(UtilityStyle.metadataFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)

                Spacer(minLength: UtilityStyle.contentSpacing)

                Button {
                    guard copy() else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { isCopied = true }
                    copyGeneration += 1
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(UtilityStyle.iconButtonFont)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(
                            width: UtilityStyle.iconButtonSize,
                            height: UtilityStyle.iconButtonSize
                        )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Copy Transcription")
                .accessibilityValue(isCopied ? "Copied" : "")
                .accessibilityHint("Copies this history entry.")
                .help(isCopied ? "Copied" : "Copy")
                .handPointer()

                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                        .font(UtilityStyle.iconButtonFont)
                        .frame(
                            width: UtilityStyle.iconButtonSize,
                            height: UtilityStyle.iconButtonSize
                        )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Delete Transcription")
                .accessibilityHint("Deletes this history entry immediately.")
                .help("Delete")
                .handPointer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcription History Entry")
        .accessibilityValue(savedTimestamp)
        .task(id: copyGeneration) {
            guard copyGeneration > 0 else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                withAnimation(.easeInOut(duration: 0.15)) { isCopied = false }
            } catch { }
        }
    }
}
