import Combine
import Foundation
import AppKit

@MainActor
struct KeepAwakeClock {
    let now: () -> Double
    let date: () -> Date
    let sleepUntil: (Double) async throws -> Void

    static func system() -> Self {
        let origin = ContinuousClock.now
        let now: () -> Double = {
            let elapsed = origin.duration(to: .now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        let sleep: (Double) async throws -> Void = { deadline in
            try await Task.sleep(for: .seconds(max(0, deadline - now())), clock: .continuous)
        }
        return Self(now: now, date: Date.init, sleepUntil: sleep)
    }
}

@MainActor
final class KeepAwakeController: ObservableObject {
    @Published private(set) var presetConfiguration: KeepAwakePresetConfiguration
    @Published private(set) var selectedPresetID: KeepAwakePresetID
    @Published private(set) var activeSession: KeepAwakeSessionSnapshot?
    @Published private(set) var remainingMinutes: Int?
    @Published private(set) var isKeepDisplayOn: Bool
    @Published private(set) var errorMessage: String?
    @Published private(set) var warningMessage: String?
    @Published private(set) var preferenceError: String?

    static let presetsPreferenceKey = "keepAwake.presets.v1"
    static let keepDisplayOnPreferenceKey = "keepAwake.keepDisplayOn.v1"

    private let power: any PowerAsserting
    private let preferences: UserDefaults
    private let clock: KeepAwakeClock
    private let wakeNotificationCenter: NotificationCenter
    private var wakeObserver: NSObjectProtocol?
    private var sessionDeadline: Double?
    private var baseAssertionID: PowerAssertionID?
    private var displayAssertionID: PowerAssertionID?
    private var timerTask: Task<Void, Never>?
    private var sessionGeneration: UInt64 = 0
    private var timerGeneration: UInt64 = 0
    private var failedReleaseMessage: String?
    private var hasShutDown = false

    init(
        power: any PowerAsserting,
        preferences: UserDefaults = .standard,
        clock: KeepAwakeClock? = nil,
        wakeNotificationCenter: NotificationCenter? = nil
    ) {
        self.power = power
        self.preferences = preferences
        self.clock = clock ?? .system()
        self.wakeNotificationCenter = wakeNotificationCenter ?? NSWorkspace.shared.notificationCenter

        let savedConfiguration: KeepAwakePresetConfiguration
        var savedPreferenceError: String? = nil
        if let data = preferences.data(forKey: Self.presetsPreferenceKey) {
            do {
                let savedPresets = try JSONDecoder().decode([KeepAwakePreset].self, from: data)
                savedConfiguration = try KeepAwakePresetConfiguration(validating: savedPresets)
            } catch {
                savedConfiguration = .defaults
                savedPreferenceError = "Saved duration presets could not be read. Restore Defaults to save a valid configuration."
            }
        } else {
            savedConfiguration = .defaults
            savedPreferenceError = nil
        }

        presetConfiguration = savedConfiguration
        selectedPresetID = savedConfiguration.firstEnabledPreset.id
        isKeepDisplayOn = preferences.object(forKey: Self.keepDisplayOnPreferenceKey) as? Bool ?? false
        preferenceError = savedPreferenceError
        wakeObserver = self.wakeNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileAfterWake() }
        }
    }

    var isActive: Bool { activeSession != nil }
    var isStartBlocked: Bool { failedReleaseMessage != nil }
    var isUntilStopped: Bool { activeSession?.duration == .untilStopped }

    var menuBarPrefix: String {
        guard let activeSession else { return "" }
        if activeSession.duration == .untilStopped { return "☾ ∞\u{2003}" }
        return remainingText.map { "☾ \($0)\u{2003}" } ?? ""
    }

    var remainingText: String? {
        guard let remainingMinutes else { return nil }
        return KeepAwakeDuration.timed(minutes: remainingMinutes).title
    }

    func selectPreset(_ id: KeepAwakePresetID) {
        guard !hasShutDown,
              presetConfiguration.enabledPresets.contains(where: { $0.id == id }) else { return }
        let shouldReplaceActiveSession = isActive && activeSession?.presetID != id
        guard selectedPresetID != id || shouldReplaceActiveSession else { return }

        selectedPresetID = id
        guard isActive, shouldReplaceActiveSession else { return }
        startSession(using: id)
    }

