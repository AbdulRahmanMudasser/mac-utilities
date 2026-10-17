import SwiftUI

enum UtilityStyle {
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let contentSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let cornerRadius: CGFloat = 10
    static let headerHeight: CGFloat = 28
    static let helpWidth: CGFloat = 440
    static let sidebarSpacing: CGFloat = 6
    static let sidebarWidth: CGFloat = 180
    static let sidebarVerticalPadding: CGFloat = 10
    static let headingFont: Font = .headline
    static let bodyFont: Font = .body
    static let helpFont: Font = .callout
    static let metadataFont: Font = .caption
    static let emphasizedBodyFont: Font = bodyFont.weight(.semibold)
    static let menuBarFont: Font = .system(size: 11, weight: .medium)
    static let controlSize: ControlSize = .regular
    static let progressControlSize: ControlSize = .small
    static let sidebarProgressControlSize: ControlSize = .mini
    static let successColor: Color = .green
    static let warningColor: Color = .orange
    static let cardBackgroundOpacity: Double = 0.45
    static let sidebarSelectedBackground = Color.primary.opacity(0.08)
    static let sidebarBackground = Color(nsColor: .controlBackgroundColor)
    static let aboutIconSize: CGFloat = 32
    static let aboutVerticalPadding: CGFloat = 4
    static let confirmationWidth: CGFloat = 420

    enum Tooltip {
        static let spacing: CGFloat = 4
        static let padding: CGFloat = 8
        static let background = Color(nsColor: .windowBackgroundColor)
        static let border = Color.primary.opacity(0.12)
        static let borderWidth: CGFloat = 1
        static let shadow = Color.black.opacity(0.12)
        static let shadowRadius: CGFloat = 6
        static let infoWidth: CGFloat = 280
    }

    enum Chart {
        static let summaryColumnWidth: CGFloat = 400
        static let selectionColor = Color.secondary.opacity(0.55)
        static let legendSize: CGFloat = 8
        static let hiddenLegendOpacity: Double = 0.4
    }

    enum History {
        static let metricSpacing: CGFloat = 4
        static let chartHeight: CGFloat = 200
        static let downloadColor = UsageChartPresentation.downloadColor
        static let uploadColor = UsageChartPresentation.uploadColor
        static let symbolSize: CGFloat = 18
        static let axisTickCount = 5
    }

    enum Stability {
        static let tooltipWidth: CGFloat = 180
        static let chartHeight: CGFloat = 220
        static let lineWidth: CGFloat = 2
        static let pointSize: CGFloat = 18
        static let missPointSize: CGFloat = 24
        static let laneFraction: Double = 0.14
        static let missLaneOffsets: [Double] = [0.65, 1.35]
        static let missLaneLowerBound: Double = 1.7
        static let axisTickCount = 4
        static let legendMarkWidth: CGFloat = 24
        static let gapColor = Color.secondary.opacity(0.12)
        static let laneColor = Color.secondary.opacity(0.5)
        static let transitionColor = Color.primary.opacity(0.42)
        static let firstSeriesColor = Color.primary.opacity(0.88)
        static let secondSeriesColor = Color.secondary.opacity(0.72)
        static let firstSeriesDash: [CGFloat] = []
        static let secondSeriesDash: [CGFloat] = [5, 3]
    }

    enum Window {
        static let defaultSize = NSSize(width: 860, height: 660)
        static let minimumSize = NSSize(width: 620, height: 420)
    }

    enum Toggle {
        static let width: CGFloat = 36
        static let height: CGFloat = 22
        static let thumbSize: CGFloat = 18
        static let thumbInset: CGFloat = 2
        static let offColor = Color.secondary.opacity(0.3)
        static let onThumbColor = Color(nsColor: .windowBackgroundColor)
        static let offThumbColor = Color.white
    }

    enum Picker {
        static let indicatorFont: Font = .caption2
        static let optionSpacing: CGFloat = 4
        static let optionPadding: CGFloat = 8
        static let padding: CGFloat = 6
        static let width: CGFloat = 150
    }

    static func sidebarFont(selected: Bool) -> Font {
        selected ? emphasizedBodyFont : bodyFont
    }

    enum Popover {
        static let controlSize: ControlSize = .small
        static let width: CGFloat = 390
        static let confirmationWidth: CGFloat = 340
        static let pagePadding: CGFloat = 16
        static let sectionSpacing: CGFloat = 16
        static let sectionContentSpacing: CGFloat = 9
        static let cardPadding: CGFloat = 12
        static let rowSpacing: CGFloat = 6
        static let valueSpacing: CGFloat = 4
        static let columnSpacing: CGFloat = 8
        static let dividerWidth: CGFloat = 1
        static let dividerHeight: CGFloat = 16
        static let valueFont: Font = UtilityStyle.emphasizedBodyFont.monospacedDigit()
        static let labelFont: Font = UtilityStyle.helpFont
    }
}

extension View {
    func utilityCardBackground() -> some View {
        background(.quaternary.opacity(UtilityStyle.cardBackgroundOpacity), in: RoundedRectangle(cornerRadius: UtilityStyle.cornerRadius))
    }
}

