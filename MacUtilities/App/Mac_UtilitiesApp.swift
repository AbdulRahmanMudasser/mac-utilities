import AppKit
import SwiftUI

@main
struct Mac_UtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var startup = HostStartupController()

    var body: some Scene {
        MenuBarExtra {
            if let runtime = startup.runtime {
                ContentView()
                    .environmentObject(runtime.monitor)
                    .environmentObject(runtime.keepAwakeController)
                    .environmentObject(runtime.notificationsController)
                    .environmentObject(runtime.utilityWindow)
            } else {
                HostStartupView(controller: startup)
                    .task { startup.start(appDelegate: appDelegate) }
            }
        } label: {
            if let runtime = startup.runtime {
                MenuBarStatusLabel(text: runtime.monitor.menuBarText, status: runtime.monitor.collectionStatus)
                    .environmentObject(runtime.keepAwakeController)
                    .environmentObject(runtime.utilityWindow)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .accessibilityLabel("Mac Utilities Startup")
                    .task { startup.start(appDelegate: appDelegate) }
            }
        }
        .menuBarExtraStyle(.window)
        .commands { CommandGroup(replacing: .systemServices) { EmptyView() } }
    }
}
