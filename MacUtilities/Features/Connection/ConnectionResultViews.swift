import SwiftUI

struct ConnectionServerCards<Content: View>: View {
    @ViewBuilder let content: (ProbeTarget) -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: UtilityStyle.contentSpacing) {
                ForEach(ProbeTarget.defaults) { target in
                    card(for: target)
                        .frame(minWidth: UtilityStyle.Chart.summaryColumnWidth, maxWidth: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                ForEach(ProbeTarget.defaults) { target in card(for: target) }
            }
        }
    }

    private func card(for target: ProbeTarget) -> some View {
        VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            Text("\(target.name) · \(target.address)")
                .font(UtilityStyle.emphasizedBodyFont)
                .accessibilityAddTraits(.isHeader)
            content(target)
        }
        .font(UtilityStyle.bodyFont)
        .padding(UtilityStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .utilityCardBackground()
        .accessibilityElement(children: .contain)
    }
}

struct ConnectionReplyMetrics: View {
    let received: Int?
    let completed: Int?
    let missed: Int?
    let missedPercent: Double?
    let median: Double?
    let minimum: Double?
    let maximum: Double?
    let changes: Double?
    let isWaiting: Bool
    let changesExplanation: String

    var body: some View {
        UtilityMetricRow(title: "Replies", value: repliesLabel)
        UtilityMetricRow(title: "Typical Reply Time", value: milliseconds(median))
        UtilityMetricRow(title: "Fastest / Slowest", value: replyRange)
        UtilityMetricRow(title: "Reply Time Changes", value: milliseconds(changes), explanation: changesExplanation)
    }

    private var unavailable: String { isWaiting ? "Waiting…" : "Not Available" }

    private var repliesLabel: String {
        guard let received, let completed, completed > 0, let missed, let missedPercent else { return unavailable }
        return "\(received) of \(completed) received · \(missed) missed (\(missedPercent.formatted(.number.precision(.fractionLength(0))))%)"
    }

    private var replyRange: String {
        guard let minimum, let maximum else { return unavailable }
        return "\(minimum.formatted(.number.precision(.fractionLength(1)))) / \(milliseconds(maximum))"
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) ms" } ?? unavailable
    }
}
