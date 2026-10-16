import AppKit
import SwiftUI

@main
struct Mac_UtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor: UsageMonitor
    @StateObject private var diagnostics: ConnectionDiagnostics
    @StateObject private var utilityWindow: UtilityWindowCoordinator

    init() {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        let monitor: UsageMonitor
        if testing {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("usage-history-tests-\(ProcessInfo.processInfo.processIdentifier)/today-usage.json")
            monitor = UsageMonitor(stateURL: file, startAutomatically: false, readCounters: { [:] })
        } else {
            #if DEBUG
            if CommandLine.arguments.contains("--usage-preview") {
                monitor = Self.previewMonitor()
            } else { monitor = UsageMonitor() }
            #else
            monitor = UsageMonitor()
            #endif
        }
        let diagnostics = ConnectionDiagnostics()
        _monitor = StateObject(wrappedValue: monitor)
        _diagnostics = StateObject(wrappedValue: diagnostics)
        _utilityWindow = StateObject(wrappedValue: UtilityWindowCoordinator(diagnostics: diagnostics) { coordinator in
            AnyView(UtilityWindowView()
                .environmentObject(monitor)
                .environmentObject(diagnostics)
                .environmentObject(coordinator))
        })
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(utilityWindow)
        } label: {
            MenuBarStatusLabel(text: monitor.menuBarText, status: monitor.collectionStatus)
                .environmentObject(utilityWindow)
                .onAppear {
                    appDelegate.utilityWindow = utilityWindow
                    appDelegate.monitor = monitor
                }
        }
        .menuBarExtraStyle(.window)
    }

    #if DEBUG
    private static func previewMonitor() -> UsageMonitor {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("usage-history-preview/today-usage.json")
        let calendar = UsageHistory.calendar()
        let date = Date()
        var state = PersistedUsage(schemaVersion: 3, localDayKey: UsageHistory.key(for: date), history: [])
        state.history = (0..<40).compactMap { offset in
            guard offset != 6, let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
            return DailyUsageRecord(dayKey: UsageHistory.key(for: day), downloaded: UInt64(offset == 8 ? 0 : 2 + (offset * 7) % 18) * 1_000_000_000,
                uploaded: UInt64(offset == 8 ? 0 : 1 + offset % 3) * 500_000_000,
                firstObservedAt: day, lastObservedAt: day, isIncomplete: true)
        }
        try? UsageStateStore.saveState(state, at: file)
        return UsageMonitor(stateURL: file, startAutomatically: false, readCounters: { [:] })
    }
    #endif
}
