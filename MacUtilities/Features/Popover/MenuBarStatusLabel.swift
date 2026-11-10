import SwiftUI

struct MenuBarStatusLabel: View {
    @EnvironmentObject private var monitor: UsageMonitor
    @EnvironmentObject private var utilityWindow: UtilityWindowCoordinator
    @EnvironmentObject private var keepAwakeController: KeepAwakeController
    @State private var presentedDebugWindow = false

    static func displayedText(rateText: String, keepAwakePrefix: String) -> String {
        keepAwakePrefix + rateText
    }

    var body: some View {
        Text(Self.displayedText(rateText: monitor.menuBarText, keepAwakePrefix: keepAwakeController.menuBarPrefix))
            .monospacedDigit()
            .font(UtilityStyle.menuBarFont)
            .help(monitor.collectionStatus)
            .onAppear {
                #if DEBUG
                if !presentedDebugWindow && CommandLine.arguments.contains("--connection-check") {
                    presentedDebugWindow = true
                    utilityWindow.present(.connection)
                }
                if !presentedDebugWindow && CommandLine.arguments.contains("--settings") {
                    presentedDebugWindow = true
                    utilityWindow.present(.settings)
                }
                if !presentedDebugWindow && CommandLine.arguments.contains("--usage") {
                    presentedDebugWindow = true
                    utilityWindow.present(.usage)
                }
                #endif
            }
    }
}
