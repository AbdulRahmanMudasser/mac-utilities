import Charts
import SwiftUI

struct StabilityCheckView: View {
    @EnvironmentObject private var diagnostics: ConnectionDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.sectionSpacing) {
            UtilityPanel("5-Minute Connection Check", action: AnyView(
                Button("Start Check") { diagnostics.startStability() }
                    .buttonStyle(.bordered).disabled(diagnostics.isRunning).handPointer()
            ), info: "Checks two servers every five seconds for five minutes. It shows reply times and missed replies. Short problems may happen between checks. Closing this window stops the check.",
               showsContent: diagnostics.stabilitySnapshot != nil, wrapsContent: false) {
                if let snapshot = diagnostics.stabilitySnapshot {
                    results(for: snapshot)
                }
            }
            if let snapshot = diagnostics.stabilitySnapshot, snapshot.hasCompletedChecks {
                UtilityPanel("Reply Times", info: "Lines show reply times for each server. Marks along the bottom show missed replies. Shaded areas show when checks could not run.") {
                    StabilityTimelineChart(snapshot: snapshot)
                }
            }
        }
    }

    private func results(for snapshot: StabilitySnapshot) -> some View {
        let summaries = ProbeTarget.defaults.map { snapshot.summary(for: $0.id) }
        return VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            ConnectionServerCards { target in
                targetSummary(target, snapshot: snapshot,
                    showsNoResult: summaries.contains { $0.unobserved > 0 },
                    showsStopped: summaries.contains { $0.interrupted > 0 })
            }
            if snapshot.detailsLimited {
                Text("Some details are hidden. The totals still include all checks.")
                    .font(UtilityStyle.helpFont).foregroundStyle(.secondary)
                    .frame(maxWidth: UtilityStyle.helpWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ConnectionCheckTimestamp(date: snapshot.finishedAt ?? snapshot.startedAt,
                title: snapshot.status == .completed ? "Last Checked" : snapshot.status.rawValue,
                symbol: snapshot.status == .completed && !snapshot.hasCompletedChecks
                    ? "exclamationmark.circle.fill" : statusSymbol(for: snapshot.status),
                color: snapshot.status == .completed
                    ? (snapshot.hasCompletedChecks ? UtilityStyle.successColor : UtilityStyle.warningColor) : .secondary)
        }
    }

    private func targetSummary(_ target: ProbeTarget, snapshot: StabilitySnapshot,
                               showsNoResult: Bool, showsStopped: Bool) -> some View {
        let summary = snapshot.summary(for: target.id)
        let reasons = snapshot.reasons(for: target.id)
        let startupDetail = reasons.contains(StabilityGapReason.pendingPath.rawValue)
            ? " Includes checks skipped while the app was checking the network at the start." : ""
        let waiting = summary.completed == 0 && snapshot.status == .running
        let reasonDetail = reasons.filter { $0 != StabilityGapReason.pendingPath.rawValue }.joined(separator: "; ")
        let noResultExplanation = "These checks could not run or return a result. They do not count as missed replies."
            + startupDetail + (reasonDetail.isEmpty ? "" : " Details: " + reasonDetail)
        return VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            ConnectionReplyMetrics(received: summary.received, completed: summary.completed,
                missed: summary.missed, missedPercent: summary.missedPercent,
                median: summary.median, minimum: summary.minimum, maximum: summary.maximum,
                changes: summary.replyTimeChanges, isWaiting: waiting,
                changesExplanation: "Shows how much reply times speed up or slow down between checks. A missed or skipped check starts a new line.")
            if showsNoResult {
                UtilityMetricRow(title: "Checks With No Result", value: "\(summary.unobserved)",
                    explanation: noResultExplanation)
            }
            if showsStopped {
                UtilityMetricRow(title: "Stopped Checks", value: "\(summary.interrupted)",
                    explanation: "These checks stopped before they finished. They do not count as missed replies."
                        + (!showsNoResult && !reasonDetail.isEmpty ? " Details: " + reasonDetail : ""))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func statusSymbol(for status: StabilitySnapshot.Status) -> String {
        switch status {
        case .running: "waveform.path"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }


}

private struct StabilityTimelineChart: View {
    let snapshot: StabilitySnapshot
    @State private var hoveredObservationID: String?
    @State private var hoveredGapID: String?
    @State private var selectedObservationID: String?
    @State private var selectedGapID: String?
    @State private var tooltipSize: CGSize = .zero
    @State private var hiddenTargetIDs: Set<String> = []
    @State private var showGaps = true
    @State private var showTransitions = true

    private var observations: [StabilityObservation] {
        snapshot.observations.filter { !hiddenTargetIDs.contains($0.targetID) }.sorted {
            if $0.slot != $1.slot { return $0.slot < $1.slot }
            return $0.targetID < $1.targetID
        }
    }

    private var replies: [StabilityObservation] {
        observations.filter { $0.outcome.milliseconds != nil }
    }

    private var plottedObservations: [StabilityObservation] {
        observations.filter { $0.outcome.milliseconds != nil || $0.outcome == .noReply }
    }

    private var lineSegments: [LineSegment] {
        var result: [LineSegment] = []
        for (targetIndex, target) in ProbeTarget.defaults.enumerated() {
            var segment: [StabilityObservation] = []
            var previous: StabilityObservation?

            func appendSegment() {
                guard !segment.isEmpty else { return }
                let first = segment[0]
                result.append(LineSegment(id: "\(target.id)-\(first.slot)-\(first.epoch)",
                                          targetIndex: targetIndex, observations: segment))
                segment.removeAll(keepingCapacity: true)
            }

            for observation in replies where observation.targetID == target.id {
                if let previous,
                   (observation.slot != previous.slot + 1 || observation.epoch != previous.epoch) {
                    appendSegment()
                }
                segment.append(observation)
                previous = observation
            }
            appendSegment()
        }
        return result
    }

    private var maximumReplyTime: Double {
        replies.compactMap(\.outcome.milliseconds).max() ?? 0
    }

    private var hasReplySamples: Bool {
        !replies.isEmpty
    }

    private var missLane: Double {
        -max(0.5, maximumReplyTime * UtilityStyle.Stability.laneFraction)
    }

    private var yDomain: ClosedRange<Double> {
        (missLane * UtilityStyle.Stability.missLaneLowerBound)...(hasReplySamples ? max(maximumReplyTime * 1.16, 1) : 0)
    }

    private func missedReplyPosition(for targetIndex: Int) -> Double {
        missLane * UtilityStyle.Stability.missLaneOffsets[targetIndex]
    }

    private var yAxisValues: [Double] {
        hasReplySamples ? [missLane, 0, yDomain.upperBound] : [missLane]
    }

    private var xDomainMaximum: Double {
        max(0.5, snapshot.elapsed / 60)
    }

    private var visibleGaps: [StabilityGap] { showGaps ? snapshot.gaps : [] }

    private var inspectedObservation: StabilityObservation? {
        if let hoveredGapID, visibleGaps.contains(where: { $0.id == hoveredGapID }) { return nil }
        if let hoveredObservationID,
           let observation = observations.first(where: { $0.id == hoveredObservationID }) { return observation }
        if let selectedGapID, visibleGaps.contains(where: { $0.id == selectedGapID }) { return nil }
        return observations.first(where: { $0.id == selectedObservationID })
    }

    private var inspectedGap: StabilityGap? {
        guard hoveredObservationID == nil, let gapID = hoveredGapID ?? selectedGapID else { return nil }
        return visibleGaps.first(where: { $0.id == gapID })
    }

    private var inspectedElapsedMinutes: Double? {
        if let observation = inspectedObservation { return observation.elapsed / 60 }
        if let gap = inspectedGap { return (gap.start + gap.end) / 120 }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            chartLegend

            if plottedObservations.isEmpty && visibleGaps.isEmpty && (!showTransitions || snapshot.transitions.isEmpty) {
                UtilityChartEmptyState(height: UtilityStyle.Stability.chartHeight)
            } else {
                Text("Reply Time (ms)")
                    .font(UtilityStyle.metadataFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Chart {
                    ForEach(visibleGaps) { gap in
                        RectangleMark(
                            xStart: .value("Gap Start", gap.start / 60),
                            xEnd: .value("Gap End", gap.end / 60),
                            yStart: .value("Missed Reply Lane", yDomain.lowerBound),
                            yEnd: .value("Reply Time Scale", yDomain.upperBound)
                        )
                        .foregroundStyle(UtilityStyle.Stability.gapColor)
                        .accessibilityLabel("Time Not Checked, \(gap.reason.rawValue)")
                        .accessibilityValue("\(intervalLabel(gap.start)) to \(intervalLabel(gap.end))")
                    }

                    ForEach(lineSegments) { segment in
                        ForEach(segment.observations) { observation in
                            if let milliseconds = observation.outcome.milliseconds {
                                LineMark(
                                    x: .value("Minutes", observation.elapsed / 60),
                                    y: .value("Reply Time", milliseconds),
                                    series: .value("Reply Segment", segment.id)
                                )
                                .foregroundStyle(seriesColor(segment.targetIndex))
                                .lineStyle(StrokeStyle(lineWidth: UtilityStyle.Stability.lineWidth,
                                                       dash: seriesDash(segment.targetIndex)))
                            }
                        }
                    }

                    ForEach(observations) { observation in
                        let targetIndex = seriesIndex(for: observation.targetID)
                        if let milliseconds = observation.outcome.milliseconds {
                            if targetIndex == 0 {
                                PointMark(x: .value("Minutes", observation.elapsed / 60),
                                          y: .value("Reply Time", milliseconds))
                                    .symbol(.circle)
                                    .symbolSize(UtilityStyle.Stability.pointSize)
                                    .foregroundStyle(seriesColor(targetIndex))
                                    .accessibilityLabel(sampleLabel(observation))
                                    .accessibilityValue(observation.outcome.description)
                            } else {
                                PointMark(x: .value("Minutes", observation.elapsed / 60),
                                          y: .value("Reply Time", milliseconds))
                                    .symbol(.diamond)
                                    .symbolSize(UtilityStyle.Stability.pointSize)
                                    .foregroundStyle(seriesColor(targetIndex))
                                    .accessibilityLabel(sampleLabel(observation))
                                    .accessibilityValue(observation.outcome.description)
                            }
                        } else if observation.outcome == .noReply {
                            if targetIndex == 0 {
                                PointMark(x: .value("Minutes", observation.elapsed / 60),
                                          y: .value("Missed Test Reply Lane", missedReplyPosition(for: targetIndex)))
                                    .symbol(.circle)
                                    .symbolSize(UtilityStyle.Stability.missPointSize)
                                    .foregroundStyle(seriesColor(targetIndex))
                                    .accessibilityLabel(sampleLabel(observation))
                                    .accessibilityValue("Missed Test Reply")
                            } else {
                                PointMark(x: .value("Minutes", observation.elapsed / 60),
                                          y: .value("Missed Test Reply Lane", missedReplyPosition(for: targetIndex)))
                                    .symbol(.diamond)
                                    .symbolSize(UtilityStyle.Stability.missPointSize)
                                    .foregroundStyle(seriesColor(targetIndex))
                                    .accessibilityLabel(sampleLabel(observation))
                                    .accessibilityValue("Missed Test Reply")
                            }
                        }
                    }

                    RuleMark(y: .value("Missed Test Replies", missLane))
                        .foregroundStyle(UtilityStyle.Stability.laneColor)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .accessibilityHidden(true)

                    ForEach(showTransitions ? snapshot.transitions : []) { transition in
                        RuleMark(x: .value("Network Changed", transition.elapsed / 60))
                            .foregroundStyle(UtilityStyle.Stability.transitionColor)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .accessibilityLabel("Network Changed")
                            .accessibilityValue(intervalLabel(transition.elapsed))
                    }

                    if let elapsedMinutes = inspectedElapsedMinutes {
                        RuleMark(x: .value("Selected Sample", elapsedMinutes))
                            .foregroundStyle(UtilityStyle.Chart.selectionColor)
                            .accessibilityHidden(true)
                    }
                }
                .chartXScale(domain: 0...xDomainMaximum)
                .chartYScale(domain: yDomain)
                .chartYAxis {
                    AxisMarks(values: yAxisValues) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                if abs(amount - missLane) < 0.001 {
                                    Text("Misses").font(UtilityStyle.metadataFont)
                                } else {
                                    Text(amount.formatted(.number.precision(.fractionLength(0))))
                                        .font(UtilityStyle.metadataFont)
                                }
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: UtilityStyle.Stability.axisTickCount)) { value in
                        AxisValueLabel {
                            if let minute = value.as(Double.self) {
                                Text(axisTimeLabel(minute))
                                    .font(UtilityStyle.metadataFont)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location): updateHover(at: location, proxy: proxy, geometry: geometry)
                                case .ended:
                                    hoveredObservationID = nil
                                    hoveredGapID = nil
                                }
                            }
                            .onTapGesture { location in
                                selectObservation(at: location, proxy: proxy, geometry: geometry)
                            }
                            .overlay(alignment: .topLeading) {
                                if let elapsed = inspectedElapsedMinutes,
                                   let plotFrame = proxy.plotFrame,
                                   let x = proxy.position(forX: elapsed) {
                                    let frame = geometry[plotFrame]
                                    let halfWidth = tooltipSize.width / 2
                                    let centerX = min(max(frame.minX + x, halfWidth),
                                                      max(halfWidth, geometry.size.width - halfWidth))
                                    inspectedTooltip
                                        .id(inspectedObservation?.id ?? inspectedGap?.id)
                                        .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
                                        .position(x: centerX, y: frame.minY + tooltipSize.height / 2)
                                        .allowsHitTesting(false)
                                }
                            }
                            .transaction { $0.animation = nil }
                    }
                }
                .frame(height: UtilityStyle.Stability.chartHeight)
                .focusable()
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    if direction == .left { moveSelection(by: -1) }
                    if direction == .right { moveSelection(by: 1) }
                }
                .onExitCommand {
                    hoveredObservationID = nil
                    hoveredGapID = nil
                    selectedObservationID = nil
                    selectedGapID = nil
                }
                .accessibilityLabel("Connection Reply Times")
                .accessibilityValue(accessibilitySelectionDescription)
                .accessibilityHint("Use the left and right arrow keys to check results.")
                .accessibilityAction(named: Text("Next Result")) { moveSelection(by: 1) }
                .accessibilityAction(named: Text("Previous Result")) { moveSelection(by: -1) }
            }

        }
        .onChange(of: showGaps) { _, _ in
            hoveredGapID = nil
            selectedGapID = nil
        }
    }

    private var chartLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.contentSpacing) { legendItems }.fixedSize()
            VStack(alignment: .leading, spacing: UtilityStyle.Tooltip.spacing) {
                HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.contentSpacing) {
                    legendItem(target: ProbeTarget.defaults[0], index: 0)
                    legendItem(target: ProbeTarget.defaults[1], index: 1)
                }
                HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.contentSpacing) { contextLegendItems }
            }
        }
        .font(UtilityStyle.metadataFont)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
    }

    private func axisTimeLabel(_ minutes: Double) -> String {
        let seconds = max(0, Int((minutes * 60).rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private var legendItems: some View {
        legendItem(target: ProbeTarget.defaults[0], index: 0)
        legendItem(target: ProbeTarget.defaults[1], index: 1)
        contextLegendItems
    }

    @ViewBuilder
    private var contextLegendItems: some View {
        if !snapshot.gaps.isEmpty {
            UtilityChartLegendButton(title: "Not Checked", isVisible: $showGaps) {
                HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.Tooltip.spacing) {
                    Rectangle().fill(UtilityStyle.Stability.gapColor)
                        .frame(width: UtilityStyle.Chart.legendSize, height: UtilityStyle.Chart.legendSize)
                    Text("Not Checked")
                }
            }
        }
        if !snapshot.transitions.isEmpty {
            UtilityChartLegendButton(title: "Network Changed", isVisible: $showTransitions) {
                HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.Tooltip.spacing) {
                    Rectangle().fill(UtilityStyle.Stability.transitionColor)
                        .frame(width: UtilityStyle.Stability.lineWidth, height: UtilityStyle.Chart.legendSize)
                        .accessibilityHidden(true)
                    Text("Network Changed")
                }
            }
        }
    }

    private func legendItem(target: ProbeTarget, index: Int) -> some View {
        UtilityChartLegendButton(title: target.name, isVisible: Binding(
            get: { !hiddenTargetIDs.contains(target.id) },
            set: { visible in
                if visible { hiddenTargetIDs.remove(target.id) } else { hiddenTargetIDs.insert(target.id) }
                hoveredObservationID = nil
                hoveredGapID = nil
                selectedObservationID = nil
                selectedGapID = nil
            }
        )) {
            HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.Tooltip.spacing) {
                Image(systemName: index == 0 ? "circle.fill" : "diamond.fill")
                    .foregroundStyle(seriesColor(index))
                    .accessibilityHidden(true)
                Rectangle()
                    .stroke(seriesColor(index), style: StrokeStyle(lineWidth: UtilityStyle.Stability.lineWidth,
                                                                   dash: seriesDash(index)))
                    .frame(width: UtilityStyle.Stability.legendMarkWidth, height: UtilityStyle.Stability.lineWidth)
                    .accessibilityHidden(true)
                Text(target.name)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(target.name), \(index == 0 ? "solid line with circle markers" : "dashed line with diamond markers")")
        }
    }

    @ViewBuilder
    private var inspectedTooltip: some View {
        if let observation = inspectedObservation {
            UtilityTooltip {
                VStack(alignment: .leading, spacing: UtilityStyle.Tooltip.spacing) {
                    Text(observation.timestamp.formatted(date: .omitted, time: .standard))
                        .font(UtilityStyle.helpFont.weight(.semibold))
                    Text(targetName(observation.targetID))
                        .foregroundStyle(.secondary)
                    Text(observation.outcome.description)
                        .monospacedDigit()
                }
                .frame(width: tooltipWidth(for: observation.outcome),
                       alignment: .leading)
            }
            .font(UtilityStyle.metadataFont)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
            .allowsHitTesting(false)
        } else if let gap = inspectedGap {
            UtilityTooltip {
                VStack(alignment: .leading, spacing: UtilityStyle.Tooltip.spacing) {
                    Text(gap.reason.rawValue)
                        .font(UtilityStyle.helpFont.weight(.semibold))
                    Text("\(intervalLabel(gap.start))–\(intervalLabel(gap.end)) not checked")
                        .monospacedDigit()
                }
                .frame(width: UtilityStyle.Stability.tooltipWidth,
                       alignment: .leading)
            }
            .font(UtilityStyle.metadataFont)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .allowsHitTesting(false)
        }
    }

    private func tooltipWidth(for outcome: StabilityOutcome) -> CGFloat? {
        switch outcome {
        case .reply, .noReply: nil
        case .unavailable, .interrupted: UtilityStyle.Stability.tooltipWidth
        }
    }

    private var accessibilitySelectionDescription: String {
        if let observation = inspectedObservation { return "\(sampleLabel(observation)), \(observation.outcome.description)" }
        if let gap = inspectedGap { return "Time not checked, \(gap.reason.rawValue), \(intervalLabel(gap.start)) to \(intervalLabel(gap.end))" }
        return "No result selected"
    }

    private func updateHover(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        guard frame.contains(location),
              let x = proxy.value(atX: location.x - frame.minX, as: Double.self),
              let y = proxy.value(atY: location.y - frame.minY, as: Double.self) else {
            hoveredObservationID = nil
            hoveredGapID = nil
            return
        }
        selectNearestEvent(at: x * 60, replyTime: y)
    }

    private func selectObservation(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        guard frame.contains(location),
              let x = proxy.value(atX: location.x - frame.minX, as: Double.self),
              let y = proxy.value(atY: location.y - frame.minY, as: Double.self) else { return }
        selectNearestEvent(at: x * 60, replyTime: y)
        selectedObservationID = hoveredObservationID
        selectedGapID = hoveredGapID
        hoveredObservationID = nil
        hoveredGapID = nil
    }

    private func selectNearestEvent(at elapsedSeconds: Double, replyTime: Double) {
        if let gap = visibleGaps.first(where: { elapsedSeconds >= $0.start && elapsedSeconds <= $0.end }) {
            hoveredGapID = gap.id
            hoveredObservationID = nil
            return
        }
        hoveredGapID = nil
        let nearestElapsed = plottedObservations.min {
            abs($0.elapsed - elapsedSeconds) < abs($1.elapsed - elapsedSeconds)
        }?.elapsed
        guard let nearestElapsed else {
            hoveredObservationID = nil
            return
        }
        let candidates = plottedObservations.filter { abs($0.elapsed - nearestElapsed) < 0.001 }
        hoveredObservationID = candidates.min { left, right in
            chartDistance(from: left, to: replyTime) < chartDistance(from: right, to: replyTime)
        }?.id
    }

    private func chartDistance(from observation: StabilityObservation, to replyTime: Double) -> Double {
        if let milliseconds = observation.outcome.milliseconds { return abs(milliseconds - replyTime) }
        if observation.outcome == .noReply {
            return abs(missedReplyPosition(for: seriesIndex(for: observation.targetID)) - replyTime)
        }
        return .infinity
    }

    private func moveSelection(by offset: Int) {
        guard !observations.isEmpty else { return }
        let currentID = selectedObservationID ?? inspectedObservation?.id
        let currentIndex = observations.firstIndex(where: { $0.id == currentID }) ?? (offset > 0 ? -1 : observations.count)
        selectedObservationID = observations[min(max(0, currentIndex + offset), observations.count - 1)].id
        selectedGapID = nil
        hoveredObservationID = nil
        hoveredGapID = nil
    }

    private func seriesIndex(for targetID: String) -> Int {
        ProbeTarget.defaults.firstIndex(where: { $0.id == targetID }) ?? 0
    }

    private func seriesColor(_ index: Int) -> Color {
        index == 0 ? UtilityStyle.Stability.firstSeriesColor : UtilityStyle.Stability.secondSeriesColor
    }

    private func seriesDash(_ index: Int) -> [CGFloat] {
        index == 0 ? UtilityStyle.Stability.firstSeriesDash : UtilityStyle.Stability.secondSeriesDash
    }

    private func targetName(_ targetID: String) -> String {
        ProbeTarget.defaults.first(where: { $0.id == targetID })?.name ?? targetID
    }

    private func sampleLabel(_ observation: StabilityObservation) -> String {
        "\(targetName(observation.targetID)), \(observation.timestamp.formatted(date: .abbreviated, time: .standard))"
    }

    private func intervalLabel(_ seconds: Double) -> String {
        let tenths = max(0, Int((seconds * 10).rounded(.down)))
        return String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

private struct LineSegment: Identifiable {
    let id: String
    let targetIndex: Int
    let observations: [StabilityObservation]
}
