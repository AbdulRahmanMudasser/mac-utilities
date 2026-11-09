import Foundation

nonisolated enum NetworkTransport: String, Equatable, Sendable {
    case wifi, ethernet, cellular, loopback, other
}

nonisolated struct NetworkPathSnapshot: Equatable, Sendable {
    enum Status: Equatable, Sendable { case pending, available, unavailable }
    var status: Status = .pending
    var usedTypes: Set<NetworkTransport> = []
    var wifiInterfaces: Set<String> = []
}

nonisolated struct ConnectedNetworkLabel: Equatable, Sendable {
    let title: String
    let symbol: String
    let accessibilityValue: String

    static func sanitizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = String(value.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || (0x202A...0x202E).contains($0.value)
                || (0x2066...0x2069).contains($0.value) ? " " : String($0)
        }.joined())
        let display = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return display.isEmpty ? nil : display
    }

    static func resolve(path: NetworkPathSnapshot, name: String?, interface: String?, authorized: Bool) -> Self {
        switch path.status {
        case .pending: return Self(title: "Checking…", symbol: "network", accessibilityValue: "Checking Connection")
        case .unavailable: return Self(title: "Offline", symbol: "wifi.slash", accessibilityValue: "No Network Connection")
        case .available: break
        }
        if path.usedTypes == [.wifi] {
            let matched = path.wifiInterfaces.count == 1 && path.wifiInterfaces.first == interface
            if authorized, matched, let name = sanitizedName(name) {
                return Self(title: name, symbol: "wifi", accessibilityValue: "Wi-Fi, \(name)")
            }
            return Self(title: "Wi-Fi", symbol: "wifi", accessibilityValue: "Wi-Fi")
        }
        if path.usedTypes == [.ethernet] {
            return Self(title: "Ethernet", symbol: "network", accessibilityValue: "Ethernet")
        }
        return Self(title: "Network", symbol: "network", accessibilityValue: "Network")
    }
}

#if DEBUG
nonisolated enum NetworkLabelPreviewState: String, CaseIterable, Sendable {
    case checking, named, longName = "long-name", wifi, ethernet, network, offline, denied, requesting, unavailable
}

nonisolated enum NetworkLabelLaunchMode: Equatable, Sendable {
    case ordinary, fixture(NetworkLabelPreviewState), nativeCheck

    static func parse(_ arguments: [String]) throws -> Self {
        let fixtures = arguments.filter { $0.hasPrefix("--network-label-preview") }
        let native = arguments.filter { $0.hasPrefix("--network-label-native-check") }
        guard !fixtures.isEmpty || !native.isEmpty else { return .ordinary }
        guard arguments.filter({ $0 == "--usage-preview" || $0.hasPrefix("--usage-preview=") }) == ["--usage-preview=history"],
              fixtures.count + native.count == 1 else { throw InvalidArguments() }
        if native == ["--network-label-native-check"] { return .nativeCheck }
        guard let value = fixtures.first, value.hasPrefix("--network-label-preview="),
              let state = NetworkLabelPreviewState(rawValue: String(value.dropFirst("--network-label-preview=".count))) else {
            throw InvalidArguments()
        }
        return .fixture(state)
    }

    struct InvalidArguments: LocalizedError {
        var errorDescription: String? { "Network label checks require --usage-preview=history and one valid network label modifier." }
    }
}
#endif
