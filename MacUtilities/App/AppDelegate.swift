import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var utilityWindow: UtilityWindowCoordinator? {
        didSet { deliverPendingRoute() }
    }
    private var pendingRoute: UsageRoute?
    private var windowRoutingReady = false

    func markWindowRoutingReady() {
        windowRoutingReady = true
        deliverPendingRoute()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let route = UsageRoute(url: url) else { continue }
            pendingRoute = route
            deliverPendingRoute()
        }
    }

    private func deliverPendingRoute() {
        guard windowRoutingReady, let utilityWindow, let route = pendingRoute else { return }
        pendingRoute = nil
        utilityWindow.presentUsage(range: route.range)
    }
    var widgetReloadCoordinator: WidgetReloadCoordinator?
    weak var monitor: UsageMonitor?
    weak var diagnostics: ConnectionDiagnostics?
    weak var wifiQualityMonitor: WiFiQualityMonitor?
    weak var keepAwakeController: KeepAwakeController?
    var replyToTermination: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        keepAwakeController?.shutdown()
        wifiQualityMonitor?.shutdown()
        guard let diagnostics, diagnostics.isRunning else { return .terminateNow }
        diagnostics.shutdown()
        Task { [weak self] in
            await diagnostics.waitUntilStopped()
            self?.replyToTermination(true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        keepAwakeController?.shutdown()
        utilityWindow?.shutdown()
        wifiQualityMonitor?.shutdown()
        monitor?.shutdown()
        widgetReloadCoordinator?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let utilityWindow, utilityWindow.window != nil {
            utilityWindow.present(utilityWindow.selection)
        }
        return false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppBrand.icon
        NSApp.setActivationPolicy(.accessory)
        markWindowRoutingReady()
        #if DEBUG
        if CommandLine.arguments.contains("--stability-preview") || CommandLine.arguments.contains("--usage-preview") ||
            CommandLine.arguments.contains("--keep-awake-preview") {
            if CommandLine.arguments.contains("--keep-awake-preview") {
                utilityWindow?.present(.keepAwake)
            } else {
                utilityWindow?.present(CommandLine.arguments.contains("--usage-preview") ? .usage : .connection)
            }
        }
        #endif
    }
}
