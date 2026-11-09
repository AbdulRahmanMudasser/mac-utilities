import SwiftUI

struct WiFiQualityView: View {
    @EnvironmentObject private var wifiQuality: WiFiQualityMonitor

    var body: some View {
        UtilityPanel(
            "Wi-Fi Signal And Link",
            description: """
            Network names are shown with Location permission and stay in memory. Wi-Fi may differ from your active connection; speed totals include device-wide traffic.

            Compare your Wi-Fi signal in different places, with readings updated every five seconds while you view this page.

            Signal: A number closer to zero means a stronger signal.
            Noise: A lower number means less interference.
            Channel: The radio frequency your Wi-Fi uses.
            Wi-Fi Link Rate: The connection speed between your Mac and router.
            """,
            wrapsContent: false
        ) {
            VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                if let name = wifiQuality.associatedName {
                    UtilityValueRow(title: "Wi-Fi Network", value: name)
                }
                if let snapshot = wifiQuality.snapshot {
                    if snapshot.hasAnyReading {
                        UtilityMetricRow(title: "Signal", value: snapshot.signalText)
                        UtilityMetricRow(title: "Noise", value: snapshot.noiseText)
                        UtilityMetricRow(title: "Channel", value: snapshot.channelText)
                        UtilityMetricRow(title: "Wi-Fi Link Rate", value: snapshot.transmitRateText)
                    } else if let status = snapshot.availability.statusMessage {
                        Text(status).foregroundStyle(.secondary)
                    }
                } else {
                    Text(wifiQuality.isRefreshing ? "Reading Wi-Fi Link…" : "Waiting For Wi-Fi Readings…")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(UtilityStyle.cardPadding)
            .utilityCardBackground()
            if let snapshot = wifiQuality.snapshot {
                UtilityTimestampRow(
                    date: snapshot.sampledAt,
                    title: "Last Updated",
                    symbol: snapshot.hasAnyReading ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    color: snapshot.hasAnyReading ? UtilityStyle.successColor : UtilityStyle.warningColor
                )
            }
        }
    }
}

struct NetworkNameCapabilityView: View {
    @EnvironmentObject private var wifiQuality: WiFiQualityMonitor

    var body: some View {
        UtilityCapabilityCard(title: capabilityTitle, isActive: wifiQuality.permissionState == .authorized,
            detail: capabilityDetail, action: permissionAction)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Wi-Fi Name Capability")
            .accessibilityValue(capabilityTitle)
    }

    private var capabilityTitle: String {
        if wifiQuality.settingsOpenFailed { return "Could Not Open Settings" }
        switch wifiQuality.permissionState {
        case .authorized: return "Wi-Fi Name Access Allowed"
        case .notDetermined: return "Wi-Fi Name Access"
        case .requesting: return "Requesting Wi-Fi Name Access…"
        case .denied: return "Wi-Fi Name Access Denied"
        case .restricted: return "Wi-Fi Name Access Restricted"
        case .servicesDisabled: return "Location Services Disabled"
        case .unknown: return "Wi-Fi Name Access Unavailable"
        }
    }

    private var capabilityDetail: String? {
        if wifiQuality.settingsOpenFailed { return "Open System Settings → Privacy & Security → Location Services." }
        if wifiQuality.isSimulated { return "This preview uses simulated network and permission states." }
        switch wifiQuality.permissionState {
        case .authorized: return nil
        case .notDetermined: return "Allow Location access to reveal the Wi-Fi name. Coordinates are not requested and names are not saved."
        case .denied, .servicesDisabled: return "Allow Mac Utilities in System Settings → Privacy & Security → Location Services."
        case .restricted: return "Location access is restricted by macOS policy."
        case .unknown: return "Wi-Fi names are unavailable. Signal and link readings still work."
        case .requesting: return nil
        }
    }

    private var permissionAction: AnyView? {
        switch wifiQuality.permissionState {
        case .notDetermined:
            return AnyView(Button("Show Wi-Fi Name") { wifiQuality.requestNetworkName() }
                .buttonStyle(.bordered).controlSize(UtilityStyle.controlSize)
                .disabled(wifiQuality.isSimulated).handPointer())
        case .denied, .servicesDisabled:
            return AnyView(Button("Open Settings") { wifiQuality.openLocationSettings() }
                .buttonStyle(.bordered).controlSize(UtilityStyle.controlSize)
                .disabled(wifiQuality.isSimulated).handPointer())
        case .requesting:
            return AnyView(ProgressView().controlSize(UtilityStyle.progressControlSize).accessibilityLabel("Requesting Wi-Fi Name Access"))
        default: return nil
        }
    }
}
