import SwiftUI
import WidgetKit

struct UsageHistoryWidget: Widget {
    static let kind = "UsageHistoryWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: UsageWidgetConfigurationIntent.self,
                               provider: UsageWidgetProvider()) { entry in
            UsageWidgetView(presentation: entry.presentation)
        }
        .configurationDisplayName("Usage History")
        .description("View saved download and upload history.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

#Preview("Medium - This Month", as: .systemMedium) {
    UsageHistoryWidget()
} timeline: {
    UsageWidgetProvider.previewEntry(range: .thisMonth, now: .now)
}

#Preview("Medium - 30 Days", as: .systemMedium) {
    UsageHistoryWidget()
} timeline: {
    UsageWidgetProvider.previewEntry(range: .thirtyDays, now: .now)
}

#Preview("Medium - 15 Days", as: .systemMedium) {
    UsageHistoryWidget()
} timeline: {
    UsageWidgetProvider.previewEntry(range: .fifteenDays, now: .now)
}

#Preview("Medium - 7 Days", as: .systemMedium) {
    UsageHistoryWidget()
} timeline: {
    UsageWidgetProvider.previewEntry(range: .sevenDays, now: .now)
}

#Preview("Large - This Month", as: .systemLarge) {
    UsageHistoryWidget()
} timeline: {
    UsageWidgetProvider.previewEntry(range: .thisMonth, now: .now)
}

#Preview("Large - 30 Days", as: .systemLarge) {
    UsageHistoryWidget()
} timeline: {
    UsageWidgetProvider.previewEntry(range: .thirtyDays, now: .now)
}

#Preview("Large - 15 Days", as: .systemLarge) {
    UsageHistoryWidget()
} timeline: {
    UsageWidgetProvider.previewEntry(range: .fifteenDays, now: .now)
}

#Preview("Large - 7 Days", as: .systemLarge) {
    UsageHistoryWidget()
} timeline: {
    UsageWidgetProvider.previewEntry(range: .sevenDays, now: .now)
}
