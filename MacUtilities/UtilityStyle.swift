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
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: UtilityStyle.cornerRadius))
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
