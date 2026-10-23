import AppKit
import SwiftUI

private struct HandPointerModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .pointerStyle(.link)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
    }
}

extension View {
    func handPointer() -> some View {
        modifier(HandPointerModifier())
    }
}

struct UtilityCapabilityMessage: Equatable {
    let title: String
    let detail: String?

    var combinedText: String {
        [title, detail]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

struct UtilityCapabilityCard: View {
    let title: String
    let isActive: Bool
    let detail: String?
    var action: AnyView? = nil

    init(title: String, isActive: Bool, detail: String? = nil, action: AnyView? = nil) {
        self.title = title
        self.isActive = isActive
        self.detail = detail
        self.action = action
    }

    init(message: UtilityCapabilityMessage, isActive: Bool, action: AnyView? = nil) {
        self.init(title: message.title, isActive: isActive, detail: message.detail, action: action)
    }

    private enum TitleCenterAlignment: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[VerticalAlignment.center]
        }
    }

    private static let titleCenter = VerticalAlignment(TitleCenterAlignment.self)

    private var statusContent: some View {
        HStack(alignment: Self.titleCenter, spacing: UtilityStyle.contentSpacing) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .alignmentGuide(Self.titleCenter) { $0[VerticalAlignment.center] }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: detail == nil ? 0 : UtilityStyle.capabilityDetailSpacing) {
                Text(title)
                    .alignmentGuide(Self.titleCenter) { $0[VerticalAlignment.center] }
                if let detail {
                    Text(detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(isActive ? UtilityStyle.successColor : UtilityStyle.warningColor)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UtilityStyle.contentSpacing) {
                statusContent
                Spacer(minLength: UtilityStyle.contentSpacing)
                if let action { action.fixedSize() }
            }
            VStack(alignment: .leading, spacing: UtilityStyle.contentSpacing) {
                statusContent
                if let action {
                    HStack { Spacer(); action }
                }
            }
        }
        .padding(UtilityStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .utilityCardBackground()
    }
}

struct UtilityTimestampRow: View {
    let date: Date
    var title = "Last Checked"
    var symbol = "checkmark.circle.fill"
    var color: Color = UtilityStyle.successColor
    var detail: String?

    var body: some View {
        HStack(spacing: UtilityStyle.contentSpacing) {
            Label(title, systemImage: symbol)
            Spacer()
            Text(timestampText)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(UtilityStyle.bodyFont)
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    static func timestampText(for date: Date, detail: String?) -> String {
        let timestamp = date.formatted(date: .abbreviated, time: .shortened)
        guard let detail, !detail.isEmpty else { return timestamp }
        return "\(timestamp) · \(detail)"
    }

    private var timestampText: String {
        Self.timestampText(for: date, detail: detail)
    }
}

struct HandCursorPicker<Option: Hashable & Identifiable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let optionTitle: (Option) -> String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: UtilityStyle.contentSpacing) {
                Text(title)
                Spacer()
                Text(optionTitle(selection)).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(UtilityStyle.Picker.indicatorFont)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handPointer()
        .accessibilityLabel(title)
        .accessibilityValue(optionTitle(selection))
        .popover(isPresented: $isPresented) {
            VStack(spacing: UtilityStyle.Picker.optionSpacing) {
                ForEach(options) { option in
                    Button {
                        selection = option
                        isPresented = false
                    } label: {
                        HStack(spacing: UtilityStyle.contentSpacing) {
                            Text(optionTitle(option))
                            Spacer()
                            Image(systemName: "checkmark").opacity(selection == option ? 1 : 0)
                        }
                        .padding(UtilityStyle.Picker.optionPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handPointer()
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
            .padding(UtilityStyle.Picker.padding)
            .frame(width: UtilityStyle.Picker.width)
        }
    }
}