struct UtilityScrollContent<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UtilityStyle.sectionSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(UtilityStyle.pagePadding)
        }
        .overlayPreferenceValue(UtilityInfoTooltipPreference.self) { tooltips in
            GeometryReader { geometry in
                if let tooltip = tooltips.last {
                    UtilityInfoTooltipOverlay(message: tooltip.message, anchor: geometry[tooltip.anchor],
                                              viewport: geometry.size)
                        .id(tooltip.id)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct UtilityPanel<Content: View>: View {
    let title: String
    let action: AnyView?
    let info: String?
    let showsContent: Bool
    let wrapsContent: Bool
    let content: Content

    init(_ title: String, action: AnyView? = nil, info: String? = nil, showsContent: Bool = true,
         wrapsContent: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.info = info
        self.showsContent = showsContent
        self.wrapsContent = wrapsContent
        self.content = content()
    }

    private var panelHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.Tooltip.spacing) {
            Text(title).font(UtilityStyle.headingFont).accessibilityAddTraits(.isHeader)
            if let info {
                UtilityInfoTooltip(message: info)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: UtilityStyle.contentSpacing) {
                    panelHeading.fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    if let action { action.fixedSize() }
                }
                VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                    panelHeading
                    if let action {
                        HStack { Spacer(); action }
                    }
                }
            }
            .frame(minHeight: UtilityStyle.headerHeight)
            if showsContent {
                if wrapsContent {
                    panelContent
                        .padding(UtilityStyle.cardPadding)
                        .utilityCardBackground()
                } else {
                    panelContent
                }
            }
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) { content }
            .font(UtilityStyle.bodyFont)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UtilityChartEmptyState: View {
    let height: CGFloat

    var body: some View {
        Text("Choose A Series To Show")
            .font(UtilityStyle.metadataFont)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

struct UtilityChartLegendButton<Content: View>: View {
    let title: String
    @Binding var isVisible: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button { isVisible.toggle() } label: {
            content()
                .contentShape(Rectangle())
                .opacity(isVisible ? 1 : UtilityStyle.Chart.hiddenLegendOpacity)
        }
        .buttonStyle(.plain)
        .handPointer()
        .accessibilityLabel(title)
        .accessibilityValue(isVisible ? "Shown" : "Hidden")
        .accessibilityHint(isVisible ? "Hide from chart" : "Show in chart")
    }
}

struct UtilityTooltip<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(UtilityStyle.Tooltip.padding)
            .background(UtilityStyle.Tooltip.background,
                        in: RoundedRectangle(cornerRadius: UtilityStyle.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: UtilityStyle.cornerRadius)
                    .strokeBorder(UtilityStyle.Tooltip.border, lineWidth: UtilityStyle.Tooltip.borderWidth)
            }
            .shadow(color: UtilityStyle.Tooltip.shadow, radius: UtilityStyle.Tooltip.shadowRadius)
    }
}

struct UtilityInfoTooltip: View {
    let message: String
    @State private var id = UUID()
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(UtilityStyle.metadataFont)
            .foregroundStyle(.secondary)
            .anchorPreference(key: UtilityInfoTooltipPreference.self, value: .bounds) { anchor in
                isHovered ? [UtilityInfoTooltipAnchor(id: id, message: message, anchor: anchor)] : []
            }
            .onHover { isHovered = $0 }
            .accessibilityLabel("More information")
            .accessibilityHint(message)
    }
}

private struct UtilityInfoTooltipAnchor {
    let id: UUID
    let message: String
    let anchor: Anchor<CGRect>
}

private struct UtilityInfoTooltipPreference: PreferenceKey {
    static var defaultValue: [UtilityInfoTooltipAnchor] { [] }

    static func reduce(value: inout [UtilityInfoTooltipAnchor], nextValue: () -> [UtilityInfoTooltipAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

private struct UtilityInfoTooltipOverlay: View {
    let message: String
    let anchor: CGRect
    let viewport: CGSize
    @State private var size: CGSize = .zero

    private var margin: CGFloat { UtilityStyle.Tooltip.padding }

    private var center: CGPoint {
        let x = min(max(anchor.midX, margin + size.width / 2), viewport.width - margin - size.width / 2)
        let above = anchor.minY - UtilityStyle.Tooltip.spacing - size.height / 2
        let below = anchor.maxY + UtilityStyle.Tooltip.spacing + size.height / 2
        let preferred = above - size.height / 2 >= margin ? above : below
        let y = min(max(preferred, margin + size.height / 2), viewport.height - margin - size.height / 2)
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        if anchor.intersects(CGRect(origin: .zero, size: viewport)) {
            UtilityTooltip {
                Text(message)
                    .font(UtilityStyle.metadataFont)
                    .foregroundStyle(.primary)
                    .frame(width: max(0, min(UtilityStyle.Tooltip.infoWidth,
                        viewport.width - 2 * margin - 2 * UtilityStyle.Tooltip.padding)), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .position(center)
            .opacity(size == .zero ? 0 : 1)
        }
    }
}

struct UtilityMetricRow: View {
    let title: String
    let value: String
    var detail: String? = nil
    var explanation: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.contentSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.Tooltip.spacing) {
                Text(title).foregroundStyle(.secondary)
                if let explanation {
                    UtilityInfoTooltip(message: explanation)
                }
            }
            Spacer(minLength: UtilityStyle.contentSpacing)
            HStack(alignment: .firstTextBaseline, spacing: UtilityStyle.contentSpacing) {
                Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
                if let detail {
                    Text("· \(detail)").font(UtilityStyle.metadataFont).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(UtilityStyle.bodyFont)
        .accessibilityElement(children: .combine)
    }
}

struct UtilityValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: UtilityStyle.contentSpacing) {
            Text(title)
            Spacer(minLength: UtilityStyle.contentSpacing)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(UtilityStyle.bodyFont)
        .accessibilityElement(children: .combine)
    }
}

struct UtilityTotalValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.Popover.valueSpacing) {
            Text(value)
                .font(UtilityStyle.Popover.valueFont)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(title)
                .font(UtilityStyle.Popover.labelFont)
                .foregroundStyle(.secondary)
        }
    }
}
