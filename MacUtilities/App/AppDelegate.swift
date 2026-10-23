import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var utilityWindow: UtilityWindowCoordinator? {
        didSet { deliverPendingRoute() }
    }
    weak var notificationsController: NotificationsController?

    private enum PendingRoute {
        case usage(UsageHistoryRange)
        case keepAwake
    }

    private var pendingRoute: PendingRoute?
    private var windowRoutingReady = false

    func markWindowRoutingReady() {
        windowRoutingReady = true
        deliverPendingRoute()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let route = UsageRoute(url: url) else { continue }
            pendingRoute = .usage(route.range)
            deliverPendingRoute()
        }
    }

    func routeToKeepAwake() {
        pendingRoute = .keepAwake
        deliverPendingRoute()
    }

    private func deliverPendingRoute() {
        guard windowRoutingReady, let utilityWindow, let route = pendingRoute else { return }
        pendingRoute = nil
        switch route {
        case let .usage(range): utilityWindow.presentUsage(range: range)
        case .keepAwake: utilityWindow.present(.keepAwake)
        }
    }
    var widgetReloadCoordinator: WidgetReloadCoordinator?
    weak var monitor: UsageMonitor?
    weak var diagnostics: ConnectionDiagnostics?
    weak var wifiQualityMonitor: WiFiQualityMonitor?
    weak var keepAwakeController: KeepAwakeController?
    var replyToTermination: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        keepAwakeController?.shutdown()
        notificationsController?.shutdown()
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
        notificationsController?.shutdown()
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
        let hasNotificationPreview = CommandLine.arguments.contains("--notification-preview") ||
            CommandLine.arguments.contains(where: { $0.hasPrefix("--notification-preview=") })
        let hasStabilityPreview = CommandLine.arguments.contains("--stability-preview") ||
            CommandLine.arguments.contains(where: { $0.hasPrefix("--stability-preview=") })
        let hasUsagePreview = CommandLine.arguments.contains("--usage-preview") ||
            CommandLine.arguments.contains(where: { $0.hasPrefix("--usage-preview=") })
        let hasSettingsPreview = CommandLine.arguments.contains("--settings-preview") ||
            CommandLine.arguments.contains(where: { $0.hasPrefix("--settings-preview=") })
        let hasKeepAwakePreview = CommandLine.arguments.contains("--keep-awake-preview") ||
            CommandLine.arguments.contains(where: { $0.hasPrefix("--keep-awake-preview=") })
        if hasStabilityPreview || hasUsagePreview || hasSettingsPreview || hasKeepAwakePreview || hasNotificationPreview {
            if hasKeepAwakePreview {
                utilityWindow?.present(.keepAwake)
            } else if hasNotificationPreview {
                utilityWindow?.present(.notifications)
                if CommandLine.arguments.contains("--notification-preview=delivery-error") {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(250))
                        self?.notificationsController?.notifyTimerFinished(
                            KeepAwakeTimerFinishedEvent(sessionGeneration: 1, duration: .timed(minutes: 30))
                        )
                    }
                }
            } else if hasSettingsPreview {
                utilityWindow?.present(.settings)
            } else {
                utilityWindow?.present(hasUsagePreview ? .usage : .connection)
            }
        }
        #endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor [weak self] in
            await self?.notificationsController?.refreshAuthorization()
        }
    }
}
