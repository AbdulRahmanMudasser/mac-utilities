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
    }
}

struct UtilityPanel<Content: View>: View {
    let title: String
    let action: AnyView?
    let content: Content

    init(_ title: String, action: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: UtilityStyle.contentSpacing) {
                    Text(title).font(UtilityStyle.headingFont).accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    if let action { action.fixedSize() }
                }
                VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                    Text(title).font(UtilityStyle.headingFont).accessibilityAddTraits(.isHeader)
                    if let action {
                        HStack { Spacer(); action }
                    }
                }
            }
            .frame(minHeight: UtilityStyle.headerHeight)
            VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                content
            }
            .font(UtilityStyle.bodyFont)
            .padding(UtilityStyle.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .utilityCardBackground()
        }
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
