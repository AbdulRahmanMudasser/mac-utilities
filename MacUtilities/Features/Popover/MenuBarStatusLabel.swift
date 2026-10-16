import SwiftUI

struct MenuBarStatusLabel: View {
    let text: String
    let status: String
    @EnvironmentObject private var utilityWindow: UtilityWindowCoordinator
    @State private var presentedDebugWindow = false

    var body: some View {
        Text(text)
            .monospacedDigit()
            .font(UtilityStyle.menuBarFont)
            .help(status)
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
