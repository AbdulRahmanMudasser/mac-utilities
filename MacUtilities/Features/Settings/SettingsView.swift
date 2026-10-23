import SwiftUI

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
            UtilityCapabilityCard(title: monitor.collectionStatus, isActive: monitor.isMonitoringActive)

            UtilityPanel("General") {
                UtilityValueRow(title: "Local Time Zone", value: monitor.localTimeZoneDescription)
                HStack(spacing: UtilityStyle.contentSpacing) {
                    Text("Start At Login")
                    Spacer()
                    Toggle("Start At Login", isOn: loginItemBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Start At Login")
                        .handPointer()
                }
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
