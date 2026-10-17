import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var utilityWindow: UtilityWindowCoordinator?
    weak var monitor: UsageMonitor?
    weak var diagnostics: ConnectionDiagnostics?
    var replyToTermination: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let diagnostics, diagnostics.isRunning else { return .terminateNow }
        diagnostics.shutdown()
        Task { [weak self] in
            await diagnostics.waitUntilStopped()
            self?.replyToTermination(true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        utilityWindow?.shutdown()
        monitor?.shutdown()
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
        #if DEBUG
        if CommandLine.arguments.contains("--stability-preview") {
            Task { [weak self] in
                for _ in 0..<40 where self?.utilityWindow == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                self?.utilityWindow?.present(.connection)
            }
        }
        #endif
    }
}
