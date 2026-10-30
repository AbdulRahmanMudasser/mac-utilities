import Charts
import SwiftUI

struct UsageHistoryView: View {
    @EnvironmentObject private var utilityWindow: UtilityWindowCoordinator
    @EnvironmentObject private var monitor: UsageMonitor
    @State private var range: UsageHistoryRange = .thisMonth
    @State private var selectedKey: String?
    @State private var hoveredKey: String?
    @State private var confirmClear = false
    @State private var showDownloads = true
    @State private var showUploads = true
    @State private var selectedYear: Int?
    @State private var comparing = false
    @State private var selectedMonths: [UsageMonthID] = []

    private var currentYear: Int { monitor.historyCalendar.component(.year, from: monitor.historyDate) }
    private var historyYears: [Int] { UsageHistory.years(records: monitor.historyRecords, currentYear: currentYear) }
    private var activeYear: Int { selectedYear ?? currentYear }

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

    private var capabilityMessage: UtilityCapabilityMessage? {
        monitor.historyCapabilityMessage ?? monitor.counterCapabilityMessage
    }

    var body: some View {
        UtilityScrollContent {
            if let capabilityMessage {
                UtilityCapabilityCard(message: capabilityMessage, isActive: false)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Usage Status")
                    .accessibilityValue(capabilityMessage.combinedText)
            }

            UtilityPanel("Usage Summary", subtitle: summaryRange, action: AnyView(rangePicker), wrapsContent: false) {
                if days.contains(where: { $0.record != nil }) {
                    summaryMetrics
                } else {
                    Text("No Data In This Range").foregroundStyle(.secondary)
                }
            }
            UtilityPanel("Daily Usage", action: AnyView(
                Button("Clear History", role: .destructive) { confirmClear = true }
                    .buttonStyle(.bordered).handPointer()
                    .disabled(!monitor.historyWritable || monitor.historyRecords.isEmpty)
            )) {
                legend
                if showDownloads || showUploads {
                    chart
                } else {
                    UtilityChartEmptyState(height: UtilityStyle.History.chartHeight)
                }
            }
            monthlyHistory
        }
        .font(UtilityStyle.bodyFont)
        .controlSize(UtilityStyle.controlSize)
        .environment(\.calendar, monitor.historyCalendar)
        .environment(\.timeZone, monitor.historyCalendar.timeZone)
        .onChange(of: range) { _, _ in resetSelectionIfNeeded() }
        .onChange(of: days.map(\.dayKey)) { _, _ in resetSelectionIfNeeded() }
        .onChange(of: showDownloads) { _, _ in resetSelectionIfNeeded() }
        .onChange(of: showUploads) { _, _ in resetSelectionIfNeeded() }
        .onChange(of: historyYears) { _, years in
            if let selectedYear, !years.contains(selectedYear) { self.selectedYear = nil }
        }
        .onChange(of: monitor.historyRecords) { _, records in
            let monthsByYear = Dictionary(uniqueKeysWithValues: Set(selectedMonths.map(\.year)).map { year in
                (year, Set(UsageHistory.monthly(records: records, year: year).map(\.month)))
            })
            selectedMonths.removeAll { id in
                !(monthsByYear[id.year]?.contains(id.month) ?? false)
            }
        }
        .onChange(of: monitor.historyWritable) { _, writable in
            if !writable { selectedMonths.removeAll() }
        }
        .onAppear { applyUsageRequest() }
        .onChange(of: utilityWindow.usageRequest) { _, _ in applyUsageRequest() }
        .sheet(isPresented: $confirmClear) { clearConfirmation }
    }

