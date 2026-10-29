import AppKit
import SwiftUI
import WidgetKit
import UserNotifications

@main
struct Mac_UtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor: UsageMonitor
    @StateObject private var diagnostics: ConnectionDiagnostics
    @StateObject private var wifiQualityMonitor: WiFiQualityMonitor
    @StateObject private var keepAwakeController: KeepAwakeController
    @StateObject private var notificationsController: NotificationsController
    @StateObject private var utilityWindow: UtilityWindowCoordinator

    init() {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        #if DEBUG
        let keepAwakePreview = !testing && Self.hasArgument("--keep-awake-preview", allowingValue: true)
        let usagePreview = !testing && Self.hasArgument("--usage-preview", allowingValue: true)
        let settingsPreview = !testing && Self.hasArgument("--settings-preview", allowingValue: true)
        let stabilityPreview = !testing && Self.hasArgument("--stability-preview", allowingValue: true)
        let notificationPreview = !testing ? Self.notificationPreviewState : nil
        let previewMode = keepAwakePreview || usagePreview || settingsPreview || stabilityPreview || notificationPreview != nil
        #else
        let keepAwakePreview = false
        let previewMode = false
        #endif
        #if DEBUG
        let suppressWidgetReload = testing || (previewMode && !usagePreview)
        #else
        let suppressWidgetReload = testing
        #endif
        let reloadCoordinator = suppressWidgetReload ? nil : WidgetReloadCoordinator(widgetKind: "UsageHistoryWidget",
            reloadTimelines: { WidgetCenter.shared.reloadTimelines(ofKind: $0) })
        let didCommit: ((UsageWidgetSnapshot, WidgetReloadReason) -> Void)? = { [weak reloadCoordinator] _, reason in
            reloadCoordinator?.requestReload(for: reason)
        }
        let monitor: UsageMonitor
        if testing {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("usage-history-tests-\(ProcessInfo.processInfo.processIdentifier)/today-usage.json")
            monitor = UsageMonitor(stateURL: file, startAutomatically: false, readCounters: { [:] })
        } else {
            #if DEBUG
            if usagePreview || stabilityPreview || settingsPreview || previewMode {
                monitor = Self.previewMonitor(
                    verificationOnly: stabilityPreview,
                    state: Self.usagePreviewState ?? Self.settingsPreviewState?.usageState ?? .history
                )
            } else { monitor = UsageMonitor(onSnapshotCommittedWithReason: didCommit) }
            #else
            monitor = UsageMonitor(onSnapshotCommittedWithReason: didCommit)
            #endif
        }
        let diagnostics = ConnectionDiagnostics()
        let wifiQualityMonitor = WiFiQualityMonitor()
        let notificationsController: NotificationsController
        #if DEBUG
        if let notificationPreview {
            let suiteName = "com.abdulrahman.mac-utilities.notifications-preview.\(ProcessInfo.processInfo.processIdentifier)"
            guard let preferences = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Could not create isolated notification preview preferences.")
            }
            preferences.removePersistentDomain(forName: suiteName)
            preferences.set(notificationPreview.previewEnabled, forKey: NotificationsController.enabledPreferenceKey)
            let deliveryError = notificationPreview == .deliveryError
                ? LocalNotificationError.deliveryFailed("Preview delivery failed.") : nil
            let client = PreviewLocalNotificationClient(state: notificationPreview.authorizationState,
                                                         deliveryError: deliveryError)
            notificationsController = NotificationsController(client: client, preferences: preferences)
            if notificationPreview == .requesting {
                notificationsController.showPreviewAuthorizationRequest()
            } else {
                notificationsController.showPreviewCapabilityState(notificationPreview.authorizationState,
                                                                   enabled: notificationPreview.previewEnabled,
                                                                   capability: notificationPreview.capabilityState)
            }
        } else if testing || previewMode {
            let namespace = testing ? "tests.\(UUID().uuidString)" : "preview.\(ProcessInfo.processInfo.processIdentifier)"
            let suiteName = "com.abdulrahman.mac-utilities.notifications-\(namespace)"
            guard let preferences = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Could not create isolated notification preferences.")
            }
            preferences.removePersistentDomain(forName: suiteName)
            notificationsController = NotificationsController(
                client: PreviewLocalNotificationClient(state: .notDetermined),
                preferences: preferences
            )
        } else {
            notificationsController = NotificationsController()
        }
        #else
        notificationsController = NotificationsController()
        #endif
        let keepAwakeController: KeepAwakeController
        #if DEBUG
        if testing {
            let suiteName = "com.abdulrahman.mac-utilities.keep-awake-tests.\(UUID().uuidString)"
            guard let preferences = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Could not create isolated Keep Awake test preferences.")
            }
            keepAwakeController = KeepAwakeController(power: PreviewPowerAsserter(), preferences: preferences,
                                                      timerFinishedNotifier: notificationsController)
        } else if keepAwakePreview {
            let suiteName = "com.abdulrahman.mac-utilities.keep-awake-preview.\(ProcessInfo.processInfo.processIdentifier)"
            guard let preferences = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Could not create isolated Keep Awake preview preferences.")
            }
            preferences.removePersistentDomain(forName: suiteName)
            let keepAwakeState = Self.keepAwakePreviewState
            if keepAwakeState == .preferenceError {
                preferences.set(Data("invalid preset configuration".utf8), forKey: KeepAwakeController.presetsPreferenceKey)
            }
            let powerFailure: PreviewPowerFailure?
            switch keepAwakeState {
            case .error: powerFailure = .systemIdle
            case .displayError: powerFailure = .displayIdle
            default: powerFailure = nil
            }
            keepAwakeController = KeepAwakeController(power: PreviewPowerAsserter(failure: powerFailure), preferences: preferences,
                                                      timerFinishedNotifier: notificationsController)
            Self.configureKeepAwakePreview(keepAwakeController)
        } else if previewMode {
            let suiteName = "com.abdulrahman.mac-utilities.keep-awake-preview.\(ProcessInfo.processInfo.processIdentifier)"
            guard let preferences = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Could not create isolated Keep Awake preview preferences.")
            }
            preferences.removePersistentDomain(forName: suiteName)
            keepAwakeController = KeepAwakeController(
                power: PreviewPowerAsserter(),
                preferences: preferences,
                timerFinishedNotifier: notificationsController
            )
        } else {
            keepAwakeController = KeepAwakeController(power: PowerAssertionClient(),
                                                      timerFinishedNotifier: notificationsController)
        }
        #else
        keepAwakeController = KeepAwakeController(power: PowerAssertionClient(),
                                                  timerFinishedNotifier: notificationsController)
        #endif
        #if DEBUG
        if !testing && stabilityPreview {
            let stabilityState = Self.stabilityPreviewState
            diagnostics.showStabilityPreview(
                unobserved: stabilityState == .unobserved || CommandLine.arguments.contains("--stability-preview-unobserved"),
                sparse: stabilityState == .sparse || CommandLine.arguments.contains("--stability-preview-sparse"),
                cancelled: stabilityState == .cancelled,
                running: stabilityState == .running)
        }
        #endif
        _monitor = StateObject(wrappedValue: monitor)
        _diagnostics = StateObject(wrappedValue: diagnostics)
        _wifiQualityMonitor = StateObject(wrappedValue: wifiQualityMonitor)
        _keepAwakeController = StateObject(wrappedValue: keepAwakeController)
        _notificationsController = StateObject(wrappedValue: notificationsController)
        let coordinator = UtilityWindowCoordinator(
            diagnostics: diagnostics,
            wifiQualityMonitor: wifiQualityMonitor
        ) { coordinator in
            AnyView(UtilityWindowView()
                .environmentObject(monitor)
                .environmentObject(diagnostics)
                .environmentObject(wifiQualityMonitor)
                .environmentObject(keepAwakeController)
                .environmentObject(notificationsController)
                .environmentObject(coordinator))
        }
        _utilityWindow = StateObject(wrappedValue: coordinator)
        notificationsController.onKeepAwakeRoute = { [weak appDelegate] in
            appDelegate?.routeToKeepAwake()
        }
        #if DEBUG
        if usagePreview,
           (try? UsageStoragePaths.resolve().isVerification) == true, monitor.historyError == nil {
            reloadCoordinator?.requestReload(for: .ordinary)
        }
        #endif
        appDelegate.widgetReloadCoordinator = reloadCoordinator
        appDelegate.monitor = monitor
        appDelegate.diagnostics = diagnostics
        appDelegate.wifiQualityMonitor = wifiQualityMonitor
        appDelegate.keepAwakeController = keepAwakeController
        appDelegate.notificationsController = notificationsController
        appDelegate.utilityWindow = coordinator
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(keepAwakeController)
                .environmentObject(notificationsController)
                .environmentObject(utilityWindow)
        } label: {
            MenuBarStatusLabel(text: monitor.menuBarText, status: monitor.collectionStatus)
                .environmentObject(keepAwakeController)
                .environmentObject(utilityWindow)
        }
        .menuBarExtraStyle(.window)
        .commands {
            // Mac Utilities does not expose text or other system services. Remove
            // the automatic Services submenu so unrelated providers do not
            // appear as incomplete app-owned commands.
            CommandGroup(replacing: .systemServices) { EmptyView() }
        }
    }

    #if DEBUG
    private static func previewMonitor(verificationOnly: Bool = false,
                                       state previewState: UsagePreviewState = .history) -> UsageMonitor {
        let directory = (verificationOnly ? "stability-check-preview" : "usage-history-preview")
            + "-\(ProcessInfo.processInfo.processIdentifier)"
        let verificationPaths = try? UsageStoragePaths.resolve()
        let sharedFixturePaths = verificationPaths.flatMap { $0.isVerification ? $0 : nil }
        let file = sharedFixturePaths?.stateURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("\(directory)/today-usage.json")
        if previewState == .storageError {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? Data("preview storage failure".utf8).write(to: file)
            return UsageMonitor(stateURL: file, startAutomatically: false, readCounters: { [:] })
        }
        let calendar = UsageHistory.calendar()
        let date = Date()
        var persistedState = PersistedUsage(schemaVersion: 3, localDayKey: UsageHistory.key(for: date), history: [])
        switch previewState {
        case .history, .counterError:
            persistedState.history = (0..<40).compactMap { offset in
                guard offset != 6, let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
                return DailyUsageRecord(dayKey: UsageHistory.key(for: day), downloaded: UInt64(offset == 8 ? 0 : 2 + (offset * 7) % 18) * 1_000_000_000,
                    uploaded: UInt64(offset == 8 ? 0 : 1 + offset % 3) * 500_000_000,
                    firstObservedAt: day, lastObservedAt: day, isIncomplete: true)
            }
            if previewState == .history, let start = calendar.dateInterval(of: .month, for: date)?.start {
                let older = (2...15).compactMap { offset -> DailyUsageRecord? in
                    guard let month = calendar.date(byAdding: .month, value: -offset, to: start),
                          let day = calendar.date(byAdding: .day, value: 14, to: month) else { return nil }
                    return DailyUsageRecord(dayKey: UsageHistory.key(for: day, calendar: calendar),
                        downloaded: UInt64(offset == 5 ? 0 : offset * 5) * 1_000_000_000,
                        uploaded: UInt64(offset == 5 ? 0 : offset) * 1_000_000_000,
                        firstObservedAt: day, lastObservedAt: day, isIncomplete: true)
                }
                persistedState.history?.append(contentsOf: older)
            }
        case .empty:
            persistedState.history = []
        case .zero:
            persistedState.history = [DailyUsageRecord(dayKey: UsageHistory.key(for: date), downloaded: 0, uploaded: 0,
                                               firstObservedAt: date, lastObservedAt: date, isIncomplete: false)]
        case .storageError:
            break
        }
        persistedState.widgetSnapshot = try? UsageSnapshotPublisher.snapshot(for: persistedState, at: date, unit: .decimal, calendar: calendar)
        if sharedFixturePaths != nil && CommandLine.arguments.contains("--usage-preview-large-envelope") {
            persistedState.incompleteReason = ""
            if let overhead = try? UsageStateStore.encoded(persistedState).count {
                persistedState.incompleteReason = String(repeating: "x", count: max(0, UsageStorageLimits.maximumEnvelopeBytes - overhead))
            }
        }
        try? UsageStateStore.saveState(persistedState, at: file)
        if verificationOnly || sharedFixturePaths != nil {
            return UsageMonitor(startAutomatically: false,
                storagePaths: UsageStoragePaths(stateURL: file, isVerification: true), readCounters: { [:] })
        }
        if previewState == .counterError {
            return UsageMonitor(stateURL: file, startAutomatically: false,
                                readCounters: { throw PreviewCounterError.unavailable })
        }
        return UsageMonitor(stateURL: file, startAutomatically: false, readCounters: { [:] })
    }

    private static func configureKeepAwakePreview(_ controller: KeepAwakeController) {
        let arguments = CommandLine.arguments
        let state = keepAwakePreviewState
        if state == .twoPresets || arguments.contains("--keep-awake-preview-two-presets") {
            try? controller.setPresetEnabled(false, for: .timedThree)
            try? controller.setPresetEnabled(false, for: .untilStopped)
        } else if state == .threePresets || arguments.contains("--keep-awake-preview-three-presets") {
            try? controller.setPresetEnabled(false, for: .timedThree)
        }
        if state == .completed {
            controller.showPreviewLastSession(outcome: .completed)
        } else if state == .cancelled {
            controller.showPreviewLastSession(outcome: .cancelled(reason: .stopped))
        } else if state == .untilStopped || arguments.contains("--keep-awake-preview-until-stopped") {
            controller.selectPreset(.untilStopped)
            controller.setActive(true)
        } else if state == .displayOn || state == .displayError {
            controller.setKeepDisplayOn(true)
            controller.setActive(true)
        } else if state == .active || state == .error || arguments.contains("--keep-awake-preview-active") {
            controller.setActive(true)
        }
    }

    private static func hasArgument(_ name: String, allowingValue: Bool) -> Bool {
        CommandLine.arguments.contains(name) || (allowingValue && CommandLine.arguments.contains(where: { $0.hasPrefix(name + "=") }))
    }

    private static var usagePreviewState: UsagePreviewState? {
        guard let rawValue = argumentValue(for: "--usage-preview") else { return nil }
        return UsagePreviewState(rawValue: rawValue) ?? .history
    }

    private static var settingsPreviewState: SettingsPreviewState? {
        guard let rawValue = argumentValue(for: "--settings-preview") else {
            return hasArgument("--settings-preview", allowingValue: false) ? .active : nil
        }
        return SettingsPreviewState(rawValue: rawValue) ?? .active
    }

    private static var stabilityPreviewState: StabilityPreviewState {
        guard let rawValue = argumentValue(for: "--stability-preview") else { return .complete }
        return StabilityPreviewState(rawValue: rawValue) ?? .complete
    }

    private static var keepAwakePreviewState: KeepAwakePreviewState {
        guard let rawValue = argumentValue(for: "--keep-awake-preview") else {
            if CommandLine.arguments.contains("--keep-awake-preview-until-stopped") { return .untilStopped }
            if CommandLine.arguments.contains("--keep-awake-preview-active") { return .active }
            if CommandLine.arguments.contains("--keep-awake-preview-two-presets") { return .twoPresets }
            if CommandLine.arguments.contains("--keep-awake-preview-three-presets") { return .threePresets }
            return .idle
        }
        return KeepAwakePreviewState(rawValue: rawValue) ?? .idle
    }

    private static func argumentValue(for name: String) -> String? {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(name + "=") }) else { return nil }
        return String(argument.dropFirst(name.count + 1))
    }
    #endif
}

