import Charts
import SwiftUI

struct UsageHistoryView: View {
    @EnvironmentObject private var monitor: UsageMonitor
    @State private var range: UsageHistoryRange = .thisMonth
    @State private var selectedKey: String?
    @State private var hoveredKey: String?
    @State private var confirmClear = false
    @State private var showDownloads = true
    @State private var showUploads = true

    private var days: [UsageHistoryDay] {
        UsageHistory.days(records: monitor.historyRecords, range: range,
                          now: monitor.historyDate, calendar: monitor.historyCalendar)
    }

    private var inspectedDay: UsageHistoryDay? {
        guard showDownloads || showUploads else { return nil }
        let key = hoveredKey ?? selectedKey
        return days.first(where: { $0.dayKey == key })
    }

    private var totals: InterfaceByteCount { UsageHistory.totals(days) }
    private func visibleBytes(_ record: DailyUsageRecord) -> UInt64 {
        UsageHistory.add(showDownloads ? record.downloaded : 0, showUploads ? record.uploaded : 0)
    }
    private var maximumBytes: UInt64 { days.compactMap { $0.record.map(visibleBytes) }.max() ?? 0 }
    private var scale: Double { UsageChartPresentation.scale(maximumBytes: maximumBytes, unit: monitor.dataUnit) }
    private var scaleLabel: String { UsageChartPresentation.scaleLabel(scale: scale, unit: monitor.dataUnit) }

    var body: some View {
        UtilityScrollContent {
            UtilityPanel("Usage Summary", action: AnyView(rangePicker)) {
                if let first = days.first, let last = days.last {
                    Text("\(dateLabel(first.date)) – \(dateLabel(last.date))")
                        .font(UtilityStyle.metadataFont).foregroundStyle(.secondary)
                        .accessibilityLabel("Selected Range, \(dateLabel(first.date)) through \(dateLabel(last.date))")
                }
                if days.contains(where: { $0.record != nil }) {
                    UtilityValueRow(title: "Downloaded", value: formatted(totals.downloaded))
                    UtilityValueRow(title: "Uploaded", value: formatted(totals.uploaded))
                    UtilityValueRow(title: "Combined", value: formatted(UsageHistory.add(totals.downloaded, totals.uploaded)))
                        .fontWeight(.semibold)
                } else {
                    Text("No Data In This Range").foregroundStyle(.secondary)
                }
                if let error = monitor.historyError {
                    Text(error).font(UtilityStyle.helpFont).foregroundStyle(UtilityStyle.warningColor)
                }
                if let error = monitor.counterError {
                    Text(error).font(UtilityStyle.helpFont).foregroundStyle(UtilityStyle.warningColor)
                }
            }
            VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                UtilityPanel("Daily Usage") {
                    legend
                    if showDownloads || showUploads {
                        chart
                    } else {
                        UtilityChartEmptyState(height: UtilityStyle.History.chartHeight)
                    }
                    if monitor.historyRecords.isEmpty {
                        Text("No history yet. Usage appears as readings are collected.")
                            .font(UtilityStyle.helpFont).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear History", role: .destructive) { confirmClear = true }
                        .buttonStyle(.bordered).handPointer()
                        .disabled(!monitor.historyWritable || monitor.historyRecords.isEmpty)
                }
            }
        }
        .font(UtilityStyle.bodyFont)
        .controlSize(UtilityStyle.controlSize)
        .environment(\.calendar, monitor.historyCalendar)
        .environment(\.timeZone, monitor.historyCalendar.timeZone)
        .onChange(of: range) { _, _ in resetSelectionIfNeeded() }
        .onChange(of: days.map(\.dayKey)) { _, _ in resetSelectionIfNeeded() }
        .onChange(of: showDownloads) { _, _ in resetSelectionIfNeeded() }
        .onChange(of: showUploads) { _, _ in resetSelectionIfNeeded() }
        .sheet(isPresented: $confirmClear) { clearConfirmation }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(UsageHistoryRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu).labelsHidden()
        .accessibilityLabel("Usage Range")
    }

