import AppKit
import SwiftUI

struct KeepAwakeView: View {
    @EnvironmentObject private var controller: KeepAwakeController
    @State private var minuteInputs: [KeepAwakePresetID: String] = [:]
    @State private var validationMessage: String?

    private var activeBinding: Binding<Bool> {
        Binding(
            get: { controller.isActive },
            set: { controller.setActive($0) }
        )
    }

    private var displayBinding: Binding<Bool> {
        Binding(
            get: { controller.isKeepDisplayOn },
            set: { controller.setKeepDisplayOn($0) }
        )
    }

    var body: some View {
        UtilityScrollContent {
            UtilityPanel(
                "Keep Awake",
                action: AnyView(
                    Toggle("Keep Awake", isOn: activeBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Keep Awake")
                        .disabled(controller.isStartBlocked && !controller.isActive)
                        .handPointer()
                ),
                description: "Prevents idle sleep during downloads, builds, and other long tasks. It stops at the selected time, when you turn it off, or when Mac Utilities quits.",
                showsContent: false
            ) {
                EmptyView()
            }

            UtilityPanel("Current Session") {
                UtilityValueRow(title: "Status", value: controller.isActive ? "On" : "Off")
                UtilityValueRow(title: controller.isActive ? "Session Preset" : "Selected Preset",
                                value: currentPresetTitle)
                UtilityValueRow(title: "Started", value: sessionDate(controller.activeSession?.startedAt) ?? "Not Active")
                UtilityValueRow(title: "Ends", value: endTimeText)
                UtilityValueRow(title: "Remaining", value: remainingText)

                if let message = controller.errorMessage {
                    messageText(message)
                }
                if let message = controller.warningMessage {
                    messageText(message)
                }
            }

            if let lastSession = controller.lastSession {
                UtilityTimestampRow(
                    date: lastSession.startedAt,
                    title: "Last Ran",
                    symbol: "hourglass",
                    detail: lastSession.duration.title
                )
            }

            UtilityPanel(
                "Keep Display On",
                action: AnyView(
                    Toggle("Keep Display On", isOn: displayBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Keep Display On")
                        .handPointer()
                ),
                showsContent: false
            ) {
                EmptyView()
            }

            VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                UtilityPanel(
                    "Duration Presets",
                    description: "Enable two to four presets. Timed presets use unique whole-minute values from 1 to 1,440.",
                    wrapsContent: false
                ) {
                    VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                        presetEditor

                        if let validationMessage {
                            messageText(validationMessage)
                        }
                        if let message = controller.preferenceError {
                            messageText(message)
                        }
                    }
                    .padding(.horizontal, UtilityStyle.cardPadding)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .utilityCardBackground()
                }

                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        controller.restoreDefaultPresets()
                        validationMessage = nil
                        syncMinuteInputs(controller.presetConfiguration)
                    }
                    .buttonStyle(.bordered)
                    .handPointer()
                }
            }
        }
        .font(UtilityStyle.bodyFont)
        .controlSize(UtilityStyle.controlSize)
        .onAppear { syncMinuteInputs(controller.presetConfiguration) }
        .onChange(of: controller.presetConfiguration) { _, configuration in
            syncMinuteInputs(configuration)
        }
    }

    private var currentPresetTitle: String {
        if let activeSession = controller.activeSession {
            return activeSession.duration.editorTitle
        }
        return controller.presetConfiguration.presets
            .first(where: { $0.id == controller.selectedPresetID })?.title ?? "Not Available"
    }

    private var endTimeText: String {
        guard let session = controller.activeSession else { return "Not Active" }
        guard let end = session.endsAt else { return "Until Stopped" }
        return sessionDate(end) ?? "Not Available"
    }

    private var remainingText: String {
        guard let session = controller.activeSession else { return "Not Active" }
        return controller.remainingText ?? (session.duration.isTimed ? "Not Available" : "Until Stopped")
    }

    @ViewBuilder
    private var presetEditor: some View {
        VStack(spacing: 0) {
            ForEach(controller.presetConfiguration.presets) { preset in
                presetEditorRow(preset)
                    .padding(.vertical, 8)

                if preset.id != controller.presetConfiguration.presets.last?.id {
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func presetEditorRow(_ preset: KeepAwakePreset) -> some View {
        HStack(spacing: UtilityStyle.contentSpacing) {
            Text(presetRowTitle(for: preset.id))
                .frame(width: 120, alignment: .leading)

            if let minutes = preset.duration.minutes {
                SelectAllMinuteField(
                    text: minuteBinding(for: preset, currentMinutes: minutes),
                    accessibilityLabel: "\(presetRowTitle(for: preset.id)) Duration In Minutes",
                    onCommit: { commitDuration(for: preset.id) }
                )
                    .frame(width: 76)

                Text("Minutes")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                Text("No Time Limit")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: UtilityStyle.contentSpacing)

            Toggle(presetRowTitle(for: preset.id), isOn: enabledBinding(for: preset))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(presetRowTitle(for: preset.id))
                .disabled(preset.isEnabled &&
                    controller.presetConfiguration.enabledPresets.count == KeepAwakeLimits.minimumEnabledPresets)
                .handPointer()
        }
    }

    private func enabledBinding(for preset: KeepAwakePreset) -> Binding<Bool> {
        Binding(
            get: { controller.presetConfiguration.presets.first(where: { $0.id == preset.id })?.isEnabled ?? false },
            set: { setPresetEnabled($0, for: preset.id) }
        )
    }

    private func minuteBinding(for preset: KeepAwakePreset, currentMinutes: Int) -> Binding<String> {
        Binding(
            get: { minuteInputs[preset.id] ?? String(currentMinutes) },
            set: { minuteInputs[preset.id] = $0 }
        )
    }

    private func setPresetEnabled(_ isEnabled: Bool, for id: KeepAwakePresetID) {
        do {
            let updated = try controller.presetConfiguration.settingEnabled(isEnabled, for: id)
            try controller.updatePresetConfiguration(updated)
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func commitDuration(for id: KeepAwakePresetID) {
        guard let rawValue = minuteInputs[id],
              let minutes = Int(rawValue),
              (KeepAwakeLimits.minimumTimedMinutes...KeepAwakeLimits.maximumTimedMinutes).contains(minutes) else {
            validationMessage = "Enter a whole number from 1 to 1,440 minutes."
            return
        }

        do {
            let duration = KeepAwakeDuration.timed(minutes: minutes)
            let updated = try controller.presetConfiguration.settingDuration(duration, for: id)
            try controller.updatePresetConfiguration(updated)
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func syncMinuteInputs(_ configuration: KeepAwakePresetConfiguration) {
        for preset in configuration.presets {
            guard let minutes = preset.duration.minutes else { continue }
            minuteInputs[preset.id] = String(minutes)
        }
    }

    private func presetRowTitle(for id: KeepAwakePresetID) -> String {
        switch id {
        case .timedOne: "Preset 1"
        case .timedTwo: "Preset 2"
        case .timedThree: "Preset 3"
        case .untilStopped: "Until Stopped"
        }
    }

    private func sessionDate(_ date: Date?) -> String? {
        date?.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    private func messageText(_ message: String) -> some View {
        Text(message)
            .font(UtilityStyle.helpFont)
            .foregroundStyle(UtilityStyle.warningColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SelectAllMinuteField: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> SelectAllNSTextField {
        let field = SelectAllNSTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = "Minutes"
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.setAccessibilityLabel(accessibilityLabel)
        return field
    }

    func updateNSView(_ field: SelectAllNSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        field.setAccessibilityLabel(accessibilityLabel)
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommit: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onCommit()
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}

private final class SelectAllNSTextField: NSTextField {
    private var outsideClickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeOutsideClickMonitor()

        guard window != nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  self.currentEditor() != nil,
                  event.window === window else {
                return event
            }

            let location = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(location) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        currentEditor()?.selectAll(nil)
    }

    deinit {
        removeOutsideClickMonitor()
    }

    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }
}

struct KeepAwakePopoverSection: View {
    @EnvironmentObject private var controller: KeepAwakeController

    private var activeBinding: Binding<Bool> {
        Binding(
            get: { controller.isActive },
            set: { controller.setActive($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.Popover.sectionContentSpacing) {
            HStack(spacing: UtilityStyle.contentSpacing) {
                Text("Keep Awake")
                    .font(UtilityStyle.headingFont)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Toggle("Keep Awake", isOn: activeBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(controller.isStartBlocked && !controller.isActive)
                    .accessibilityLabel("Keep Awake")
                    .handPointer()
            }

            HStack(spacing: UtilityStyle.Popover.valueSpacing) {
                ForEach(controller.presetConfiguration.enabledPresets) { preset in
                    presetButton(preset)
                }
            }
        }
    }

    @ViewBuilder
    private func presetButton(_ preset: KeepAwakePreset) -> some View {
        let isSelected = controller.selectedPresetID == preset.id
        if isSelected {
            Button {
                controller.selectPreset(preset.id)
            } label: {
                presetButtonLabel(preset)
            }
            .buttonStyle(.borderedProminent)
            .presetButtonAccessibility(isSelected: true, title: preset.title)
        } else {
            Button {
                controller.selectPreset(preset.id)
            } label: {
                presetButtonLabel(preset)
            }
            .buttonStyle(.bordered)
            .presetButtonAccessibility(isSelected: false, title: preset.title)
        }
    }

    private func presetButtonLabel(_ preset: KeepAwakePreset) -> some View {
        Text(preset.title)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(Rectangle())
    }
}

private extension View {
    func presetButtonAccessibility(isSelected: Bool, title: String) -> some View {
        self
            .controlSize(UtilityStyle.Popover.controlSize)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(title)
            .accessibilityValue(isSelected ? "Selected" : "Not Selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .handPointer()
    }
}
