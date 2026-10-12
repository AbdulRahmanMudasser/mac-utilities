import AppKit
import SwiftUI

@main
struct Mac_UtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            Label("Setup Needed", systemImage: "network.slash")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .frame(width: 420, height: 260)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct SettingsView: View {
    var body: some View {
        Form {
            Section("Monitoring") {
                Label("Needs Setup", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("The network filter extension and signing configuration are not part of this starter scaffold yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Usage data will be stored locally on this Mac when monitoring is implemented.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
