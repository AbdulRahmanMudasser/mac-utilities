import Foundation

nonisolated enum KeepAwakeLimits {
    static let minimumEnabledPresets = 2
    static let maximumEnabledPresets = 4
    static let minimumTimedMinutes = 1
    static let maximumTimedMinutes = 1_440
}

nonisolated enum KeepAwakePresetID: String, CaseIterable, Codable, Identifiable, Sendable {
    case timedOne
    case timedTwo
    case timedThree
    case untilStopped

    var id: String { rawValue }
}

nonisolated enum KeepAwakeDuration: Equatable, Codable, Sendable {
    case timed(minutes: Int)
    case untilStopped

    var minutes: Int? {
        guard case let .timed(minutes) = self else { return nil }
        return minutes
    }

    var isTimed: Bool { minutes != nil }

    var title: String {
        switch self {
        case let .timed(minutes) where minutes % 60 == 0:
            let hours = minutes / 60
            return "\(hours) Hour" + (hours == 1 ? "" : "s")
        case let .timed(minutes):
            return "\(minutes) Min"
        case .untilStopped:
            return "Until Stopped"
        }
    }

    var editorTitle: String {
        switch self {
        case let .timed(minutes) where minutes % 60 == 0:
            let hours = minutes / 60
            return "\(hours) Hour" + (hours == 1 ? "" : "s")
        case let .timed(minutes):
            return "\(minutes) Minutes"
        case .untilStopped:
            return "Until Stopped"
        }
    }
}

nonisolated struct KeepAwakePreset: Equatable, Codable, Identifiable, Sendable {
    let id: KeepAwakePresetID
    let duration: KeepAwakeDuration
    let isEnabled: Bool

    init(id: KeepAwakePresetID, duration: KeepAwakeDuration, isEnabled: Bool = true) {
        self.id = id
        self.duration = duration
        self.isEnabled = isEnabled
    }

    var title: String { duration.title }
}

nonisolated struct KeepAwakePresetConfiguration: Equatable, Sendable {
    static let defaults = KeepAwakePresetConfiguration(unchecked: [
        KeepAwakePreset(id: .timedOne, duration: .timed(minutes: 30)),
        KeepAwakePreset(id: .timedTwo, duration: .timed(minutes: 60)),
        KeepAwakePreset(id: .timedThree, duration: .timed(minutes: 120)),
        KeepAwakePreset(id: .untilStopped, duration: .untilStopped),
    ])

    private(set) var presets: [KeepAwakePreset]

    var enabledPresets: [KeepAwakePreset] { presets.filter(\.isEnabled) }

    var firstEnabledPreset: KeepAwakePreset { enabledPresets[0] }

    init(validating presets: [KeepAwakePreset]) throws {
        try Self.validate(presets)
        self.presets = Self.ordered(presets)
    }

    private init(unchecked presets: [KeepAwakePreset]) {
        self.presets = presets
    }

    func settingEnabled(_ isEnabled: Bool, for id: KeepAwakePresetID) throws -> Self {
        let updated = presets.map { preset in
            preset.id == id
                ? KeepAwakePreset(id: preset.id, duration: preset.duration, isEnabled: isEnabled)
                : preset
        }
        return try Self(validating: updated)
    }

    func settingDuration(_ duration: KeepAwakeDuration, for id: KeepAwakePresetID) throws -> Self {
        let updated = presets.map { preset in
            preset.id == id
                ? KeepAwakePreset(id: preset.id, duration: duration, isEnabled: preset.isEnabled)
                : preset
        }
        return try Self(validating: updated)
    }

    static func validatedOrDefaults(_ presets: [KeepAwakePreset]?) -> Self {
        guard let presets, let configuration = try? Self(validating: presets) else {
            return .defaults
        }
        return configuration
    }

    private static func validate(_ presets: [KeepAwakePreset]) throws {
        guard presets.count == KeepAwakePresetID.allCases.count,
              Set(presets.map(\.id)).count == KeepAwakePresetID.allCases.count,
              Set(presets.map(\.id)) == Set(KeepAwakePresetID.allCases) else {
            throw KeepAwakePresetValidationError.invalidSlots
        }

        for preset in presets {
            switch (preset.id, preset.duration) {
            case (.untilStopped, .untilStopped),
                 (.timedOne, .timed(minutes: _)),
                 (.timedTwo, .timed(minutes: _)),
                 (.timedThree, .timed(minutes: _)):
                break
            default:
                throw KeepAwakePresetValidationError.invalidDuration(for: preset.id)
            }

            if case let .timed(minutes) = preset.duration,
               !(KeepAwakeLimits.minimumTimedMinutes...KeepAwakeLimits.maximumTimedMinutes).contains(minutes) {
                throw KeepAwakePresetValidationError.durationOutOfRange(for: preset.id)
            }
        }

        let enabled = presets.filter(\.isEnabled)
        guard (KeepAwakeLimits.minimumEnabledPresets...KeepAwakeLimits.maximumEnabledPresets).contains(enabled.count) else {
            throw KeepAwakePresetValidationError.enabledCountOutOfRange
        }

        let timedMinutes = presets.compactMap { $0.duration.minutes }
        guard Set(timedMinutes).count == timedMinutes.count else {
            throw KeepAwakePresetValidationError.duplicateDuration
        }
    }

    private static func ordered(_ presets: [KeepAwakePreset]) -> [KeepAwakePreset] {
        let order = Dictionary(uniqueKeysWithValues: KeepAwakePresetID.allCases.enumerated().map { ($1, $0) })
        return presets.sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }
    }
}

