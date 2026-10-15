import AppKit
import SwiftUI

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
        try? UsageMonitor.saveState(state, at: file)
        return UsageMonitor(stateURL: file, startAutomatically: false, readCounters: { [:] })
    }
    #endif
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var utilityWindow: UtilityWindowCoordinator?
    weak var monitor: UsageMonitor?

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
    }
}

struct SettingsView: View {
    @EnvironmentObject private var monitor: UsageMonitor

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { monitor.loginItemEnabled },
            set: { monitor.setLoginItemEnabled($0) }
        )
    }

    var body: some View {
        UtilityScrollContent {
            Label(monitor.collectionStatus, systemImage: monitor.counterError == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(monitor.counterError == nil ? UtilityStyle.successColor : UtilityStyle.warningColor)
                .padding(UtilityStyle.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .utilityCardBackground()

            UtilityPanel("General") {
                UtilityValueRow(title: "Local Time Zone", value: monitor.localTimeZoneDescription)
                Toggle("Start At Login", isOn: loginItemBinding)
                    .toggleStyle(HandCursorToggleStyle())
                if let message = monitor.loginItemMessage {
                    Text(message)
                        .font(UtilityStyle.helpFont)
                        .foregroundStyle(UtilityStyle.warningColor)
                }
            }

            UtilityPanel("Display") {
                HandCursorPicker(title: "Speed Display", options: RateDisplayUnit.allCases, selection: $monitor.rateUnit, optionTitle: { $0.title })
                HandCursorPicker(title: "Data Display", options: DataDisplayUnit.allCases, selection: $monitor.dataUnit, optionTitle: { $0.title })
            }

            UtilityPanel("About") {
                HStack(spacing: UtilityStyle.contentSpacing) {
                    Image(nsImage: AppBrand.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: UtilityStyle.aboutIconSize, height: UtilityStyle.aboutIconSize)
                        .accessibilityHidden(true)
                    Text("Mac Utilities").font(UtilityStyle.headingFont)
                    Spacer(minLength: UtilityStyle.contentSpacing)
                    Text("Version \(appVersion)")
                        .font(UtilityStyle.metadataFont)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, UtilityStyle.aboutVerticalPadding)
            }
        }
        .font(UtilityStyle.bodyFont)
        .controlSize(UtilityStyle.controlSize)
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
            HStack(spacing: UtilityStyle.contentSpacing) {
                configuration.label
                Spacer()
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : UtilityStyle.Toggle.offColor)
                    .frame(width: UtilityStyle.Toggle.width, height: UtilityStyle.Toggle.height)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? UtilityStyle.Toggle.onThumbColor : UtilityStyle.Toggle.offThumbColor)
                            .frame(width: UtilityStyle.Toggle.thumbSize, height: UtilityStyle.Toggle.thumbSize)
                            .padding(UtilityStyle.Toggle.thumbInset)
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
            HStack(spacing: UtilityStyle.contentSpacing) {
                Text(title)
                Spacer()
                Text(optionTitle(selection)).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(UtilityStyle.Picker.indicatorFont)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handPointer()
        .accessibilityLabel(title)
        .accessibilityValue(optionTitle(selection))
        .popover(isPresented: $isPresented) {
            VStack(spacing: UtilityStyle.Picker.optionSpacing) {
                ForEach(options) { option in
                    Button {
                        selection = option
                        isPresented = false
                    } label: {
                        HStack(spacing: UtilityStyle.contentSpacing) {
                            Text(optionTitle(option))
                            Spacer()
                            Image(systemName: "checkmark").opacity(selection == option ? 1 : 0)
                        }
                        .padding(UtilityStyle.Picker.optionPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handPointer()
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
            .padding(UtilityStyle.Picker.padding)
            .frame(width: UtilityStyle.Picker.width)
        }
    }
}

private struct MenuBarStatusLabel: View {
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