    private func tooltip(for day: UsageHistoryDay) -> some View {
        UtilityTooltip {
            VStack(alignment: .leading, spacing: UtilityStyle.Tooltip.spacing) {
                Text(dateLabel(day.date)).font(UtilityStyle.helpFont.weight(.semibold))
                if let record = day.record {
                    Grid(alignment: .leading, horizontalSpacing: UtilityStyle.contentSpacing,
                         verticalSpacing: UtilityStyle.Tooltip.spacing) {
                        if showDownloads { tooltipMetric("Downloaded", bytes: record.downloaded) }
                        if showUploads { tooltipMetric("Uploaded", bytes: record.uploaded) }
                        if showDownloads && showUploads { tooltipMetric("Combined", bytes: record.combined) }
                    }
                } else {
                    Text("No Data").foregroundStyle(.secondary)
                }
            }
        }
        .font(UtilityStyle.metadataFont)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private func tooltipMetric(_ title: String, bytes: UInt64) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(formatted(bytes)).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(days) { day in
                if let record = day.record {
                    if showDownloads {
                        BarMark(x: .value("Day", day.dayKey), y: .value("Usage", Double(record.downloaded) / scale))
                            .foregroundStyle(by: .value("Direction", "Downloaded"))
                            .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), Downloaded")
                            .accessibilityValue(formatted(record.downloaded))
                    }
                    if showUploads {
                        BarMark(x: .value("Day", day.dayKey), y: .value("Usage", Double(record.uploaded) / scale))
                            .foregroundStyle(by: .value("Direction", "Uploaded"))
                            .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), Uploaded")
                            .accessibilityValue(formatted(record.uploaded))
                    }
                    if (showDownloads || showUploads) && visibleBytes(record) == 0 {
                        PointMark(x: .value("Day", day.dayKey), y: .value("Usage", 0))
                            .symbol(.square).symbolSize(UtilityStyle.History.symbolSize)
                            .foregroundStyle(UtilityStyle.History.downloadColor)
                            .accessibilityLabel("\(day.dayKey), \(zeroUsageLabel)")
                    }
                } else if showDownloads || showUploads {
                    PointMark(x: .value("Day", day.dayKey), y: .value("Usage", 0))
                        .symbol(.circle).symbolSize(UtilityStyle.History.symbolSize)
                        .foregroundStyle(UtilityStyle.History.uploadColor)
                        .accessibilityLabel("\(day.dayKey), No Data")
                }
            }
            if let day = inspectedDay {
                RuleMark(x: .value("Selected Day", day.dayKey))
                    .foregroundStyle(UtilityStyle.Chart.selectionColor)
                    .annotation(position: .top, alignment: .center, spacing: UtilityStyle.contentSpacing,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(for: day)
                    }
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: days.map(\.dayKey))
        .chartYScale(domain: 0...max(1, Double(maximumBytes) / scale))
        .chartForegroundStyleScale(["Downloaded": UtilityStyle.History.downloadColor,
                                    "Uploaded": UtilityStyle.History.uploadColor])
        .chartLegend(.hidden)
        .chartYAxisLabel(scaleLabel)
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel().font(UtilityStyle.metadataFont)
            }
        }
        .chartXAxis {
            AxisMarks(values: axisKeys) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let day = days.first(where: { $0.dayKey == key }) {
                        Text(day.date, format: .dateTime.month(.abbreviated).day())
                            .font(UtilityStyle.metadataFont)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hoveredKey = dayKey(at: location, proxy: proxy, geometry: geometry)
                        case .ended: hoveredKey = nil
                        }
                    }
                    .onTapGesture { location in
                        if let key = dayKey(at: location, proxy: proxy, geometry: geometry) { selectedKey = key }
                        hoveredKey = nil
                    }
            }
        }
        .frame(height: UtilityStyle.History.chartHeight)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            if direction == .left { moveSelection(-1) }
            if direction == .right { moveSelection(1) }
        }
        .onExitCommand { hoveredKey = nil; selectedKey = nil }
        .accessibilityLabel("Daily Download And Upload Usage")
    }

    private var axisKeys: [String] {
        let stride = max(1, Int(ceil(Double(days.count) / Double(UtilityStyle.History.axisTickCount))))
        return days.enumerated().compactMap { index, day in index % stride == 0 ? day.dayKey : nil }
    }

    private var zeroUsageLabel: String {
        if showDownloads && showUploads { return "recorded zero usage" }
        return showDownloads ? "recorded zero downloaded usage" : "recorded zero uploaded usage"
    }

    private var legend: some View {
        HStack(spacing: UtilityStyle.contentSpacing) {
            legendItem("Downloaded", color: UtilityStyle.History.downloadColor, isVisible: $showDownloads)
            legendItem("Uploaded", color: UtilityStyle.History.uploadColor, isVisible: $showUploads)
        }.font(UtilityStyle.metadataFont)
    }

    private func legendItem(_ title: String, color: Color, isVisible: Binding<Bool>) -> some View {
        UtilityChartLegendButton(title: title, isVisible: isVisible) {
            HStack(spacing: UtilityStyle.History.metricSpacing) {
                Rectangle().fill(color).frame(width: UtilityStyle.Chart.legendSize, height: UtilityStyle.Chart.legendSize)
                    .accessibilityHidden(true)
                Text(title)
            }
        }
    }

    private var clearConfirmation: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            Text("Clear Usage History?").font(UtilityStyle.headingFont)
            Text("This removes saved daily history. Today's counters will stay the same.")
            HStack(spacing: UtilityStyle.contentSpacing) {
                Spacer()
                Button("Cancel", role: .cancel) { confirmClear = false }
                    .keyboardShortcut(.defaultAction)
                Button("Clear History", role: .destructive) {
                    monitor.clearHistory()
                    selectedKey = nil
                    hoveredKey = nil
                    confirmClear = false
                }.disabled(!monitor.historyWritable)
            }.buttonStyle(.bordered).handPointer()
        }
        .font(UtilityStyle.bodyFont)
        .padding(UtilityStyle.pagePadding)
        .frame(width: UtilityStyle.confirmationWidth)
        .onExitCommand { confirmClear = false }
    }

    private func moveSelection(_ offset: Int) {
        guard !days.isEmpty else { return }
        let index = days.firstIndex(where: { $0.dayKey == inspectedDay?.dayKey }) ?? (offset > 0 ? -1 : days.count)
        selectedKey = days[min(max(0, index + offset), days.count - 1)].dayKey
        hoveredKey = nil
    }

    private func resetSelectionIfNeeded() {
        hoveredKey = nil
        selectedKey = nil
    }

    private func dayKey(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        guard frame.contains(location) else { return nil }
        return proxy.value(atX: location.x - frame.minX, as: String.self)
    }

    private func dateLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: monitor.historyCalendar, timeZone: monitor.historyCalendar.timeZone))
    }

    private func formatted(_ bytes: UInt64) -> String { UsageFormatting.data(bytes, unit: monitor.dataUnit) }
}
