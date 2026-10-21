import SwiftUI

struct WiFiQualityView: View {
    @EnvironmentObject private var wifiQuality: WiFiQualityMonitor

    var body: some View {
        UtilityPanel(
            "Wi-Fi Signal And Link",
            description: """
            Compare your Wi-Fi signal in different places, with readings updated every five seconds while you view this page.

            Signal: A number closer to zero means a stronger signal.
            Noise: A lower number means less interference.
            Channel: The radio frequency your Wi-Fi uses.
            Wi-Fi Link Rate: The connection speed between your Mac and router.
            """,
            wrapsContent: false
        ) {
            VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
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