    func setActive(_ shouldBeActive: Bool) {
        guard !hasShutDown else { return }
        if shouldBeActive {
            guard !isActive else { return }
            startSession(using: selectedPresetID)
        } else {
            stopSession()
        }
    }

    func setKeepDisplayOn(_ enabled: Bool) {
        guard !hasShutDown, isKeepDisplayOn != enabled else { return }
        isKeepDisplayOn = enabled
        preferences.set(enabled, forKey: Self.keepDisplayOnPreferenceKey)
        warningMessage = nil

        guard isActive else { return }
        if enabled {
            createDisplayAssertionForActiveSession()
        } else {
            releaseDisplayAssertion()
        }
    }

    func setPresetEnabled(_ enabled: Bool, for id: KeepAwakePresetID) throws {
        try updatePresetConfiguration(presetConfiguration.settingEnabled(enabled, for: id))
    }

    func setPresetDuration(_ duration: KeepAwakeDuration, for id: KeepAwakePresetID) throws {
        try updatePresetConfiguration(presetConfiguration.settingDuration(duration, for: id))
    }

    func updatePresetConfiguration(_ configuration: KeepAwakePresetConfiguration) throws {
        guard !hasShutDown else { return }
        let validated = try KeepAwakePresetConfiguration(validating: configuration.presets)
        presetConfiguration = validated
        if !validated.enabledPresets.contains(where: { $0.id == selectedPresetID }) {
            selectedPresetID = validated.firstEnabledPreset.id
        }
        persistPresets()
        preferenceError = nil
    }

    func restoreDefaultPresets() {
        guard !hasShutDown else { return }
        presetConfiguration = .defaults
        if !presetConfiguration.enabledPresets.contains(where: { $0.id == selectedPresetID }) {
            selectedPresetID = presetConfiguration.firstEnabledPreset.id
        }
        persistPresets()
        preferenceError = nil
    }

    func reconcileAfterWake() {
        guard !hasShutDown, let session = activeSession else { return }
        reconcileTimer(generation: session.generation, timerToken: timerGeneration)
    }