    private var monthlyHistory: some View {
        let months = UsageHistory.monthly(records: monitor.historyRecords, year: activeYear)
        return UtilityPanel("History", action: AnyView(HStack {
            Picker("Year", selection: Binding(get: { activeYear }, set: { selectedYear = $0 })) {
                ForEach(historyYears, id: \.self) { year in Text(String(year)).tag(year) }
            }
            .pickerStyle(.menu).labelsHidden().accessibilityLabel("History Year").handPointer()
            Button {
                comparing.toggle()
                selectedMonths.removeAll()
            } label: {
                Image(systemName: comparing ? "checkmark" : "rectangle.2.swap")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(comparing ? "Done" : "Compare")
            .help(comparing ? "Done" : "Compare")
            .handPointer().disabled(!monitor.historyWritable)
        })) {
            if !monitor.historyWritable {
                historyPlaceholder("Saved Usage Unavailable", symbol: "exclamationmark.triangle")
            } else if comparing {
                comparisonContent(months: months)
            } else if months.isEmpty {
                historyPlaceholder("No Data For This Year", symbol: "chart.bar.xaxis")
            } else {
                VStack(spacing: UtilityStyle.contentSpacing) {
                    historyTableHeader
                    ForEach(months) { month in
                        HStack(spacing: UtilityStyle.contentSpacing) {
                            Text(monthName(month.month)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(formatted(month.downloaded)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel("\(monthName(month.month)), Downloaded, \(formatted(month.downloaded))")
                            Text(formatted(month.uploaded)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel("\(monthName(month.month)), Uploaded, \(formatted(month.uploaded))")
                            Text(formatted(month.combined)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel("\(monthName(month.month)), Combined, \(formatted(month.combined))")
                        }
                    }
                }
            }
        }
    }

    private var comparisonRows: [(id: UsageMonthID, usage: MonthlyUsage)] {
        let monthsByYear = Dictionary(uniqueKeysWithValues: Set(selectedMonths.map(\.year)).map { year in
            (year, UsageHistory.monthly(records: monitor.historyRecords, year: year))
        })
        return selectedMonths.compactMap { id in
            (monthsByYear[id.year] ?? [])
                .first(where: { $0.month == id.month }).map { (id, $0) }
        }
    }

    private func comparisonContent(months: [MonthlyUsage]) -> some View {
        let rows = comparisonRows
        let showYears = rows.contains { $0.id.year != activeYear }
        return VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            if months.isEmpty {
                historyPlaceholder("No Data For This Year", symbol: "chart.bar.xaxis")
            } else {
                Text(rows.count < 2 ? "Select At Least Two Months" : "Select Months To Compare")
                    .font(UtilityStyle.metadataFont).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: UtilityStyle.History.comparisonMonthWidth), alignment: .leading)],
                          alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                    ForEach(months) { month in
                        let id = UsageMonthID(year: activeYear, month: month.month)
                        Toggle(isOn: Binding(
                            get: { selectedMonths.contains(id) },
                            set: { selected in
                                if selected && !selectedMonths.contains(id) { selectedMonths.append(id) }
                                if !selected { selectedMonths.removeAll { $0 == id } }
                            })) {
                                monthDisplay(id, showYear: false)
                            }
                            .toggleStyle(.checkbox).handPointer()
                    }
                }
            }
            if rows.count >= 2 {
                historyTableHeader.padding(.top, UtilityStyle.contentSpacing)
                ForEach(rows, id: \.id) { row in
                    HStack(alignment: .top, spacing: UtilityStyle.contentSpacing) {
                        monthDisplay(row.id, showYear: showYears)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(formatted(row.usage.downloaded)).frame(maxWidth: .infinity, alignment: .trailing)
                        Text(formatted(row.usage.uploaded)).frame(maxWidth: .infinity, alignment: .trailing)
                        Text(formatted(row.usage.combined)).frame(maxWidth: .infinity, alignment: .trailing)
                    }.monospacedDigit()
                }
                if rows.count == 2 {
                    let difference = UsageHistory.difference(from: rows[0].usage.combined, to: rows[1].usage.combined)
                    HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.contentSpacing) {
                        Image(systemName: difference.comparison == .orderedSame ? "equal.circle" :
                              difference.comparison == .orderedAscending ? "arrow.down.right" : "arrow.up.right")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        (difference.comparison == .orderedSame
                         ? Text("\(monthLabel(rows[1].id, showYear: showYears)) and \(monthLabel(rows[0].id, showYear: showYears)) recorded the same usage.")
                         : Text("\(monthLabel(rows[1].id, showYear: showYears)) recorded ") +
                           Text(formatted(difference.magnitude)).bold() +
                           Text(" \(difference.comparison == .orderedAscending ? "less" : "more") than \(monthLabel(rows[0].id, showYear: showYears))."))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, UtilityStyle.contentSpacing)
                }
            }
        }
    }

    private func monthLabel(_ id: UsageMonthID, showYear: Bool) -> String {
        let year = showYear ? " \(id.year)" : ""
        return "\(monthName(id.month))\(year)"
    }

    private func monthDisplay(_ id: UsageMonthID, showYear: Bool) -> some View {
        let isCurrent = id.year == currentYear && id.month == monitor.historyCalendar.component(.month, from: monitor.historyDate)
        return Text(monthLabel(id, showYear: showYear))
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .help(isCurrent ? "Current Month" : "")
            .accessibilityLabel(isCurrent ? "\(monthLabel(id, showYear: showYear)), Current Month" : monthLabel(id, showYear: showYear))
    }

    private func historyPlaceholder(_ message: String, symbol: String) -> some View {
        VStack(spacing: UtilityStyle.contentSpacing) {
            Image(systemName: symbol)
                .font(.title2)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: UtilityStyle.History.placeholderHeight)
        .padding(.vertical, UtilityStyle.cardPadding)
    }

    private var historyTableHeader: some View {
        HStack(spacing: UtilityStyle.contentSpacing) {
            Text("Month").frame(maxWidth: .infinity, alignment: .leading)
            Text("Downloaded").frame(maxWidth: .infinity, alignment: .trailing)
            Text("Uploaded").frame(maxWidth: .infinity, alignment: .trailing)
            Text("Combined").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(UtilityStyle.metadataFont).foregroundStyle(.secondary)
    }

    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = monitor.historyCalendar
        return formatter.monthSymbols[month - 1]
    }

    private func applyUsageRequest() {
        guard let request = utilityWindow.usageRequest else { return }
        range = request.range
        selectedKey = nil
        hoveredKey = nil
        utilityWindow.consumeUsageRequest(request.generation)
    }

    private var summaryRange: String? {
        guard let first = days.first, let last = days.last else { return nil }
        let format = Date.FormatStyle(calendar: monitor.historyCalendar, timeZone: monitor.historyCalendar.timeZone)
            .month(.abbreviated).day().year(.twoDigits)
        return "(\(first.date.formatted(format)) – \(last.date.formatted(format)))"
    }

    private var summaryMetrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UtilityStyle.contentSpacing) {
                summaryTiles
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      spacing: UtilityStyle.contentSpacing) {
                summaryTiles
            }
        }
    }

    @ViewBuilder private var summaryTiles: some View {
        summaryMetric("Downloaded", value: formatted(totals.downloaded), symbol: "arrow.down")
        summaryMetric("Uploaded", value: formatted(totals.uploaded), symbol: "arrow.up")
        summaryMetric("Combined", value: formatted(UsageHistory.add(totals.downloaded, totals.uploaded)),
                      symbol: "arrow.up.arrow.down", emphasized: true)
        summaryMetric(range.averageTitle, value: formatted(UsageHistory.average(days) ?? 0),
                      symbol: "chart.bar.xaxis")
    }

    private func summaryMetric(_ title: String, value: String, symbol: String,
                               emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            HStack(spacing: UtilityStyle.History.metricSpacing) {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
                Text(title)
            }
            .font(UtilityStyle.metadataFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(UtilityStyle.History.summaryValueFont)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UtilityStyle.cardPadding)
        .background(emphasized ? UtilityStyle.History.summaryEmphasis : Color.clear,
                    in: RoundedRectangle(cornerRadius: UtilityStyle.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: UtilityStyle.cornerRadius)
                .strokeBorder(UtilityStyle.History.summaryBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
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
        .accessibilityValue(selectionAccessibilityValue)
        .accessibilityHint("Use the left and right arrow keys, or Previous Day and Next Day actions, to inspect daily usage.")
        .accessibilityAction(named: Text("Previous Day")) { moveSelection(-1) }
        .accessibilityAction(named: Text("Next Day")) { moveSelection(1) }
    }

    private var selectionAccessibilityValue: String {
        guard let day = inspectedDay else { return "No day selected" }
        guard let record = day.record else { return "\(dateLabel(day.date)), No Data" }
        var values = [dateLabel(day.date)]
        if showDownloads { values.append("Downloaded \(formatted(record.downloaded))") }
        if showUploads { values.append("Uploaded \(formatted(record.uploaded))") }
        if showDownloads && showUploads {
            values.append("Combined \(formatted(visibleBytes(record)))")
        }
        return values.joined(separator: ", ")
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
