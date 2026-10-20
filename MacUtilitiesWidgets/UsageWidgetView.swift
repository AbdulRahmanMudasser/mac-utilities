import Charts
import SwiftUI
import WidgetKit

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let presentation: UsageWidgetPresentation

    private var range: UsageHistoryRange { presentation.range }

    var body: some View {
        Group {
            switch presentation {
            case .openAppToLoadUsage:
                stateMessage("Open Mac Utilities To Load Usage", symbol: "arrow.up.forward.app")
            case .unavailable:
                stateMessage("Saved Usage Unavailable", symbol: "exclamationmark.arrow.circlepath")
            case .noUsageHistory(let reading):
                emptyReading(reading, message: "No Usage History Yet")
            case .noDataInRange(let reading):
                emptyReading(reading, message: "No Data In This Range")
            case .readings(let reading):
                readingView(reading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(UsageRoute.url(for: range))
        .containerBackground(.background, for: .widget)
    }

    private func stateMessage(_ title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(range: range)
            Spacer(minLength: 2)
            Label(title, systemImage: symbol)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Link("Open Mac Utilities", destination: UsageRoute.url(for: range))
                .font(.subheadline)
            Spacer(minLength: 2)
        }
        .accessibilityElement(children: .contain)
    }

    private func emptyReading(_ reading: UsageWidgetReadingPresentation, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                header(range: reading.range)
                Spacer(minLength: 2)
                freshness(reading.lastObservedAt)
            }
            Text(message).font(.headline)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func readingView(_ reading: UsageWidgetReadingPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                header(range: reading.range)
                Spacer(minLength: 2)
                freshness(reading.lastObservedAt)
            }
            if family != .systemLarge { Spacer(minLength: 0) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 3),
                      alignment: .leading, spacing: 0) {
                metric("Downloaded", bytes: reading.downloaded, unit: reading.dataUnit)
                metric("Uploaded", bytes: reading.uploaded, unit: reading.dataUnit, alignment: .center)
                metric("Combined", bytes: reading.combined, unit: reading.dataUnit, alignment: .trailing)
            }
            .padding(.vertical, family == .systemLarge ? 8 : 0)
            if family == .systemLarge {
                usageChart(reading)
                    .frame(minHeight: 155, maxHeight: .infinity)
                    .accessibilityLabel("Daily Download And Upload Usage")
            } else {
                Spacer(minLength: 0)
                if let average = reading.average {
                    VStack(spacing: 8) {
                        Divider()
                        HStack(alignment: .firstTextBaseline) {
                            Text("Average").foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(UsageFormatting.data(average, unit: reading.dataUnit))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func header(range: UsageHistoryRange) -> some View {
        Text(range.rawValue)
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityAddTraits(.isHeader)
    }

    private func metric(_ title: String, bytes: UInt64, unit: DataDisplayUnit,
                        alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(UsageFormatting.data(bytes, unit: unit))
                .font(.body.weight(.semibold))
                .monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(UsageFormatting.data(bytes, unit: unit))
    }

    private func freshness(_ lastObservedAt: Date?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let lastObservedAt {
                Text(lastObservedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
            } else {
                Text("No Readings Yet").foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lastObservedAt.map { "Last Reading \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No Readings Yet")
    }

    private func usageChart(_ reading: UsageWidgetReadingPresentation) -> some View {
        let maxLabels = family == .systemLarge ? 6 : 3
        let axisKeys = reading.axisDayKeys(maximumCount: maxLabels)
        let calendar = UsageHistory.calendar(timeZone: TimeZone(identifier: reading.timeZoneIdentifier) ?? .autoupdatingCurrent)

        return Chart {
            ForEach(reading.days) { day in
                if day.hasRecord {
                    downloadedMark(for: day, scale: reading.scale, unit: reading.dataUnit)
                    uploadedMark(for: day, scale: reading.scale, unit: reading.dataUnit)
                } else {
                    PointMark(x: .value("Day", day.dayKey), y: .value("Usage", 0))
                        .symbol(.circle).symbolSize(12)
                        .foregroundStyle(UsageChartPresentation.uploadColor)
                        .accessibilityLabel("\(day.dayKey), No Data")
                }
            }
        }
        .chartXScale(domain: reading.days.map(\.dayKey))
        .chartYScale(domain: 0...max(1, Double(reading.maximumDailyBytes) / reading.scale))
        .chartYAxisLabel(reading.scaleLabel)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: family == .systemLarge ? 4 : 2)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number.formatted(.number.precision(.fractionLength(0))))
                            .font(.system(size: family == .systemLarge ? 9 : 7))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisKeys) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let day = reading.days.first(where: { $0.dayKey == key }) {
                        Text(day.date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
                            .month(.abbreviated).day()))
                            .font(.system(size: family == .systemLarge ? 9 : 7))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartForegroundStyleScale(["Downloaded": UsageChartPresentation.downloadColor,
                                    "Uploaded": UsageChartPresentation.uploadColor])
    }

    @ChartContentBuilder
    private func downloadedMark(for day: UsageWidgetDayPresentation, scale: Double,
                                unit: DataDisplayUnit) -> some ChartContent {
        if let bytes = day.downloaded {
            if bytes == 0 {
                PointMark(x: .value("Day", day.dayKey), y: .value("Usage", 0))
                    .symbol(.square).symbolSize(12)
                    .foregroundStyle(UsageChartPresentation.downloadColor)
                    .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), Downloaded")
                    .accessibilityValue(UsageFormatting.data(0, unit: unit))
            } else {
                BarMark(x: .value("Day", day.dayKey), y: .value("Usage", Double(bytes) / scale))
                    .foregroundStyle(by: .value("Direction", "Downloaded"))
                    .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), Downloaded")
                    .accessibilityValue(UsageFormatting.data(bytes, unit: unit))
            }
        }
    }

    @ChartContentBuilder
    private func uploadedMark(for day: UsageWidgetDayPresentation, scale: Double,
                              unit: DataDisplayUnit) -> some ChartContent {
        if let bytes = day.uploaded {
            if bytes == 0 {
                PointMark(x: .value("Day", day.dayKey), y: .value("Usage", 0))
                    .symbol(.circle).symbolSize(12)
                    .foregroundStyle(UsageChartPresentation.uploadColor)
                    .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), Uploaded")
                    .accessibilityValue(UsageFormatting.data(0, unit: unit))
            } else {
                BarMark(x: .value("Day", day.dayKey), y: .value("Usage", Double(bytes) / scale))
                    .foregroundStyle(by: .value("Direction", "Uploaded"))
                    .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), Uploaded")
                    .accessibilityValue(UsageFormatting.data(bytes, unit: unit))
            }
        }
    }
}