nonisolated enum KeepAwakePresetValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidSlots
    case invalidDuration(for: KeepAwakePresetID)
    case durationOutOfRange(for: KeepAwakePresetID)
    case enabledCountOutOfRange
    case duplicateDuration

    var errorDescription: String? {
        switch self {
        case .invalidSlots:
            "Keep Awake must have three timed presets and one Until Stopped preset."
        case let .invalidDuration(id):
            "\(id.titleForError) has an invalid duration type."
        case let .durationOutOfRange(id):
            "\(id.titleForError) must be between 1 minute and 24 hours."
        case .enabledCountOutOfRange:
            "Enable between 2 and 4 duration presets."
        case .duplicateDuration:
            "Timed presets must have unique durations."
        }
    }
}

private extension KeepAwakePresetID {
    nonisolated var titleForError: String {
        switch self {
        case .timedOne: "First Timed Preset"
        case .timedTwo: "Second Timed Preset"
        case .timedThree: "Third Timed Preset"
        case .untilStopped: "Until Stopped Preset"
        }
    }
}

nonisolated struct KeepAwakeSessionSnapshot: Equatable, Sendable {
    let presetID: KeepAwakePresetID
    let duration: KeepAwakeDuration
    let startedAt: Date
    let endsAt: Date?
    let generation: UInt64
    let outcome: KeepAwakeSessionOutcome?

    var isFinite: Bool { duration.isTimed }

    func ended(with outcome: KeepAwakeSessionOutcome) -> Self {
        Self(
            presetID: presetID,
            duration: duration,
            startedAt: startedAt,
            endsAt: endsAt,
            generation: generation,
            outcome: outcome
        )
    }
}

nonisolated enum KeepAwakeSessionOutcome: Equatable, Sendable {
    case completed
    case cancelled(reason: KeepAwakeCancellationReason)

    var summary: String {
        switch self {
        case .completed:
            return "Completed"
        case .cancelled(reason: .stopped):
            return "Cancelled"
        case let .cancelled(reason):
            return "Cancelled · \(reason.title)"
        }
    }
}

nonisolated enum KeepAwakeCancellationReason: Equatable, Sendable {
    case stopped
    case replaced
    case applicationQuit

    var title: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .replaced:
            return "Replaced"
        case .applicationQuit:
            return "Mac Utilities Quit"
        }
    }
}
