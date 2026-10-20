import Foundation

nonisolated struct UsageRoute: Equatable, Sendable {
    let range: UsageHistoryRange

    static func token(for range: UsageHistoryRange) -> String {
        switch range {
        case .thisMonth: "thisMonth"
        case .thirtyDays: "thirtyDays"
        case .fifteenDays: "fifteenDays"
        case .sevenDays: "sevenDays"
        }
    }

    static func url(for range: UsageHistoryRange) -> URL {
        var components = URLComponents()
        components.scheme = "macutilities"
        components.host = "usage"
        components.queryItems = [URLQueryItem(name: "range", value: token(for: range))]
        return components.url!
    }

    init?(url: URL) {
        guard url.absoluteString.utf8.count <= 512,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "macutilities", components.host == "usage",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil else { return nil }
        let items = components.queryItems ?? []
        guard items.count <= 1, items.allSatisfy({ $0.name == "range" }) else { return nil }
        range = UsageHistoryRange.allCases.first { Self.token(for: $0) == items.first?.value } ?? .thisMonth
    }
}
