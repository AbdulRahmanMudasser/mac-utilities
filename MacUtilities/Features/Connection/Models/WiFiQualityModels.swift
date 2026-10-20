import Foundation

nonisolated enum WiFiQualityAvailability: Equatable, Sendable {
    case available
    case discoveryUnavailable
    case noInterfaces
    case noDefaultInterface
    case unavailable

    var statusMessage: String? {
        switch self {
        case .available: nil
        case .discoveryUnavailable: "Wi-Fi Readings Unavailable"
        case .noInterfaces: "No Wi-Fi Interface Available"
        case .noDefaultInterface: "No Default Wi-Fi Interface"
        case .unavailable: "Wi-Fi Readings Unavailable"
        }
    }
}

nonisolated enum WiFiChannelBand: Equatable, Sendable {
    case twoGHz
    case fiveGHz
    case sixGHz
    case unknown
    case notAvailable

    var displayName: String {
        switch self {
        case .twoGHz: "2.4 GHz"
        case .fiveGHz: "5 GHz"
        case .sixGHz: "6 GHz"
        case .unknown: "Unknown Band"
        case .notAvailable: "Not Available"
        }
    }
}

nonisolated enum WiFiChannelWidth: Equatable, Sendable {
    case mhz20
    case mhz40
    case mhz80
    case mhz160
    case unknown
    case notAvailable

    var displayName: String {
        switch self {
        case .mhz20: "20 MHz"
        case .mhz40: "40 MHz"
        case .mhz80: "80 MHz"
        case .mhz160: "160 MHz"
        case .unknown: "Unknown Width"
        case .notAvailable: "Not Available"
        }
    }
}

nonisolated struct WiFiQualitySnapshot: Equatable, Sendable {
    let sampledAt: Date
    let interfaceName: String?
    let signalDBm: Int?
    let noiseDBm: Int?
    let channelNumber: Int?
    let channelBand: WiFiChannelBand
    let channelWidth: WiFiChannelWidth
    let transmitRateMbps: Double?
    let availability: WiFiQualityAvailability

    init(
        sampledAt: Date = Date(),
        interfaceName: String? = nil,
        signalDBm: Int? = nil,
        noiseDBm: Int? = nil,
        channelNumber: Int? = nil,
        channelBand: WiFiChannelBand = .notAvailable,
        channelWidth: WiFiChannelWidth = .notAvailable,
        transmitRateMbps: Double? = nil,
        availability: WiFiQualityAvailability = .available
    ) {
        self.sampledAt = sampledAt
        self.interfaceName = interfaceName
        self.signalDBm = signalDBm.flatMap { $0 < 0 ? $0 : nil }
        self.noiseDBm = noiseDBm.flatMap { $0 < 0 ? $0 : nil }
        self.channelNumber = channelNumber.flatMap { $0 > 0 ? $0 : nil }
        self.channelBand = channelBand
        self.channelWidth = channelWidth
        self.transmitRateMbps = transmitRateMbps.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }

        let hasMetric = self.signalDBm != nil || self.noiseDBm != nil
            || self.channelNumber != nil || self.transmitRateMbps != nil
        self.availability = availability == .available && !hasMetric ? .unavailable : availability
    }

    var signalText: String {
        signalDBm.map { "\($0) dBm" } ?? "Not Available"
    }

    var noiseText: String {
        noiseDBm.map { "\($0) dBm" } ?? "Not Available"
    }

    var channelText: String {
        guard let channelNumber else { return "Not Available" }
        let details = [channelBand.displayName, channelWidth.displayName]
            .filter { $0 != "Not Available" }
        return (["\(channelNumber)"] + details).joined(separator: " · ")
    }

    var transmitRateText: String {
        transmitRateMbps.map { "\($0.formatted(.number.precision(.fractionLength(1)))) Mbps" }
            ?? "Not Available"
    }

    var hasAnyReading: Bool {
        signalDBm != nil || noiseDBm != nil || channelNumber != nil || transmitRateMbps != nil
    }
}
