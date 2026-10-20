import CoreWLAN
import Foundation

nonisolated protocol WiFiQualityReading: Sendable {
    func read() async -> WiFiQualitySnapshot
}

actor CoreWLANWiFiQualityReader: WiFiQualityReading {
    private var client: CWWiFiClient?

    func read() async -> WiFiQualitySnapshot {
        let client = self.client ?? CWWiFiClient.shared()
        self.client = client

        guard let interfaceNames = client.interfaceNames() else {
            return WiFiQualitySnapshot(sampledAt: Date(), availability: .discoveryUnavailable)
        }
        guard !interfaceNames.isEmpty else {
            return WiFiQualitySnapshot(sampledAt: Date(), availability: .noInterfaces)
        }
        guard let interface = client.interface() else {
            return WiFiQualitySnapshot(sampledAt: Date(), availability: .noDefaultInterface)
        }

        let channel = interface.wlanChannel()
        return WiFiQualitySnapshot(
            sampledAt: Date(),
            interfaceName: interface.interfaceName,
            signalDBm: interface.rssiValue(),
            noiseDBm: interface.noiseMeasurement(),
            channelNumber: channel.map { Int($0.channelNumber) },
            channelBand: channel.map { band(for: $0.channelBand) } ?? .notAvailable,
            channelWidth: channel.map { width(for: $0.channelWidth) } ?? .notAvailable,
            transmitRateMbps: interface.transmitRate()
        )
    }

    private func band(for band: CWChannelBand) -> WiFiChannelBand {
        switch band {
        case .band2GHz: .twoGHz
        case .band5GHz: .fiveGHz
        case .band6GHz: .sixGHz
        case .bandUnknown: .unknown
        @unknown default: .unknown
        }
    }

    private func width(for width: CWChannelWidth) -> WiFiChannelWidth {
        switch width {
        case .width20MHz: .mhz20
        case .width40MHz: .mhz40
        case .width80MHz: .mhz80
        case .width160MHz: .mhz160
        case .widthUnknown: .unknown
        @unknown default: .unknown
        }
    }
}
