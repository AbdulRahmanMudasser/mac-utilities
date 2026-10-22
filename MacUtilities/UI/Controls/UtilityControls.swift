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
