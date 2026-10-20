import AppKit
import SwiftUI

@main
struct Mac_UtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor: UsageMonitor
    @StateObject private var diagnostics: ConnectionDiagnostics
    @StateObject private var wifiQualityMonitor: WiFiQualityMonitor
    @StateObject private var utilityWindow: UtilityWindowCoordinator

    init() {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        let monitor: UsageMonitor
        if testing {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("usage-history-tests-\(ProcessInfo.processInfo.processIdentifier)/today-usage.json")
            monitor = UsageMonitor(stateURL: file, startAutomatically: false, readCounters: { [:] })
        } else {
            #if DEBUG
            if CommandLine.arguments.contains("--usage-preview") || CommandLine.arguments.contains("--stability-preview") {
                monitor = Self.previewMonitor(verificationOnly: CommandLine.arguments.contains("--stability-preview"))
            } else { monitor = UsageMonitor() }
            #else
            monitor = UsageMonitor()
            #endif
        }
        let diagnostics = ConnectionDiagnostics()
        let wifiQualityMonitor = WiFiQualityMonitor()
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
        _utilityWindow = StateObject(wrappedValue: UtilityWindowCoordinator(
            diagnostics: diagnostics,
            wifiQualityMonitor: wifiQualityMonitor
        ) { coordinator in
            AnyView(UtilityWindowView()
                .environmentObject(monitor)
                .environmentObject(diagnostics)
                .environmentObject(wifiQualityMonitor)
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
                    appDelegate.diagnostics = diagnostics
                    appDelegate.wifiQualityMonitor = wifiQualityMonitor
                }
        }
        .menuBarExtraStyle(.window)
    }

    #if DEBUG
    private static func previewMonitor(verificationOnly: Bool = false) -> UsageMonitor {
        let directory = verificationOnly ? "stability-check-preview" : "usage-history-preview"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(directory)/today-usage.json")
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
        if verificationOnly {
            return UsageMonitor(startAutomatically: false,
                storagePaths: UsageStoragePaths(stateURL: file, isVerification: true), readCounters: { [:] })
        }
        return UsageMonitor(stateURL: file, startAutomatically: false, readCounters: { [:] })
    }
    #endif
}
