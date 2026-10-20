import AppIntents

enum UsageWidgetRange: String, AppEnum {
    case thisMonth
    case thirtyDays
    case fifteenDays
    case sevenDays

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Usage Range"
    static var caseDisplayRepresentations: [UsageWidgetRange: DisplayRepresentation] = [
        .thisMonth: "This Month",
        .thirtyDays: "30 Days",
        .fifteenDays: "15 Days",
        .sevenDays: "7 Days"
    ]

    var historyRange: UsageHistoryRange {
        switch self {
        case .thisMonth: .thisMonth
        case .thirtyDays: .thirtyDays
        case .fifteenDays: .fifteenDays
        case .sevenDays: .sevenDays
        }
    }

    init(_ range: UsageHistoryRange) {
        switch range {
        case .thisMonth: self = .thisMonth
        case .thirtyDays: self = .thirtyDays
        case .fifteenDays: self = .fifteenDays
        case .sevenDays: self = .sevenDays
        }
    }
}

struct UsageWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Usage History"
    static var description = IntentDescription("Choose the saved usage history range shown in the widget.")

    @Parameter(title: "Usage Range", default: .thisMonth) var range: UsageWidgetRange?

    init() {
        range = .thisMonth
    }

    var historyRange: UsageHistoryRange { range?.historyRange ?? .thisMonth }
}
