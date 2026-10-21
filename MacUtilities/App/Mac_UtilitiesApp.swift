import AppKit
import SwiftUI
import WidgetKit

@main
struct Mac_UtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor: UsageMonitor
    @StateObject private var diagnostics: ConnectionDiagnostics
    @StateObject private var wifiQualityMonitor: WiFiQualityMonitor
    @StateObject private var keepAwakeController: KeepAwakeController
    @StateObject private var utilityWindow: UtilityWindowCoordinator

    init() {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        #if DEBUG
        let keepAwakePreview = !testing && CommandLine.arguments.contains("--keep-awake-preview")
        #else
        let keepAwakePreview = false
        #endif
        let reloadCoordinator = testing || keepAwakePreview ? nil : WidgetReloadCoordinator(widgetKind: "UsageHistoryWidget",
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
            if CommandLine.arguments.contains("--usage-preview") || CommandLine.arguments.contains("--stability-preview") || keepAwakePreview {
                monitor = Self.previewMonitor(verificationOnly: CommandLine.arguments.contains("--stability-preview"))
            } else { monitor = UsageMonitor(onSnapshotCommittedWithReason: didCommit) }
            #else
            monitor = UsageMonitor(onSnapshotCommittedWithReason: didCommit)
            #endif
        }
        let diagnostics = ConnectionDiagnostics()
        let wifiQualityMonitor = WiFiQualityMonitor()
        let keepAwakeController: KeepAwakeController
        #if DEBUG
        if testing {
            let suiteName = "com.abdulrahman.mac-utilities.keep-awake-tests.\(UUID().uuidString)"
            guard let preferences = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Could not create isolated Keep Awake test preferences.")
            }
            keepAwakeController = KeepAwakeController(power: PreviewPowerAsserter(), preferences: preferences)
        } else if keepAwakePreview {
            let suiteName = "com.abdulrahman.mac-utilities.keep-awake-preview.\(ProcessInfo.processInfo.processIdentifier)"
            guard let preferences = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Could not create isolated Keep Awake preview preferences.")
            }
            preferences.removePersistentDomain(forName: suiteName)
            keepAwakeController = KeepAwakeController(power: PreviewPowerAsserter(), preferences: preferences)
            Self.configureKeepAwakePreview(keepAwakeController)
        } else {
            keepAwakeController = KeepAwakeController(power: PowerAssertionClient())
        }
        #else
        keepAwakeController = KeepAwakeController(power: PowerAssertionClient())
        #endif
        #if DEBUG
        if !testing && CommandLine.arguments.contains("--stability-preview") {
            diagnostics.showStabilityPreview(
                unobserved: CommandLine.arguments.contains("--stability-preview-unobserved"),
                sparse: CommandLine.arguments.contains("--stability-preview-sparse"))
        }
        #endif
        _monitor = StateObject(wrappedValue: monitor)
        _diagnostics = StateObject(wrappedValue: diagnostics)
        _wifiQualityMonitor = StateObject(wrappedValue: wifiQualityMonitor)
        _keepAwakeController = StateObject(wrappedValue: keepAwakeController)
        let coordinator = UtilityWindowCoordinator(
            diagnostics: diagnostics,
            wifiQualityMonitor: wifiQualityMonitor
        ) { coordinator in
            AnyView(UtilityWindowView()
                .environmentObject(monitor)
                .environmentObject(diagnostics)
                .environmentObject(wifiQualityMonitor)
                .environmentObject(keepAwakeController)
                .environmentObject(coordinator))
        }
        _utilityWindow = StateObject(wrappedValue: coordinator)
        #if DEBUG
        if (CommandLine.arguments.contains("--usage-preview") || CommandLine.arguments.contains("--stability-preview")),
           (try? UsageStoragePaths.resolve().isVerification) == true, monitor.historyError == nil {
            reloadCoordinator?.requestReload(for: .ordinary)
        }
        #endif
        appDelegate.widgetReloadCoordinator = reloadCoordinator
        appDelegate.monitor = monitor
        appDelegate.diagnostics = diagnostics
        appDelegate.wifiQualityMonitor = wifiQualityMonitor
        appDelegate.keepAwakeController = keepAwakeController
        appDelegate.utilityWindow = coordinator
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(keepAwakeController)
                .environmentObject(utilityWindow)
        } label: {
            MenuBarStatusLabel(text: monitor.menuBarText, status: monitor.collectionStatus)
                .environmentObject(keepAwakeController)
                .environmentObject(utilityWindow)
        }
        .menuBarExtraStyle(.window)
    }

    #if DEBUG
    private static func previewMonitor(verificationOnly: Bool = false) -> UsageMonitor {
        let directory = verificationOnly ? "stability-check-preview" : "usage-history-preview"
        let verificationPaths = try? UsageStoragePaths.resolve()
        let sharedFixturePaths = verificationPaths.flatMap { $0.isVerification ? $0 : nil }
        let file = sharedFixturePaths?.stateURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("\(directory)/today-usage.json")
        let calendar = UsageHistory.calendar()
        let date = Date()
        var state = PersistedUsage(schemaVersion: 3, localDayKey: UsageHistory.key(for: date), history: [])
        state.history = (0..<40).compactMap { offset in
            guard offset != 6, let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
            return DailyUsageRecord(dayKey: UsageHistory.key(for: day), downloaded: UInt64(offset == 8 ? 0 : 2 + (offset * 7) % 18) * 1_000_000_000,
                uploaded: UInt64(offset == 8 ? 0 : 1 + offset % 3) * 500_000_000,
                firstObservedAt: day, lastObservedAt: day, isIncomplete: true)
        }
        state.widgetSnapshot = try? UsageSnapshotPublisher.snapshot(for: state, at: date, unit: .decimal, calendar: calendar)
        if sharedFixturePaths != nil && CommandLine.arguments.contains("--usage-preview-large-envelope") {
            state.incompleteReason = ""
            if let overhead = try? UsageStateStore.encoded(state).count {
                state.incompleteReason = String(repeating: "x", count: max(0, UsageStorageLimits.maximumEnvelopeBytes - overhead))
            }
        }
        try? UsageStateStore.saveState(state, at: file)
        if verificationOnly || sharedFixturePaths != nil {
            return UsageMonitor(startAutomatically: false,
                storagePaths: UsageStoragePaths(stateURL: file, isVerification: true), readCounters: { [:] })
        }
        return UsageMonitor(stateURL: file, startAutomatically: false, readCounters: { [:] })
    }

    private static func configureKeepAwakePreview(_ controller: KeepAwakeController) {
        let arguments = CommandLine.arguments
        if arguments.contains("--keep-awake-preview-two-presets") {
            try? controller.setPresetEnabled(false, for: .timedThree)
            try? controller.setPresetEnabled(false, for: .untilStopped)
        } else if arguments.contains("--keep-awake-preview-three-presets") {
            try? controller.setPresetEnabled(false, for: .timedThree)
        }
        if arguments.contains("--keep-awake-preview-until-stopped") {
            controller.selectPreset(.untilStopped)
            controller.setActive(true)
        } else if arguments.contains("--keep-awake-preview-active") {
            controller.setActive(true)
        }
    }
    #endif
}

#if DEBUG
@MainActor
private final class PreviewPowerAsserter: PowerAsserting {
    private var nextID: UInt32 = 1

    func create(_ kind: PowerAssertionKind, timeout: TimeInterval?) throws -> PowerAssertionID {
        defer { nextID &+= 1 }
        return PowerAssertionID(rawValue: nextID)
    }

    func release(_ id: PowerAssertionID) throws {}
}
#endif