    func shutdown() {
        guard !hasShutDown else { return }
        hasShutDown = true
        if let wakeObserver {
            wakeNotificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        stopSession()
    }

    private func startSession(using presetID: KeepAwakePresetID) {
        guard !hasShutDown, !isStartBlocked,
              let preset = presetConfiguration.enabledPresets.first(where: { $0.id == presetID }) else { return }

        if isActive { stopSession() }
        guard !isStartBlocked else { return }

        selectedPresetID = presetID
        errorMessage = nil
        warningMessage = nil

        let startedAt = clock.date()
        let deadline: Double?
        let endsAt: Date?
        let timeout: TimeInterval?
        switch preset.duration {
        case let .timed(minutes):
            let seconds = TimeInterval(minutes * 60)
            deadline = clock.now() + seconds
            endsAt = startedAt.addingTimeInterval(seconds)
            timeout = seconds
        case .untilStopped:
            deadline = nil
            endsAt = nil
            timeout = nil
        }

        let baseID: PowerAssertionID
        do {
            baseID = try power.create(.systemIdle, timeout: timeout)
        } catch {
            sessionGeneration &+= 1
            sessionDeadline = nil
            activeSession = nil
            remainingMinutes = nil
            errorMessage = "Keep Awake could not start. \(error.localizedDescription)"
            return
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        sessionDeadline = deadline
        baseAssertionID = baseID
        activeSession = KeepAwakeSessionSnapshot(
            presetID: preset.id,
            duration: preset.duration,
            startedAt: startedAt,
            endsAt: endsAt,
            generation: generation
        )
        remainingMinutes = deadline.map { Self.remainingMinutes(until: $0, now: clock.now()) }

        if isKeepDisplayOn {
            do {
                displayAssertionID = try power.create(.displayIdle, timeout: timeout)
            } catch {
                warningMessage = "Keep Display On could not be applied. \(error.localizedDescription)"
            }
        }

        if deadline != nil { scheduleTimer(generation: generation) }
    }

    private func stopSession() {
        cancelTimer()
        sessionGeneration &+= 1
        sessionDeadline = nil
        activeSession = nil
        remainingMinutes = nil
        warningMessage = nil

        var failures: [String] = []
        if let displayAssertionID {
            self.displayAssertionID = nil
            do {
                try power.release(displayAssertionID)
            } catch {
                failures.append("Display Assertion: \(error.localizedDescription)")
            }
        }
        if let baseAssertionID {
            self.baseAssertionID = nil
            do {
                try power.release(baseAssertionID)
            } catch {
                failures.append("System Assertion: \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            failedReleaseMessage = "A power assertion could not be released (\(failures.joined(separator: "; "))). Restart Mac Utilities to clear it."
            errorMessage = failedReleaseMessage
        }
    }

    private func createDisplayAssertionForActiveSession() {
        guard !isStartBlocked else {
            warningMessage = "Keep Display On cannot be applied until Mac Utilities restarts."
            return
        }
        guard let deadline = sessionDeadline else {
            guard !isUntilStopped else {
                do {
                    displayAssertionID = try power.create(.displayIdle, timeout: nil)
                    return
                } catch {
                    warningMessage = "Keep Display On could not be applied. \(error.localizedDescription)"
                    return
                }
            }
            warningMessage = "Keep Display On cannot be applied until Mac Utilities restarts."
            return
        }

        let timeout = max(0, deadline - clock.now())
        guard timeout > 0 else {
            reconcileAfterWake()
            return
        }
        do {
            displayAssertionID = try power.create(.displayIdle, timeout: timeout)
            warningMessage = nil
        } catch {
            warningMessage = "Keep Display On could not be applied. \(error.localizedDescription)"
        }
    }

    private func releaseDisplayAssertion() {
        guard let displayAssertionID else { return }
        self.displayAssertionID = nil
        do {
            try power.release(displayAssertionID)
            warningMessage = nil
        } catch {
            failedReleaseMessage = "The display power assertion could not be released (\(error.localizedDescription)). Restart Mac Utilities to clear it."
            errorMessage = failedReleaseMessage
        }
    }

    private func persistPresets() {
        do {
            preferences.set(try JSONEncoder().encode(presetConfiguration.presets), forKey: Self.presetsPreferenceKey)
        } catch {
            preferenceError = "Duration presets could not be saved. \(error.localizedDescription)"
        }
    }

    private func scheduleTimer(generation: UInt64) {
        cancelTimer()
        guard let deadline = sessionDeadline else { return }
        timerGeneration &+= 1
        let token = timerGeneration
        let wakeAt = Self.nextMinuteBoundary(deadline: deadline, now: clock.now())
        timerTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await clock.sleepUntil(wakeAt)
            } catch {
                return
            }
            reconcileTimer(generation: generation, timerToken: token)
        }
    }

    private func cancelTimer() {
        timerGeneration &+= 1
        timerTask?.cancel()
        timerTask = nil
    }

    private func reconcileTimer(generation: UInt64, timerToken: UInt64) {
        guard !hasShutDown,
              let session = activeSession,
              session.generation == generation,
              sessionDeadline != nil,
              timerToken == timerGeneration else { return }

        guard let deadline = sessionDeadline else { return }
        let now = clock.now()
        guard now < deadline else {
            stopSession()
            return
        }

        remainingMinutes = Self.remainingMinutes(until: deadline, now: now)
        scheduleTimer(generation: generation)
    }

    private static func remainingMinutes(until deadline: Double, now: Double) -> Int {
        max(0, Int(ceil(max(0, deadline - now) / 60)))
    }

    private static func nextMinuteBoundary(deadline: Double, now: Double) -> Double {
        let remaining = max(0, deadline - now)
        let displayedMinutes = ceil(remaining / 60)
        let boundary = deadline - max(0, displayedMinutes - 1) * 60
        return max(now + 0.001, min(deadline, boundary))
    }
}