#if DEBUG
private enum UsagePreviewState: String {
    case history
    case empty
    case zero
    case counterError = "counter-error"
    case storageError = "storage-error"
}

private enum SettingsPreviewState: String {
    case active
    case unavailable

    var usageState: UsagePreviewState {
        switch self {
        case .active: .history
        case .unavailable: .counterError
        }
    }
}

private enum StabilityPreviewState: String {
    case complete
    case sparse
    case unobserved
    case running
    case cancelled
}

private enum KeepAwakePreviewState: String {
    case idle
    case active
    case untilStopped = "until-stopped"
    case completed
    case cancelled
    case displayOn = "display-on"
    case error
    case displayError = "display-error"
    case preferenceError = "preference-error"
    case twoPresets = "two-presets"
    case threePresets = "three-presets"
}

private enum PreviewCounterError: Error {
    case unavailable
}

private enum NotificationPreviewState: String {
    case off
    case active
    case denied
    case alertsDisabled = "alerts-disabled"
    case notificationCenterDisabled = "notification-center-disabled"
    case soundDisabled = "sound-disabled"
    case requesting
    case permissionError = "permission-error"
    case deliveryError = "delivery-error"

    var isEnabled: Bool { self != .off }

    var capabilityState: NotificationCapabilityState {
        switch self {
        case .off: .off
        case .active, .alertsDisabled, .notificationCenterDisabled, .soundDisabled: .authorized
        case .denied: .denied
        case .requesting: .permissionPending
        case .permissionError: .permissionFailed
        case .deliveryError: .deliveryFailed
        }
    }

