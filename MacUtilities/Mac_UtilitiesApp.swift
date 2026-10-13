import AppKit
import SwiftUI

enum AppWindowID {
    static let settings = "settings"
}

enum AppBrand {
    static var icon: NSImage {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "AppIcon"
        let filename = name.hasSuffix(".icns") ? name : "\(name).icns"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(filename),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }
}

private struct HandPointerModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .pointerStyle(.link)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
    }
}

extension View {
    func handPointer() -> some View {
        modifier(HandPointerModifier())
    }
}

@main
struct Mac_UtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
        } label: {
            Text(monitor.menuBarText)
                .monospacedDigit()
                .font(.system(size: 11, weight: .medium))
                .help(monitor.collectionStatus)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: AppWindowID.settings) {
            SettingsView()
                .environmentObject(monitor)
                .frame(width: 500, height: 440)
        }
        .defaultSize(width: 500, height: 440)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppBrand.icon
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var monitor: UsageMonitor

    private var monitoringBinding: Binding<Bool> {
        Binding(
            get: { !monitor.isPaused },
            set: { monitor.setPaused(!$0) }
        )
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { monitor.loginItemEnabled },
            set: { monitor.setLoginItemEnabled($0) }
        )
    }

    var body: some View {
        Form {
            Section("Monitoring") {
                Toggle("Collect Device Activity", isOn: monitoringBinding)
                    .toggleStyle(HandCursorToggleStyle())
            }

            Section("Readiness") {
                LabeledContent("Local Time Zone", value: monitor.localTimeZoneDescription)
                Label(monitor.collectionStatus, systemImage: monitor.isPaused ? "pause.circle.fill" : (monitor.counterError == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                    .foregroundStyle(monitor.isPaused ? .orange : (monitor.counterError == nil ? .green : .orange))
            }

            Section("General") {
                Toggle("Start At Login", isOn: loginItemBinding)
                    .toggleStyle(HandCursorToggleStyle())
                if let message = monitor.loginItemMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Display") {
                HandCursorPicker(title: "Speed Display", options: RateDisplayUnit.allCases, selection: $monitor.rateUnit, optionTitle: { $0.title })
                HandCursorPicker(title: "Data Display", options: DataDisplayUnit.allCases, selection: $monitor.dataUnit, optionTitle: { $0.title })
            }

            Section("Today's Usage") {
                LabeledContent("Downloaded", value: monitor.formattedDownloadedToday)
                LabeledContent("Uploaded", value: monitor.formattedUploadedToday)
                LabeledContent("Combined", value: monitor.formattedCombinedToday)
                LabeledContent {
                    Button("Reset Today's Counters", role: .destructive) { monitor.resetToday() }
                        .handPointer()
                } label: {
                    EmptyView()
                }
            }

            Section("Privacy") {
                Text("Device counters and daily totals are stored locally on this Mac. No network payloads, websites, or remote telemetry are collected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                HStack(spacing: 12) {
                    Image(nsImage: AppBrand.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mac Utilities").font(.headline)
                        Text("Network Activity")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Version \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct HandCursorToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer()
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 36, height: 22)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Color(nsColor: .windowBackgroundColor) : .white)
                            .frame(width: 18, height: 18)
                            .padding(2)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handPointer()
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

private struct HandCursorPicker<Option: Hashable & Identifiable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let optionTitle: (Option) -> String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack {
                Text(title)
                Spacer()
                Text(optionTitle(selection)).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handPointer()
        .accessibilityLabel(title)
        .accessibilityValue(optionTitle(selection))
        .popover(isPresented: $isPresented) {
            VStack(spacing: 4) {
                ForEach(options) { option in
                    Button {
                        selection = option
                        isPresented = false
                    } label: {
                        HStack {
                            Text(optionTitle(option))
                            Spacer()
                            Image(systemName: "checkmark").opacity(selection == option ? 1 : 0)
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handPointer()
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
            .padding(6)
            .frame(width: 150)
        }
    }
}