    var previewEnabled: Bool {
        self != .off && self != .denied && self != .permissionError
    }

    var authorizationState: NotificationAuthorizationState {
        switch self {
        case .off, .requesting, .permissionError:
            .notDetermined
        case .active, .deliveryError:
            NotificationAuthorizationState(status: .authorized, alertsEnabled: true, soundsEnabled: true,
                                           notificationCenterEnabled: true)
        case .denied:
            NotificationAuthorizationState(status: .denied, alertsEnabled: false, soundsEnabled: false)
        case .alertsDisabled:
            NotificationAuthorizationState(status: .authorized, alertsEnabled: false, soundsEnabled: true,
                                           notificationCenterEnabled: true)
        case .notificationCenterDisabled:
            NotificationAuthorizationState(status: .authorized, alertsEnabled: true, soundsEnabled: true,
                                           notificationCenterEnabled: false)
        case .soundDisabled:
            NotificationAuthorizationState(status: .authorized, alertsEnabled: true, soundsEnabled: false,
                                           notificationCenterEnabled: true)
        }
    }
}

@MainActor
private final class PreviewLocalNotificationClient: LocalNotificationClient {
    var state: NotificationAuthorizationState
    let deliveryError: Error?
    weak var delegate: UNUserNotificationCenterDelegate?

    init(state: NotificationAuthorizationState, deliveryError: Error? = nil) {
        self.state = state
        self.deliveryError = deliveryError
    }

    func authorizationState() async -> NotificationAuthorizationState { state }

    func requestAuthorization() async throws -> Bool {
        state = NotificationAuthorizationState(status: .authorized, alertsEnabled: true, soundsEnabled: true,
                                                notificationCenterEnabled: true)
        return true
    }

    func deliver(_ payload: LocalNotificationPayload) async throws {
        if let deliveryError { throw deliveryError }
    }

    func openNotificationSettings() {
        let notificationsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.abdulrahman.mac-utilities")
        if let notificationsURL, NSWorkspace.shared.open(notificationsURL) { return }
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {
        self.delegate = delegate
    }

    func shutdown() {
        delegate = nil
    }
}

private extension Mac_UtilitiesApp {
    static var notificationPreviewState: NotificationPreviewState? {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--notification-preview=") }) else {
            return CommandLine.arguments.contains("--notification-preview") ? .off : nil
        }
        let rawValue = String(argument.dropFirst("--notification-preview=".count))
        return NotificationPreviewState(rawValue: rawValue) ?? .off
    }
}

@MainActor
private final class PreviewPowerAsserter: PowerAsserting {
    let failure: PreviewPowerFailure?
    private var nextID: UInt32 = 1

    init(failure: PreviewPowerFailure? = nil) {
        self.failure = failure
    }

    func create(_ kind: PowerAssertionKind, timeout: TimeInterval?) throws -> PowerAssertionID {
        if failure == .systemIdle && kind == .systemIdle { throw PreviewPowerError.create(kind) }
        if failure == .displayIdle && kind == .displayIdle { throw PreviewPowerError.create(kind) }
        defer { nextID &+= 1 }
        return PowerAssertionID(rawValue: nextID)
    }

    func release(_ id: PowerAssertionID) throws {
        if failure == .release { throw PreviewPowerError.release(id) }
    }
}

private enum PreviewPowerFailure: Equatable {
    case systemIdle
    case displayIdle
    case release
}

private enum PreviewPowerError: LocalizedError {
    case create(PowerAssertionKind)
    case release(PowerAssertionID)

    var errorDescription: String? {
        switch self {
        case .create(let kind): "Preview could not create the \(kind.rawValue) power assertion."
        case .release(let id): "Preview could not release power assertion \(id.rawValue)."
        }
    }
}
#endif
